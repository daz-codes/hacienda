# frozen_string_literal: true

require "fileutils"
require "sequel"
require "sequel/extensions/migration"
require "shellwords"
require "tempfile"
require_relative "../lunula"
require_relative "generator"
require_relative "cli/job_commands"

module Lunula
  class CLI
    include JobCommands

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
        generate_app(rest.fetch(0) { raise ArgumentError, "usage: luna new APP_NAME" })
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
        @out.puts "luna #{VERSION}"
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
      raise ArgumentError, "not a Lunula application: #{@cwd}" unless File.file?(config)

      pending = pending_application_migrations
      unless pending.empty?
        @err.puts "#{pending.length} pending #{pluralize(pending.length, "migration")}:"
        pending.each { |path| @err.puts "  #{File.basename(path)}" }
        @err.puts "Run: bundle exec luna db:migrate"
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
      reject_unknown_options!("luna routes [METHOD] [PATH] [--domain DOMAIN]", arguments)
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
        raise ArgumentError, "usage: luna routes [METHOD] PATH [--domain DOMAIN]"
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
      raise ArgumentError, "usage: luna db:rollback [STEPS]" if arguments.length > 1

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
          raise ArgumentError, "usage: luna db:checkpoint [--mode PASSIVE|FULL|RESTART|TRUNCATE]"
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

    def load_application
      ensure_application!
      require File.join(@cwd, "config", "application")

      unless Object.const_defined?(:APP, false) && Object.const_get(:APP).respond_to?(:routes)
        raise ArgumentError, "config/application.rb must define APP as a Lunula application"
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
      raise ArgumentError, "usage: luna #{command}" unless arguments.empty?
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

      Tempfile.create(["lunula-credentials", ".yml"]) do |file|
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
      @out.puts "Update any LUNULA_MASTER_KEY copies (deploy secrets, CI) with the new key."
    end

    def ensure_application!
      raise ArgumentError, "not a Lunula application: #{@cwd}" unless File.file?(File.join(@cwd, "config", "application.rb"))
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
        generator.generate_domain(names.fetch(0) { raise ArgumentError, "usage: luna generate domain NAME" })
      when "rest"
        reject_unknown_options!("luna generate rest NAME", names)
        generator.generate_rest(names.fetch(0) { raise ArgumentError, "usage: luna generate rest NAME" })
      when "action"
        group = consume_option!(names, "--actions", "--group")
        reject_unknown_options!("luna generate action DOMAIN NAME [--actions GROUP]", names)
        domain = names.fetch(0) { raise ArgumentError, "usage: luna generate action DOMAIN NAME" }
        action = names.fetch(1) { raise ArgumentError, "usage: luna generate action DOMAIN NAME" }
        generator.generate_action(domain, action, group:)
      when "migration"
        generator.generate_migration(names.fetch(0) { raise ArgumentError, "usage: luna generate migration NAME" })
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
      @out.puts "  bundle exec luna db:migrate"
      @out.puts "  bundle exec luna start"
    end

    def framework_root
      File.expand_path("../..", __dir__)
    end

    def help
      <<~TEXT
        Lunula #{VERSION}

        Usage:
          luna new APP_NAME
          luna generate domain NAME
          luna generate rest NAME
          luna generate action DOMAIN NAME [--actions GROUP]
          luna generate migration NAME
          luna generate auth
          luna credentials:show
          luna credentials:edit
          luna credentials:rotate
          luna start [RACKUP_OPTIONS]
          luna console
          luna routes [--domain DOMAIN]
          luna routes [METHOD] PATH [--domain DOMAIN]
          luna db:migrate
          luna db:rollback [STEPS]
          luna db:seed
          luna db:check
          luna db:checkpoint [--mode PASSIVE|FULL|RESTART|TRUNCATE]
          luna assets:precompile
          luna assets:clobber
          luna jobs:work [--once] [--queue NAME|--all-queues] [--threads N] [--batch-size N] [--poll SECONDS]
          luna jobs:status
          luna jobs:health
          luna jobs:benchmark [--jobs N] [--retry-jobs N] [--web-requests N] [--web-path PATH] [--outbox-items N] [--checkpoint-mode MODE] [--threads N] [--batch-size N] [--queue NAME] [--latency-samples N] [--timeout SECONDS] [--keep]
          luna jobs:list [pending|running|scheduled|blocked|completed|discarded|failed] [--limit N]
          luna jobs:failed
          luna jobs:scheduled
          luna jobs:prune [--completed SECONDS] [--discarded SECONDS] [--failed SECONDS]
          luna jobs:pause QUEUE
          luna jobs:resume QUEUE
          luna jobs:schedule [--once] [--poll SECONDS] [--config PATH]
          luna jobs:recurring [run|enable|disable TASK] [--config PATH]
          luna jobs:cancel ID
          luna jobs:discard ID [REASON]
          luna jobs:reschedule ID SECONDS_FROM_NOW
          luna jobs:retry job|handoff|event ID
          luna --version
      TEXT
    end
  end
end
