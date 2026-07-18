# frozen_string_literal: true

require "securerandom"

module Lunula
  module Jobs
    class OutboxError < Error; end

    class Outbox
      attr_reader :database, :table, :default_queue, :max_attempts

      def initialize(
        database:,
        table: :lunula_job_outbox,
        queue: "default",
        max_attempts: 10,
        lease_seconds: 300,
        retry_delay: nil,
        clock: nil
      )
        @database = database
        @table = table.to_sym
        @default_queue = queue.to_s
        @max_attempts = Integer(max_attempts)
        raise ArgumentError, "job outbox max_attempts must be positive" unless @max_attempts.positive?

        @clock = clock || -> { Time.now.utc }
        @durable_queue = Durable::Queue.new(
          database:,
          table:,
          lease_seconds:,
          retry_delay:,
          clock: @clock,
          order: %i[priority available_at id]
        )
      end

      def write(job, args:, kwargs:, queue: nil, priority: nil, scheduled_at: nil)
        job_class = Jobs.job_name(job)
        current_time = now
        database[table].insert(
          handoff_id: SecureRandom.uuid,
          queue: queue_name(job, queue),
          priority: priority || Jobs.priority(job),
          job_class:,
          payload: Serializer.dump(args:, kwargs:),
          attempts: 0,
          max_attempts:,
          available_at: Jobs.normalize_scheduled_at(scheduled_at) || current_time,
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

      def dispatch_once(adapter:)
        Adapter.validate!(adapter)
        claim = @durable_queue.claim
        return unless claim

        begin
          row = claim.row
          args, kwargs = Serializer.load(row.fetch(:payload))
          job = Jobs.constantize(row.fetch(:job_class))
          adapter.enqueue(
            job,
            args:,
            kwargs:,
            queue: row.fetch(:queue),
            priority: row.fetch(:priority),
            scheduled_at: nil,
            idempotency_key: row.fetch(:handoff_id)
          )
          @durable_queue.complete(claim)
          Execution.new(id: row.fetch(:id), status: :succeeded, error: nil)
        rescue Durable::LeaseLost => error
          Execution.new(id: claim.row.fetch(:id), status: :lease_lost, error:)
        rescue StandardError => error
          outcome = @durable_queue.fail_claim(claim, error, kind: "error")
          status = outcome == :terminal ? :failed : outcome == :retrying ? :retrying : :lease_lost
          Execution.new(id: claim.row.fetch(:id), status:, error:)
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

      def scheduled
        current_time = now
        database[table]
          .where(failed_at: nil, locked_at: nil)
          .where { available_at > current_time }
          .order(:available_at, :priority, :id)
          .all
      rescue Sequel::DatabaseError => error
        raise OutboxError, outbox_error(error)
      end

      private

      def queue_name(job, explicit)
        (explicit || (job.respond_to?(:queue) && job.queue) || default_queue).to_s
      end

      def now
        value = @clock.call
        value.respond_to?(:to_time) ? value.to_time.utc : value
      end

      def outbox_error(error)
        SQLite.report_busy(error, source: "job_outbox", table:)
        if error.message.match?(/no such table|does not exist/i)
          "job handoff outbox table #{table.inspect} is missing; run luna db:migrate"
        else
          error.message
        end
      end
    end
  end
end
