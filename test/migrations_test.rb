# frozen_string_literal: true

require_relative "test_helper"
require "sequel"
require "sequel/extensions/migration"

class MigrationsTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("hacienda-migrations")
    @database = Sequel.sqlite
  end

  def teardown
    @database.disconnect
    FileUtils.rm_rf(@root)
  end

  def test_timestamp_migrations_report_only_unapplied_files
    first = write_migration("20260717090000_create_posts.rb", :posts)
    second = write_migration("20260717090100_create_comments.rb", :comments)

    assert_equal [first, second], Hacienda::Migrations.pending(database: @database, directory: @root)

    Sequel::TimestampMigrator.run_single(@database, first, direction: :up)

    assert_equal [second], Hacienda::Migrations.pending(database: @database, directory: @root)
    refute Hacienda::Migrations.current?(database: @database, directory: @root)

    Sequel::Migrator.run(@database, @root)

    assert Hacienda::Migrations.current?(database: @database, directory: @root)
  end

  def test_integer_migrations_report_versions_after_the_current_version
    first = write_migration("001_create_posts.rb", :posts)
    second = write_migration("002_create_comments.rb", :comments)

    assert_equal [first, second], Hacienda::Migrations.pending(database: @database, directory: @root)

    Sequel::Migrator.run(@database, @root, target: 1)

    assert_equal [second], Hacienda::Migrations.pending(database: @database, directory: @root)
  end

  def test_pending_migration_middleware_recovers_after_migrations_are_applied
    migration = write_migration("20260717090000_create_posts.rb", :posts)
    now = 0.0
    calls = 0
    app = ->(_env) { calls += 1; [200, {"content-type" => "text/plain"}, ["Ready"]] }
    middleware = Hacienda::Middleware::PendingMigrations.new(
      app,
      database: @database,
      directory: @root,
      environment: "development",
      check_interval: 1,
      clock: -> { now }
    )
    request = Rack::MockRequest.new(middleware)

    response = request.get("/")

    assert_equal 503, response.status
    assert_includes response.body, File.basename(migration)
    assert_includes response.body, "bundle exec hac db:migrate"
    assert_equal 0, calls

    Sequel::Migrator.run(@database, @root)
    now = 2.0

    response = request.get("/")

    assert_equal 200, response.status
    assert_equal "Ready", response.body
    assert_equal 1, calls
  end

  def test_pending_migration_middleware_does_not_leak_names_in_production
    migration = write_migration("20260717090000_create_secret_records.rb", :secret_records)
    middleware = Hacienda::Middleware::PendingMigrations.new(
      ->(_env) { flunk "pending request should not reach the application" },
      database: @database,
      directory: @root,
      environment: "production"
    )

    response = Rack::MockRequest.new(middleware).get("/")

    assert_equal 503, response.status
    assert_includes response.body, "Service unavailable"
    refute_includes response.body, File.basename(migration)
  end

  private

  def write_migration(filename, table)
    File.join(@root, filename).tap do |path|
      File.write(path, <<~RUBY)
        Sequel.migration do
          change do
            create_table(:#{table}) { primary_key :id }
          end
        end
      RUBY
    end
  end
end
