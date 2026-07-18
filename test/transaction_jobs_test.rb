# frozen_string_literal: true

require_relative "test_helper"
require "sequel"

class TransactionJobsTest < Minitest::Test
  module ExampleJob
    module_function

    def queue = "imports"

    def perform(value, label:)
      [value, label]
    end
  end

  module PriorityJob
    module_function

    def queue = "imports"
    def priority = -20
    def perform(value) = value
  end

  class ExternalAdapter
    attr_accessor :failures
    attr_reader :calls

    def initialize(failures: 0)
      @failures = failures
      @calls = []
    end

    def capabilities = %i[durable external idempotent_handoff]

    def enqueue(job, args:, kwargs:, queue:, priority:, scheduled_at:, idempotency_key:)
      calls << {
        job:,
        args:,
        kwargs:,
        queue:,
        priority:,
        scheduled_at:,
        idempotency_key:
      }
      if failures.positive?
        self.failures -= 1
        raise "external queue unavailable"
      end

      idempotency_key
    end
  end

  class ImmediateAdapter
    attr_reader :calls

    def initialize
      @calls = []
    end

    def capabilities = []

    def enqueue(job, args:, kwargs:, queue:, priority:, scheduled_at:, idempotency_key:)
      calls << job
    end
  end

  def setup
    @root = Dir.mktmpdir("lunula-transaction-jobs")
    FileUtils.mkdir_p(File.join(@root, "app", "domains"))
    @now = Time.utc(2026, 7, 2, 12)
    @database = Sequel.sqlite
    create_tables
    Lunula.clear_enqueued_jobs
  end

  def teardown
    @app&.loader&.unload
    @app&.loader&.unregister
    @database.disconnect
    Lunula.configure_jobs(adapter: :inline, outbox: nil)
    Lunula.clear_enqueued_jobs
    FileUtils.rm_rf(@root)
  end

  def test_database_adapter_enqueues_in_the_business_transaction
    adapter = database_adapter
    app_for(adapter:)

    @app.transaction do |transaction|
      @database[:records].insert(value: "committed")
      assert_equal ExampleJob, transaction.enqueue(ExampleJob, 7, label: "direct")
      assert_equal :transaction, transaction.enqueued_jobs.first.delivery
      assert_equal 1, @database[:lunula_jobs].count
    end

    row = @database[:lunula_jobs].first
    args, kwargs = Lunula::Jobs::Serializer.load(row.fetch(:payload))
    assert_equal [7], args
    assert_equal({label: "direct"}, kwargs)
    assert_equal "imports", row.fetch(:queue)
  end

  def test_database_adapter_job_is_removed_when_the_transaction_rolls_back
    app_for(adapter: database_adapter)

    @app.transaction do |transaction|
      @database[:records].insert(value: "rolled back")
      transaction.enqueue(ExampleJob, 7, label: "rollback")
      raise Sequel::Rollback
    end

    assert_empty @database[:records]
    assert_empty @database[:lunula_jobs]
  end

  def test_database_adapter_bulk_enqueue_participates_in_the_business_transaction
    app_for(adapter: database_adapter)
    callback_ids = nil

    @app.transaction do |transaction|
      ids = transaction.enqueue_all([
        {job: ExampleJob, args: [1], kwargs: {label: "bulk"}},
        {job: PriorityJob, args: [2], kwargs: {}}
      ]) { |inserted| callback_ids = inserted }

      assert_equal 2, ids.length
      assert_equal ids, callback_ids
      assert_equal 2, transaction.enqueued_jobs.length
      assert_equal 2, @database[:lunula_jobs].count
    end

    assert_equal ["imports"], @database[:lunula_jobs].select_map(:queue).uniq
    assert_equal 2, @database[:lunula_jobs].count
  end

  def test_database_adapter_respects_nested_savepoint_rollback
    app_for(adapter: database_adapter)

    @app.transaction do |outer|
      @app.transaction(savepoint: true) do |inner|
        inner.enqueue(ExampleJob, 1, label: "inner")
        raise Sequel::Rollback
      end
      outer.enqueue(ExampleJob, 2, label: "outer")
    end

    assert_equal 1, @database[:lunula_jobs].count
    args, = Lunula::Jobs::Serializer.load(@database[:lunula_jobs].get(:payload))
    assert_equal [2], args
  end

  def test_nondurable_adapter_enqueues_only_after_commit
    app_for(adapter: Lunula::Jobs::Adapters::Test)

    @app.transaction do |transaction|
      transaction.enqueue(ExampleJob, 3, label: "after")
      assert_empty Lunula.enqueued_jobs
      assert_equal :after_commit, transaction.enqueued_jobs.first.delivery
    end

    assert_equal 1, Lunula.enqueued_jobs.length
    assert_equal [3], Lunula.enqueued_jobs.first.fetch(:args)
  end

  def test_nondurable_adapter_does_not_enqueue_after_rollback
    app_for(adapter: Lunula::Jobs::Adapters::Test)

    @app.transaction do |transaction|
      transaction.enqueue(ExampleJob, 3, label: "rollback")
      raise Sequel::Rollback
    end

    assert_empty Lunula.enqueued_jobs
  end

  def test_unsupported_scheduling_is_rejected_before_commit
    adapter = ImmediateAdapter.new
    app_for(adapter:)

    error = assert_raises(Lunula::Jobs::Error) do
      @app.transaction do |transaction|
        @database[:records].insert(value: "must roll back")
        transaction.enqueue_at(@now + 60, ExampleJob, 3, label: "unsupported")
      end
    end

    assert_includes error.message, "does not support scheduled jobs"
    assert_empty @database[:records]
    assert_empty adapter.calls
  end

  def test_external_adapter_is_handed_off_after_commit
    adapter = ExternalAdapter.new
    outbox = job_outbox
    app_for(adapter:, outbox:)

    @app.transaction do |transaction|
      transaction.enqueue(ExampleJob, 4, label: "external")
      assert_equal :outbox, transaction.enqueued_jobs.first.delivery
      assert_equal 1, @database[:lunula_job_outbox].count
      assert_empty adapter.calls
    end

    execution = outbox.dispatch_once(adapter:)

    assert_equal :succeeded, execution.status
    assert_empty @database[:lunula_job_outbox]
    call = adapter.calls.fetch(0)
    assert_equal ExampleJob, call.fetch(:job)
    assert_equal [4], call.fetch(:args)
    assert_equal({label: "external"}, call.fetch(:kwargs))
    assert_equal "imports", call.fetch(:queue)
    refute_empty call.fetch(:idempotency_key)
  end

  def test_scheduled_external_handoff_waits_until_due_and_preserves_priority
    adapter = ExternalAdapter.new
    outbox = job_outbox
    app_for(adapter:, outbox:)

    @app.transaction do |transaction|
      transaction.enqueue_at(@now + 90, PriorityJob, 14)
    end

    row = @database[:lunula_job_outbox].first
    assert_equal(-20, row.fetch(:priority))
    assert_equal(
      (@now + 90).strftime("%Y-%m-%d %H:%M:%S"),
      row.fetch(:available_at).strftime("%Y-%m-%d %H:%M:%S")
    )
    assert_nil outbox.dispatch_once(adapter:)
    assert_equal [row.fetch(:id)], outbox.scheduled.map { |scheduled| scheduled.fetch(:id) }

    @now += 90
    assert_equal :succeeded, outbox.dispatch_once(adapter:).status
    assert_equal(-20, adapter.calls.first.fetch(:priority))
    assert_nil adapter.calls.first.fetch(:scheduled_at)
  end

  def test_external_handoff_is_removed_on_rollback
    adapter = ExternalAdapter.new
    app_for(adapter:, outbox: job_outbox)

    @app.transaction do |transaction|
      transaction.enqueue(ExampleJob, 5, label: "rollback")
      raise Sequel::Rollback
    end

    assert_empty @database[:lunula_job_outbox]
    assert_empty adapter.calls
  end

  def test_external_handoff_respects_nested_savepoint_rollback
    adapter = ExternalAdapter.new
    outbox = job_outbox
    app_for(adapter:, outbox:)

    @app.transaction do |outer|
      @app.transaction(savepoint: true) do |inner|
        inner.enqueue(ExampleJob, 10, label: "inner")
        raise Sequel::Rollback
      end
      outer.enqueue(ExampleJob, 11, label: "outer")
    end

    assert_equal 1, @database[:lunula_job_outbox].count
    args, = Lunula::Jobs::Serializer.load(@database[:lunula_job_outbox].get(:payload))
    assert_equal [11], args
  end

  def test_plain_enqueue_remains_independent_of_the_open_transaction
    app_for(adapter: Lunula::Jobs::Adapters::Test)

    @app.transaction do
      Lunula.enqueue(ExampleJob, 12, label: "independent")
      raise Sequel::Rollback
    end

    assert_equal 1, Lunula.enqueued_jobs.length
    assert_equal [12], Lunula.enqueued_jobs.first.fetch(:args)
  end

  def test_external_adapter_requires_a_transactional_outbox
    adapter = ExternalAdapter.new
    app_for(adapter:)

    error = assert_raises(Lunula::Jobs::OutboxError) do
      @app.transaction do |transaction|
        transaction.enqueue(ExampleJob, 6, label: "unsafe")
      end
    end

    assert_includes error.message, "requires a job outbox"
  end

  def test_handoff_retries_with_the_same_idempotency_key
    adapter = ExternalAdapter.new(failures: 1)
    outbox = job_outbox
    app_for(adapter:, outbox:)
    @app.transaction { |transaction| transaction.enqueue(ExampleJob, 8, label: "retry") }

    first = outbox.dispatch_once(adapter:)
    assert_equal :retrying, first.status
    first_key = adapter.calls.fetch(0).fetch(:idempotency_key)
    assert_equal 1, @database[:lunula_job_outbox].get(:attempts)

    @now += 1
    second = outbox.dispatch_once(adapter:)

    assert_equal :succeeded, second.status
    assert_equal first_key, adapter.calls.fetch(1).fetch(:idempotency_key)
    assert_empty @database[:lunula_job_outbox]
  end

  def test_worker_relays_external_handoffs
    adapter = ExternalAdapter.new
    outbox = job_outbox
    app_for(adapter:, outbox:)
    @app.transaction { |transaction| transaction.enqueue(ExampleJob, 9, label: "worker") }
    worker = Lunula::Jobs::Worker.new(adapter:, job_outbox: outbox, poll_interval: 0)

    result = worker.work_once

    assert_nil result.jobs
    assert_equal :succeeded, result.handoffs.status
    assert_nil result.events
    assert_empty @database[:lunula_job_outbox]
  end

  def test_terminal_handoff_failures_are_visible_and_retryable
    adapter = ExternalAdapter.new(failures: 1)
    outbox = job_outbox(max_attempts: 1)
    app_for(adapter:, outbox:)
    @app.transaction { |transaction| transaction.enqueue(ExampleJob, 13, label: "terminal") }

    execution = outbox.dispatch_once(adapter:)
    row = outbox.failed.fetch(0)

    assert_equal :failed, execution.status
    assert_equal 1, row.fetch(:attempts)
    assert_includes row.fetch(:last_error), "external queue unavailable"
    assert outbox.retry_failed(row.fetch(:id))

    assert_equal :succeeded, outbox.dispatch_once(adapter:).status
    assert_empty outbox.failed
  end

  def test_application_rejects_a_job_outbox_on_another_database
    adapter = ExternalAdapter.new
    other_database = Sequel.sqlite
    other_outbox = Lunula::Jobs::Outbox.new(database: other_database)
    Lunula.configure_jobs(adapter:)

    error = assert_raises(ArgumentError) do
      Lunula::Application.new(
        root: @root,
        database: @database,
        job_outbox: other_outbox
      )
    end

    assert_includes error.message, "application's database"
  ensure
    other_database&.disconnect
  end

  private

  def app_for(adapter:, outbox: nil)
    Lunula.configure_jobs(adapter:, outbox:)
    @app = Lunula::Application.new(
      root: @root,
      database: @database,
      job_outbox: outbox
    )
  end

  def database_adapter
    Lunula::Jobs::Adapters::Database.new(
      database: @database,
      lease_seconds: 60,
      retry_delay: ->(_attempt) { 1 },
      clock: -> { @now }
    )
  end

  def job_outbox(max_attempts: 10)
    Lunula::Jobs::Outbox.new(
      database: @database,
      max_attempts:,
      lease_seconds: 60,
      retry_delay: ->(_attempt) { 1 },
      clock: -> { @now }
    )
  end

  def create_tables
    @database.create_table(:records) do
      primary_key :id
      String :value
    end
    @database.create_table(:lunula_jobs) do
      primary_key :id
      String :queue, null: false
      Integer :priority, null: false, default: 0
      String :job_class, null: false
      String :payload, text: true, null: false
      Integer :attempts, null: false
      Integer :max_attempts, null: false
      DateTime :available_at, null: false
      DateTime :locked_at
      String :locked_by
      String :worker_id
      String :last_error, text: true
      String :failure_kind
      DateTime :cancel_requested_at
      DateTime :cancelled_at
      DateTime :failed_at
      DateTime :completed_at
      DateTime :discarded_at
      String :unique_key
      DateTime :unique_until
      String :concurrency_key
      Integer :concurrency_limit
      DateTime :blocked_at
      String :blocked_reason
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
    @database.create_table(:lunula_job_outbox) do
      primary_key :id
      String :handoff_id, null: false, unique: true
      String :queue, null: false
      Integer :priority, null: false, default: 0
      String :job_class, null: false
      String :payload, text: true, null: false
      Integer :attempts, null: false
      Integer :max_attempts, null: false
      DateTime :available_at, null: false
      DateTime :locked_at
      String :locked_by
      String :last_error, text: true
      String :failure_kind
      DateTime :failed_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
    @database.create_table(:lunula_job_workers) do
      String :id, primary_key: true
      Integer :process_id, null: false
      String :hostname, null: false
      String :queues, text: true, null: false
      Integer :thread_count, null: false
      Integer :batch_size, null: false
      DateTime :started_at, null: false
      DateTime :last_heartbeat_at, null: false
      Integer :current_workload, null: false, default: 0
    end
  end
end
