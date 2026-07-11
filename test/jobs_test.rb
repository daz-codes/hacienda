# frozen_string_literal: true

require_relative "test_helper"

class JobsTest < Minitest::Test
  module RecorderJob
    module_function

    def perform(value, store:)
      store << value
    end
  end

  module BrokenJob
    module_function

    def perform
      raise "boom"
    end
  end

  module PriorityJob
    module_function

    def priority = -5

    def perform(value, store:)
      store << value
    end
  end

  class UnknownCapabilityAdapter
    def capabilities = %i[telepathic]

    def enqueue(job, args:, kwargs:, queue:, priority:, scheduled_at:, idempotency_key:)
      true
    end
  end

  class LegacyAdapter
    def enqueue(job, args:, kwargs:)
      true
    end
  end

  def setup
    Hacienda.configure_logger(output: File::NULL, level: :warn)
    Hacienda.clear_enqueued_jobs
    Hacienda.configure_jobs(adapter: :inline, outbox: nil)
  end

  def teardown
    Hacienda.shutdown_jobs
    Hacienda.clear_enqueued_jobs
    Hacienda.configure_jobs(adapter: :inline, outbox: nil)
  end

  def test_inline_adapter_performs_immediately
    store = []

    Hacienda.configure_jobs(adapter: :inline)
    Hacienda.enqueue(RecorderJob, "published", store:)

    assert_equal ["published"], store
  end

  def test_test_adapter_records_jobs
    store = []

    Hacienda.configure_jobs(adapter: :test)
    Hacienda.enqueue(RecorderJob, "queued", store:)

    assert_empty store
    assert_equal 1, Hacienda.enqueued_jobs.length
    assert_equal RecorderJob, Hacienda.enqueued_jobs.first.fetch(:job)

    assert_equal 1, Hacienda.perform_enqueued_jobs
    assert_equal ["queued"], store
    assert_empty Hacienda.enqueued_jobs
  end

  def test_async_adapter_performs_in_background
    store = Queue.new

    adapter = Hacienda::Jobs::Adapters::Async.new
    Hacienda.configure_jobs(adapter:)
    Hacienda.enqueue(RecorderJob, "async", store:)

    assert_equal "async", store.pop
  ensure
    adapter&.shutdown
  end

  def test_async_adapter_waits_for_scheduled_jobs_and_orders_ready_work_by_priority
    store = Queue.new
    adapter = Hacienda::Jobs::Adapters::Async.new
    due_at = Time.now.utc + 0.05

    adapter.enqueue(RecorderJob, args: ["normal"], kwargs: {store:}, scheduled_at: due_at)
    adapter.enqueue(PriorityJob, args: ["priority"], kwargs: {store:}, scheduled_at: due_at)

    sleep 0.01
    assert_predicate store, :empty?
    assert_equal "priority", store.pop
    assert_equal "normal", store.pop
  ensure
    adapter&.shutdown
  end

  def test_enqueue_in_and_enqueue_at_record_schedule_metadata
    Hacienda.configure_jobs(adapter: :test)
    before = Time.now.utc

    Hacienda.enqueue_in(30, PriorityJob, "later", store: [])
    relative = Hacienda.enqueued_jobs.last
    Hacienda.enqueue_at(before + 60, PriorityJob, "at", store: [])
    absolute = Hacienda.enqueued_jobs.last

    assert_in_delta before + 30, relative.fetch(:scheduled_at), 1
    assert_equal(-5, relative.fetch(:priority))
    assert_equal before + 60, absolute.fetch(:scheduled_at)
  end

  def test_enqueue_in_rejects_invalid_delays
    error = assert_raises(Hacienda::Jobs::Error) do
      Hacienda.enqueue_in(-1, RecorderJob, "never", store: [])
    end

    assert_includes error.message, "finite and non-negative"
  end

  def test_unknown_job_adapter_raises_a_clear_error
    Hacienda.configure_jobs(adapter: :somewhere)

    error = assert_raises(Hacienda::Jobs::Error) do
      Hacienda.enqueue(RecorderJob, "nope", store: [])
    end

    assert_includes error.message, "unknown job adapter"
  end

  def test_builtin_adapters_publish_explicit_capabilities
    assert_equal %i[inline], Hacienda::Jobs::Adapter.capabilities(Hacienda::Jobs::Adapters::Inline)
    assert_equal %i[asynchronous scheduled priorities], Hacienda::Jobs::Adapter.capabilities(Hacienda::Jobs::Adapters::Async.new)
    assert_equal %i[test scheduled priorities], Hacienda::Jobs::Adapter.capabilities(Hacienda::Jobs::Adapters::Test)
  end

  def test_adapter_must_implement_enqueue
    Hacienda.configure_jobs(adapter: Object.new)

    error = assert_raises(Hacienda::Jobs::Error) { Hacienda.job_adapter }

    assert_includes error.message, "must respond to enqueue"
  end

  def test_adapter_rejects_unknown_capabilities
    Hacienda.configure_jobs(adapter: UnknownCapabilityAdapter.new)

    error = assert_raises(Hacienda::Jobs::Error) { Hacienda.job_adapter }

    assert_includes error.message, "unknown capabilities: telepathic"
  end

  def test_adapter_rejects_an_incomplete_enqueue_contract
    Hacienda.configure_jobs(adapter: LegacyAdapter.new)

    error = assert_raises(Hacienda::Jobs::Error) { Hacienda.job_adapter }

    assert_includes error.message, "must implement enqueue"
  end
end
