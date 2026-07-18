# frozen_string_literal: true

module Lunula
  module Jobs
    module Adapters
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
  end
end
