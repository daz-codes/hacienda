# frozen_string_literal: true

require "rack/mock"

module Hacienda
  module Jobs
    module BenchmarkJob
      module_function

      def perform(_token = nil)
        true
      end
    end

    module RetryBenchmarkJob
      @seen = {}
      @mutex = Mutex.new

      class << self
        def max_attempts = 1

        def perform(token)
          first_attempt = @mutex.synchronize do
            unless @seen.key?(token)
              @seen[token] = true
              true
            end
          end
          raise "intentional benchmark retry" if first_attempt

          true
        end

        def reset!
          @mutex.synchronize { @seen.clear }
        end
      end
    end

    class BenchmarkEvent
      attr_reader :token

      def initialize(token:)
        @token = token
      end

      def to_h
        {token: token}
      end

      def self.from_h(attributes)
        new(token: attributes[:token] || attributes["token"])
      end
    end

    class Benchmark
      Result = Data.define(
        :queue,
        :jobs,
        :retry_jobs,
        :web_requests,
        :outbox_items,
        :threads,
        :batch_size,
        :enqueue_seconds,
        :work_seconds,
        :web_seconds,
        :job_outbox_seconds,
        :event_outbox_seconds,
        :checkpoint_seconds,
        :total_seconds,
        :enqueue_per_second,
        :work_per_second,
        :web_per_second,
        :job_outbox_per_second,
        :event_outbox_per_second,
        :db_latency_avg_ms,
        :db_latency_p95_ms,
        :db_latency_max_ms,
        :web_failures,
        :job_outbox_processed,
        :event_outbox_processed,
        :checkpoint_busy,
        :checkpoint_log,
        :checkpointed,
        :cleanup_deleted
      )

      attr_reader :adapter, :database, :application, :job_outbox, :outbox,
        :events, :queue, :jobs, :retry_jobs, :web_requests, :web_path,
        :outbox_items, :checkpoint_mode, :threads, :batch_size,
        :latency_samples, :timeout, :keep

      def initialize(
        adapter:,
        database:,
        application: nil,
        job_outbox: nil,
        outbox: nil,
        events: nil,
        queue: default_queue,
        jobs: 100,
        retry_jobs: nil,
        web_requests: 0,
        web_path: "/up",
        outbox_items: 0,
        checkpoint_mode: "PASSIVE",
        threads: 2,
        batch_size: nil,
        latency_samples: 25,
        timeout: 30,
        keep: false
      )
        @adapter = adapter
        @database = database
        @application = application
        @job_outbox = job_outbox
        @outbox = outbox
        @events = events || Events.new
        @queue = queue.to_s
        @jobs = Integer(jobs)
        @retry_jobs = Integer(retry_jobs || [[@jobs / 10, 1].max, 10].min)
        @web_requests = Integer(web_requests)
        @web_path = web_path.to_s
        @outbox_items = Integer(outbox_items)
        @checkpoint_mode = checkpoint_mode.to_s.upcase
        @threads = Integer(threads)
        @batch_size = Integer(batch_size || @threads * 2)
        @latency_samples = Integer(latency_samples)
        @timeout = Float(timeout)
        @keep = keep

        raise Error, "jobs benchmark requires the database job adapter" unless database_adapter?
        raise ArgumentError, "benchmark queue is required" if @queue.empty?
        raise ArgumentError, "benchmark jobs must be positive" unless @jobs.positive?
        raise ArgumentError, "benchmark retry_jobs cannot be negative" if @retry_jobs.negative?
        raise ArgumentError, "benchmark web_requests cannot be negative" if @web_requests.negative?
        raise ArgumentError, "benchmark web_path must start with /" if @web_requests.positive? && !@web_path.start_with?("/")
        raise ArgumentError, "benchmark outbox_items cannot be negative" if @outbox_items.negative?
        raise ArgumentError, "benchmark threads must be positive" unless @threads.positive?
        raise ArgumentError, "benchmark batch_size must be positive" unless @batch_size.positive?
        raise ArgumentError, "benchmark latency_samples cannot be negative" if @latency_samples.negative?
        raise ArgumentError, "benchmark timeout must be positive" unless @timeout.positive?
        raise Error, "web request benchmark requires an application" if @web_requests.positive? && !application
      end

      def run
        started = monotonic_time
        ids = []
        retry_ids = []
        cleanup_deleted = 0
        RetryBenchmarkJob.reset!

        begin
          enqueue_seconds = elapsed do
            ids.concat(enqueue(BenchmarkJob, count: jobs, token_prefix: "success"))
          end

          latencies = []
          work_seconds = elapsed do
            run_worker_until(ids:, expected_completed: jobs, latencies:)
          end

          retry_seconds = elapsed do
            retry_ids = run_retry_cycle if retry_jobs.positive?
          end

          web_failures = 0
          web_seconds = elapsed do
            web_failures = run_web_requests
          end

          job_outbox_processed = 0
          job_outbox_seconds = elapsed do
            job_outbox_processed = run_job_outbox_cycle if outbox_items.positive? && job_outbox
          end

          event_outbox_processed = 0
          event_outbox_seconds = elapsed do
            event_outbox_processed = run_event_outbox_cycle if outbox_items.positive? && outbox
          end

          checkpoint_result = {}
          checkpoint_seconds = elapsed do
            checkpoint_result = run_checkpoint
          end

          cleanup_deleted = keep ? 0 : cleanup(ids + retry_ids)
          total_seconds = monotonic_time - started
          processed = jobs + retry_ids.length
          work_total = work_seconds + retry_seconds

          Result.new(
            queue:,
            jobs:,
            retry_jobs: retry_ids.length,
            web_requests:,
            outbox_items:,
            threads:,
            batch_size:,
            enqueue_seconds: round(enqueue_seconds),
            work_seconds: round(work_total),
            web_seconds: round(web_seconds),
            job_outbox_seconds: round(job_outbox_seconds),
            event_outbox_seconds: round(event_outbox_seconds),
            checkpoint_seconds: round(checkpoint_seconds),
            total_seconds: round(total_seconds),
            enqueue_per_second: rate(jobs, enqueue_seconds),
            work_per_second: rate(processed, work_total),
            web_per_second: rate(web_requests, web_seconds),
            job_outbox_per_second: rate(job_outbox_processed, job_outbox_seconds),
            event_outbox_per_second: rate(event_outbox_processed, event_outbox_seconds),
            db_latency_avg_ms: round(milliseconds(average(latencies))),
            db_latency_p95_ms: round(milliseconds(percentile(latencies, 0.95))),
            db_latency_max_ms: round(milliseconds(latencies.max || 0)),
            web_failures:,
            job_outbox_processed:,
            event_outbox_processed:,
            checkpoint_busy: checkpoint_result[:busy],
            checkpoint_log: checkpoint_result[:log],
            checkpointed: checkpoint_result[:checkpointed],
            cleanup_deleted:
          )
        ensure
          cleanup(ids + retry_ids) unless keep || cleanup_deleted.positive?
        end
      end

      private

      def self.default_queue
        "hacienda-benchmark-#{Process.pid}-#{Process.clock_gettime(Process::CLOCK_REALTIME).to_i}"
      end

      def default_queue = self.class.default_queue

      def database_adapter?
        adapter.respond_to?(:enqueue_all) &&
          adapter.respond_to?(:claim_many) &&
          adapter.respond_to?(:retry_failed) &&
          adapter.respond_to?(:table) &&
          adapter.respond_to?(:database) &&
          adapter.database.equal?(database)
      end

      def enqueue(job, count:, token_prefix:)
        return [] if count.zero?

        entries = count.times.map do |index|
          {
            job:,
            args: ["#{token_prefix}-#{Process.pid}-#{object_id}-#{index}"],
            kwargs: {},
            queue:,
            priority: 0
          }
        end
        adapter.enqueue_all(entries)
      end

      def run_retry_cycle
        ids = enqueue(RetryBenchmarkJob, count: retry_jobs, token_prefix: "retry")
        run_worker_until(ids:, expected_discarded: retry_jobs, latencies: [])
        ids.each { |id| adapter.retry_failed(id) }
        run_worker_until(ids:, expected_completed: retry_jobs, latencies: [])
        ids
      end

      def run_web_requests
        return 0 if web_requests.zero?

        failures = 0
        mutex = Mutex.new
        distribute(web_requests).map do |count|
          Thread.new do
            count.times do
              status, _headers, body = application.call(Rack::MockRequest.env_for(web_path, method: "GET"))
              body.each { |_chunk| nil }
              body.close if body.respond_to?(:close)
              mutex.synchronize { failures += 1 } unless status.between?(200, 399)
            end
          end
        end.each(&:join)
        failures
      end

      def run_job_outbox_cycle
        outbox_items.times do |index|
          job_outbox.write(
            BenchmarkJob,
            args: ["handoff-#{Process.pid}-#{object_id}-#{index}"],
            kwargs: {},
            queue:,
            priority: 0
          )
        end
        dispatch_until_empty { job_outbox.dispatch_once(adapter:) }
      end

      def run_event_outbox_cycle
        outbox_items.times do |index|
          outbox.write(BenchmarkEvent.new(token: "event-#{Process.pid}-#{object_id}-#{index}"))
        end
        dispatch_until_empty { outbox.dispatch_once(events:) }
      end

      def dispatch_until_empty
        processed = 0
        deadline = monotonic_time + timeout
        loop do
          execution = yield
          processed += 1 if execution
          break unless execution
          raise Error, "jobs benchmark timed out after #{timeout}s" if monotonic_time >= deadline
        end
        processed
      end

      def run_checkpoint
        return {} unless SQLite.sqlite?(database)

        SQLite.checkpoint(database, mode: checkpoint_mode)
      end

      def run_worker_until(ids:, expected_completed: 0, expected_discarded: 0, latencies:)
        worker = Worker.new(
          adapter:,
          queues: [queue],
          threads:,
          batch_size:,
          poll_interval: 0
        )
        stop = false
        worker_thread = Thread.new do
          until stop
            result = worker.work_once
            sleep 0.001 if result.empty?
          end
        end

        deadline = monotonic_time + timeout
        loop do
          sample_latency(latencies) if latencies.length < latency_samples
          completed = terminal_count(ids, :completed_at)
          discarded = terminal_count(ids, :discarded_at)
          break if completed >= expected_completed && discarded >= expected_discarded
          raise Error, "jobs benchmark timed out after #{timeout}s" if monotonic_time >= deadline

          sleep 0.005
        end
      ensure
        stop = true
        worker&.stop
        worker_thread&.join(1)
      end

      def terminal_count(ids, column)
        return 0 if ids.empty?

        dataset.where(id: ids).exclude(column => nil).count
      end

      def sample_latency(latencies)
        latencies << elapsed { database.fetch("SELECT 1").all }
      end

      def cleanup(ids)
        return 0 if ids.empty?

        dataset.where(id: ids).delete
      end

      def distribute(total)
        base = total / threads
        extra = total % threads
        threads.times.map { |index| base + (index < extra ? 1 : 0) }.reject(&:zero?)
      end

      def dataset
        database[adapter.table]
      end

      def elapsed
        started = monotonic_time
        yield
        monotonic_time - started
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def average(values)
        return 0 if values.empty?

        values.sum / values.length.to_f
      end

      def percentile(values, point)
        return 0 if values.empty?

        sorted = values.sort
        sorted[[((sorted.length - 1) * point).ceil, sorted.length - 1].min]
      end

      def milliseconds(seconds)
        seconds * 1000.0
      end

      def rate(count, seconds)
        return 0 if seconds <= 0

        round(count / seconds)
      end

      def round(value)
        value.round(3)
      end
    end
  end
end
