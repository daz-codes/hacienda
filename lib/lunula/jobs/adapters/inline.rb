# frozen_string_literal: true

module Lunula
  module Jobs
    module Adapters
      module Inline
        module_function

        def capabilities = %i[inline]

        def enqueue(job, args:, kwargs:, queue: nil, priority: nil, scheduled_at: nil, idempotency_key: nil)
          Jobs.perform(job, args:, kwargs:)
        end
      end
    end
  end
end
