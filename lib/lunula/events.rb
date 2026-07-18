# frozen_string_literal: true

module Lunula
  class Events
    class OutboxError < Lunula::Error; end
    DeliveryError = Data.define(:subscriber, :error)
    DeliveryReport = Data.define(:event, :delivered, :errors) do
      def success?
        errors.empty?
      end
    end
    Subscription = Data.define(:event_class, :subscriber)

    class Configuration
      attr_reader :subscriptions

      def initialize
        @subscriptions = Hash.new { |hash, event_class| hash[event_class] = [] }
      end

      def subscribe(event_class, subscriber = nil, &block)
        subscriber ||= block
        Events.validate_subscription!(event_class, subscriber)
        subscriptions[event_class] << subscriber
        Subscription.new(event_class:, subscriber:)
      end
    end

    class Recorder
      def initialize
        @events = []
        @mutex = Mutex.new
      end

      def call(event)
        @mutex.synchronize { @events << event }
        event
      end

      def events
        @mutex.synchronize { @events.dup }
      end

      def clear
        @mutex.synchronize { @events.clear }
        self
      end
    end

    class Outbox
      attr_reader :database, :table

      def initialize(
        database:,
        table: :lunula_outbox,
        lease_seconds: 300,
        retry_delay: nil,
        clock: nil
      )
        @database = database
        @table = table.to_sym
        @clock = clock || -> { Time.now.utc }
        @durable_queue = Durable::Queue.new(
          database:,
          table:,
          lease_seconds:,
          retry_delay:,
          clock: @clock
        )
      end

      def write(event)
        event_class = event.class.name.to_s
        raise OutboxError, "durable event must have a named class" if event_class.empty?
        unless event.respond_to?(:to_h)
          raise OutboxError, "durable event #{event_class} must respond to to_h"
        end

        max_attempts = event.class.respond_to?(:max_attempts) ? Integer(event.class.max_attempts) : 10
        raise OutboxError, "event max_attempts must be positive" unless max_attempts.positive?

        current_time = now
        database[table].insert(
          event_class:,
          payload: Jobs::Serializer.dump(args: [], kwargs: event.to_h),
          attempts: 0,
          max_attempts:,
          available_at: current_time,
          locked_at: nil,
          locked_by: nil,
          last_error: nil,
          failed_at: nil,
          created_at: current_time,
          updated_at: current_time
        )
      rescue Sequel::DatabaseError => error
        raise OutboxError, outbox_error(error)
      end

      def dispatch_once(events:)
        raise OutboxError, "event dispatcher is required" unless events.respond_to?(:publish)

        claim = @durable_queue.claim
        return unless claim

        begin
          event = deserialize(claim.row)
          report = events.publish(event)
          unless report.success?
            messages = report.errors.map { |failure| "#{failure.error.class}: #{failure.error.message}" }
            raise OutboxError, "one or more event subscribers failed: #{messages.join("; ")}"
          end

          @durable_queue.complete(claim)
          Jobs::Execution.new(id: claim.row.fetch(:id), status: :succeeded, error: nil)
        rescue Durable::LeaseLost => error
          Jobs::Execution.new(id: claim.row.fetch(:id), status: :lease_lost, error:)
        rescue StandardError => error
          outcome = @durable_queue.fail_claim(claim, error, kind: "error")
          status = outcome == :terminal ? :failed : outcome == :retrying ? :retrying : :lease_lost
          Jobs::Execution.new(id: claim.row.fetch(:id), status:, error:)
        end
      end

      def failed
        @durable_queue.failed
      end

      def retry_failed(id)
        @durable_queue.retry_failed(id)
      end

      def pending_count
        @durable_queue.pending_count
      end

      private

      def deserialize(row)
        event_class = Jobs.constantize(row.fetch(:event_class))
        _args, attributes = Jobs::Serializer.load(row.fetch(:payload))
        event_class.respond_to?(:from_h) ? event_class.from_h(attributes) : event_class.new(**attributes)
      rescue ArgumentError, TypeError => error
        raise OutboxError, "cannot rebuild #{row.fetch(:event_class)}: #{error.message}"
      end

      def now
        value = @clock.call
        value.respond_to?(:to_time) ? value.to_time.utc : value
      end

      def outbox_error(error)
        SQLite.report_busy(error, source: "event_outbox", table:)
        if error.message.match?(/no such table|does not exist/i)
          "event outbox table #{table.inspect} is missing; run luna db:migrate"
        else
          error.message
        end
      end
    end

    def initialize(logger: nil, on_error: nil)
      @logger = logger || -> { Lunula.logger }
      @on_error = on_error
      @subscriptions = {}.freeze
      @configuration = nil
      @mutex = Mutex.new
    end

    def configure(&block)
      raise ArgumentError, "events configuration block is required" unless block

      @mutex.synchronize { @configuration = block }
      reload!
    end

    def configured?
      @mutex.synchronize { !@configuration.nil? }
    end

    def reload!
      configuration = @mutex.synchronize { @configuration }
      return self unless configuration

      registry = Configuration.new
      configuration.call(registry)
      replace_subscriptions(registry.subscriptions)
      self
    end

    def subscribe(event_class, subscriber = nil, &block)
      subscriber ||= block
      self.class.validate_subscription!(event_class, subscriber)
      subscription = Subscription.new(event_class:, subscriber:)

      @mutex.synchronize do
        updated = mutable_subscriptions
        updated[event_class] << subscriber
        @subscriptions = freeze_subscriptions(updated)
      end

      subscription
    end

    def unsubscribe(subscription)
      @mutex.synchronize do
        updated = mutable_subscriptions
        subscribers = updated[subscription.event_class]
        subscribers.delete(subscription.subscriber)
        updated.delete(subscription.event_class) if subscribers.empty?
        @subscriptions = freeze_subscriptions(updated)
      end

      self
    end

    def publish(event)
      raise ArgumentError, "event is required" if event.nil?

      subscribers = @mutex.synchronize { Array(@subscriptions[event.class]).dup }
      errors = []
      delivered = 0

      subscribers.each do |subscriber|
        subscriber.call(event)
        delivered += 1
      rescue StandardError => error
        delivery_error = DeliveryError.new(subscriber:, error:)
        errors << delivery_error
        report_error(event, delivery_error)
      end

      DeliveryReport.new(event:, delivered:, errors: errors.freeze)
    end

    def subscriptions
      @mutex.synchronize do
        @subscriptions.transform_values(&:dup)
      end
    end

    def self.validate_subscription!(event_class, subscriber)
      raise ArgumentError, "event class is required" if event_class.nil?
      raise ArgumentError, "subscriber must respond to call" unless subscriber.respond_to?(:call)
    end

    private

    def replace_subscriptions(subscriptions)
      @mutex.synchronize do
        @subscriptions = freeze_subscriptions(subscriptions)
      end
    end

    def mutable_subscriptions
      @subscriptions.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(event_class, subscribers), copy|
        copy[event_class] = subscribers.dup
      end
    end

    def freeze_subscriptions(subscriptions)
      subscriptions.each_with_object({}) do |(event_class, subscribers), frozen|
        frozen[event_class] = subscribers.dup.freeze
      end.freeze
    end

    def report_error(event, delivery_error)
      error = delivery_error.error
      logger.error(
        "event_delivery_failed " \
        "event=#{event.class.name.inspect} " \
        "subscriber=#{subscriber_name(delivery_error.subscriber).inspect} " \
        "error=#{error.class.name.inspect} " \
        "message=#{error.message.inspect}\n#{Array(error.backtrace).join("\n")}"
      )
      @on_error&.call(event, delivery_error.subscriber, error)
    rescue StandardError => reporter_error
      logger.error("event_error_reporter_failed error=#{reporter_error.class.name.inspect} message=#{reporter_error.message.inspect}")
    end

    def logger
      @logger.respond_to?(:error) ? @logger : @logger.call
    end

    def subscriber_name(subscriber)
      if subscriber.is_a?(Method)
        "#{subscriber.receiver}.#{subscriber.name}"
      else
        subscriber.class.name.to_s.empty? ? subscriber.inspect : subscriber.class.name
      end
    end
  end
end
