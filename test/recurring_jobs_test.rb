# frozen_string_literal: true

require_relative "test_helper"
require "sequel"
require "tempfile"

class RecurringJobsTest < Minitest::Test
  module RecurringRecorderJob
    module_function

    def perform(value = nil, label: nil)
      calls << [value, label]
    end

    def calls
      @calls ||= []
    end

    def clear
      calls.clear
    end
  end

  def setup
    @now = Time.utc(2026, 7, 5, 12, 34, 56)
    @database = Sequel.sqlite
    create_jobs_table
    @adapter = Hacienda::Jobs::Adapters::Database.new(database: @database, clock: -> { @now })
    @schedule_file = Tempfile.new(["hacienda-recurring", ".yml"])
    RecurringRecorderJob.clear
  end

  def teardown
    @schedule_file.close
    @schedule_file.unlink
    @database.disconnect
    RecurringRecorderJob.clear
  end

  def test_schedule_loads_explicit_interval_tasks
    write_schedule(<<~YAML)
      tasks:
        heartbeat:
          job: "RecurringJobsTest::RecurringRecorderJob"
          every: "5 minutes"
          queue: "maintenance"
          priority: 10
          args: ["ping"]
          kwargs:
            label: "recurring"
    YAML

    schedule = Hacienda::Jobs::RecurringSchedule.load(@schedule_file.path)
    entry = schedule.entries.fetch(0)

    assert_equal "heartbeat", entry.name
    assert_equal 300, entry.interval
    assert_equal ["ping"], entry.args
    assert_equal({label: "recurring"}, entry.kwargs)
    assert_equal "maintenance", entry.queue
    assert_equal 10, entry.priority
    assert entry.enabled
  end

  def test_scheduler_enqueues_each_task_once_per_interval_slot
    write_schedule(<<~YAML)
      tasks:
        heartbeat:
          job: "RecurringJobsTest::RecurringRecorderJob"
          every: "1 minute"
          args: ["ping"]
          kwargs:
            label: "slot"
    YAML
    scheduler = scheduler_for_file

    first = scheduler.tick
    duplicate = scheduler.tick
    @now += 60
    second = scheduler.tick

    assert_equal 1, first.length
    assert_empty duplicate
    assert_equal 1, second.length
    assert_equal 2, @database[:hacienda_recurring_runs].count
    assert_equal 2, @database[:hacienda_jobs].count
    assert_equal ["12:34", "12:35"],
      @database[:hacienda_recurring_runs].order(:scheduled_at).select_map(:scheduled_at).map { |time| time.strftime("%H:%M") }
  end

  def test_scheduler_skips_disabled_tasks_and_can_trigger_manually
    write_schedule(<<~YAML)
      tasks:
        disabled:
          job: "RecurringJobsTest::RecurringRecorderJob"
          every: "1 hour"
          enabled: false
    YAML
    scheduler = scheduler_for_file

    assert_empty scheduler.tick
    result = scheduler.trigger("disabled")

    assert_equal "disabled", result.entry.name
    assert_equal 1, @database[:hacienda_recurring_runs].count
    assert @database[:hacienda_recurring_runs].first.fetch(:manual)
  end

  def test_schedule_can_toggle_enabled_in_yaml
    write_schedule(<<~YAML)
      tasks:
        cleanup:
          job: "RecurringJobsTest::RecurringRecorderJob"
          every: "1 hour"
          enabled: false
    YAML

    Hacienda::Jobs::RecurringSchedule.set_enabled(@schedule_file.path, "cleanup", true)

    schedule = Hacienda::Jobs::RecurringSchedule.load(@schedule_file.path)
    assert schedule.find("cleanup").enabled
  end

  private

  def scheduler_for_file
    Hacienda::Jobs::RecurringScheduler.new(
      database: @database,
      adapter: @adapter,
      path: @schedule_file.path,
      clock: -> { @now },
      poll_interval: 0
    )
  end

  def write_schedule(content)
    @schedule_file.rewind
    @schedule_file.write(content)
    @schedule_file.truncate(@schedule_file.pos)
    @schedule_file.flush
  end

  def create_jobs_table
    @database.create_table(:hacienda_jobs) do
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

    @database.create_table(:hacienda_recurring_runs) do
      primary_key :id
      String :task_name, null: false
      DateTime :scheduled_at, null: false
      TrueClass :manual, null: false, default: false
      Integer :enqueued_job_id
      DateTime :created_at, null: false
      unique [:task_name, :scheduled_at], name: :hacienda_recurring_runs_unique
    end
  end
end
