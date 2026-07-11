# frozen_string_literal: true

module Hacienda
  module Jobs
    module Adapter
      CAPABILITIES = %i[
        inline
        asynchronous
        test
        durable
        transactional
        worker
        external
        idempotent_handoff
        scheduled
        priorities
        uniqueness
        concurrency
        bulk
      ].freeze

      module_function

      def validate!(adapter)
        unless adapter.respond_to?(:enqueue)
          raise Error, "job adapter #{adapter.inspect} must respond to enqueue(job, args:, kwargs:, queue:, priority:, scheduled_at:, idempotency_key:)"
        end

        validate_enqueue_signature!(adapter)

        unknown = capabilities(adapter) - CAPABILITIES
        unless unknown.empty?
          raise Error, "job adapter #{adapter.inspect} declares unknown capabilities: #{unknown.join(", ")}"
        end

        adapter
      end

      def capabilities(adapter)
        values = adapter.respond_to?(:capabilities) ? adapter.capabilities : []
        Array(values).map(&:to_sym).uniq.freeze
      end

      def supports?(adapter, capability)
        capabilities(adapter).include?(capability.to_sym)
      end

      def transactional_with?(adapter, database)
        supports?(adapter, :transactional) &&
          adapter.respond_to?(:transactional_with?) &&
          adapter.transactional_with?(database)
      end

      def external?(adapter)
        supports?(adapter, :external)
      end

      def durable?(adapter)
        supports?(adapter, :durable)
      end

      def requires_outbox?(adapter, database)
        (external?(adapter) || durable?(adapter)) && !transactional_with?(adapter, database)
      end

      def validate_enqueue_signature!(adapter)
        parameters = adapter.method(:enqueue).parameters
        accepts_job = parameters.any? { |type, _name| %i[req opt rest].include?(type) }
        accepts_keywords = parameters.any? { |type, _name| type == :keyrest }
        keywords = parameters.filter_map { |type, name| name if %i[key keyreq].include?(type) }
        required = %i[args kwargs queue priority scheduled_at idempotency_key]
        return if accepts_job && (accepts_keywords || (required - keywords).empty?)

        raise Error, "job adapter #{adapter.inspect} must implement enqueue(job, args:, kwargs:, queue:, priority:, scheduled_at:, idempotency_key:)"
      end
      private_class_method :validate_enqueue_signature!
    end
  end
end
