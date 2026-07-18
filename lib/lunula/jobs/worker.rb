# frozen_string_literal: true

module Lunula
  module Jobs
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
          raise Error, "luna jobs:work requires a worker-capable adapter or a configured outbox"
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
  end
end
