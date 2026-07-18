# frozen_string_literal: true

module Lunula
  class CLI
    module JobCommands
      private

      def work_jobs(arguments)
        once, queues, poll_interval, threads, batch_size = parse_worker_arguments(arguments)
        application = load_application
        adapter = Lunula.job_adapter
        worker = Jobs::Worker.new(
          adapter:,
          job_outbox: application.job_outbox,
          outbox: application.outbox,
          events: application.events,
          queues:,
          threads:,
          batch_size:,
          poll_interval:
        )

        if once
          report_worker_result(worker.work_once)
          return
        end

        queue_label = queues == :all ? "all queues" : "queues #{queues.join(", ")}"
        @out.puts "Lunula worker started for #{queue_label} with #{threads} threads. Press Ctrl-C to stop."
        with_worker_signal_handlers(worker) do
          worker.run(on_error: ->(error) { @err.puts "Worker unavailable: #{error.message}" }) do |result|
            report_worker_result(result)
          end
        end
        @out.puts "Lunula worker stopped."
      end

      def with_worker_signal_handlers(worker)
        previous_handlers = %w[INT TERM].to_h do |signal|
          [signal, Signal.trap(signal) { worker.stop }]
        end
        yield
      ensure
        previous_handlers&.each { |signal, handler| Signal.trap(signal, handler) }
      end

      def list_failed_work(arguments)
        expect_no_arguments!("jobs:failed", arguments)
        application = load_application
        adapter = Lunula.job_adapter
        rows = failed_rows("JOB", adapter.respond_to?(:failed) ? adapter.failed : []) +
          failed_rows("HANDOFF", application.job_outbox ? application.job_outbox.failed : []) +
          failed_rows("EVENT", application.outbox ? application.outbox.failed : [])

        if rows.empty?
          @out.puts "No failed jobs or events."
        else
          print_table([["TYPE", "ID", "ATTEMPTS", "KIND", "FAILED AT", "ERROR"], *rows])
        end
      end

      def list_scheduled_work(arguments)
        expect_no_arguments!("jobs:scheduled", arguments)
        application = load_application
        adapter = Lunula.job_adapter
        rows = scheduled_rows("JOB", adapter.respond_to?(:scheduled) ? adapter.scheduled : []) +
          scheduled_rows("HANDOFF", application.job_outbox ? application.job_outbox.scheduled : [])

        if rows.empty?
          @out.puts "No scheduled jobs."
        else
          print_table([["TYPE", "ID", "QUEUE", "PRIORITY", "AVAILABLE AT", "JOB"], *rows])
        end
      end

      def show_jobs_status(arguments)
        expect_no_arguments!("jobs:status", arguments)
        application = load_application
        adapter = Lunula.job_adapter
        raise ArgumentError, "configured job adapter does not provide status" unless adapter.respond_to?(:status)

        status = adapter.status
        rows = [
          ["METRIC", "VALUE"],
          ["pending", status.fetch(:pending)],
          ["scheduled", status.fetch(:scheduled)],
          ["running", status.fetch(:running)],
          ["blocked", status.fetch(:blocked)],
          ["paused_queues", status.fetch(:paused_queues)],
          ["completed", status.fetch(:completed)],
          ["discarded", status.fetch(:discarded)],
          ["failed", status.fetch(:failed)],
          ["workers", status.fetch(:workers)],
          ["oldest_pending_age", format_duration(status[:oldest_pending_age])],
          ["completed_last_minute", status.fetch(:completed_last_minute)],
          ["completed_last_hour", status.fetch(:completed_last_hour)]
        ]
        if application.job_outbox
          rows << ["handoff_pending", application.job_outbox.pending_count]
          rows << ["handoff_failed", application.job_outbox.failed.length]
        end
        if application.outbox
          rows << ["event_pending", application.outbox.pending_count]
          rows << ["event_failed", application.outbox.failed.length]
        end
        print_table(rows)
      end

      def show_jobs_health(arguments)
        expect_no_arguments!("jobs:health", arguments)
        load_application
        adapter = Lunula.job_adapter
        raise ArgumentError, "configured job adapter does not provide health" unless adapter.respond_to?(:health)

        health = adapter.health
        checks = health.fetch(:checks)
        rows = [["CHECK", "VALUE"]]
        rows << ["status", health.fetch(:status)]
        rows << ["generated_at", health.fetch(:generated_at)]
        checks.each { |name, value| rows << [name, value.nil? ? "-" : value] }
        print_table(rows)
        health.fetch(:status) == "critical" ? 1 : 0
      end

      def benchmark_jobs(arguments)
        options = parse_job_benchmark_arguments(arguments)
        application = load_application
        benchmark = Jobs::Benchmark.new(
          adapter: Lunula.job_adapter,
          database: application_database(application),
          application:,
          job_outbox: application.job_outbox,
          outbox: application.outbox,
          events: application.events,
          **options
        )
        result = benchmark.run
        print_table([
          ["METRIC", "VALUE"],
          ["queue", result.queue],
          ["jobs", result.jobs],
          ["retry_jobs", result.retry_jobs],
          ["web_requests", result.web_requests],
          ["outbox_items", result.outbox_items],
          ["threads", result.threads],
          ["batch_size", result.batch_size],
          ["enqueue_seconds", result.enqueue_seconds],
          ["work_seconds", result.work_seconds],
          ["web_seconds", result.web_seconds],
          ["job_outbox_seconds", result.job_outbox_seconds],
          ["event_outbox_seconds", result.event_outbox_seconds],
          ["checkpoint_seconds", result.checkpoint_seconds],
          ["total_seconds", result.total_seconds],
          ["enqueue_per_second", result.enqueue_per_second],
          ["work_per_second", result.work_per_second],
          ["web_per_second", result.web_per_second],
          ["job_outbox_per_second", result.job_outbox_per_second],
          ["event_outbox_per_second", result.event_outbox_per_second],
          ["db_latency_avg_ms", result.db_latency_avg_ms],
          ["db_latency_p95_ms", result.db_latency_p95_ms],
          ["db_latency_max_ms", result.db_latency_max_ms],
          ["web_failures", result.web_failures],
          ["job_outbox_processed", result.job_outbox_processed],
          ["event_outbox_processed", result.event_outbox_processed],
          ["checkpoint_busy", result.checkpoint_busy || "-"],
          ["checkpoint_log", result.checkpoint_log || "-"],
          ["checkpointed", result.checkpointed || "-"],
          ["cleanup_deleted", result.cleanup_deleted]
        ])
      end

      def list_job_work(arguments)
        state = arguments.first || "pending"
        limit = 50
        remaining = arguments.drop(1)
        until remaining.empty?
          case remaining.shift
          when "--limit"
            limit = Integer(remaining.shift || raise(ArgumentError, "--limit requires a number"))
          else
            raise ArgumentError, "usage: luna jobs:list [pending|running|scheduled|blocked|completed|discarded|failed] [--limit N]"
          end
        end
        raise ArgumentError, "job list limit must be positive" unless limit.positive?

        load_application
        adapter = Lunula.job_adapter
        rows = case state
        when "pending"
          require_job_adapter_method!(adapter, :pending).pending.first(limit)
        when "running"
          require_job_adapter_method!(adapter, :running).running.first(limit)
        when "scheduled"
          require_job_adapter_method!(adapter, :scheduled).scheduled.first(limit)
        when "blocked"
          require_job_adapter_method!(adapter, :blocked).blocked(limit:)
        when "completed"
          require_job_adapter_method!(adapter, :completed).completed(limit:)
        when "discarded"
          require_job_adapter_method!(adapter, :discarded).discarded(limit:)
        when "failed"
          require_job_adapter_method!(adapter, :failed).failed.first(limit)
        else
          raise ArgumentError, "usage: luna jobs:list [pending|running|scheduled|blocked|completed|discarded|failed] [--limit N]"
        end

        if rows.empty?
          @out.puts "No #{state} jobs."
        else
          print_table([["ID", "QUEUE", "PRIORITY", "ATTEMPTS", "STATE AT", "JOB", "DETAIL"], *job_rows_for_state(state, rows)])
        end
      end

      def prune_job_history(arguments)
        completed = nil
        discarded = nil
        failed = nil
        remaining = arguments.dup
        until remaining.empty?
          case remaining.shift
          when "--completed"
            completed = duration_seconds(remaining.shift || raise(ArgumentError, "--completed requires seconds"))
          when "--discarded"
            discarded = duration_seconds(remaining.shift || raise(ArgumentError, "--discarded requires seconds"))
          when "--failed"
            failed = duration_seconds(remaining.shift || raise(ArgumentError, "--failed requires seconds"))
          else
            raise ArgumentError, "usage: luna jobs:prune [--completed SECONDS] [--discarded SECONDS] [--failed SECONDS]"
          end
        end

        load_application
        adapter = Lunula.job_adapter
        require_job_adapter_method!(adapter, :prune)
        now = Time.now.utc
        completed ||= adapter.respond_to?(:completed_retention) ? adapter.completed_retention : nil
        discarded ||= adapter.respond_to?(:discarded_retention) ? adapter.discarded_retention : nil
        failed ||= adapter.respond_to?(:failed_retention) ? adapter.failed_retention : nil
        counts = adapter.prune(
          completed_before: completed && now - completed,
          discarded_before: discarded && now - discarded,
          failed_before: failed && now - failed
        )
        @out.puts "Pruned #{counts.fetch(:completed)} completed, #{counts.fetch(:discarded)} discarded, and #{counts.fetch(:failed)} failed jobs."
      end

      def pause_job_queue(arguments)
        unless arguments.length == 1
          raise ArgumentError, "usage: luna jobs:pause QUEUE"
        end

        load_application
        adapter = Lunula.job_adapter
        require_job_adapter_method!(adapter, :pause_queue).pause_queue(arguments.fetch(0), by: "luna")
        @out.puts "Paused queue #{arguments.fetch(0)}."
      end

      def resume_job_queue(arguments)
        unless arguments.length == 1
          raise ArgumentError, "usage: luna jobs:resume QUEUE"
        end

        load_application
        adapter = Lunula.job_adapter
        require_job_adapter_method!(adapter, :resume_queue).resume_queue(arguments.fetch(0))
        @out.puts "Resumed queue #{arguments.fetch(0)}."
      end

      def schedule_recurring_jobs(arguments)
        once = false
        poll_interval = 60.0
        config = recurring_config_path
        remaining = arguments.dup
        until remaining.empty?
          case remaining.shift
          when "--once"
            once = true
          when "--poll"
            poll_interval = Float(remaining.shift || raise(ArgumentError, "--poll requires seconds"))
          when "--config"
            config = File.expand_path(remaining.shift || raise(ArgumentError, "--config requires a path"), @cwd)
          else
            raise ArgumentError, "usage: luna jobs:schedule [--once] [--poll SECONDS] [--config PATH]"
          end
        end
        raise ArgumentError, "recurring scheduler poll interval cannot be negative" if poll_interval.negative?

        application = load_application
        scheduler = Jobs::RecurringScheduler.new(
          database: application_database(application),
          adapter: Lunula.job_adapter,
          path: config,
          poll_interval:
        )

        if once
          report_recurring_results(scheduler.tick)
          return
        end

        @out.puts "Lunula recurring scheduler started from #{config}. Press Ctrl-C to stop."
        with_worker_signal_handlers(scheduler) do
          scheduler.run { |results| report_recurring_results(results) }
        end
        @out.puts "Lunula recurring scheduler stopped."
      rescue ArgumentError => error
        raise if error.message.start_with?("usage:", "--")

        raise ArgumentError, "recurring scheduler options must use valid numbers"
      end

      def inspect_recurring_jobs(arguments)
        config = recurring_config_path
        command = nil
        task = nil
        remaining = arguments.dup
        until remaining.empty?
          case (argument = remaining.shift)
          when "--config"
            config = File.expand_path(remaining.shift || raise(ArgumentError, "--config requires a path"), @cwd)
          when "run", "enable", "disable"
            command = argument
            task = remaining.shift || raise(ArgumentError, "usage: luna jobs:recurring #{command} TASK [--config PATH]")
          else
            raise ArgumentError, "usage: luna jobs:recurring [run|enable|disable TASK] [--config PATH]"
          end
        end

        application = load_application
        case command
        when "run"
          scheduler = Jobs::RecurringScheduler.new(
            database: application_database(application),
            adapter: Lunula.job_adapter,
            path: config
          )
          result = scheduler.trigger(task)
          @out.puts "Triggered recurring task #{result.entry.name} as job #{result.job_id}."
        when "enable", "disable"
          Jobs::RecurringSchedule.set_enabled(config, task, command == "enable")
          @out.puts "#{command == "enable" ? "Enabled" : "Disabled"} recurring task #{task}."
        else
          schedule = Jobs::RecurringSchedule.load(config)
          if schedule.entries.empty?
            @out.puts "No recurring tasks defined."
          else
            print_table([["TASK", "JOB", "EVERY", "QUEUE", "PRIORITY", "ENABLED"], *recurring_rows(schedule)])
          end
        end
      end

      def retry_failed_work(arguments)
        unless arguments.length == 2 && %w[job handoff event].include?(arguments.first)
          raise ArgumentError, "usage: luna jobs:retry job|handoff|event ID"
        end

        type, id = arguments
        application = load_application
        adapter = Lunula.job_adapter
        retried = if type == "job" && adapter.respond_to?(:retry_failed)
          adapter.retry_failed(id)
        elsif type == "handoff" && application.job_outbox
          application.job_outbox.retry_failed(id)
        elsif application.outbox
          application.outbox.retry_failed(id)
        else
          false
        end

        raise ArgumentError, "failed #{type} #{id} was not found" unless retried

        @out.puts "Queued #{type} #{id} for retry."
      end

      def cancel_job(arguments)
        unless arguments.length == 1
          raise ArgumentError, "usage: luna jobs:cancel ID"
        end

        load_application
        id = arguments.fetch(0)
        raise ArgumentError, "job #{id} was not found or was already terminal" unless Lunula.cancel_job(id)

        @out.puts "Requested cancellation for job #{id}."
      end

      def discard_job(arguments)
        id = arguments.shift || raise(ArgumentError, "usage: luna jobs:discard ID [REASON]")
        reason = arguments.empty? ? nil : arguments.join(" ")

        load_application
        adapter = Lunula.job_adapter
        discarded = require_job_adapter_method!(adapter, :discard).discard(id, reason:)
        raise ArgumentError, "job #{id} was not found or is currently running" unless discarded

        @out.puts "Discarded job #{id}."
      end

      def reschedule_job(arguments)
        unless arguments.length == 2
          raise ArgumentError, "usage: luna jobs:reschedule ID SECONDS_FROM_NOW"
        end

        id, delay = arguments
        scheduled_at = Time.now.utc + duration_seconds(delay)
        load_application
        adapter = Lunula.job_adapter
        rescheduled = require_job_adapter_method!(adapter, :reschedule).reschedule(id, at: scheduled_at)
        raise ArgumentError, "job #{id} was not found or is currently running" unless rescheduled

        @out.puts "Rescheduled job #{id} for #{scheduled_at}."
      end

      def parse_worker_arguments(arguments)
        once = false
        queues = []
        all_queues = false
        poll_interval = 1.0
        threads = 1
        batch_size = nil
        remaining = arguments.dup
        until remaining.empty?
          case remaining.shift
          when "--once"
            once = true
          when "--queue"
            value = remaining.shift || raise(ArgumentError, "--queue requires a name")
            queues.concat(value.split(",").map(&:strip).reject(&:empty?))
          when "--all-queues"
            all_queues = true
          when "--poll"
            poll_interval = Float(remaining.shift || raise(ArgumentError, "--poll requires seconds"))
          when "--threads"
            threads = Integer(remaining.shift || raise(ArgumentError, "--threads requires a number"))
          when "--batch-size"
            batch_size = Integer(remaining.shift || raise(ArgumentError, "--batch-size requires a number"))
          else
            raise ArgumentError, "usage: luna jobs:work [--once] [--queue NAME|--all-queues] [--threads N] [--batch-size N] [--poll SECONDS]"
          end
        end
        raise ArgumentError, "--all-queues cannot be combined with --queue" if all_queues && !queues.empty?

        selected = all_queues ? :all : (queues.empty? ? ["default"] : queues.uniq)
        [once, selected, poll_interval, threads, batch_size || threads]
      rescue ArgumentError => error
        raise if error.message.start_with?("usage:", "--")

        raise ArgumentError, "worker options must use valid positive numbers"
      end

      def parse_job_benchmark_arguments(arguments)
        options = {}
        remaining = arguments.dup
        until remaining.empty?
          case remaining.shift
          when "--jobs"
            options[:jobs] = Integer(remaining.shift || raise(ArgumentError, "--jobs requires a number"))
          when "--retry-jobs"
            options[:retry_jobs] = Integer(remaining.shift || raise(ArgumentError, "--retry-jobs requires a number"))
          when "--web-requests"
            options[:web_requests] = Integer(remaining.shift || raise(ArgumentError, "--web-requests requires a number"))
          when "--web-path"
            options[:web_path] = remaining.shift || raise(ArgumentError, "--web-path requires a path")
          when "--outbox-items"
            options[:outbox_items] = Integer(remaining.shift || raise(ArgumentError, "--outbox-items requires a number"))
          when "--checkpoint-mode"
            options[:checkpoint_mode] = remaining.shift || raise(ArgumentError, "--checkpoint-mode requires a mode")
          when "--threads"
            options[:threads] = Integer(remaining.shift || raise(ArgumentError, "--threads requires a number"))
          when "--batch-size"
            options[:batch_size] = Integer(remaining.shift || raise(ArgumentError, "--batch-size requires a number"))
          when "--queue"
            options[:queue] = remaining.shift || raise(ArgumentError, "--queue requires a name")
          when "--latency-samples"
            options[:latency_samples] = Integer(remaining.shift || raise(ArgumentError, "--latency-samples requires a number"))
          when "--timeout"
            options[:timeout] = Float(remaining.shift || raise(ArgumentError, "--timeout requires seconds"))
          when "--keep"
            options[:keep] = true
          else
            raise ArgumentError, "usage: luna jobs:benchmark [--jobs N] [--retry-jobs N] [--web-requests N] [--web-path PATH] [--outbox-items N] [--checkpoint-mode MODE] [--threads N] [--batch-size N] [--queue NAME] [--latency-samples N] [--timeout SECONDS] [--keep]"
          end
        end
        options
      rescue ArgumentError => error
        raise if error.message.start_with?("usage:", "--")

        raise ArgumentError, "jobs benchmark options must use valid numbers"
      end

      def failed_rows(type, rows)
        rows.map do |row|
          [
            type,
            row.fetch(:id),
            row.fetch(:attempts),
            row[:failure_kind] || "error",
            row.fetch(:failed_at),
            row.fetch(:last_error).to_s.lines.first.to_s.strip
          ]
        end
      end

      def scheduled_rows(type, rows)
        rows.map do |row|
          [
            type,
            row.fetch(:id),
            row.fetch(:queue),
            row.fetch(:priority),
            row.fetch(:available_at),
            row.fetch(:job_class)
          ]
        end
      end

      def job_rows_for_state(state, rows)
        rows.map do |row|
          [
            row.fetch(:id),
            row.fetch(:queue),
            row.fetch(:priority),
            row.fetch(:attempts),
            job_state_time(state, row),
            row.fetch(:job_class),
            state == "blocked" ? row[:blocked_reason].to_s : row[:last_error].to_s.lines.first.to_s.strip
          ]
        end
      end

      def job_state_time(state, row)
        case state
        when "pending", "scheduled" then row.fetch(:available_at)
        when "running" then row.fetch(:locked_at)
        when "blocked" then row.fetch(:blocked_at)
        when "completed" then row.fetch(:completed_at)
        when "discarded" then row.fetch(:discarded_at)
        when "failed" then row.fetch(:failed_at)
        end
      end

      def require_job_adapter_method!(adapter, method)
        raise ArgumentError, "configured job adapter does not support #{method}" unless adapter.respond_to?(method)

        adapter
      end

      def duration_seconds(value)
        seconds = Float(value)
        raise ArgumentError, "duration must be non-negative seconds" unless seconds >= 0 && seconds.finite?

        seconds
      rescue ArgumentError, TypeError
        raise ArgumentError, "duration must be non-negative seconds"
      end

      def format_duration(seconds)
        return "-" if seconds.nil?

        "#{seconds}s"
      end

      def recurring_config_path
        File.join(@cwd, "config", "recurring.yml")
      end

      def recurring_rows(schedule)
        schedule.entries.map do |entry|
          [
            entry.name,
            entry.job_class,
            "#{entry.interval}s",
            entry.queue || "default",
            entry.priority || 0,
            entry.enabled ? "yes" : "no"
          ]
        end
      end

      def report_worker_result(result)
        report_execution("job", result.jobs)
        report_execution("job handoff", result.handoffs)
        report_execution("event", result.events)
        @out.puts "No work available." if result.empty?
      end

      def report_recurring_results(results)
        if results.empty?
          @out.puts "No recurring tasks due."
        else
          results.each do |result|
            @out.puts "Scheduled recurring task #{result.entry.name} for #{result.scheduled_at} as job #{result.job_id}."
          end
        end
      end

      def report_execution(type, execution)
        return unless execution
        if execution.is_a?(Array)
          execution.each { |item| report_execution(type, item) }
          return
        end

        case execution.status
        when :succeeded
          @out.puts "Completed #{type} #{execution.id}."
        when :retrying
          @err.puts "Retrying #{type} #{execution.id}: #{execution.error.class}: #{execution.error.message}"
        when :failed
          @err.puts "Failed #{type} #{execution.id} permanently: #{execution.error.class}: #{execution.error.message}"
        when :timed_out
          @err.puts "Timed out #{type} #{execution.id}: #{execution.error.message}"
        when :cancelled
          @err.puts "Cancelled #{type} #{execution.id}."
        when :lease_lost
          @err.puts "Lost lease for #{type} #{execution.id}; its outcome is uncertain and it may be delivered again."
        else
          @err.puts "#{execution.status} #{type} #{execution.id}: #{execution.error.class}: #{execution.error.message}"
        end
      end
    end
  end
end
