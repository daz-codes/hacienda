# frozen_string_literal: true

module Hacienda
  class Transaction
    EnqueuedJob = Data.define(:job, :args, :kwargs, :delivery, :scheduled_at, :priority)

    attr_reader :database, :events, :outbox, :emitted_events,
      :job_adapter, :job_outbox, :enqueued_jobs

    def initialize(database:, events:, outbox: nil, job_adapter: Hacienda.job_adapter, job_outbox: nil)
      @database = database
      @events = events
      @outbox = outbox
      @job_adapter = Jobs::Adapter.validate!(job_adapter)
      @job_outbox = job_outbox
      @emitted_events = []
      @enqueued_jobs = []
    end

    def emit(event)
      raise ArgumentError, "event is required" if event.nil?

      emitted_events << event
      if outbox
        outbox.write(event)
      else
        database.after_commit(savepoint: true) { events.publish(event) }
      end
      event
    end

    def enqueue(job, *args, **kwargs)
      enqueue_at(nil, job, *args, **kwargs)
    end

    def enqueue_all(entries, &block)
      normalized_entries = entries.map { |entry| Jobs.normalize_enqueue_entry(entry) }
      if Jobs::Adapter.transactional_with?(job_adapter, database) && job_adapter.respond_to?(:enqueue_all)
        ids = Jobs.enqueue_all(job_adapter, normalized_entries)
        normalized_entries.each do |entry|
          enqueued_jobs << EnqueuedJob.new(
            job: entry.fetch(:job),
            args: entry.fetch(:args),
            kwargs: entry.fetch(:kwargs),
            delivery: :transaction,
            scheduled_at: entry[:scheduled_at],
            priority: entry[:priority] || Jobs.priority(entry.fetch(:job))
          )
        end
        block&.call(ids)
        ids
      else
        ids = normalized_entries.map do |entry|
          enqueue_at(entry[:scheduled_at], entry.fetch(:job), *entry.fetch(:args), **entry.fetch(:kwargs))
        end
        database.after_commit(savepoint: true) { block.call(ids) } if block
        ids
      end
    end

    def enqueue_in(duration, job, *args, **kwargs)
      seconds = Float(duration)
      raise Jobs::Error, "job delay must be finite and non-negative" unless seconds.finite? && seconds >= 0

      enqueue_at(Time.now.utc + seconds, job, *args, **kwargs)
    rescue ArgumentError, TypeError
      raise Jobs::Error, "job delay must be a number of seconds"
    end

    def enqueue_at(time, job, *args, **kwargs)
      scheduled_at = Jobs.normalize_scheduled_at(time)
      priority = Jobs.priority(job)
      delivery = if Jobs::Adapter.transactional_with?(job_adapter, database)
        Jobs.enqueue(job_adapter, job, args:, kwargs:, scheduled_at:)
        :transaction
      elsif Jobs::Adapter.requires_outbox?(job_adapter, database)
        unless job_outbox
          raise Jobs::OutboxError,
            "#{job_adapter.class} requires a job outbox for transaction-safe enqueueing"
        end

        job_outbox.write(job, args:, kwargs:, priority:, scheduled_at:)
        :outbox
      else
        Jobs.validate_metadata!(job_adapter, scheduled_at:, priority:)
        database.after_commit(savepoint: true) do
          Jobs.enqueue(job_adapter, job, args:, kwargs:, scheduled_at:)
        end
        :after_commit
      end

      enqueued_jobs << EnqueuedJob.new(job:, args:, kwargs:, delivery:, scheduled_at:, priority:)
      job
    end
  end
end
