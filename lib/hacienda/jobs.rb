# frozen_string_literal: true

require "date"
require "json"
require "socket"
require "time"
require "yaml"

module Hacienda
  module Jobs
    class Error < Hacienda::Error; end
    class TimeoutError < Error; end
    class CancelledError < Error; end
    Execution = Data.define(:id, :status, :error)
    Subscription = Data.define(:id, :listener)
    EXECUTION_CONTEXT_KEY = :__hacienda_job_execution_context__

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
      TYPE_KEY = "__hacienda_type__"

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
          raise Error, "database job adapter requires Hacienda::Jobs::Adapters::Database.new(database: DB)"
        else
          raise Error, "unknown job adapter: #{name.inspect}"
        end
      end
    end

    class RecurringSchedule
      Entry = Data.define(:name, :job_class, :interval, :args, :kwargs, :queue, :priority, :enabled)

      class << self
        def load(path)
          raise Error, "recurring schedule file not found: #{path}" unless File.file?(path)

          data = YAML.safe_load_file(path, aliases: false) || {}
          new(data, path:)
        rescue Psych::SyntaxError => error
          raise Error, "invalid recurring schedule #{path}: #{error.message}"
        end

        def set_enabled(path, name, enabled)
          raise Error, "recurring schedule file not found: #{path}" unless File.file?(path)

          data = YAML.safe_load_file(path, aliases: false) || {}
          tasks = tasks_hash(data)
          task = tasks[name.to_s] || raise(Error, "recurring task not found: #{name}")
          task["enabled"] = enabled
          File.write(path, YAML.dump(data))
          true
        end

        def tasks_hash(data)
          tasks = data.fetch("tasks", data)
          unless tasks.is_a?(Hash)
            raise Error, "recurring schedule must be a mapping or contain a tasks mapping"
          end

          tasks
        end
      end

      attr_reader :path, :entries

      def initialize(data, path:)
        @path = path
        @entries = self.class.tasks_hash(data).map do |name, attributes|
          build_entry(name, attributes || {})
        end.freeze
      end

      def enabled_entries
        entries.select(&:enabled)
      end

      def find(name)
        entries.find { |entry| entry.name == name.to_s }
      end

      def due_at(entry, now)
        timestamp = normalize_time(now).to_i
        Time.at(timestamp - (timestamp % entry.interval)).utc
      end

      private

      def build_entry(name, attributes)
        unless attributes.is_a?(Hash)
          raise Error, "recurring task #{name.inspect} must be a mapping"
        end

        job_class = required_string(attributes, "job", name)
        interval = parse_interval(attributes.fetch("every") { raise Error, "recurring task #{name.inspect} requires every" })
        args = attributes.fetch("args", [])
        kwargs = attributes.fetch("kwargs", {})
        unless args.is_a?(Array)
          raise Error, "recurring task #{name.inspect} args must be an array"
        end
        unless kwargs.is_a?(Hash)
          raise Error, "recurring task #{name.inspect} kwargs must be a mapping"
        end

        Entry.new(
          name: name.to_s,
          job_class:,
          interval:,
          args:,
          kwargs: kwargs.transform_keys(&:to_sym),
          queue: attributes["queue"]&.to_s,
          priority: attributes.key?("priority") ? Integer(attributes["priority"]) : nil,
          enabled: attributes.fetch("enabled", true) != false
        )
      rescue ArgumentError, TypeError
        raise Error, "recurring task #{name.inspect} priority must be an integer"
      end

      def required_string(attributes, key, name)
        value = attributes[key].to_s.strip
        raise Error, "recurring task #{name.inspect} requires #{key}" if value.empty?

        value
      end

      def parse_interval(value)
        return integer_interval(value) if value.is_a?(Numeric)

        text = value.to_s.strip.downcase
        match = text.match(/\A(\d+)\s*(s|sec|second|seconds|m|min|minute|minutes|h|hour|hours|d|day|days)\z/)
        raise Error, "recurring every value must look like '5 minutes', '1 hour', or an integer number of seconds" unless match

        count = Integer(match[1])
        unit = match[2]
        multiplier = case unit
        when "s", "sec", "second", "seconds" then 1
        when "m", "min", "minute", "minutes" then 60
        when "h", "hour", "hours" then 3600
        when "d", "day", "days" then 86_400
        end
        integer_interval(count * multiplier)
      end

      def integer_interval(value)
        seconds = Integer(value)
        raise Error, "recurring interval must be positive" unless seconds.positive?

        seconds
      rescue ArgumentError, TypeError
        raise Error, "recurring interval must be positive seconds"
      end

      def normalize_time(value)
        value.respond_to?(:to_time) ? value.to_time.utc : value
      end
    end

    class RecurringScheduler
      Result = Data.define(:entry, :scheduled_at, :job_id)

      attr_reader :database, :adapter, :path, :table, :clock, :poll_interval

      def initialize(database:, adapter:, path:, table: :hacienda_recurring_runs, clock: nil, poll_interval: 60)
        @database = database
        @adapter = Adapter.validate!(adapter)
        @path = path
        @table = table.to_sym
        @clock = clock || -> { Time.now.utc }
        @poll_interval = Float(poll_interval)
        @stopping = false
        raise ArgumentError, "recurring scheduler poll interval cannot be negative" if @poll_interval.negative?
      end

      def schedule
        RecurringSchedule.load(path)
      end

      def tick
        current_time = now
        current_schedule = schedule
        current_schedule.enabled_entries.filter_map do |entry|
          enqueue_entry(entry, scheduled_at: current_schedule.due_at(entry, current_time), current_time:)
        end
      end

      def trigger(name)
        entry = schedule.find(name) || raise(Error, "recurring task not found: #{name}")
        enqueue_entry(entry, scheduled_at: now, current_time: now, manual: true)
      end

      def stop
        @stopping = true
        self
      end

      def stopping?
        @stopping
      end

      def run
        until stopping?
          results = tick
          yield results if block_given?
          sleep poll_interval if results.empty? && poll_interval.positive? && !stopping?
        end
        self
      end

      private

      def enqueue_entry(entry, scheduled_at:, current_time:, manual: false)
        database.transaction do
          database[table].insert(
            task_name: entry.name,
            scheduled_at:,
            manual:,
            enqueued_job_id: nil,
            created_at: current_time
          )
          job = Jobs.constantize(entry.job_class)
          job_id = adapter.enqueue(
            job,
            args: entry.args,
            kwargs: entry.kwargs,
            queue: entry.queue,
            priority: entry.priority,
            scheduled_at: current_time,
            idempotency_key: "recurring:#{entry.name}:#{scheduled_at.to_i}"
          )
          database[table]
            .where(task_name: entry.name, scheduled_at:)
            .update(enqueued_job_id: job_id)
          Result.new(entry:, scheduled_at:, job_id:)
        end
      rescue Sequel::UniqueConstraintViolation
        nil
      rescue Sequel::DatabaseError => error
        raise Error, recurring_error(error)
      end

      def now
        value = clock.call
        value.respond_to?(:to_time) ? value.to_time.utc : value
      end

      def recurring_error(error)
        if error.message.match?(/no such table|does not exist/i)
          "recurring runs table #{table.inspect} is missing; run hac db:migrate"
        else
          error.message
        end
      end
    end

    module Adapters
      module Inline
        module_function

        def capabilities = %i[inline]

        def enqueue(job, args:, kwargs:, queue: nil, priority: nil, scheduled_at: nil, idempotency_key: nil)
          Jobs.perform(job, args:, kwargs:)
        end
      end

      class Async
        Item = Data.define(:job, :args, :kwargs, :priority, :scheduled_at, :sequence)

        def initialize(clock: nil)
          @clock = clock || -> { Time.now.utc }
          @mutex = Mutex.new
          @condition = ConditionVariable.new
          @items = []
          @sequence = 0
          @thread = nil
          @stopping = false
        end

        def capabilities = %i[asynchronous scheduled priorities]

        def enqueue(job, args:, kwargs:, queue: nil, priority: nil, scheduled_at: nil, idempotency_key: nil)
          @mutex.synchronize do
            start_locked
            @sequence += 1
            @items << Item.new(
              job:,
              args:,
              kwargs:,
              priority: priority || Jobs.priority(job),
              scheduled_at: Jobs.normalize_scheduled_at(scheduled_at) || now,
              sequence: @sequence
            )
            @condition.signal
          end
          true
        end

        def shutdown
          thread = @mutex.synchronize do
            @stopping = true
            @condition.broadcast
            @thread
          end
          return unless thread

          thread.join(1)
          @mutex.synchronize do
            unless thread.alive?
              @thread = nil
              @items.clear
              @stopping = false
            end
          end
        end

        private

        def start_locked
          return if @thread&.alive?

          @stopping = false
          @thread = Thread.new do
            Thread.current.name = "hacienda-jobs" if Thread.current.respond_to?(:name=)

            while (item = next_item)
              begin
                Jobs.perform(item.job, args: item.args, kwargs: item.kwargs)
              rescue StandardError => error
                Hacienda.logger.error("#{error.class}: #{error.message}\n#{Array(error.backtrace).join("\n")}")
              end
            end
          end
        end

        def next_item
          @mutex.synchronize do
            loop do
              return if @stopping

              current_time = now
              ready = @items.select { |item| item.scheduled_at <= current_time }
              unless ready.empty?
                item = ready.min_by { |candidate| [candidate.priority, candidate.scheduled_at, candidate.sequence] }
                @items.delete(item)
                return item
              end

              next_time = @items.map(&:scheduled_at).min
              wait = next_time ? [next_time - current_time, 0].max : nil
              @condition.wait(@mutex, wait)
            end
          end
        end

        def now
          value = @clock.call
          value.respond_to?(:to_time) ? value.to_time.utc : value
        end
      end

      class Database
        attr_reader :database, :table, :queue, :workers_table, :queues_table, :lease_seconds,
          :heartbeat_interval, :default_execution_timeout, :worker_timeout,
          :completed_retention, :discarded_retention, :failed_retention

        def initialize(
          database:,
          table: :hacienda_jobs,
          workers_table: :hacienda_job_workers,
          queues_table: :hacienda_job_queues,
          queue: "default",
          lease_seconds: 300,
          heartbeat_interval: nil,
          execution_timeout: nil,
          worker_timeout: nil,
          retry_delay: nil,
          completed_retention: 7 * 24 * 60 * 60,
          discarded_retention: 30 * 24 * 60 * 60,
          failed_retention: 30 * 24 * 60 * 60,
          clock: nil
        )
          @database = database
          @table = table.to_sym
          @workers_table = workers_table.to_sym
          @queues_table = queues_table.to_sym
          @queue = queue.to_s
          @queue_cursor = 0
          @queue_mutex = Mutex.new
          @clock = clock || -> { Time.now.utc }
          @lease_seconds = Float(lease_seconds)
          @heartbeat_interval = Float(heartbeat_interval || [@lease_seconds / 3.0, 30.0].min)
          @default_execution_timeout = execution_timeout && Float(execution_timeout)
          @worker_timeout = Float(worker_timeout || [@lease_seconds * 2.0, 60.0].max)
          @completed_retention = normalize_retention(completed_retention)
          @discarded_retention = normalize_retention(discarded_retention)
          @failed_retention = normalize_retention(failed_retention)
          raise ArgumentError, "heartbeat_interval must be positive and shorter than lease_seconds" unless @heartbeat_interval.positive? && @heartbeat_interval < @lease_seconds
          if @default_execution_timeout && (!@default_execution_timeout.positive? || !@default_execution_timeout.finite?)
            raise ArgumentError, "execution_timeout must be positive and finite"
          end
          raise ArgumentError, "worker_timeout must be positive" unless @worker_timeout.positive?
          @durable_queue = Durable::Queue.new(
            database:,
            table:,
            lease_seconds: @lease_seconds,
            retry_delay:,
            clock: @clock,
            order: %i[priority available_at id],
            complete_attributes: ->(at) do
              {
                completed_at: at,
                locked_at: nil,
                locked_by: nil,
                worker_id: nil,
                last_error: nil,
                failure_kind: nil,
                cancel_requested_at: nil,
                updated_at: at
              }
            end,
            terminal_attributes: ->(at) { {discarded_at: at} },
            terminal_filters: {completed_at: nil, discarded_at: nil}
          )
        end

        def capabilities = %i[durable transactional worker scheduled priorities uniqueness concurrency bulk]

        def transactional_with?(candidate)
          database.equal?(candidate)
        end

        def enqueue(job, args:, kwargs:, queue: nil, priority: nil, scheduled_at: nil, idempotency_key: nil)
          attributes = build_job_attributes(
            job,
            args:,
            kwargs:,
            queue:,
            priority:,
            scheduled_at:,
            current_time: now
          )
          id = insert_job_attributes(attributes, job)
          Jobs.instrument(:enqueue, id:, job_class: attributes.fetch(:job_class), queue: attributes.fetch(:queue), scheduled_at:)
          id
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def enqueue_all(entries)
          normalized_entries = entries.map { |entry| Jobs.normalize_enqueue_entry(entry) }
          ids = []
          database.transaction do
            normalized_entries.each do |entry|
              attributes = build_job_attributes(
                entry.fetch(:job),
                args: entry.fetch(:args),
                kwargs: entry.fetch(:kwargs),
                queue: entry[:queue],
                priority: entry[:priority],
                scheduled_at: entry[:scheduled_at],
                current_time: now
              )
              ids << insert_job_attributes(attributes, entry.fetch(:job))
            end
          end
          Jobs.instrument(:enqueue_bulk, ids:, count: ids.length)
          ids
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def build_job_attributes(job, args:, kwargs:, queue: nil, priority: nil, scheduled_at: nil, current_time:)
          job_name = Jobs.job_name(job)
          max_attempts = job.respond_to?(:max_attempts) ? Integer(job.max_attempts) : 10
          raise Error, "job max_attempts must be positive" unless max_attempts.positive?

          queue_name = queue || (job.respond_to?(:queue) ? job.queue.to_s : self.queue)
          unique_key = Jobs.unique_key(job, args:, kwargs:)
          unique_until = unique_key && current_time + Jobs.unique_for(job)
          concurrency_key = Jobs.concurrency_key(job, args:, kwargs:)
          concurrency_limit = concurrency_key && Jobs.concurrency_limit(job)
          attributes = queue_block_attributes(queue_name, at: current_time)
          attributes.merge(
            queue: queue_name,
            priority: priority || Jobs.priority(job),
            job_class: job_name,
            payload: Serializer.dump(args:, kwargs:),
            attempts: 0,
            max_attempts:,
            available_at: Jobs.normalize_scheduled_at(scheduled_at) || current_time,
            locked_at: nil,
            locked_by: nil,
            last_error: nil,
            failed_at: nil,
            unique_key:,
            unique_until:,
            concurrency_key:,
            concurrency_limit:,
            created_at: current_time,
            updated_at: current_time
          )
        end

        def insert_job_attributes(attributes, job)
          current_time = now
          unique_key = attributes[:unique_key]
          id = database.transaction(savepoint: true) do
            if unique_key
              existing = dataset
                .where(unique_key:)
                .where(discarded_at: nil)
                .order(:id)
                .all
                .find { |row| future_wall_time?(row[:unique_until], current_time) }
              if existing
                case Jobs.unique_conflict(job)
                when :keep
                  existing.fetch(:id)
                when :raise
                  raise Error, "unique job already exists for #{unique_key.inspect}"
                end
              else
                dataset.insert(attributes)
              end
            else
              dataset.insert(attributes)
            end
          end
          id
        end

        def work_once(queue: self.queue)
          claim = claim_many(queues: [queue], limit: 1).first
          return unless claim

          perform_claim(claim)
        end

        def claim_many(queues:, limit:, worker_id: nil)
          recover_abandoned_workers if worker_id
          selected = normalize_queues(queues)
          claim_attributes = {blocked_at: nil, blocked_reason: nil}
          claim_attributes[:worker_id] = worker_id.to_s if worker_id
          return @durable_queue.claim_many(limit:, filters: {}, claim_attributes:, before_claim: method(:claim_allowed?)) if selected == :all

          limit = Integer(limit)
          raise ArgumentError, "claim limit must be positive" unless limit.positive?

          start = @queue_mutex.synchronize do
            current = @queue_cursor
            @queue_cursor = (@queue_cursor + 1) % selected.length
            current
          end
          claims = []
          empty_queues = 0
          offset = 0
          while claims.length < limit && empty_queues < selected.length
            queue_name = selected[(start + offset) % selected.length]
            claim = @durable_queue.claim(filters: {queue: queue_name}, claim_attributes:, before_claim: method(:claim_allowed?))
            if claim
              claims << claim
              empty_queues = 0
            else
              empty_queues += 1
            end
            offset += 1
          end
          claims
        end

        def perform_claim(claim)
          context = nil
          monitor = nil
          begin
            args, kwargs = Serializer.load(claim.row.fetch(:payload))
            job = Jobs.constantize(claim.row.fetch(:job_class))
            context = ExecutionContext.new(timeout: Jobs.execution_timeout(job, default: default_execution_timeout))
            monitor = start_claim_monitor(claim, context)
            Jobs.instrument(:start, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue), attempt: claim.row.fetch(:attempts))
            Jobs.with_execution_context(context) do
              Jobs.perform(job, args:, kwargs:)
              context.cancel! if cancellation_requested?(claim)
              Jobs.checkpoint!
            end
            @durable_queue.complete(claim)
            Jobs.instrument(:finish, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue), status: :succeeded)
            Execution.new(id: claim.row.fetch(:id), status: :succeeded, error: nil)
          rescue TimeoutError => error
            outcome = @durable_queue.fail_claim(
              claim,
              error,
              kind: "timeout",
              release_attributes: {worker_id: nil}
            )
            status = outcome ? :timed_out : :lease_lost
            Jobs.instrument(:timeout, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue), status:)
            Jobs.instrument(:discard, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue), kind: "timeout") if outcome == :terminal
            Execution.new(id: claim.row.fetch(:id), status:, error:)
          rescue CancelledError => error
            @durable_queue.terminate_claim(
              claim,
              error,
              kind: "cancelled",
              release_attributes: {worker_id: nil, cancelled_at: now, cancel_requested_at: nil}
            )
            Jobs.instrument(:discard, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue), kind: "cancelled")
            Execution.new(id: claim.row.fetch(:id), status: :cancelled, error:)
          rescue Durable::LeaseLost => error
            Jobs.instrument(:lease_loss, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue))
            Execution.new(id: claim.row.fetch(:id), status: :lease_lost, error:)
          rescue StandardError => error
            outcome = @durable_queue.fail_claim(
              claim,
              error,
              kind: "error",
              release_attributes: {worker_id: nil}
            )
            status = if outcome == :terminal
              :failed
            elsif outcome == :retrying
              :retrying
            else
              :lease_lost
            end
            case status
            when :retrying
              Jobs.instrument(:retry, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue), error: error.message)
            when :failed
              Jobs.instrument(:discard, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue), kind: "error", error: error.message)
            when :lease_lost
              Jobs.instrument(:lease_loss, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue))
            end
            Execution.new(id: claim.row.fetch(:id), status:, error:)
          ensure
            stop_claim_monitor(monitor)
          end
        end

        def register_worker(attributes)
          database[workers_table].insert(attributes)
          true
        rescue Sequel::DatabaseError => error
          raise Error, worker_error(error)
        end

        def heartbeat_worker(id, current_workload: nil)
          attributes = {last_heartbeat_at: now}
          attributes[:current_workload] = Integer(current_workload) unless current_workload.nil?
          database[workers_table].where(id:).update(attributes) == 1
        rescue Sequel::DatabaseError => error
          raise Error, worker_error(error)
        end

        def unregister_worker(id)
          database[workers_table].where(id:).delete
          true
        rescue Sequel::DatabaseError => error
          raise Error, worker_error(error)
        end

        def workers
          database[workers_table].order(:started_at, :id).all
        rescue Sequel::DatabaseError => error
          raise Error, worker_error(error)
        end

        def paused_queues
          database[queues_table].order(:queue).all
        rescue Sequel::DatabaseError => error
          raise Error, queue_error(error)
        end

        def pause_queue(queue, by: nil)
          queue_name = queue.to_s
          raise Error, "queue name is required" if queue_name.empty?

          current_time = now
          database.transaction do
            changed = database[queues_table]
              .where(queue: queue_name)
              .update(paused_at: current_time, paused_by: by&.to_s, updated_at: current_time)
            if changed.zero?
              database[queues_table].insert(
                queue: queue_name,
                paused_at: current_time,
                paused_by: by&.to_s,
                created_at: current_time,
                updated_at: current_time
              )
            end
            active_scope.where(queue: queue_name, locked_at: nil).update(
              blocked_at: current_time,
              blocked_reason: paused_reason(queue_name),
              updated_at: current_time
            )
          end
          true
        rescue Sequel::DatabaseError => error
          raise Error, queue_error(error)
        end

        def resume_queue(queue)
          queue_name = queue.to_s
          raise Error, "queue name is required" if queue_name.empty?

          current_time = now
          database.transaction do
            database[queues_table].where(queue: queue_name).delete
            active_scope
              .where(queue: queue_name, locked_at: nil, blocked_reason: paused_reason(queue_name))
              .update(blocked_at: nil, blocked_reason: nil, updated_at: current_time)
          end
          true
        rescue Sequel::DatabaseError => error
          raise Error, queue_error(error)
        end

        def discard(id, reason: nil)
          current_time = now
          active_scope
            .where(id: Integer(id), locked_at: nil)
            .update(
              failed_at: current_time,
              discarded_at: current_time,
              failure_kind: "discarded",
              last_error: "Hacienda::Jobs::Discarded: #{reason || "discarded by operator"}",
              blocked_at: nil,
              blocked_reason: nil,
              updated_at: current_time
            ) == 1
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def reschedule(id, at:)
          scheduled_at = Jobs.normalize_scheduled_at(at) || now
          row = active_scope.where(id: Integer(id), locked_at: nil).first
          return false unless row

          current_time = now
          active_scope
            .where(id: row.fetch(:id), locked_at: nil)
            .update({
              available_at: scheduled_at,
              updated_at: current_time
            }.merge(queue_block_attributes(row.fetch(:queue), at: current_time))) == 1
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def failed
          @durable_queue.failed
        end

        def pending
          current_time = now
          active_scope
            .where(locked_at: nil)
            .where(blocked_at: nil)
            .where { available_at <= current_time }
            .order(:priority, :available_at, :id)
            .all
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def running
          active_scope
            .exclude(locked_at: nil)
            .order(:locked_at, :id)
            .all
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def blocked(limit: 50)
          limited(
            active_scope
              .where(locked_at: nil)
              .exclude(blocked_at: nil)
              .order(:blocked_at, :priority, :available_at, :id),
            limit
          ).all
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def completed(limit: 50)
          limited(dataset.exclude(completed_at: nil).reverse_order(:completed_at, :id), limit).all
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def discarded(limit: 50)
          limited(dataset.exclude(discarded_at: nil).reverse_order(:discarded_at, :id), limit).all
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def status
          current_time = now
          oldest = pending.first
          {
            pending: pending.length,
            scheduled: scheduled.length,
            running: running.length,
            blocked: blocked.length,
            paused_queues: paused_queues.length,
            completed: dataset.exclude(completed_at: nil).count,
            discarded: dataset.exclude(discarded_at: nil).count,
            failed: dataset.exclude(failed_at: nil).count,
            workers: workers.length,
            oldest_pending_age: oldest && (current_time - wall_time_utc(oldest.fetch(:created_at))).to_i,
            completed_last_minute: dataset.where { completed_at >= current_time - 60 }.count,
            completed_last_hour: dataset.where { completed_at >= current_time - 3600 }.count
          }
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def health(pending_warn_after: 300, pending_critical_after: 3600)
          current_time = now
          metrics = status
          stale_workers = workers.select do |row|
            timestamp = row[:last_heartbeat_at]
            timestamp && wall_time_utc(timestamp) <= current_time - worker_timeout
          end
          oldest_age = metrics[:oldest_pending_age].to_i if metrics[:oldest_pending_age]

          level = "ok"
          level = "warn" if metrics.fetch(:failed).positive? || stale_workers.any? ||
            (oldest_age && oldest_age >= pending_warn_after)
          level = "critical" if oldest_age && oldest_age >= pending_critical_after

          {
            status: level,
            generated_at: current_time,
            checks: {
              failed_jobs: metrics.fetch(:failed),
              stale_workers: stale_workers.length,
              oldest_pending_age: metrics[:oldest_pending_age],
              paused_queues: metrics.fetch(:paused_queues),
              running_jobs: metrics.fetch(:running)
            }
          }
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def prune(completed_before: nil, discarded_before: nil, failed_before: nil)
          counts = {completed: 0, discarded: 0, failed: 0}
          database.transaction do
            if completed_before
              counts[:completed] = dataset.where { completed_at <= completed_before }.delete
            end
            if discarded_before
              counts[:discarded] = dataset.where { discarded_at <= discarded_before }.delete
            end
            if failed_before
              counts[:failed] = dataset.where { failed_at <= failed_before }.delete
            end
          end
          counts
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def retry_failed(id)
          @durable_queue.retry_failed(
            id,
            reset_attributes: {
              worker_id: nil,
              cancel_requested_at: nil,
              cancelled_at: nil,
              discarded_at: nil,
              blocked_at: nil,
              blocked_reason: nil
            }
          )
        end

        def cancel(id)
          row = database[table].where(id: Integer(id)).first
          return false unless row

          current_time = now
          if row[:locked_at]
            database[table].where(id: row.fetch(:id), locked_by: row[:locked_by]).update(
              cancel_requested_at: current_time,
              updated_at: current_time
            ) == 1
          else
            active_scope.where(id: row.fetch(:id)).update(
              failed_at: current_time,
              discarded_at: current_time,
              cancelled_at: current_time,
              cancel_requested_at: nil,
              failure_kind: "cancelled",
              last_error: "Hacienda::Jobs::CancelledError: job cancellation was requested",
              updated_at: current_time
            ) == 1
          end
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def pending_count
          @durable_queue.pending_count
        end

        def scheduled
          current_time = now
          active_scope
            .where(locked_at: nil)
            .where(blocked_at: nil)
            .where { available_at > current_time }
            .order(:available_at, :priority, :id)
            .all
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        private

        Monitor = Data.define(:thread, :mutex, :condition, :state)

        def start_claim_monitor(claim, context)
          mutex = Mutex.new
          condition = ConditionVariable.new
          state = {stopped: false}
          thread = Thread.new do
            loop do
              stopped = mutex.synchronize do
                condition.wait(mutex, heartbeat_interval) unless state[:stopped]
                state[:stopped]
              end
              break if stopped

              begin
                @durable_queue.renew(claim)
                worker_id = claim.row[:worker_id]
                heartbeat_worker(worker_id) if worker_id
                context.cancel! if cancellation_requested?(claim)
                context.poll!
              rescue Durable::LeaseLost
                context.lease_lost!
                break
              rescue Durable::Error, Error => error
                Hacienda.logger.error("job_lease_renewal_failed job_id=#{claim.row.fetch(:id)} error=#{error.class}: #{error.message}")
              end
            end
          end
          Monitor.new(thread:, mutex:, condition:, state:)
        end

        def stop_claim_monitor(monitor)
          return unless monitor

          monitor.mutex.synchronize do
            monitor.state[:stopped] = true
            monitor.condition.broadcast
          end
          monitor.thread.join
        end

        def cancellation_requested?(claim)
          !database[table]
            .where(id: claim.row.fetch(:id), locked_by: claim.token)
            .get(:cancel_requested_at)
            .nil?
        end

        def claim_allowed?(row)
          if queue_paused?(row.fetch(:queue))
            current_time = now
            dataset.where(id: row.fetch(:id), locked_at: nil).update(
              blocked_at: current_time,
              blocked_reason: paused_reason(row.fetch(:queue)),
              updated_at: current_time
            )
            return false
          end

          key = row[:concurrency_key].to_s
          limit = row[:concurrency_limit].to_i
          return true if key.empty? || !limit.positive?

          running = active_scope
            .where(concurrency_key: key)
            .exclude(locked_at: nil)
            .count
          if running >= limit
            current_time = now
            dataset.where(id: row.fetch(:id), locked_at: nil).update(
              blocked_at: current_time,
              blocked_reason: "concurrency limit #{limit} reached for #{key}",
              updated_at: current_time
            )
            false
          else
            true
          end
        end

        def recover_abandoned_workers
          current_time = now
          cutoff = current_time - worker_timeout
          stale_ids = database[workers_table].where { last_heartbeat_at <= cutoff }.select_map(:id)
          return 0 if stale_ids.empty?

          recovered = 0
          database.transaction do
            scope = database[table]
              .where(worker_id: stale_ids, failed_at: nil)
              .exclude(locked_at: nil)
            retryable = scope.where { attempts < max_attempts }
            recovered += retryable.update(
              available_at: current_time,
              locked_at: nil,
              locked_by: nil,
              worker_id: nil,
              failure_kind: "abandoned",
              last_error: "Hacienda::Jobs::Error: worker heartbeat expired",
              updated_at: current_time
            )
            exhausted = scope.where { attempts >= max_attempts }
            recovered += exhausted.update(
              locked_at: nil,
              locked_by: nil,
              worker_id: nil,
              failed_at: current_time,
              discarded_at: current_time,
              failure_kind: "abandoned",
              last_error: "Hacienda::Jobs::Error: worker heartbeat expired after final attempt",
              updated_at: current_time
            )
            database[workers_table].where(id: stale_ids).delete
          end
          recovered
        rescue Sequel::DatabaseError => error
          raise Error, worker_error(error)
        end

        def normalize_queues(values)
          return :all if values == :all

          queues = Array(values).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:empty?)
          return :all if queues.include?("*") || queues.include?("all")
          raise ArgumentError, "at least one queue is required" if queues.empty?

          queues.uniq
        end

        def active_scope
          dataset.where(failed_at: nil, completed_at: nil, discarded_at: nil)
        end

        def dataset
          database[table]
        end

        def limited(scope, limit)
          limit ? scope.limit(Integer(limit)) : scope
        end

        def queue_block_attributes(queue, at:)
          if queue_paused?(queue)
            {blocked_at: at, blocked_reason: paused_reason(queue)}
          else
            {blocked_at: nil, blocked_reason: nil}
          end
        end

        def queue_paused?(queue)
          database[queues_table].where(queue: queue.to_s).count.positive?
        rescue Sequel::DatabaseError
          false
        end

        def paused_reason(queue)
          "queue #{queue} is paused"
        end

        def normalize_retention(value)
          return if value.nil? || value == false

          seconds = Float(value)
          raise ArgumentError, "job retention values must be positive seconds" unless seconds.positive? && seconds.finite?

          seconds
        end

        def future_wall_time?(value, current_time)
          return false unless value

          time = value.respond_to?(:to_time) ? value.to_time : value
          time.strftime("%Y%m%d%H%M%S.%6N") > current_time.strftime("%Y%m%d%H%M%S.%6N")
        end

        def wall_time_utc(value)
          time = value.respond_to?(:to_time) ? value.to_time : value
          return time unless time.respond_to?(:year)

          Time.utc(time.year, time.month, time.day, time.hour, time.min, time.sec, time.respond_to?(:usec) ? time.usec : 0)
        end

        def now
          value = @clock.call
          value.respond_to?(:to_time) ? value.to_time.utc : value
        end

        def durable_error(error)
          SQLite.report_busy(error, source: "jobs", table:)
          if error.message.match?(/no such table|does not exist/i)
            "durable jobs table #{table.inspect} is missing; run hac db:migrate"
          else
            error.message
          end
        end

        def worker_error(error)
          SQLite.report_busy(error, source: "jobs_workers", table: workers_table)
          if error.message.match?(/no such table|does not exist/i)
            "job workers table #{workers_table.inspect} is missing; run hac db:migrate"
          else
            error.message
          end
        end

        def queue_error(error)
          SQLite.report_busy(error, source: "jobs_queues", table: queues_table)
          if error.message.match?(/no such table|does not exist/i)
            "job queues table #{queues_table.inspect} is missing; run hac db:migrate"
          else
            error.message
          end
        end
      end

      module Test
        module_function

        def capabilities = %i[test scheduled priorities]

        def enqueue(job, args:, kwargs:, queue: nil, priority: nil, scheduled_at: nil, idempotency_key: nil)
          enqueued_jobs << {
            job:,
            args:,
            kwargs:,
            queue:,
            priority: priority || Jobs.priority(job),
            scheduled_at:,
            idempotency_key:
          }
          true
        end

        def enqueued_jobs
          @enqueued_jobs ||= []
        end

        def clear
          enqueued_jobs.clear
        end

        def perform_enqueued_jobs
          jobs = enqueued_jobs.dup
          clear
          jobs.each { |entry| Jobs.perform(entry.fetch(:job), args: entry.fetch(:args), kwargs: entry.fetch(:kwargs)) }
          jobs.length
        end
      end
    end

    class Worker
      Result = Data.define(:jobs, :handoffs, :events) do
        def empty?
          [jobs, handoffs, events].all? { |value| value.nil? || (value.respond_to?(:empty?) && value.empty?) }
        end
      end

      attr_reader :adapter, :job_outbox, :outbox, :events, :queues,
        :poll_interval, :thread_count, :batch_size, :id, :process_id,
        :hostname, :started_at, :current_workload

      def initialize(
        adapter:,
        job_outbox: nil,
        outbox: nil,
        events: nil,
        queue: nil,
        queues: nil,
        threads: 1,
        batch_size: nil,
        poll_interval: 1.0,
        id: nil
      )
        Adapter.validate!(adapter)
        direct_worker = adapter.respond_to?(:work_once)
        handoff_relay = job_outbox
        unless direct_worker || handoff_relay || outbox
          raise Error, "hac jobs:work requires a worker-capable adapter or a configured outbox"
        end

        @adapter = adapter
        @job_outbox = handoff_relay
        @outbox = outbox
        @events = events
        @queues = normalize_queues(queues || queue || ["default"])
        @thread_count = Integer(threads)
        @batch_size = Integer(batch_size || @thread_count)
        @poll_interval = Float(poll_interval)
        @id = id || SecureRandom.uuid
        @process_id = Process.pid
        @hostname = Socket.gethostname
        @started_at = nil
        @current_workload = 0
        @registered = false
        @stopping = false
        raise ArgumentError, "worker threads must be positive" unless @thread_count.positive?
        raise ArgumentError, "worker batch_size must be positive" unless @batch_size.positive?
        raise ArgumentError, "poll_interval cannot be negative" if @poll_interval.negative?
      end

      def queue
        queues == :all ? "*" : queues.first
      end

      def work_once
        return Result.new(jobs: nil, handoffs: nil, events: nil) if stopping?

        job_execution = perform_direct_work
        return Result.new(jobs: job_execution, handoffs: nil, events: nil) if stopping?

        handoff_execution = job_outbox&.dispatch_once(adapter:)
        return Result.new(jobs: job_execution, handoffs: handoff_execution, events: nil) if stopping?

        Result.new(
          jobs: job_execution,
          handoffs: handoff_execution,
          events: outbox&.dispatch_once(events:)
        )
      end

      def stop
        @stopping = true
        self
      end

      def stopping?
        @stopping
      end

      def run(on_error: nil)
        register
        begin
          until stopping?
            begin
              heartbeat
              result = work_once
              yield result if block_given? && !result.empty?
              sleep poll_interval if result.empty? && poll_interval.positive? && !stopping?
            rescue Durable::Error, Error => error
              raise unless on_error

              on_error.call(error)
              sleep poll_interval if poll_interval.positive? && !stopping?
            end
          end
        ensure
          unregister
        end

        self
      end

      private

      def perform_direct_work
        if adapter.respond_to?(:claim_many) && adapter.respond_to?(:perform_claim)
          claims = adapter.claim_many(queues:, limit: batch_size, worker_id: id)
          return if claims.empty?

          update_workload(claims.length)
          begin
            executions = perform_claims(claims)
            executions.length == 1 ? executions.first : executions
          ensure
            update_workload(0)
          end
        elsif adapter.respond_to?(:work_once)
          adapter.work_once(queue:)
        end
      end

      def perform_claims(claims)
        work = ::Queue.new
        results = ::Queue.new
        claims.each { |claim| work << claim }
        workers = [thread_count, claims.length].min.times.map do
          Thread.new do
            loop do
              claim = work.pop(true)
              begin
                results << adapter.perform_claim(claim)
              rescue StandardError => error
                results << Execution.new(id: claim.row.fetch(:id), status: :failed, error:)
              end
            end
          rescue ThreadError
            nil
          end
        end
        workers.each(&:join)
        claims.length.times.map { results.pop }
      end

      def register
        return unless adapter.respond_to?(:register_worker)

        @started_at = Time.now.utc
        adapter.register_worker(
          id:,
          process_id:,
          hostname:,
          queues: JSON.generate(queues == :all ? ["*"] : queues),
          thread_count:,
          batch_size:,
          started_at:,
          last_heartbeat_at: started_at,
          current_workload: 0
        )
        @registered = true
      end

      def heartbeat
        return unless @registered && adapter.respond_to?(:heartbeat_worker)

        adapter.heartbeat_worker(id, current_workload:)
      end

      def update_workload(value)
        @current_workload = value
        heartbeat
      end

      def unregister
        return unless @registered && adapter.respond_to?(:unregister_worker)

        adapter.unregister_worker(id)
      ensure
        @registered = false
      end

      def normalize_queues(values)
        return :all if values == :all

        selected = Array(values).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:empty?)
        return :all if selected.include?("*") || selected.include?("all")
        raise ArgumentError, "at least one queue is required" if selected.empty?

        selected.uniq.freeze
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
        Hacienda.logger.error("job_notification_failed event=#{event} subscriber=#{subscription.id} error=#{error.class}: #{error.message}")
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
