# frozen_string_literal: true

require_relative "test_helper"
require "sequel"

class SQLiteTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("lunula-sqlite")
    @path = File.join(@directory, "production.sqlite3")
    @database = Sequel.sqlite(@path)
  end

  def teardown
    Lunula::SQLite.busy_monitor = nil
    @database.disconnect
    FileUtils.rm_rf(@directory)
  end

  def test_configure_sets_production_sqlite_pragmas
    Lunula::SQLite.configure(@database)

    assert_equal "wal", Lunula::SQLite.journal_mode(@database)
    assert_equal 5_000, Lunula::SQLite.busy_timeout(@database)
    assert_equal "NORMAL", Lunula::SQLite.synchronous_label(@database)
    assert Lunula::SQLite.foreign_keys(@database)
    assert_includes @database.pool.connect_sqls, "PRAGMA busy_timeout = 5000"
    assert_includes @database.pool.connect_sqls, "PRAGMA foreign_keys = ON"
    assert_includes @database.pool.connect_sqls, "PRAGMA journal_mode = WAL"
    assert_includes @database.pool.connect_sqls, "PRAGMA synchronous = NORMAL"
  end

  def test_diagnostics_report_sqlite_health
    Lunula::SQLite.configure(@database)
    diagnostics = Lunula::SQLite.diagnostics(@database)
    by_name = diagnostics.to_h { |check| [check.fetch(:name), check] }

    assert_equal "ok", by_name.fetch("adapter").fetch(:status)
    assert_equal "ok", by_name.fetch("journal_mode").fetch(:status)
    assert_equal "ok", by_name.fetch("busy_timeout").fetch(:status)
    assert_equal "ok", by_name.fetch("foreign_keys").fetch(:status)
    assert_equal @path, by_name.fetch("database_path").fetch(:value)
  end

  def test_checkpoint_reports_sqlite_wal_state
    Lunula::SQLite.configure(@database)
    @database.create_table(:widgets) { primary_key :id }
    @database[:widgets].insert

    result = Lunula::SQLite.checkpoint(@database, mode: "TRUNCATE")

    assert_equal "TRUNCATE", result.fetch(:mode)
    assert_operator result.fetch(:busy), :>=, 0
    assert_operator result.fetch(:log), :>=, 0
    assert_operator result.fetch(:checkpointed), :>=, 0
  end

  def test_busy_error_detects_sqlite_busy_messages
    error = Sequel::DatabaseError.new("SQLite3::BusyException: database is locked")

    assert Lunula::SQLite.busy_error?(error)
    refute Lunula::SQLite.busy_error?(Sequel::DatabaseError.new("no such table: posts"))
  end

  def test_busy_monitor_logs_only_after_sustained_contention
    messages = []
    now = 1_000.0
    logger = Struct.new(:messages) do
      def warn(message) = messages << message
    end.new(messages)
    monitor = Lunula::SQLite::BusyMonitor.new(
      threshold: 2,
      window: 10,
      cooldown: 60,
      clock: -> { now },
      logger:
    )
    error = Sequel::DatabaseError.new("SQLite3::BusyException: database is locked")

    assert monitor.report(error, source: "request", path: "/posts")
    assert_empty messages
    assert monitor.report(error, source: "request", path: "/posts")
    assert_equal 1, messages.length
    assert_includes messages.first, "sqlite_busy_contention"
    assert_includes messages.first, %(source="request")
    assert_includes messages.first, %(path="/posts")

    now += 1
    monitor.report(error, source: "request", path: "/posts")
    assert_equal 1, messages.length

    now += 60
    monitor.report(error, source: "jobs", table: :lunula_jobs)
    monitor.report(error, source: "jobs", table: :lunula_jobs)
    assert_equal 2, messages.length
    assert_includes messages.last, %(source="jobs")
  end

  def test_busy_monitor_ignores_non_busy_database_errors
    messages = []
    monitor = Lunula::SQLite::BusyMonitor.new(
      threshold: 1,
      logger: Struct.new(:messages) do
        def warn(message) = messages << message
      end.new(messages)
    )

    refute monitor.report(Sequel::DatabaseError.new("no such table: posts"), source: "request")
    assert_empty messages
  end

  def test_database_job_adapter_reports_sqlite_busy_errors
    messages = []
    Lunula::SQLite.busy_monitor = Lunula::SQLite::BusyMonitor.new(
      threshold: 1,
      logger: Struct.new(:messages) do
        def warn(message) = messages << message
      end.new(messages)
    )
    adapter = Lunula::Jobs::Adapters::Database.new(database: @database)

    adapter.__send__(:durable_error, Sequel::DatabaseError.new("SQLite3::BusyException: database is locked"))

    assert_equal 1, messages.length
    assert_includes messages.first, "sqlite_busy_contention"
    assert_includes messages.first, %(source="jobs")
    assert_includes messages.first, %(table="lunula_jobs")
  end
end
