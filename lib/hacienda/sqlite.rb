# frozen_string_literal: true

require "sequel"
require "thread"

module Hacienda
  module SQLite
    DEFAULT_BUSY_TIMEOUT = 5_000
    DEFAULT_BUSY_LOG_THRESHOLD = 3
    DEFAULT_BUSY_LOG_WINDOW = 60
    DEFAULT_BUSY_LOG_COOLDOWN = 60
    CLOUD_STORAGE_PATTERNS = %r{/(CloudStorage|Dropbox|Google Drive|OneDrive|iCloud|ProtonDrive)[/-]}i
    SYNCHRONOUS_LEVELS = {
      0 => "OFF",
      1 => "NORMAL",
      2 => "FULL",
      3 => "EXTRA"
    }.freeze

    module_function

    class BusyMonitor
      attr_reader :threshold, :window, :cooldown

      def initialize(
        threshold: DEFAULT_BUSY_LOG_THRESHOLD,
        window: DEFAULT_BUSY_LOG_WINDOW,
        cooldown: DEFAULT_BUSY_LOG_COOLDOWN,
        clock: nil,
        logger: nil
      )
        @threshold = Integer(threshold)
        @window = Float(window)
        @cooldown = Float(cooldown)
        raise ArgumentError, "busy monitor threshold must be positive" unless @threshold.positive?
        raise ArgumentError, "busy monitor window must be positive" unless @window.positive?
        raise ArgumentError, "busy monitor cooldown must be positive" unless @cooldown.positive?

        @clock = clock || -> { Time.now }
        @logger = logger || -> { Hacienda.logger }
        @events = []
        @last_logged_at = nil
        @mutex = Mutex.new
      end

      def report(error, source:, **metadata)
        return false unless SQLite.busy_error?(error)

        now = current_time
        payload = nil
        @mutex.synchronize do
          @events << now
          cutoff = now - window
          @events.select! { |timestamp| timestamp >= cutoff }
          if @events.length >= threshold && should_log?(now)
            @last_logged_at = now
            payload = {source:, count: @events.length, window:, error: busy_message(error)}.merge(metadata)
          end
        end

        log(payload) if payload
        true
      end

      private

      def current_time
        value = @clock.call
        return value.to_f if value.respond_to?(:to_f)
        return value.to_time.to_f if value.respond_to?(:to_time)

        Float(value)
      end

      def should_log?(now)
        @last_logged_at.nil? || now - @last_logged_at >= cooldown
      end

      def log(payload)
        logger = @logger.respond_to?(:call) ? @logger.call : @logger
        return unless logger&.respond_to?(:warn)

        logger.warn("sqlite_busy_contention #{format_payload(payload)}")
      end

      def format_payload(payload)
        payload.compact.map { |key, value| "#{key}=#{format_value(value)}" }.join(" ")
      end

      def format_value(value)
        value.to_s.inspect
      end

      def busy_message(error)
        error_chain(error).map(&:message).find { |message| message.to_s.match?(/busy|locked|SQLITE_BUSY/i) } || error.message
      end

      def error_chain(error)
        chain = []
        current = error
        while current
          chain << current
          current = current.respond_to?(:cause) ? current.cause : nil
        end
        chain
      end
    end

    def configure(database, wal: true, busy_timeout: DEFAULT_BUSY_TIMEOUT, synchronous: "NORMAL", foreign_keys: true)
      return database unless sqlite?(database)

      statements = [
        "PRAGMA busy_timeout = #{Integer(busy_timeout)}",
        "PRAGMA foreign_keys = #{foreign_keys ? "ON" : "OFF"}"
      ]
      statements << "PRAGMA journal_mode = WAL" if wal
      statements << "PRAGMA synchronous = #{synchronous}" if synchronous

      statements.each { |statement| database.run(statement) }
      register_connection_pragmas(database, statements)
      database
    end

    def busy_monitor
      @busy_monitor ||= BusyMonitor.new
    end

    def busy_monitor=(monitor)
      @busy_monitor = monitor
    end

    def report_busy(error, source:, **metadata)
      busy_monitor.report(error, source:, **metadata)
    end

    def busy_error?(error)
      error_chain(error).any? do |candidate|
        candidate.class.name.to_s.match?(/SQLite.*Busy|BusyException|LockedException/i) ||
          candidate.message.to_s.match?(/SQLITE_BUSY|database is locked|database table is locked|busy/i)
      end
    end

    def sqlite?(database)
      database.respond_to?(:database_type) && database.database_type == :sqlite
    end

    def diagnostics(database)
      raise Error, "database is not configured" unless database
      return [{name: "adapter", status: "info", value: database.database_type, message: "not SQLite"}] unless sqlite?(database)

      path = database_path(database)
      journal = journal_mode(database)
      timeout = busy_timeout(database)
      synchronous = synchronous_label(database)
      keys_enabled = foreign_keys(database)
      checks = [
        check("adapter", "ok", "sqlite", "SQLite database detected"),
        check("sqlite_version", "info", sqlite_version(database), nil),
        check("database_path", path ? "info" : "warning", path || ":memory:", path ? nil : "in-memory databases are not production durable"),
        check("journal_mode", journal.casecmp?("wal") ? "ok" : "warning", journal, "production SQLite should use WAL mode"),
        check("busy_timeout", timeout >= DEFAULT_BUSY_TIMEOUT ? "ok" : "warning", "#{timeout}ms", "busy_timeout below #{DEFAULT_BUSY_TIMEOUT}ms can fail under normal write contention"),
        check("synchronous", synchronous_status(synchronous), synchronous, "WAL production apps normally use NORMAL or FULL"),
        check("foreign_keys", keys_enabled ? "ok" : "warning", keys_enabled ? "on" : "off", "foreign key enforcement is disabled")
      ]
      checks.concat(path_checks(path))
      checks
    end

    def checkpoint(database, mode: "PASSIVE")
      raise Error, "database is not configured" unless database
      raise Error, "db:checkpoint only supports SQLite databases" unless sqlite?(database)

      normalized = mode.to_s.upcase
      unless %w[PASSIVE FULL RESTART TRUNCATE].include?(normalized)
        raise Error, "checkpoint mode must be PASSIVE, FULL, RESTART, or TRUNCATE"
      end

      row = database.fetch("PRAGMA wal_checkpoint(#{normalized})").first || {}
      {
        mode: normalized,
        busy: integer_value(row, :busy, "busy"),
        log: integer_value(row, :log, "log"),
        checkpointed: integer_value(row, :checkpointed, "checkpointed")
      }
    end

    def database_path(database)
      path = database.opts[:database] if database.respond_to?(:opts)
      return if path.nil? || path.to_s.empty? || path.to_s == ":memory:"

      File.expand_path(path.to_s)
    end

    def sqlite_version(database)
      database.fetch("SELECT sqlite_version() AS version").first.fetch(:version).to_s
    end

    def journal_mode(database)
      first_value(database.fetch("PRAGMA journal_mode").first).to_s
    end

    def busy_timeout(database)
      first_value(database.fetch("PRAGMA busy_timeout").first).to_i
    end

    def synchronous_label(database)
      SYNCHRONOUS_LEVELS.fetch(first_value(database.fetch("PRAGMA synchronous").first).to_i, "unknown")
    end

    def synchronous_status(label)
      %w[NORMAL FULL EXTRA].include?(label) ? "ok" : "warning"
    end

    def foreign_keys(database)
      first_value(database.fetch("PRAGMA foreign_keys").first).to_i == 1
    end

    def path_checks(path)
      return [] unless path

      checks = []
      directory = File.dirname(path)
      checks << check("database_directory", File.directory?(directory) ? "ok" : "critical", directory, "database directory does not exist")
      checks << check("database_directory_writable", File.writable?(directory) ? "ok" : "critical", File.writable?(directory) ? "yes" : "no", "database directory is not writable")
      checks << check("cloud_or_network_path", path.match?(CLOUD_STORAGE_PATTERNS) ? "warning" : "ok", path.match?(CLOUD_STORAGE_PATTERNS) ? "yes" : "no", "SQLite production databases should not live on synced or network filesystems")
      checks
    end

    def check(name, status, value, message)
      {name:, status:, value:, message: status == "ok" ? nil : message}.compact
    end

    def integer_value(row, *keys)
      key = keys.find { |candidate| row.key?(candidate) || row.key?(candidate.to_s) }
      return 0 unless key

      (row[key] || row[key.to_s]).to_i
    end

    def register_connection_pragmas(database, statements)
      return unless database.respond_to?(:pool) && database.pool.respond_to?(:connect_sqls=)

      database.pool.connect_sqls = (Array(database.pool.connect_sqls) + statements).uniq
    end

    def first_value(row)
      return nil unless row

      row.values.first
    end

    def error_chain(error)
      chain = []
      current = error
      while current
        chain << current
        current = current.respond_to?(:cause) ? current.cause : nil
      end
      chain
    end
  end
end
