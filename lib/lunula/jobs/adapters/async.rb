# frozen_string_literal: true

module Lunula
  module Jobs
    module Adapters
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
            Thread.current.name = "lunula-jobs" if Thread.current.respond_to?(:name=)

            while (item = next_item)
              begin
                Jobs.perform(item.job, args: item.args, kwargs: item.kwargs)
              rescue StandardError => error
                Lunula.logger.error("#{error.class}: #{error.message}\n#{Array(error.backtrace).join("\n")}")
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
    end
  end
end
