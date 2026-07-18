# frozen_string_literal: true

require_relative "test_helper"
require "sequel"
require "tempfile"

class DurableJobsTest < Minitest::Test
  module RecorderJob
    module_function

    def perform(value, label:)
      calls << [value, label]
    end

    def calls
      @calls ||= []
    end

    def clear
      calls.clear
    end
  end

  module FailingJob
    module_function

    def max_attempts = 2
    def perform = raise("boom")
  end

  module LowPriorityJob
    module_function

    def priority = 20
    def perform = RecorderJob.calls << [:low]
  end

  module HighPriorityJob
    module_function

    def priority = -10
    def perform = RecorderJob.calls << [:high]
  end

  module UniqueJob
    module_function

    def unique_key(account_id)
      "unique:#{account_id}"
    end

    def unique_for = 60

    def perform(account_id)
      RecorderJob.calls << [:unique, account_id]
    end
  end

  module RaisingUniqueJob
    module_function

    def unique_key(account_id)
      "raising:#{account_id}"
    end

    def unique_for = 60
    def unique_conflict = :raise
    def perform(account_id) = RecorderJob.calls << [:raising, account_id]
  end

  module ConcurrencyJob
    module_function

    def concurrency_key(account_id)
      "account:#{account_id}"
    end

    def concurrency_limit = 1

    def perform(account_id)
      RecorderJob.calls << [:concurrent, account_id]
    end
  end

  module LeaseLosingJob
    class << self
      attr_accessor :database
    end

    module_function

    def perform
      database[:lunula_jobs].update(locked_by: "another-worker")
    end
  end

  module BlockingJob
    class << self
      attr_accessor :started, :release, :completed
    end

    def self.perform(value)
      started << value
      release.pop
      completed << value
    end
  end

  module TimeoutJob
    class << self
      attr_accessor :started
    end

    def self.timeout = 0.03
    def self.max_attempts = 2

    def self.perform
      started << true
      loop do
        sleep 0.005
        Lunula::Jobs.checkpoint!
      end
    end
  end

  module CancellableJob
    class << self
      attr_accessor :started
    end

    def self.perform
      started << true
      loop do
        sleep 0.005
        Lunula::Jobs.checkpoint!
      end
    end
  end

  def setup
    @now = Time.utc(2026, 6, 29, 12)
    @database = Sequel.sqlite
    create_jobs_table
    @adapter = adapter
    RecorderJob.clear
    LeaseLosingJob.database = @database
    BlockingJob.started = Queue.new
    BlockingJob.release = Queue.new
    BlockingJob.completed = Queue.new
    TimeoutJob.started = Queue.new
    CancellableJob.started = Queue.new
  end

  def teardown
    @database.disconnect
    RecorderJob.clear
    Lunula.configure_jobs(adapter: :inline)
    Lunula.clear_mail_deliveries
  end

  def test_serializer_round_trips_supported_values
    date = Date.new(2026, 6, 29)
    time = Time.utc(2026, 6, 29, 12, 30, 1, 123_456)
    payload = Lunula::Jobs::Serializer.dump(
      args: [1, :published, date, time, {nested: [true, nil]}, {"__lunula_type__" => "application"}],
      kwargs: {label: "post"}
    )

    args, kwargs = Lunula::Jobs::Serializer.load(payload)

    assert_equal [
      1,
      :published,
      date,
      time,
      {"nested" => [true, nil]},
      {"__lunula_type__" => "application"}
    ], args
    assert_equal({label: "post"}, kwargs)
  end

  def test_rejects_arbitrary_objects
    error = assert_raises(Lunula::Jobs::Error) do
      @adapter.enqueue(RecorderJob, args: [Object.new], kwargs: {})
    end

    assert_includes error.message, "only accept JSON values"
    assert_empty @database[:lunula_jobs]
  end

  def test_job_survives_adapter_recreation_and_records_completion_history
    id = @adapter.enqueue(RecorderJob, args: [7], kwargs: {label: "durable"})
    restarted_adapter = adapter

    execution = restarted_adapter.work_once

    assert_equal id, execution.id
    assert_equal :succeeded, execution.status
    assert_equal [[7, "durable"]], RecorderJob.calls
    row = @database[:lunula_jobs].where(id:).first
    refute_nil row.fetch(:completed_at)
    assert_nil row.fetch(:locked_at)
    assert_nil row.fetch(:discarded_at)
    assert_empty restarted_adapter.pending
  end

  def test_scheduled_job_is_not_claimed_until_it_is_due
    Lunula.configure_jobs(adapter: @adapter)
    id = Lunula.enqueue_at(@now + 60, RecorderJob, 12, label: "scheduled")

    assert_nil @adapter.work_once
    assert_equal [id], @adapter.scheduled.map { |row| row.fetch(:id) }

    @now += 60
    execution = @adapter.work_once

    assert_equal id, execution.id
    assert_equal [[12, "scheduled"]], RecorderJob.calls
  end

  def test_priority_precedes_scheduled_time_for_eligible_jobs
    @adapter.enqueue(LowPriorityJob, args: [], kwargs: {})
    @adapter.enqueue(HighPriorityJob, args: [], kwargs: {}, scheduled_at: @now + 10)
    @now += 10

    @adapter.work_once
    @adapter.work_once

    assert_equal [[:high], [:low]], RecorderJob.calls
  end

  def test_equal_priority_jobs_use_scheduled_time_then_id
    first = @adapter.enqueue(RecorderJob, args: [1], kwargs: {label: "first"})
    second = @adapter.enqueue(RecorderJob, args: [2], kwargs: {label: "second"})

    assert_operator first, :<, second
    @adapter.work_once
    @adapter.work_once

    assert_equal [[1, "first"], [2, "second"]], RecorderJob.calls
  end

  def test_failed_jobs_retry_and_then_move_to_failed_state
    id = @adapter.enqueue(FailingJob, args: [], kwargs: {})

    first = @adapter.work_once
    assert_equal :retrying, first.status
    row = @database[:lunula_jobs].where(id:).first
    assert_equal 1, row[:attempts]
    assert_nil row[:failed_at]

    @now += 2
    second = @adapter.work_once
    assert_equal :failed, second.status
    row = @database[:lunula_jobs].where(id:).first
    assert_equal 2, row[:attempts]
    refute_nil row[:failed_at]
    refute_nil row[:discarded_at]
    assert_includes row[:last_error], "boom"
    assert_nil @adapter.work_once

    assert @adapter.retry_failed(id)
    assert_equal 0, @database[:lunula_jobs].where(id:).get(:attempts)
    assert_nil @database[:lunula_jobs].where(id:).get(:discarded_at)
  end

  def test_status_lists_and_prunes_job_history
    completed_id = @adapter.enqueue(RecorderJob, args: [1], kwargs: {label: "done"})
    failed_id = @adapter.enqueue(FailingJob, args: [], kwargs: {})
    scheduled_id = @adapter.enqueue(RecorderJob, args: [2], kwargs: {label: "later"}, scheduled_at: @now + 3600)

    @adapter.work_once
    @adapter.work_once
    @now += 1
    @adapter.work_once

    status = @adapter.status
    assert_equal 1, status.fetch(:completed)
    assert_equal 1, status.fetch(:discarded)
    assert_equal 1, status.fetch(:failed)
    assert_equal 1, status.fetch(:scheduled)
    assert_equal 0, status.fetch(:pending)
    assert_equal 1, status.fetch(:completed_last_hour)
    assert_equal [completed_id], @adapter.completed.map { |row| row.fetch(:id) }
    assert_equal [failed_id], @adapter.discarded.map { |row| row.fetch(:id) }
    assert_equal [scheduled_id], @adapter.scheduled.map { |row| row.fetch(:id) }

    counts = @adapter.prune(
      completed_before: @now + 1,
      discarded_before: @now + 1,
      failed_before: @now + 1
    )

    assert_equal 1, counts.fetch(:completed)
    assert_equal 1, counts.fetch(:discarded)
    assert_equal 0, counts.fetch(:failed)
    assert_equal [scheduled_id], @database[:lunula_jobs].select_map(:id)
  end

  def test_health_reports_failed_jobs_stale_workers_and_old_pending_work
    @adapter.enqueue(RecorderJob, args: [1], kwargs: {label: "old"})
    @now += 7200
    @database[:lunula_job_workers].insert(
      id: "stale-worker",
      process_id: 123,
      hostname: "worker.example",
      queues: JSON.generate(["default"]),
      thread_count: 1,
      batch_size: 1,
      started_at: @now - 7200,
      last_heartbeat_at: @now - 7200,
      current_workload: 0
    )

    health = @adapter.health(pending_warn_after: 60, pending_critical_after: 3600)

    assert_equal "critical", health.fetch(:status)
    assert_equal 1, health.dig(:checks, :stale_workers)
    assert_equal 7200, health.dig(:checks, :oldest_pending_age)
  end

  def test_dashboard_renders_queue_state_and_health_json
    recurring = Tempfile.new(["lunula-dashboard-recurring", ".yml"])
    recurring.write(<<~YAML)
      tasks:
        heartbeat:
          job: "DurableJobsTest::RecorderJob"
          every: "5 minutes"
    YAML
    recurring.flush
    @adapter.enqueue(RecorderJob, args: [5], kwargs: {label: "dashboard"})
    application = Struct.new(:root).new(Dir.mktmpdir("lunula-dashboard-root"))
    dashboard = Lunula::Jobs::Dashboard.new(
      application:,
      adapter: @adapter,
      recurring_path: recurring.path,
      authorized: ->(_request) { true }
    )
    request = Rack::MockRequest.new(dashboard)

    response = request.get("/")
    health = request.get("/health")

    assert_equal 200, response.status
    assert_includes response.body, "Lunula Jobs"
    assert_includes response.body, "DurableJobsTest::RecorderJob"
    assert_includes response.body, "heartbeat"
    assert_equal 200, health.status
    assert_includes health.body, %("status":"ok")
  ensure
    recurring&.close!
    FileUtils.rm_rf(application.root) if defined?(application) && application
  end

  def test_dashboard_requires_authorization_in_production_without_password
    previous = Lunula.env.name
    Lunula.env = "production"
    application = Struct.new(:root).new(Dir.mktmpdir("lunula-dashboard-root"))
    dashboard = Lunula::Jobs::Dashboard.new(application:, adapter: @adapter)

    response = Rack::MockRequest.new(dashboard).get("/")

    assert_equal 403, response.status
  ensure
    Lunula.env = previous
    FileUtils.rm_rf(application.root) if defined?(application) && application
  end

  def test_dashboard_local_development_gate_uses_remote_addr_not_forwarded_for
    previous = Lunula.env.name
    Lunula.env = "development"
    application = Struct.new(:root).new(Dir.mktmpdir("lunula-dashboard-root"))
    dashboard = Lunula::Jobs::Dashboard.new(application:, adapter: @adapter)

    response = Rack::MockRequest.new(dashboard).get(
      "/",
      "REMOTE_ADDR" => "203.0.113.10",
      "HTTP_X_FORWARDED_FOR" => "127.0.0.1"
    )

    assert_equal 403, response.status
  ensure
    Lunula.env = previous
    FileUtils.rm_rf(application.root) if defined?(application) && application
  end

  def test_lifecycle_notifications_are_emitted
    events = []
    subscription = Lunula::Jobs.subscribe { |event, payload| events << [event, payload] }
    id = @adapter.enqueue(RecorderJob, args: [4], kwargs: {label: "notify"})

    @adapter.work_once

    assert_equal [:enqueue, :start, :finish], events.map(&:first)
    assert events.all? { |_event, payload| payload.fetch(:id) == id }
  ensure
    Lunula::Jobs.unsubscribe(subscription) if subscription
  end

  def test_expired_lease_can_be_reclaimed
    id = @adapter.enqueue(RecorderJob, args: [9], kwargs: {label: "lease"})
    @database[:lunula_jobs].where(id:).update(
      locked_at: @now - 120,
      locked_by: "dead-worker"
    )

    execution = @adapter.work_once

    assert_equal :succeeded, execution.status
    assert_equal [[9, "lease"]], RecorderJob.calls
  end

  def test_expired_final_attempt_moves_to_failed_state_after_a_worker_crash
    id = @adapter.enqueue(RecorderJob, args: [9], kwargs: {label: "crashed"})
    @database[:lunula_jobs].where(id:).update(
      attempts: 10,
      locked_at: @now - 120,
      locked_by: "dead-worker"
    )

    assert_nil @adapter.work_once
    row = @database[:lunula_jobs].where(id:).first
    refute_nil row[:failed_at]
    assert_includes row[:last_error], "LeaseExpired"
    assert_empty RecorderJob.calls
  end

  def test_two_workers_cannot_claim_the_same_job
    @adapter.enqueue(RecorderJob, args: [11], kwargs: {label: "once"})
    results = Queue.new
    workers = 2.times.map do
      Thread.new { results << adapter.work_once }
    end
    workers.each(&:join)

    executions = 2.times.map { results.pop }.compact
    assert_equal 1, executions.length
    assert_equal :succeeded, executions.first.status
    assert_equal [[11, "once"]], RecorderJob.calls
  end

  def test_claim_many_returns_distinct_atomic_leases
    5.times { |index| @adapter.enqueue(RecorderJob, args: [index], kwargs: {label: "batch"}) }

    claims = @adapter.claim_many(queues: :all, limit: 3)

    assert_equal 3, claims.length
    assert_equal 3, claims.map { |claim| claim.row.fetch(:id) }.uniq.length
    assert claims.all? { |claim| claim.row.fetch(:attempts) == 1 }
  end

  def test_worker_processes_a_batch_with_configured_thread_concurrency
    4.times { |index| @adapter.enqueue(BlockingJob, args: [index], kwargs: {}) }
    worker = Lunula::Jobs::Worker.new(
      adapter: @adapter,
      queues: :all,
      threads: 2,
      batch_size: 4,
      poll_interval: 0
    )

    execution = Thread.new { worker.work_once }
    first_wave = 2.times.map { BlockingJob.started.pop }
    assert_empty BlockingJob.started
    2.times { BlockingJob.release << true }
    second_wave = 2.times.map { BlockingJob.started.pop }
    2.times { BlockingJob.release << true }
    result = execution.value

    assert_equal [0, 1, 2, 3], (first_wave + second_wave).sort
    assert_equal 4, result.jobs.length
    assert result.jobs.all? { |item| item.status == :succeeded }
  end

  def test_ordered_queues_are_served_fairly
    4.times do |index|
      @adapter.enqueue(RecorderJob, args: [index], kwargs: {label: "critical"}, queue: "critical")
    end
    @adapter.enqueue(RecorderJob, args: [99], kwargs: {label: "default"}, queue: "default")
    worker = Lunula::Jobs::Worker.new(
      adapter: @adapter,
      queues: %w[critical default],
      threads: 1,
      batch_size: 3,
      poll_interval: 0
    )

    worker.work_once

    assert_equal [[0, "critical"], [99, "default"], [1, "critical"]], RecorderJob.calls
  end

  def test_all_queues_use_global_priority_ordering
    @adapter.enqueue(LowPriorityJob, args: [], kwargs: {}, queue: "slow")
    @adapter.enqueue(HighPriorityJob, args: [], kwargs: {}, queue: "fast")
    worker = Lunula::Jobs::Worker.new(
      adapter: @adapter,
      queues: :all,
      threads: 1,
      batch_size: 2,
      poll_interval: 0
    )

    worker.work_once

    assert_equal [[:high], [:low]], RecorderJob.calls
  end

  def test_unique_job_keeps_existing_job_until_expiry
    first = @adapter.enqueue(UniqueJob, args: [7], kwargs: {})
    duplicate = @adapter.enqueue(UniqueJob, args: [7], kwargs: {})

    assert_equal first, duplicate
    assert_equal 1, @database[:lunula_jobs].count
    assert_equal "unique:7", @database[:lunula_jobs].where(id: first).get(:unique_key)

    @now += 61
    second = @adapter.enqueue(UniqueJob, args: [7], kwargs: {})

    refute_equal first, second
    assert_equal 2, @database[:lunula_jobs].count
  end

  def test_unique_job_can_raise_on_conflict
    @adapter.enqueue(RaisingUniqueJob, args: [8], kwargs: {})

    error = assert_raises(Lunula::Jobs::Error) do
      @adapter.enqueue(RaisingUniqueJob, args: [8], kwargs: {})
    end

    assert_includes error.message, "unique job already exists"
    assert_equal 1, @database[:lunula_jobs].count
  end

  def test_concurrency_limit_blocks_claims_and_exposes_reason
    first = @adapter.enqueue(ConcurrencyJob, args: [42], kwargs: {})
    second = @adapter.enqueue(ConcurrencyJob, args: [42], kwargs: {})

    claims = @adapter.claim_many(queues: :all, limit: 2)

    assert_equal [first], claims.map { |claim| claim.row.fetch(:id) }
    blocked = @adapter.blocked
    assert_equal [second], blocked.map { |row| row.fetch(:id) }
    assert_includes blocked.first.fetch(:blocked_reason), "concurrency limit 1"
    assert_equal 1, @adapter.status.fetch(:blocked)

    execution = @adapter.perform_claim(claims.first)
    assert_equal :succeeded, execution.status

    next_claim = @adapter.claim_many(queues: :all, limit: 1).fetch(0)
    assert_equal second, next_claim.row.fetch(:id)
    assert_nil @database[:lunula_jobs].where(id: second).get(:blocked_at)
    assert_nil @database[:lunula_jobs].where(id: second).get(:blocked_reason)
  end

  def test_concurrency_limit_survives_independent_connection_contention
    path = File.join(Dir.mktmpdir("lunula-job-concurrency"), "jobs.sqlite3")
    first_database = Sequel.sqlite(path, timeout: 5_000)
    first_database.run("PRAGMA journal_mode=WAL")
    create_jobs_table_on(first_database)
    second_database = Sequel.sqlite(path, timeout: 5_000)
    writer = Lunula::Jobs::Adapters::Database.new(database: first_database, clock: -> { @now })
    first_adapter = Lunula::Jobs::Adapters::Database.new(database: first_database, clock: -> { @now })
    second_adapter = Lunula::Jobs::Adapters::Database.new(database: second_database, clock: -> { @now })
    2.times { writer.enqueue(ConcurrencyJob, args: [99], kwargs: {}) }
    ready = Queue.new
    release = Queue.new

    workers = [first_adapter, second_adapter].map do |connection_adapter|
      Thread.new do
        ready << true
        release.pop
        connection_adapter.claim_many(queues: :all, limit: 1).map { |claim| claim.row.fetch(:id) }
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    ids = workers.flat_map(&:value)

    assert_equal 1, ids.length
  ensure
    first_database&.disconnect
    second_database&.disconnect
    FileUtils.rm_rf(File.dirname(path)) if path
  end

  def test_enqueue_all_inserts_jobs_in_one_transaction_and_runs_callback
    callback_ids = nil

    ids = Lunula::Jobs.enqueue_all(
      @adapter,
      [
        {job: RecorderJob, args: [1], kwargs: {label: "bulk"}},
        {job: RecorderJob, args: [2], kwargs: {label: "bulk"}}
      ]
    ) { |inserted| callback_ids = inserted }

    assert_equal 2, ids.length
    assert_equal ids, callback_ids
    assert_equal ids, @database[:lunula_jobs].order(:id).select_map(:id)
  end

  def test_pausing_and_resuming_a_queue_blocks_and_releases_pending_work
    first = @adapter.enqueue(RecorderJob, args: [1], kwargs: {label: "pause"}, queue: "mailers")

    assert @adapter.pause_queue("mailers", by: "test")
    assert_equal ["mailers"], @adapter.paused_queues.map { |row| row.fetch(:queue) }
    assert_empty @adapter.claim_many(queues: ["mailers"], limit: 1)
    blocked = @adapter.blocked
    assert_equal [first], blocked.map { |row| row.fetch(:id) }
    assert_equal "queue mailers is paused", blocked.first.fetch(:blocked_reason)

    second = @adapter.enqueue(RecorderJob, args: [2], kwargs: {label: "pause"}, queue: "mailers")
    assert_equal [first, second], @adapter.blocked.map { |row| row.fetch(:id) }

    assert @adapter.resume_queue("mailers")
    assert_empty @adapter.paused_queues
    claim = @adapter.claim_many(queues: ["mailers"], limit: 1).fetch(0)
    assert_equal first, claim.row.fetch(:id)
  end

  def test_discard_and_reschedule_are_safe_for_pending_jobs
    discard_id = @adapter.enqueue(RecorderJob, args: [1], kwargs: {label: "discard"})
    reschedule_id = @adapter.enqueue(RecorderJob, args: [2], kwargs: {label: "reschedule"})

    assert @adapter.discard(discard_id, reason: "operator")
    discarded = @database[:lunula_jobs].where(id: discard_id).first
    assert_equal "discarded", discarded.fetch(:failure_kind)
    assert_includes discarded.fetch(:last_error), "operator"
    refute_nil discarded.fetch(:discarded_at)

    assert @adapter.reschedule(reschedule_id, at: @now + 120)
    assert_equal [reschedule_id], @adapter.scheduled.map { |row| row.fetch(:id) }
  end

  def test_lifecycle_operations_do_not_mutate_running_jobs
    id = @adapter.enqueue(BlockingJob, args: [44], kwargs: {})
    claim = @adapter.claim_many(queues: :all, limit: 1).fetch(0)

    refute @adapter.discard(id, reason: "running")
    refute @adapter.reschedule(id, at: @now + 60)
    assert @adapter.cancel(id)
    assert_equal id, claim.row.fetch(:id)
  end

  def test_worker_registry_tracks_workload_and_graceful_drain
    @adapter.enqueue(BlockingJob, args: [21], kwargs: {})
    worker = Lunula::Jobs::Worker.new(
      adapter: @adapter,
      queues: %w[default mailers],
      threads: 2,
      batch_size: 4,
      poll_interval: 0,
      id: "worker-test"
    )

    thread = Thread.new { worker.run }
    assert_equal 21, BlockingJob.started.pop
    row = @adapter.workers.fetch(0)
    assert_equal "worker-test", row.fetch(:id)
    assert_equal Process.pid, row.fetch(:process_id)
    assert_equal ["default", "mailers"], JSON.parse(row.fetch(:queues))
    assert_equal 2, row.fetch(:thread_count)
    assert_equal 4, row.fetch(:batch_size)
    assert_equal 1, row.fetch(:current_workload)

    worker.stop
    assert_predicate thread, :alive?
    BlockingJob.release << true
    thread.join

    assert_equal 21, BlockingJob.completed.pop
    assert_empty @adapter.workers
  end

  def test_running_job_renews_its_lease
    adapter = Lunula::Jobs::Adapters::Database.new(
      database: @database,
      lease_seconds: 0.06,
      heartbeat_interval: 0.01,
      retry_delay: ->(_attempt) { 0 }
    )
    competing_adapter = Lunula::Jobs::Adapters::Database.new(
      database: @database,
      lease_seconds: 0.06,
      heartbeat_interval: 0.01
    )
    id = adapter.enqueue(BlockingJob, args: [31], kwargs: {})
    worker = Lunula::Jobs::Worker.new(adapter:, threads: 1, batch_size: 1, poll_interval: 0)

    execution = Thread.new { worker.work_once }
    assert_equal 31, BlockingJob.started.pop
    sleep 0.12

    assert_empty competing_adapter.claim_many(queues: :all, limit: 1)
    assert_equal id, @database[:lunula_jobs].get(:id)
    BlockingJob.release << true
    assert_equal :succeeded, execution.value.jobs.status
  end

  def test_running_job_keeps_its_worker_heartbeat_alive
    adapter = Lunula::Jobs::Adapters::Database.new(
      database: @database,
      lease_seconds: 0.1,
      heartbeat_interval: 0.01,
      worker_timeout: 0.04
    )
    competing = Lunula::Jobs::Adapters::Database.new(
      database: @database,
      lease_seconds: 0.1,
      heartbeat_interval: 0.01,
      worker_timeout: 0.04
    )
    adapter.enqueue(BlockingJob, args: [34], kwargs: {})
    worker = Lunula::Jobs::Worker.new(adapter:, threads: 1, batch_size: 1, poll_interval: 0, id: "live-worker")

    thread = Thread.new { worker.run }
    assert_equal 34, BlockingJob.started.pop
    sleep 0.1

    assert_empty competing.claim_many(queues: :all, limit: 1, worker_id: "competitor")
    assert_equal "live-worker", adapter.workers.fetch(0).fetch(:id)
    worker.stop
    BlockingJob.release << true
    thread.join

    assert_empty adapter.workers
  ensure
    worker&.stop
    BlockingJob.release << true if thread&.alive?
    thread&.join(1)
  end

  def test_cooperative_timeout_is_retried_then_becomes_terminal
    adapter = Lunula::Jobs::Adapters::Database.new(
      database: @database,
      lease_seconds: 1,
      heartbeat_interval: 0.01,
      retry_delay: ->(_attempt) { 0 }
    )
    id = adapter.enqueue(TimeoutJob, args: [], kwargs: {})

    first = adapter.work_once
    row = @database[:lunula_jobs].where(id:).first
    assert_equal :timed_out, first.status
    assert_equal "timeout", row.fetch(:failure_kind)
    assert_nil row.fetch(:failed_at)

    second = adapter.work_once
    row = @database[:lunula_jobs].where(id:).first
    assert_equal :timed_out, second.status
    assert_equal "timeout", row.fetch(:failure_kind)
    refute_nil row.fetch(:failed_at)
    assert_includes row.fetch(:last_error), "cooperative timeout"
  end

  def test_running_job_can_be_cancelled_cooperatively
    adapter = Lunula::Jobs::Adapters::Database.new(
      database: @database,
      lease_seconds: 1,
      heartbeat_interval: 0.01
    )
    id = adapter.enqueue(CancellableJob, args: [], kwargs: {})

    execution = Thread.new { adapter.work_once }
    CancellableJob.started.pop
    assert adapter.cancel(id)
    result = execution.value
    row = @database[:lunula_jobs].where(id:).first

    assert_equal :cancelled, result.status
    assert_equal "cancelled", row.fetch(:failure_kind)
    refute_nil row.fetch(:cancelled_at)
    refute_nil row.fetch(:failed_at)
    assert_nil row.fetch(:locked_at)
  end

  def test_pending_job_can_be_cancelled_without_execution
    id = @adapter.enqueue(RecorderJob, args: [32], kwargs: {label: "cancelled"})

    assert @adapter.cancel(id)
    row = @database[:lunula_jobs].where(id:).first

    assert_equal "cancelled", row.fetch(:failure_kind)
    refute_nil row.fetch(:failed_at)
    assert_nil @adapter.work_once
    assert_empty RecorderJob.calls
  end

  def test_stale_worker_heartbeat_releases_owned_jobs_before_the_lease_expires
    id = @adapter.enqueue(RecorderJob, args: [33], kwargs: {label: "recovered"})
    @database[:lunula_job_workers].insert(
      id: "dead-worker",
      process_id: 123,
      hostname: "dead.example",
      queues: '["default"]',
      thread_count: 1,
      batch_size: 1,
      started_at: @now - 120,
      last_heartbeat_at: @now - 120,
      current_workload: 1
    )
    @database[:lunula_jobs].where(id:).update(
      attempts: 1,
      locked_at: @now,
      locked_by: "dead-token",
      worker_id: "dead-worker"
    )
    recovering = Lunula::Jobs::Adapters::Database.new(
      database: @database,
      lease_seconds: 300,
      heartbeat_interval: 10,
      worker_timeout: 30,
      clock: -> { @now }
    )

    claim = recovering.claim_many(queues: :all, limit: 1, worker_id: "new-worker").fetch(0)

    assert_equal id, claim.row.fetch(:id)
    assert_equal "new-worker", claim.row.fetch(:worker_id)
    assert_equal "abandoned", claim.row.fetch(:failure_kind)
    assert_empty @database[:lunula_job_workers].where(id: "dead-worker")
  end

  def test_independent_database_connections_do_not_claim_duplicate_jobs
    path = File.join(Dir.mktmpdir("lunula-job-contention"), "jobs.sqlite3")
    first_database = Sequel.sqlite(path, timeout: 5_000)
    first_database.run("PRAGMA journal_mode=WAL")
    create_jobs_table_on(first_database)
    second_database = Sequel.sqlite(path, timeout: 5_000)
    first_adapter = Lunula::Jobs::Adapters::Database.new(database: first_database, clock: -> { @now })
    second_adapter = Lunula::Jobs::Adapters::Database.new(database: second_database, clock: -> { @now })
    12.times { |index| first_adapter.enqueue(RecorderJob, args: [index], kwargs: {label: "shared"}) }
    ready = Queue.new
    release = Queue.new

    workers = [first_adapter, second_adapter].map do |connection_adapter|
      Thread.new do
        ready << true
        release.pop
        connection_adapter.claim_many(queues: :all, limit: 6).map { |claim| claim.row.fetch(:id) }
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    ids = workers.flat_map(&:value)

    assert_equal 12, ids.length
    assert_equal ids.length, ids.uniq.length
  ensure
    first_database&.disconnect
    second_database&.disconnect
    FileUtils.rm_rf(File.dirname(path)) if path
  end

  def test_worker_processes_do_not_claim_duplicate_jobs
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    directory = Dir.mktmpdir("lunula-job-processes")
    path = File.join(directory, "jobs.sqlite3")
    database = Sequel.sqlite(path, timeout: 5_000)
    database.run("PRAGMA journal_mode=WAL")
    create_jobs_table_on(database)
    writer = Lunula::Jobs::Adapters::Database.new(database:, clock: -> { @now })
    12.times { |index| writer.enqueue(RecorderJob, args: [index], kwargs: {label: "process"}) }
    database.disconnect
    @database.disconnect
    children = 2.times.map do
      gate_read, gate_write = IO.pipe
      result_read, result_write = IO.pipe
      pid = fork do
        gate_write.close
        result_read.close
        gate_read.read(1)
        child_database = Sequel.sqlite(path, timeout: 5_000)
        adapter = Lunula::Jobs::Adapters::Database.new(database: child_database, clock: -> { @now })
        ids = adapter.claim_many(queues: :all, limit: 6).map { |claim| claim.row.fetch(:id) }
        Marshal.dump(ids, result_write)
        result_write.close
        child_database.disconnect
        exit! 0
      end
      gate_read.close
      result_write.close
      [pid, gate_write, result_read]
    end

    children.each { |_pid, gate, _result| gate.write("1"); gate.close }
    ids = children.flat_map { |_pid, _gate, result| Marshal.load(result) }
    statuses = children.map { |pid, _gate, _result| Process.wait2(pid).last }

    assert statuses.all?(&:success?)
    assert_equal 12, ids.length
    assert_equal ids.length, ids.uniq.length
  ensure
    children&.each do |_pid, gate, result|
      gate.close unless gate.closed?
      result.close unless result.closed?
    end
    database&.disconnect
    FileUtils.rm_rf(directory) if directory
  end

  def test_sigkill_job_is_recovered_from_the_dead_worker_heartbeat
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    directory = Dir.mktmpdir("lunula-job-sigkill")
    path = File.join(directory, "jobs.sqlite3")
    database = Sequel.sqlite(path, timeout: 5_000)
    database.run("PRAGMA journal_mode=WAL")
    create_jobs_table_on(database)
    create_workers_table_on(database)
    writer = Lunula::Jobs::Adapters::Database.new(database:, lease_seconds: 10, heartbeat_interval: 1)
    id = writer.enqueue(RecorderJob, args: [40], kwargs: {label: "sigkill"})
    database.disconnect
    @database.disconnect
    result_read, result_write = IO.pipe

    pid = fork do
      result_read.close
      child_database = Sequel.sqlite(path, timeout: 5_000)
      child_adapter = Lunula::Jobs::Adapters::Database.new(
        database: child_database,
        lease_seconds: 10,
        heartbeat_interval: 1,
        worker_timeout: 0.05
      )
      current_time = Time.now.utc
      child_adapter.register_worker(
        id: "killed-worker",
        process_id: Process.pid,
        hostname: "child.example",
        queues: '["default"]',
        thread_count: 1,
        batch_size: 1,
        started_at: current_time,
        last_heartbeat_at: current_time,
        current_workload: 1
      )
      claim = child_adapter.claim_many(queues: :all, limit: 1, worker_id: "killed-worker").fetch(0)
      Marshal.dump(claim.row.fetch(:id), result_write)
      result_write.close
      sleep
    end
    result_write.close
    assert_equal id, Marshal.load(result_read)
    Process.kill("KILL", pid)
    _waited, status = Process.wait2(pid)
    assert_predicate status, :signaled?
    sleep 0.08

    recovery_database = Sequel.sqlite(path, timeout: 5_000)
    recovery = Lunula::Jobs::Adapters::Database.new(
      database: recovery_database,
      lease_seconds: 10,
      heartbeat_interval: 1,
      worker_timeout: 0.05
    )
    claim = recovery.claim_many(queues: :all, limit: 1, worker_id: "replacement").fetch(0)

    assert_equal id, claim.row.fetch(:id)
    assert_equal "replacement", claim.row.fetch(:worker_id)
    assert_equal "abandoned", claim.row.fetch(:failure_kind)
    assert_empty recovery.workers
  ensure
    Process.kill("KILL", pid) if pid && process_alive?(pid)
    Process.wait(pid) if pid && process_alive?(pid)
    result_read&.close unless result_read&.closed?
    result_write&.close unless result_write&.closed?
    database&.disconnect
    recovery_database&.disconnect
    FileUtils.rm_rf(directory) if directory
  end

  def test_lease_loss_is_not_reported_as_a_job_failure
    id = @adapter.enqueue(LeaseLosingJob, args: [], kwargs: {})

    execution = @adapter.work_once

    assert_equal id, execution.id
    assert_equal :lease_lost, execution.status
    assert_instance_of Lunula::Durable::LeaseLost, execution.error
    assert_nil @database[:lunula_jobs].where(id:).get(:failed_at)
  end

  def test_worker_stop_finishes_the_current_job_without_starting_an_event
    started = Queue.new
    release = Queue.new
    adapter = Object.new
    adapter.define_singleton_method(:enqueue) do |_job, args:, kwargs:, queue:, priority:, scheduled_at:, idempotency_key:|
      true
    end
    adapter.define_singleton_method(:work_once) do |queue:|
      started << queue
      release.pop
      Lunula::Jobs::Execution.new(id: 1, status: :succeeded, error: nil)
    end
    outbox_calls = 0
    outbox = Object.new
    outbox.define_singleton_method(:dispatch_once) do |events:|
      outbox_calls += 1
    end
    worker = Lunula::Jobs::Worker.new(adapter:, outbox:, events: Object.new, poll_interval: 0)

    thread = Thread.new { worker.run }
    assert_equal "default", started.pop
    worker.stop
    release << true

    assert_same worker, thread.value
    assert_equal 0, outbox_calls
    assert_predicate worker, :stopping?
  end

  def test_enqueue_participates_in_the_callers_database_transaction
    Lunula.configure_jobs(adapter: @adapter)

    @database.transaction do
      Lunula.enqueue(RecorderJob, 3, label: "rolled-back")
      raise Sequel::Rollback
    end

    assert_empty @database[:lunula_jobs]
  ensure
    Lunula.configure_jobs(adapter: :inline)
  end

  def test_deliver_later_serializes_mail_for_a_durable_worker
    Lunula.configure_mail(delivery: :test, from: "hello@example.test")
    Lunula.configure_jobs(adapter: @adapter)

    Lunula.mail(
      to: "reader@example.test",
      subject: "Durable mail",
      text: "Delivered after restart"
    ).deliver_later

    assert_empty Lunula.mail_deliveries
    execution = adapter.work_once

    assert_equal :succeeded, execution.status
    assert_equal 1, Lunula.mail_deliveries.length
    assert_equal "Durable mail", Lunula.mail_deliveries.first.subject
  end

  private

  def adapter
    Lunula::Jobs::Adapters::Database.new(
      database: @database,
      lease_seconds: 60,
      retry_delay: ->(_attempt) { 1 },
      clock: -> { @now }
    )
  end

  def create_jobs_table
    create_jobs_table_on(@database)
    create_workers_table_on(@database)
    create_queues_table_on(@database)
  end

  def create_workers_table_on(database)
    database.create_table(:lunula_job_workers) do
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

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def create_queues_table_on(database)
    database.create_table(:lunula_job_queues) do
      String :queue, primary_key: true
      DateTime :paused_at, null: false
      String :paused_by
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
  end

  def create_jobs_table_on(database)
    database.create_table(:lunula_jobs) do
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
  end
end
