# frozen_string_literal: true

require_relative "test_helper"

unless ENV["POSTGRES_DATABASE_URL"]
  class PostgreSQLContractTest < Minitest::Test
    def test_postgresql_contracts_require_an_explicit_database
      skip "set POSTGRES_DATABASE_URL to run PostgreSQL portability contracts"
    end
  end
else
  require "json"
  require "securerandom"
  require "sequel"
  require "sequel/extensions/migration"

  class PostgreSQLContractRecord
    include Hacienda::Attributes

    attributes :id, :name, :metadata, :created_at, :updated_at
    attribute :lock_version, default: 0, cast: ->(value) { value.to_i }
  end

  module PostgreSQLRecorderJob
    module_function

    def perform(value)
      calls << value
    end

    def calls
      @calls ||= []
    end
  end

  module PostgreSQLFailingJob
    module_function

    def max_attempts = 2
    def perform = raise "expected PostgreSQL contract failure"
  end

  class PostgreSQLContractTest < Minitest::Test
    MIGRATIONS = File.expand_path("../examples/store/db/migrations", __dir__)

    def setup
      @schema = :"hacienda_test_#{Process.pid}_#{SecureRandom.hex(6)}"
      @admin = Sequel.connect(ENV.fetch("POSTGRES_DATABASE_URL"), max_connections: 1)
      @admin.create_schema(@schema)
      @database = Sequel.connect(ENV.fetch("POSTGRES_DATABASE_URL"), max_connections: 1)
      @database.run("SET search_path TO #{@database.literal(Sequel.identifier(@schema))}")
      Sequel::Migrator.run(@database, MIGRATIONS)
      create_contract_records
      @now = Time.utc(2026, 7, 13, 12)
      PostgreSQLRecorderJob.calls.clear
    end

    def teardown
      @database&.disconnect
      @admin&.drop_schema(@schema, cascade: true) if @schema
      @admin&.disconnect
      Hacienda.configure_jobs(adapter: :inline)
      PostgreSQLRecorderJob.calls.clear
    end

    def test_generated_migrations_apply_to_postgresql
      expected = %i[
        hacienda_jobs
        hacienda_job_outbox
        hacienda_job_workers
        hacienda_job_queues
        hacienda_outbox
        hacienda_recurring_runs
        hacienda_sessions
      ]

      expected.each { |table| assert @database.table_exists?(table), "expected #{table} to exist" }
      assert Hacienda::Migrations.current?(database: @database, directory: MIGRATIONS)
    end

    def test_store_crud_transactions_and_optimistic_locking
      store = contract_store
      record = store.save(PostgreSQLContractRecord.new(name: "Initial", metadata: {"portable" => true}))
      first = store.find(record.id)
      stale = store.find(record.id)

      first.name = "Committed"
      store.save(first)
      stale.name = "Stale"

      assert_raises(Hacienda::Store::StaleObject) { store.save(stale) }
      assert_equal "Committed", store.find(record.id).name
      assert_equal({"portable" => true}, store.find(record.id).metadata)

      @database.transaction do
        store.save(PostgreSQLContractRecord.new(name: "Rolled back"))
        raise Sequel::Rollback
      end

      assert_equal 1, @database[:contract_records].count
    end

    def test_durable_queue_completes_retries_and_respects_transactions
      adapter = database_adapter
      id = adapter.enqueue(PostgreSQLRecorderJob, args: ["portable"], kwargs: {})

      execution = adapter.work_once

      assert_equal id, execution.id
      assert_equal :succeeded, execution.status
      assert_equal ["portable"], PostgreSQLRecorderJob.calls
      refute_nil @database[:hacienda_jobs].where(id:).get(:completed_at)

      failed_id = adapter.enqueue(PostgreSQLFailingJob, args: [], kwargs: {})
      assert_equal :retrying, adapter.work_once.status
      @now += 1
      assert_equal :failed, adapter.work_once.status
      refute_nil @database[:hacienda_jobs].where(id: failed_id).get(:failed_at)

      @database.transaction do
        adapter.enqueue(PostgreSQLRecorderJob, args: ["rolled back"], kwargs: {})
        raise Sequel::Rollback
      end

      assert_equal 2, @database[:hacienda_jobs].count
    end

    private

    def create_contract_records
      @database.create_table(:contract_records) do
        primary_key :id
        String :name, null: false
        String :metadata, text: true, null: false, default: "{}"
        Integer :lock_version, null: false, default: 0
        DateTime :created_at
        DateTime :updated_at
      end
    end

    def contract_store
      Hacienda::Store.new(
        database: @database,
        table: :contract_records,
        record: PostgreSQLContractRecord,
        lock: :lock_version,
        coercions: {
          metadata: {
            load: ->(value) { JSON.parse(value.to_s) },
            dump: ->(value) { JSON.generate(value || {}) }
          }
        },
        clock: -> { @now }
      )
    end

    def database_adapter
      Hacienda::Jobs::Adapters::Database.new(
        database: @database,
        lease_seconds: 60,
        retry_delay: ->(_attempt) { 1 },
        clock: -> { @now }
      )
    end
  end
end
