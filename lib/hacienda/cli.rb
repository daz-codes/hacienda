# frozen_string_literal: true

require "fileutils"
require "sequel"
require "sequel/extensions/migration"
require "shellwords"
require "tempfile"
require_relative "../hacienda"
require_relative "generator"

module Hacienda
  class CLI
    def self.start(arguments, out: $stdout, err: $stderr, cwd: Dir.pwd, executor: Kernel.method(:exec))
      new(out: out, err: err, cwd: cwd, executor: executor).start(arguments)
    end

    def initialize(out:, err:, cwd:, executor:)
      @out = out
      @err = err
      @cwd = File.expand_path(cwd)
      @executor = executor
    end

    def start(arguments)
      command, *rest = arguments

      case command
      when "new"
        generate_app(rest.fetch(0) { raise ArgumentError, "usage: hac new APP_NAME" })
      when "generate", "g"
        generate(rest)
      when "credentials:show"
        credentials_show
      when "credentials:edit"
        credentials_edit
      when "credentials:rotate"
        credentials_rotate
      when "start"
        return run_server(rest)
      when "console", "c"
        run_console
      when "routes"
        return list_routes(rest)
      when "db:migrate"
        migrate_database(rest)
      when "db:rollback"
        rollback_database(rest)
      when "db:seed"
        seed_database(rest)
      when "db:check"
        return check_database(rest)
      when "db:checkpoint"
        checkpoint_database(rest)
      when "assets:precompile"
        precompile_assets(rest)
      when "assets:clobber"
        clobber_assets(rest)
      when "jobs:work"
        work_jobs(rest)
      when "jobs:failed"
        list_failed_work(rest)
      when "jobs:scheduled"
        list_scheduled_work(rest)
      when "jobs:status"
        show_jobs_status(rest)
      when "jobs:health"
        return show_jobs_health(rest)
      when "jobs:benchmark"
        benchmark_jobs(rest)
      when "jobs:list"
        list_job_work(rest)
      when "jobs:prune"
        prune_job_history(rest)
      when "jobs:pause"
        pause_job_queue(rest)
      when "jobs:resume"
        resume_job_queue(rest)
      when "jobs:schedule"
        schedule_recurring_jobs(rest)
      when "jobs:recurring"
        inspect_recurring_jobs(rest)
      when "jobs:cancel"
        cancel_job(rest)
      when "jobs:discard"
        discard_job(rest)
      when "jobs:reschedule"
        reschedule_job(rest)
      when "jobs:retry"
        retry_failed_work(rest)
      when "--version", "-v"
        @out.puts "hac #{VERSION}"
      when "help", "--help", "-h", nil
        @out.puts help
      else
        raise ArgumentError, "unknown command: #{command}\n\n#{help}"
      end

      0
    rescue ArgumentError, Error, Generator::Error, Credentials::Error, Jobs::Error, Events::OutboxError, Durable::Error => error
      @err.puts error.message
      1
    end

    private

    def run_server(arguments)
      config = File.join(@cwd, "config.ru")
      raise ArgumentError, "not a Hacienda application: #{@cwd}" unless File.file?(config)

      pending = pending_application_migrations
      unless pending.empty?
        @err.puts "#{pending.length} pending #{pluralize(pending.length, "migration")}:"
        pending.each { |path| @err.puts "  #{File.basename(path)}" }
        @err.puts "Run: bundle exec hac db:migrate"
        return 1
      end

      rackup_arguments = arguments.dup
      rackup_arguments.unshift("-p", "5151") unless port_argument?(rackup_arguments)
      @executor.call(Gem.ruby, "-S", "rackup", *rackup_arguments)
      0
    end

    def run_console
      ensure_application!

      Dir.chdir(@cwd) do
        @executor.call(
          Gem.ruby,
          "-r",
          File.join(@cwd, "config", "application"),
          "-r",
          "irb",
          "-e",
          "IRB.start"
        )
      end
    end

    def list_routes(arguments)
      arguments = arguments.dup
      domain = consume_option!(arguments, "--domain")
      reject_unknown_options!("hac routes [METHOD] [PATH] [--domain DOMAIN]", arguments)
      application = load_application
      routes = if arguments.empty?
        application.routes.entries.sort_by(&:order)
      else
        lookup_routes(application.routes, arguments)
      end
      routes = routes.select { |route| route.domain_name == domain } if domain

      if routes.empty?
        message = if arguments.empty? && domain
          "No routes defined for domain #{domain.inspect}."
        elsif arguments.empty?
          "No routes defined."
        else
          request = arguments.length == 2 ? "#{arguments.first.upcase} #{arguments.last}" : arguments.first
          "No route matches #{request}#{" in domain #{domain.inspect}" if domain}."
        end
        @out.puts message
        return arguments.empty? ? 0 : 1
      end

      rows = routes.map do |route|
        [
          route.verb,
          route.path,
          route.domain_name,
          route.action_handler_name,
          route.guards.empty? ? "-" : route.guards.map { |guard| guard_name(guard) }.join(", "),
          route_source(route)
        ]
      end

      print_table([%w[VERB PATH DOMAIN ACTION GUARDS SOURCE], *rows])
      0
    end

    def lookup_routes(routes, arguments)
      method, path = case arguments.length
      when 1
        [nil, arguments.first]
      when 2
        [arguments.first.to_s.upcase, arguments.last]
      else
        raise ArgumentError, "usage: hac routes [METHOD] PATH [--domain DOMAIN]"
      end

      unless path.to_s.start_with?("/")
        raise ArgumentError, "route lookup path must start with /: #{path.inspect}"
      end
      if method && !(["HEAD"] + Routes::VERBS.map { |verb| verb.to_s.upcase }).include?(method)
        raise ArgumentError, "unsupported route method: #{method.inspect}"
      end

      if method
        match = routes.find(method, path)
        match ? [match.first] : []
      else
        routes.entries.map(&:verb).uniq.filter_map do |verb|
          routes.find(verb, path)&.first
        end.sort_by(&:order)
      end
    end

    def route_source(route)
      return "-" unless route.source_file

      root = File.realpath(@cwd)
      source = File.realpath(route.source_file).delete_prefix("#{root}/")
      route.source_line ? "#{source}:#{route.source_line}" : source
    rescue SystemCallError
      route.source_location
    end

    def migrate_database(arguments)
      expect_no_arguments!("db:migrate", arguments)
      application = load_application
      directory = migrations_directory
      files = migration_files(directory)

      if files.empty?
        @out.puts "No migrations found."
        return
      end

      database = application_database(application)
      before = applied_migration_count(database, directory)
      Sequel::Migrator.run(database, directory)
      applied = applied_migration_count(database, directory) - before

      if applied.zero?
        @out.puts "Database is already up to date."
      else
        @out.puts "Applied #{applied} #{pluralize(applied, "migration")}."
      end
    end

    def rollback_database(arguments)
      raise ArgumentError, "usage: hac db:rollback [STEPS]" if arguments.length > 1

      steps = Integer(arguments.first || 1, exception: false)
      unless steps&.positive?
        raise ArgumentError, "rollback steps must be a positive integer"
      end

      application = load_application
      directory = migrations_directory
      if migration_files(directory).empty?
        @out.puts "No migrations found."
        return
      end

      database = application_database(application)
      rolled_back = rollback_migrations(database, directory, steps)
      if rolled_back.zero?
        @out.puts "No migrations to roll back."
      else
        @out.puts "Rolled back #{rolled_back} #{pluralize(rolled_back, "migration")}."
      end
    end

    def seed_database(arguments)
      expect_no_arguments!("db:seed", arguments)
      application = load_application
      application_database(application)
      seeds = File.join(@cwd, "db", "seeds.rb")
      raise ArgumentError, "seed file not found: #{seeds}" unless File.file?(seeds)

      Dir.chdir(@cwd) { load seeds }
      @out.puts "Database seed complete."
    end

    def check_database(arguments)
      expect_no_arguments!("db:check", arguments)
      application = load_application
      checks = SQLite.diagnostics(application_database(application))
      rows = checks.map do |check|
        [
          check.fetch(:status).upcase,
          check.fetch(:name),
          check.fetch(:value),
          check[:message] || "-"
        ]
      end

      print_table([["STATUS", "CHECK", "VALUE", "MESSAGE"], *rows])
      checks.any? { |check| check.fetch(:status) == "critical" } ? 1 : 0
    end

    def checkpoint_database(arguments)
      mode = "PASSIVE"
      remaining = arguments.dup
      until remaining.empty?
        case remaining.shift
        when "--mode"
          mode = remaining.shift || raise(ArgumentError, "--mode requires PASSIVE, FULL, RESTART, or TRUNCATE")
        else
          raise ArgumentError, "usage: hac db:checkpoint [--mode PASSIVE|FULL|RESTART|TRUNCATE]"
        end
      end
      unless %w[PASSIVE FULL RESTART TRUNCATE].include?(mode.to_s.upcase)
        raise ArgumentError, "checkpoint mode must be PASSIVE, FULL, RESTART, or TRUNCATE"
      end

      application = load_application
      result = SQLite.checkpoint(application_database(application), mode:)
      print_table([
        ["MODE", "BUSY", "LOG_FRAMES", "CHECKPOINTED_FRAMES"],
        [result.fetch(:mode), result.fetch(:busy), result.fetch(:log), result.fetch(:checkpointed)]
      ])
    end

    def precompile_assets(arguments)
      expect_no_arguments!("assets:precompile", arguments)
      ensure_application!
      manifest = Assets.precompile(root: @cwd)
      count = manifest.fetch("assets").length
      @out.puts "Compiled #{count} #{pluralize(count, "asset")}."
    end

    def clobber_assets(arguments)
      expect_no_arguments!("assets:clobber", arguments)
      ensure_application!
      count = Assets.clobber(root: @cwd)
      @out.puts "Removed #{count} compiled #{pluralize(count, "asset")} and the asset manifest."
    end

    def work_jobs(arguments)
      once, queues, poll_interval, threads, batch_size = parse_worker_arguments(arguments)
      application = load_application
      adapter = Hacienda.job_adapter
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
      @out.puts "Hacienda worker started for #{queue_label} with #{threads} threads. Press Ctrl-C to stop."
      with_worker_signal_handlers(worker) do
        worker.run(on_error: ->(error) { @err.puts "Worker unavailable: #{error.message}" }) do |result|
          report_worker_result(result)
        end
      end
      @out.puts "Hacienda worker stopped."
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
      adapter = Hacienda.job_adapter
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
      adapter = Hacienda.job_adapter
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
      adapter = Hacienda.job_adapter
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
      adapter = Hacienda.job_adapter
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
        adapter: Hacienda.job_adapter,
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
          raise ArgumentError, "usage: hac jobs:list [pending|running|scheduled|blocked|completed|discarded|failed] [--limit N]"
        end
      end
      raise ArgumentError, "job list limit must be positive" unless limit.positive?

      load_application
      adapter = Hacienda.job_adapter
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
        raise ArgumentError, "usage: hac jobs:list [pending|running|scheduled|blocked|completed|discarded|failed] [--limit N]"
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
          raise ArgumentError, "usage: hac jobs:prune [--completed SECONDS] [--discarded SECONDS] [--failed SECONDS]"
        end
      end

      load_application
      adapter = Hacienda.job_adapter
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
        raise ArgumentError, "usage: hac jobs:pause QUEUE"
      end

      load_application
      adapter = Hacienda.job_adapter
      require_job_adapter_method!(adapter, :pause_queue).pause_queue(arguments.fetch(0), by: "hac")
      @out.puts "Paused queue #{arguments.fetch(0)}."
    end

    def resume_job_queue(arguments)
      unless arguments.length == 1
        raise ArgumentError, "usage: hac jobs:resume QUEUE"
      end

      load_application
      adapter = Hacienda.job_adapter
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
          raise ArgumentError, "usage: hac jobs:schedule [--once] [--poll SECONDS] [--config PATH]"
        end
      end
      raise ArgumentError, "recurring scheduler poll interval cannot be negative" if poll_interval.negative?

      application = load_application
      scheduler = Jobs::RecurringScheduler.new(
        database: application_database(application),
        adapter: Hacienda.job_adapter,
        path: config,
        poll_interval:
      )

      if once
        report_recurring_results(scheduler.tick)
        return
      end

      @out.puts "Hacienda recurring scheduler started from #{config}. Press Ctrl-C to stop."
      with_worker_signal_handlers(scheduler) do
        scheduler.run { |results| report_recurring_results(results) }
      end
      @out.puts "Hacienda recurring scheduler stopped."
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
          task = remaining.shift || raise(ArgumentError, "usage: hac jobs:recurring #{command} TASK [--config PATH]")
        else
          raise ArgumentError, "usage: hac jobs:recurring [run|enable|disable TASK] [--config PATH]"
        end
      end

      application = load_application
      case command
      when "run"
        scheduler = Jobs::RecurringScheduler.new(
          database: application_database(application),
          adapter: Hacienda.job_adapter,
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
        raise ArgumentError, "usage: hac jobs:retry job|handoff|event ID"
      end

      type, id = arguments
      application = load_application
      adapter = Hacienda.job_adapter
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
        raise ArgumentError, "usage: hac jobs:cancel ID"
      end

      load_application
      id = arguments.fetch(0)
      raise ArgumentError, "job #{id} was not found or was already terminal" unless Hacienda.cancel_job(id)

      @out.puts "Requested cancellation for job #{id}."
    end

    def discard_job(arguments)
      id = arguments.shift || raise(ArgumentError, "usage: hac jobs:discard ID [REASON]")
      reason = arguments.empty? ? nil : arguments.join(" ")

      load_application
      adapter = Hacienda.job_adapter
      discarded = require_job_adapter_method!(adapter, :discard).discard(id, reason:)
      raise ArgumentError, "job #{id} was not found or is currently running" unless discarded

      @out.puts "Discarded job #{id}."
    end

    def reschedule_job(arguments)
      unless arguments.length == 2
        raise ArgumentError, "usage: hac jobs:reschedule ID SECONDS_FROM_NOW"
      end

      id, delay = arguments
      scheduled_at = Time.now.utc + duration_seconds(delay)
      load_application
      adapter = Hacienda.job_adapter
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
          raise ArgumentError, "usage: hac jobs:work [--once] [--queue NAME|--all-queues] [--threads N] [--batch-size N] [--poll SECONDS]"
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
          raise ArgumentError, "usage: hac jobs:benchmark [--jobs N] [--retry-jobs N] [--web-requests N] [--web-path PATH] [--outbox-items N] [--checkpoint-mode MODE] [--threads N] [--batch-size N] [--queue NAME] [--latency-samples N] [--timeout SECONDS] [--keep]"
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

    def load_application
      ensure_application!
      require File.join(@cwd, "config", "application")

      unless Object.const_defined?(:APP, false) && Object.const_get(:APP).respond_to?(:routes)
        raise ArgumentError, "config/application.rb must define APP as a Hacienda application"
      end

      Object.const_get(:APP)
    end

    def application_database(application)
      database = application.database if application.respond_to?(:database)
      unless database.respond_to?(:transaction) && database.respond_to?(:[])
        raise ArgumentError, "application database is not configured"
      end

      database
    end

    def migrations_directory
      directory = File.join(@cwd, "db", "migrations")
      raise ArgumentError, "migration directory not found: #{directory}" unless File.directory?(directory)

      directory
    end

    def pending_application_migrations
      application_config = File.join(@cwd, "config", "application.rb")
      directory = File.join(@cwd, "db", "migrations")
      return [] unless File.file?(application_config) && File.directory?(directory)

      application = load_application
      Migrations.pending(database: application_database(application), directory:)
    end

    def migration_files(directory)
      Dir[File.join(directory, "*.rb")].select do |path|
        Sequel::Migrator::MIGRATION_FILE_PATTERN.match?(File.basename(path))
      end
    end

    def applied_migration_count(database, directory)
      migrator = Sequel::Migrator.migrator_class(directory).new(database, directory)
      if migrator.is_a?(Sequel::TimestampMigrator)
        migrator.applied_migrations.length
      else
        migrator.current
      end
    end

    def rollback_migrations(database, directory, steps)
      migrator_class = Sequel::Migrator.migrator_class(directory)
      migrator = migrator_class.new(database, directory)

      if migrator.is_a?(Sequel::TimestampMigrator)
        applied = migrator.applied_migrations.last(steps)
        paths = migration_files(directory).to_h { |path| [File.basename(path).downcase, path] }
        applied.reverse_each do |filename|
          Sequel::TimestampMigrator.run_single(database, paths.fetch(filename), direction: :down)
        end
        applied.length
      else
        count = [steps, migrator.current].min
        Sequel::Migrator.run(database, directory, relative: -count) if count.positive?
        count
      end
    end

    def expect_no_arguments!(command, arguments)
      raise ArgumentError, "usage: hac #{command}" unless arguments.empty?
    end

    def pluralize(count, singular)
      count == 1 ? singular : "#{singular}s"
    end

    def guard_name(guard)
      return guard.name if guard.respond_to?(:name) && guard.name

      guard.to_s
    end

    def print_table(rows)
      widths = rows.first.length.times.map do |column|
        rows.map { |row| row[column].to_s.length }.max
      end

      rows.each do |row|
        line = row.each_with_index.map do |value, column|
          column == row.length - 1 ? value.to_s : value.to_s.ljust(widths[column])
        end.join("  ")
        @out.puts line.rstrip
      end
    end

    def credentials_show
      ensure_application!
      @out.write Credentials.new(root: @cwd).read_text
    end

    def credentials_edit
      ensure_application!
      credentials = Credentials.new(root: @cwd).ensure_files
      editor = ENV["VISUAL"] || ENV["EDITOR"]
      raise ArgumentError, "set VISUAL or EDITOR to edit credentials" if editor.to_s.strip.empty?

      Tempfile.create(["hacienda-credentials", ".yml"]) do |file|
        file.write(credentials.read_text)
        file.flush

        success = system("#{editor} #{Shellwords.escape(file.path)}")
        raise ArgumentError, "credentials editor failed" unless success

        file.rewind
        credentials.write_text(file.read)
      end

      @out.puts "Updated #{credentials.encrypted_path}"
    end

    def credentials_rotate
      ensure_application!
      credentials = Credentials.new(root: @cwd)
      credentials.rotate
      @out.puts "Rotated master key at #{credentials.master_key_path}"
      @out.puts "Re-encrypted #{credentials.encrypted_path}"
      @out.puts "Update any HACIENDA_MASTER_KEY copies (deploy secrets, CI) with the new key."
    end

    def ensure_application!
      raise ArgumentError, "not a Hacienda application: #{@cwd}" unless File.file?(File.join(@cwd, "config", "application.rb"))
    end

    def port_argument?(arguments)
      arguments.any? do |argument|
        argument == "-p" ||
          argument == "--port" ||
          argument.match?(/\A-p\d+\z/) ||
          argument.start_with?("--port=")
      end
    end

    def generate(arguments)
      generator = Generator.new(target: @cwd, source_root: framework_root, cwd: @cwd)
      type, *names = arguments

      destination = case type
      when "domain"
        generator.generate_domain(names.fetch(0) { raise ArgumentError, "usage: hac generate domain NAME" })
      when "rest"
        reject_unknown_options!("hac generate rest NAME", names)
        generator.generate_rest(names.fetch(0) { raise ArgumentError, "usage: hac generate rest NAME" })
      when "action"
        group = consume_option!(names, "--actions", "--group")
        reject_unknown_options!("hac generate action DOMAIN NAME [--actions GROUP]", names)
        domain = names.fetch(0) { raise ArgumentError, "usage: hac generate action DOMAIN NAME" }
        action = names.fetch(1) { raise ArgumentError, "usage: hac generate action DOMAIN NAME" }
        generator.generate_action(domain, action, group:)
      when "migration"
        generator.generate_migration(names.fetch(0) { raise ArgumentError, "usage: hac generate migration NAME" })
      when "auth"
        generator.generate_auth
      else
        raise ArgumentError, "unknown generator: #{type.inspect}\n\n#{help}"
      end

      @out.puts "Generated #{destination}"
    end

    def consume_option!(arguments, *flags)
      flags.each do |flag|
        index = arguments.index(flag)
        next unless index

        value = arguments[index + 1]
        raise ArgumentError, "#{flag} requires a value" if value.nil? || value.start_with?("-")
        arguments.slice!(index, 2)
        return value
      end
      nil
    end

    def reject_unknown_options!(usage, arguments)
      unknown = arguments.find { |argument| argument.start_with?("-") }
      raise ArgumentError, "unknown option: #{unknown}\nusage: #{usage}" if unknown
    end

    def generate_app(name)
      target = File.expand_path(name, @cwd)
      Generator.new(target: target, source_root: framework_root, cwd: @cwd).new_app
      @out.puts "Created #{target}"
      @out.puts
      @out.puts "  cd #{name}"
      @out.puts "  bundle install"
      @out.puts "  bundle exec hac db:migrate"
      @out.puts "  bundle exec hac start"
    end

    def framework_root
      File.expand_path("../..", __dir__)
    end

    def help
      <<~TEXT
        Hacienda #{VERSION}

        Usage:
          hac new APP_NAME
          hac generate domain NAME
          hac generate rest NAME
          hac generate action DOMAIN NAME [--actions GROUP]
          hac generate migration NAME
          hac generate auth
          hac credentials:show
          hac credentials:edit
          hac credentials:rotate
          hac start [RACKUP_OPTIONS]
          hac console
          hac routes [--domain DOMAIN]
          hac routes [METHOD] PATH [--domain DOMAIN]
          hac db:migrate
          hac db:rollback [STEPS]
          hac db:seed
          hac db:check
          hac db:checkpoint [--mode PASSIVE|FULL|RESTART|TRUNCATE]
          hac assets:precompile
          hac assets:clobber
          hac jobs:work [--once] [--queue NAME|--all-queues] [--threads N] [--batch-size N] [--poll SECONDS]
          hac jobs:status
          hac jobs:health
          hac jobs:benchmark [--jobs N] [--retry-jobs N] [--web-requests N] [--web-path PATH] [--outbox-items N] [--checkpoint-mode MODE] [--threads N] [--batch-size N] [--queue NAME] [--latency-samples N] [--timeout SECONDS] [--keep]
          hac jobs:list [pending|running|scheduled|blocked|completed|discarded|failed] [--limit N]
          hac jobs:failed
          hac jobs:scheduled
          hac jobs:prune [--completed SECONDS] [--discarded SECONDS] [--failed SECONDS]
          hac jobs:pause QUEUE
          hac jobs:resume QUEUE
          hac jobs:schedule [--once] [--poll SECONDS] [--config PATH]
          hac jobs:recurring [run|enable|disable TASK] [--config PATH]
          hac jobs:cancel ID
          hac jobs:discard ID [REASON]
          hac jobs:reschedule ID SECONDS_FROM_NOW
          hac jobs:retry job|handoff|event ID
          hac --version
      TEXT
    end
  end
end
