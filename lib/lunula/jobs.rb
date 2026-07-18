# frozen_string_literal: true

require "date"
require "json"
require "socket"
require "time"
require "yaml"

module Lunula
  module Jobs
    class Error < Lunula::Error; end
    class TimeoutError < Error; end
    class CancelledError < Error; end
    Execution = Data.define(:id, :status, :error)
    Subscription = Data.define(:id, :listener)
    EXECUTION_CONTEXT_KEY = :__lunula_job_execution_context__

    class ExecutionContext
      attr_reader :timeout

      def initialize(timeout: nil, monotonic_clock: nil)
        @timeout = timeout && Float(timeout)
        raise ArgumentError, "job timeout must be positive" if @timeout && !@timeout.positive?

        @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @deadline = @timeout && @monotonic_clock.call + @timeout
        @state = nil
        @mutex = Mutex.new
      end

      def timeout!
        mark(:timeout)
      end

      def cancel!
        mark(:cancelled)
      end

      def lease_lost!
        @mutex.synchronize { @state = :lease_lost }
      end

      def state
        @mutex.synchronize { @state }
      end

      def checkpoint!
        poll!
        case state
        when :timeout then raise TimeoutError, "job exceeded its #{@timeout}-second cooperative timeout"
        when :cancelled then raise CancelledError, "job cancellation was requested"
        when :lease_lost then raise Durable::LeaseLost, "job no longer owns its lease"
        end
        true
      end

      def poll!
        timeout! if @deadline && @monotonic_clock.call >= @deadline
        state
      end

      private

      def mark(value)
        @mutex.synchronize { @state ||= value }
      end
    end

    module Serializer
      TYPE_KEY = "__lunula_type__"

      module_function

      def dump(args:, kwargs:)
        JSON.generate("args" => encode(args), "kwargs" => encode(kwargs))
      rescue JSON::GeneratorError => error
        raise Error, "job arguments are not JSON serializable: #{error.message}"
      end

      def load(payload)
        data = JSON.parse(payload)
        [decode(data.fetch("args")), symbolize_top_level(decode(data.fetch("kwargs")))]
      rescue JSON::ParserError, KeyError => error
        raise Error, "invalid durable job payload: #{error.message}"
      end

      def encode(value)
        case value
        when nil, true, false, String, Integer
          value
        when Float
          raise Error, "job arguments cannot contain non-finite numbers" unless value.finite?

          value
        when Symbol
          {TYPE_KEY => "symbol", "value" => value.to_s}
        when Time
          {TYPE_KEY => "time", "value" => value.iso8601(6)}
        when DateTime
          {TYPE_KEY => "datetime", "value" => value.iso8601(6)}
        when Date
          {TYPE_KEY => "date", "value" => value.iso8601}
        when Array
          value.map { |item| encode(item) }
        when Hash
          {
            TYPE_KEY => "hash",
            "value" => value.each_with_object({}) do |(key, item), encoded|
              encoded[key.to_s] = encode(item)
            end
          }
        else
          raise Error, "durable jobs only accept JSON values, symbols, dates, and times; got #{value.class}"
        end
      end

      def decode(value)
        case value
        when Array
          value.map { |item| decode(item) }
        when Hash
          if value.key?(TYPE_KEY)
            decode_typed(value)
          else
            value.transform_values { |item| decode(item) }
          end
        else
          value
        end
      end

      def decode_typed(value)
        case value.fetch(TYPE_KEY)
        when "hash" then value.fetch("value").transform_values { |item| decode(item) }
        when "symbol" then value.fetch("value").to_sym
        when "time" then Time.iso8601(value.fetch("value"))
        when "datetime" then DateTime.iso8601(value.fetch("value"))
        when "date" then Date.iso8601(value.fetch("value"))
        else raise Error, "unknown durable payload type: #{value[TYPE_KEY].inspect}"
        end
      end

      def symbolize_top_level(value)
        value.to_h { |key, item| [key.to_sym, item] }
      end
      private_class_method :encode, :decode, :decode_typed, :symbolize_top_level
    end

    class Configuration
      UNDEFINED = Object.new.freeze

      attr_reader :outbox

      def initialize(adapter: :inline, outbox: nil)
        @adapter = adapter
        @outbox = outbox
      end

      def adapter=(value)
        @adapter = value
        @async_adapter = nil unless value.to_s == "async"
      end

      def outbox=(value)
        @outbox = value
      end

      def adapter
        resolved = case @adapter
        when Symbol, String
          build_adapter(@adapter)
        else
          @adapter
        end
        Adapter.validate!(resolved)
      end

      private

      def build_adapter(name)
        case name.to_s
        when "inline"
          Adapters::Inline
        when "async"
          @async_adapter ||= Adapters::Async.new
        when "test"
          Adapters::Test
        when "database"
          raise Error, "database job adapter requires Lunula::Jobs::Adapters::Database.new(database: DB)"
        else
          raise Error, "unknown job adapter: #{name.inspect}"
        end
      end
    end

    module_function

    def subscribe(&listener)
      raise ArgumentError, "job notification subscription requires a block" unless listener

      notification_mutex.synchronize do
        subscription = Subscription.new(id: SecureRandom.uuid, listener:)
        notification_subscribers << subscription
        subscription
      end
    end

    def unsubscribe(subscription)
      notification_mutex.synchronize do
        notification_subscribers.delete_if { |candidate| candidate.id == subscription.id }
      end
      true
    end

    def instrument(event, payload = {})
      subscribers = notification_mutex.synchronize { notification_subscribers.dup }
      subscribers.each do |subscription|
        subscription.listener.call(event, payload)
      rescue StandardError => error
        Lunula.logger.error("job_notification_failed event=#{event} subscriber=#{subscription.id} error=#{error.class}: #{error.message}")
      end
      true
    end

    def with_execution_context(context)
      previous = Thread.current[EXECUTION_CONTEXT_KEY]
      Thread.current[EXECUTION_CONTEXT_KEY] = context
      yield
    ensure
      Thread.current[EXECUTION_CONTEXT_KEY] = previous
    end

    def execution_context
      Thread.current[EXECUTION_CONTEXT_KEY]
    end

    def checkpoint!
      execution_context&.checkpoint! || true
    end

    def cancelled?
      execution_context&.state == :cancelled
    end

    def timed_out?
      execution_context&.state == :timeout
    end

    def execution_timeout(job, default: nil)
      value = job.respond_to?(:timeout) ? job.timeout : default
      return if value.nil?

      timeout = Float(value)
      raise Error, "job timeout must be positive" unless timeout.positive? && timeout.finite?

      timeout
    rescue ArgumentError, TypeError
      raise Error, "job timeout must be a positive number of seconds"
    end

    def enqueue(adapter, job, args:, kwargs:, scheduled_at: nil, idempotency_key: nil)
      adapter = Adapter.validate!(adapter)
      scheduled_at = normalize_scheduled_at(scheduled_at)
      job_priority = priority(job)
      validate_metadata!(adapter, scheduled_at:, priority: job_priority)

      adapter.enqueue(
        job,
        args:,
        kwargs:,
        queue: queue_name(job),
        priority: job_priority,
        scheduled_at:,
        idempotency_key:
      )
    end

    def enqueue_all(adapter, entries)
      adapter = Adapter.validate!(adapter)
      normalized_entries = entries.map { |entry| normalize_enqueue_entry(entry) }
      normalized_entries.each do |entry|
        validate_metadata!(
          adapter,
          scheduled_at: normalize_scheduled_at(entry[:scheduled_at]),
          priority: entry[:priority] || priority(entry.fetch(:job))
        )
      end

      ids = if adapter.respond_to?(:enqueue_all)
        adapter.enqueue_all(normalized_entries)
      else
        normalized_entries.map do |entry|
          enqueue(
            adapter,
            entry.fetch(:job),
            args: entry.fetch(:args),
            kwargs: entry.fetch(:kwargs),
            scheduled_at: entry[:scheduled_at],
            idempotency_key: entry[:idempotency_key]
          )
        end
      end
      yield ids if block_given?
      ids
    end

    def validate_metadata!(adapter, scheduled_at:, priority:)
      Adapter.validate!(adapter)
      if scheduled_at && !Adapter.supports?(adapter, :scheduled) && !Adapter.supports?(adapter, :inline)
        raise Error, "job adapter #{adapter.inspect} does not support scheduled jobs"
      end
      if !priority.zero? && !Adapter.supports?(adapter, :priorities) && !Adapter.supports?(adapter, :inline)
        raise Error, "job adapter #{adapter.inspect} does not support job priorities"
      end
      true
    end

    def queue_name(job, default: "default")
      (job.respond_to?(:queue) ? job.queue : default).to_s
    end

    def priority(job)
      job.respond_to?(:priority) ? Integer(job.priority) : 0
    rescue ArgumentError, TypeError
      raise Error, "job priority must be an integer"
    end

    def unique_key(job, args:, kwargs:)
      return unless job.respond_to?(:unique_key)

      value = call_job_hook(job, :unique_key, args:, kwargs:)
      value.nil? || value.to_s.empty? ? nil : value.to_s
    end

    def unique_for(job)
      value = job.respond_to?(:unique_for) ? job.unique_for : 300
      seconds = Float(value)
      raise Error, "job unique_for must be positive seconds" unless seconds.positive? && seconds.finite?

      seconds
    rescue ArgumentError, TypeError
      raise Error, "job unique_for must be positive seconds"
    end

    def unique_conflict(job)
      value = job.respond_to?(:unique_conflict) ? job.unique_conflict : :keep
      conflict = value.to_sym
      return conflict if %i[keep raise].include?(conflict)

      raise Error, "job unique_conflict must be :keep or :raise"
    rescue NoMethodError
      raise Error, "job unique_conflict must be :keep or :raise"
    end

    def concurrency_key(job, args:, kwargs:)
      return unless job.respond_to?(:concurrency_key)

      value = call_job_hook(job, :concurrency_key, args:, kwargs:)
      value.nil? || value.to_s.empty? ? nil : value.to_s
    end

    def concurrency_limit(job)
      value = job.respond_to?(:concurrency_limit) ? job.concurrency_limit : 1
      limit = Integer(value)
      raise Error, "job concurrency_limit must be positive" unless limit.positive?

      limit
    rescue ArgumentError, TypeError
      raise Error, "job concurrency_limit must be positive"
    end

    def normalize_scheduled_at(value)
      return if value.nil?

      time = if value.respond_to?(:to_time)
        value.to_time
      elsif value.is_a?(Numeric)
        Time.at(value)
      end
      raise Error, "scheduled job time must be a Time, DateTime, or numeric timestamp" unless time

      time.utc
    end

    def normalize_enqueue_entry(entry)
      unless entry.is_a?(Hash)
        raise Error, "bulk job entries must be hashes with :job, :args, and :kwargs"
      end

      job = entry[:job] || entry["job"] || raise(Error, "bulk job entry requires :job")
      args = entry.key?(:args) ? entry[:args] : entry.fetch("args", [])
      kwargs = entry.key?(:kwargs) ? entry[:kwargs] : entry.fetch("kwargs", {})
      unless args.is_a?(Array)
        raise Error, "bulk job entry :args must be an array"
      end
      unless kwargs.is_a?(Hash)
        raise Error, "bulk job entry :kwargs must be a hash"
      end

      {
        job:,
        args:,
        kwargs: kwargs.transform_keys(&:to_sym),
        queue: entry[:queue] || entry["queue"],
        priority: entry.key?(:priority) ? entry[:priority] : entry["priority"],
        scheduled_at: entry.key?(:scheduled_at) ? entry[:scheduled_at] : entry["scheduled_at"],
        idempotency_key: entry[:idempotency_key] || entry["idempotency_key"]
      }
    end

    def perform(job, args:, kwargs:)
      raise Error, "#{job.inspect} must respond to perform" unless job.respond_to?(:perform)

      kwargs.empty? ? job.perform(*args) : job.perform(*args, **kwargs)
    end

    def call_job_hook(job, hook, args:, kwargs:)
      kwargs.empty? ? job.public_send(hook, *args) : job.public_send(hook, *args, **kwargs)
    rescue ArgumentError => error
      raise Error, "#{job_name(job)}.#{hook} must accept the same arguments as perform: #{error.message}"
    end

    def job_name(job)
      name = job.respond_to?(:name) ? job.name.to_s : ""
      raise Error, "durable job must be a named module or class" if name.empty?

      name
    end

    def constantize(name)
      name.split("::").inject(Object) { |scope, constant| scope.const_get(constant) }
    rescue NameError
      raise Error, "durable job class is not loaded: #{name}"
    end

    def notification_subscribers
      @notification_subscribers ||= []
    end

    def notification_mutex
      @notification_mutex ||= Mutex.new
    end
  end
end

require_relative "jobs/recurring"
require_relative "jobs/adapters"
require_relative "jobs/worker"
