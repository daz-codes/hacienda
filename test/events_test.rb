# frozen_string_literal: true

require_relative "test_helper"
require "sequel"
require "stringio"

class EventsTest < Minitest::Test
  Published = Data.define(:post_id)
  Archived = Data.define(:post_id)

  def test_publishes_typed_events_to_each_subscriber_in_declaration_order
    events = Hacienda::Events.new
    calls = []
    events.subscribe(Published, ->(event) { calls << [:first, event.post_id] })
    events.subscribe(Published, ->(event) { calls << [:second, event.post_id] })
    events.subscribe(Archived, ->(_event) { calls << [:wrong] })

    report = events.publish(Published.new(post_id: 42))

    assert_equal [[:first, 42], [:second, 42]], calls
    assert_equal 2, report.delivered
    assert_predicate report, :success?
  end

  def test_unsubscribe_removes_a_runtime_subscription
    events = Hacienda::Events.new
    recorder = Hacienda::Events::Recorder.new
    subscription = events.subscribe(Published, recorder)

    events.publish(Published.new(post_id: 1))
    events.unsubscribe(subscription)
    events.publish(Published.new(post_id: 2))

    assert_equal [Published.new(post_id: 1)], recorder.events
  end

  def test_configuration_can_be_reloaded_without_duplicate_subscribers
    events = Hacienda::Events.new
    recorder = Hacienda::Events::Recorder.new
    events.configure do |registry|
      registry.subscribe(Published, recorder)
    end

    events.reload!
    events.reload!
    events.publish(Published.new(post_id: 1))

    assert_equal 1, recorder.events.length
    assert_equal 1, events.subscriptions.fetch(Published).length
  end

  def test_subscriber_failures_are_reported_without_stopping_other_subscribers
    output = StringIO.new
    logger = Logger.new(output)
    reported = []
    events = Hacienda::Events.new(
      logger:,
      on_error: ->(event, subscriber, error) { reported << [event, subscriber, error] }
    )
    recorder = Hacienda::Events::Recorder.new
    failure = ->(_event) { raise "subscriber exploded" }
    events.subscribe(Published, failure)
    events.subscribe(Published, recorder)

    event = Published.new(post_id: 7)
    report = events.publish(event)

    assert_equal [event], recorder.events
    assert_equal 1, report.delivered
    refute_predicate report, :success?
    assert_equal [[event, failure, report.errors.first.error]], reported
    assert_includes output.string, "event_delivery_failed"
    assert_includes output.string, "subscriber exploded"
  end

  def test_subscriptions_are_safe_to_register_concurrently
    events = Hacienda::Events.new
    queue = Queue.new
    threads = 20.times.map do
      Thread.new { events.subscribe(Published, ->(_event) { queue << true }) }
    end
    threads.each(&:join)

    report = events.publish(Published.new(post_id: 1))

    assert_equal 20, report.delivered
    assert_equal 20, queue.size
  end

  def test_recorder_returns_a_copy_and_can_be_cleared
    recorder = Hacienda::Events::Recorder.new
    event = Published.new(post_id: 1)
    recorder.call(event)

    recorder.events.clear
    assert_equal [event], recorder.events

    assert_same recorder, recorder.clear
    assert_empty recorder.events
  end
end

class TransactionEventsTest < Minitest::Test
  Changed = Data.define(:value)

  def setup
    @root = Dir.mktmpdir("hacienda-events")
    FileUtils.mkdir_p(File.join(@root, "app", "domains"))
    @database = Sequel.sqlite
    @database.create_table(:records) do
      primary_key :id
      String :value
    end
    @events = Hacienda::Events.new
    @recorder = Hacienda::Events::Recorder.new
    @events.subscribe(Changed, @recorder)
    @app = Hacienda::Application.new(root: @root, database: @database, events: @events)
  end

  def teardown
    @app.loader.unload
    @app.loader.unregister
    @database.disconnect
    FileUtils.rm_rf(@root)
  end

  def test_dispatches_events_only_after_the_transaction_commits
    result = @app.transaction do |transaction|
      @database[:records].insert(value: "committed")
      transaction.emit Changed.new(value: "committed")

      assert_empty @recorder.events
      :result
    end

    assert_equal :result, result
    assert_equal [Changed.new(value: "committed")], @recorder.events
    assert_equal "committed", @database[:records].get(:value)
  end

  def test_discards_events_when_the_transaction_rolls_back
    @app.transaction do |transaction|
      @database[:records].insert(value: "rolled back")
      transaction.emit Changed.new(value: "rolled back")
      raise Sequel::Rollback
    end

    assert_empty @recorder.events
    assert_empty @database[:records].all
  end

  def test_discards_events_from_a_rolled_back_savepoint
    @app.transaction do |outer|
      @app.transaction(savepoint: true) do |inner|
        inner.emit Changed.new(value: "inner")
        raise Sequel::Rollback
      end

      outer.emit Changed.new(value: "outer")
    end

    assert_equal [Changed.new(value: "outer")], @recorder.events
  end

  def test_preserves_event_emission_order
    @app.transaction do |transaction|
      transaction.emit Changed.new(value: "first")
      transaction.emit Changed.new(value: "second")
    end

    assert_equal %w[first second], @recorder.events.map(&:value)
  end

  def test_context_delegates_to_the_application_transaction
    context = Hacienda::Context.new(Rack::MockRequest.env_for("/"), application: @app)

    context.transaction do |transaction|
      transaction.emit Changed.new(value: "from context")
    end

    assert_equal [Changed.new(value: "from context")], @recorder.events
  end

  def test_application_requires_an_explicit_database
    other_root = Dir.mktmpdir("hacienda-events-no-database")
    FileUtils.mkdir_p(File.join(other_root, "app", "domains"))
    app = Hacienda::Application.new(root: other_root)

    error = assert_raises(Hacienda::Error) { app.transaction { nil } }

    assert_includes error.message, "database is not configured"
  ensure
    app&.loader&.unload
    app&.loader&.unregister
    FileUtils.rm_rf(other_root) if other_root
  end
end

class EventReloadingTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("hacienda-event-reload")
    write "app/domains/posts/events.rb", <<~RUBY
      module Posts
        module Events
          Published = Data.define(:post_id)
        end
      end
    RUBY
    @app = Hacienda::Application.new(root: @root, reload: true)
    @recorder = Hacienda::Events::Recorder.new
    @app.events.configure do |events|
      events.subscribe Posts::Events::Published, @recorder
    end
  end

  def teardown
    @app.loader.unload
    @app.loader.unregister
    Object.__send__(:remove_const, :Posts) if Object.const_defined?(:Posts, false)
    FileUtils.rm_rf(@root)
  end

  def test_rebuilds_configured_subscriptions_after_code_reload
    original_event_class = Posts::Events::Published

    @app.reload!
    reloaded_event_class = Posts::Events::Published
    event = reloaded_event_class.new(post_id: 9)
    @app.events.publish(event)

    refute_same original_event_class, reloaded_event_class
    assert_equal [event], @recorder.events
    assert_equal [reloaded_event_class], @app.events.subscriptions.keys
  end

  private

  def write(path, content)
    destination = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(destination))
    File.write(destination, content)
  end
end

class DurableEventOutboxTest < Minitest::Test
  Changed = Data.define(:record_id, :occurred_at)

  def setup
    @root = Dir.mktmpdir("hacienda-outbox")
    FileUtils.mkdir_p(File.join(@root, "app", "domains"))
    @now = Time.utc(2026, 6, 29, 12)
    @database = Sequel.sqlite
    @database.create_table(:records) { primary_key :id; String :value }
    create_outbox_table
    @events = Hacienda::Events.new
    @recorder = Hacienda::Events::Recorder.new
    @events.subscribe(Changed, @recorder)
    @outbox = outbox
    @app = Hacienda::Application.new(
      root: @root,
      database: @database,
      events: @events,
      outbox: @outbox
    )
  end

  def teardown
    @app.loader.unload
    @app.loader.unregister
    @database.disconnect
    FileUtils.rm_rf(@root)
  end

  def test_commit_persists_event_without_delivering_it_inline
    @app.transaction do |transaction|
      id = @database[:records].insert(value: "changed")
      transaction.emit Changed.new(record_id: id, occurred_at: @now)
    end

    assert_empty @recorder.events
    assert_equal 1, @database[:hacienda_outbox].count

    execution = outbox.dispatch_once(events: @events)

    assert_equal :succeeded, execution.status
    assert_equal [Changed.new(record_id: 1, occurred_at: @now)], @recorder.events
    assert_empty @database[:hacienda_outbox]
  end

  def test_rollback_removes_business_write_and_outbox_record
    @app.transaction do |transaction|
      @database[:records].insert(value: "rolled back")
      transaction.emit Changed.new(record_id: 1, occurred_at: @now)
      raise Sequel::Rollback
    end

    assert_empty @database[:records]
    assert_empty @database[:hacienda_outbox]
  end

  def test_subscriber_failure_keeps_event_for_retry
    @events.subscribe(Changed, ->(_event) { raise "not available" })

    @app.transaction do |transaction|
      transaction.emit Changed.new(record_id: 1, occurred_at: @now)
    end
    execution = @outbox.dispatch_once(events: @events)

    assert_equal :retrying, execution.status
    row = @database[:hacienda_outbox].first
    assert_equal 1, row[:attempts]
    assert_nil row[:failed_at]
    assert_includes row[:last_error], "subscriber"
  end

  def test_application_rejects_an_outbox_on_a_different_database
    other_database = Sequel.sqlite
    other_outbox = Hacienda::Events::Outbox.new(database: other_database)

    error = assert_raises(ArgumentError) do
      Hacienda::Application.new(root: @root, database: @database, outbox: other_outbox)
    end

    assert_includes error.message, "application's database"
  ensure
    other_database&.disconnect
  end

  def test_lease_loss_is_an_uncertain_outbox_outcome_not_a_delivery_failure
    @events.subscribe(Changed, ->(_event) { @database[:hacienda_outbox].update(locked_by: "another-worker") })
    @app.transaction do |transaction|
      transaction.emit Changed.new(record_id: 1, occurred_at: @now)
    end

    execution = @outbox.dispatch_once(events: @events)

    assert_equal :lease_lost, execution.status
    assert_instance_of Hacienda::Durable::LeaseLost, execution.error
    assert_nil @database[:hacienda_outbox].get(:failed_at)
  end

  private

  def outbox
    Hacienda::Events::Outbox.new(
      database: @database,
      lease_seconds: 60,
      retry_delay: ->(_attempt) { 1 },
      clock: -> { @now }
    )
  end

  def create_outbox_table
    @database.create_table(:hacienda_outbox) do
      primary_key :id
      String :event_class, null: false
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
  end
end
