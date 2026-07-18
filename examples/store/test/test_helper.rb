# frozen_string_literal: true

ENV["LUNULA_ENV"] = "test"
ENV["RACK_ENV"] = "test"

require "minitest/autorun"
require "rack"
require "rack/test"
require "sequel"
require "sequel/extensions/migration"
require "tmpdir"
require "fileutils"

TEST_ROOT = File.expand_path("..", __dir__) unless defined?(TEST_ROOT)
test_database_directory = unless ENV["DATABASE_URL"]
  Dir.mktmpdir("lunula-store-test").tap do |directory|
    ENV["DATABASE_URL"] = "sqlite://#{File.join(directory, "test.sqlite3")}"
  end
end
TEST_APP = Rack::Builder.parse_file(File.join(TEST_ROOT, "config.ru")) unless defined?(TEST_APP)

Minitest.after_run do
  APP.database&.disconnect
  FileUtils.rm_rf(test_database_directory) if test_database_directory
end

migrations = File.join(TEST_ROOT, "db", "migrations")
if Dir[File.join(migrations, "*.rb")].any?
  Sequel::Migrator.run(APP.database, migrations)
end

class ApplicationTest < Minitest::Test
  include Rack::Test::Methods

  def app
    TEST_APP
  end

  def database
    APP.database
  end

  def csrf_token(path = "/")
    get path unless last_request
    last_request.env.fetch("rack.session").fetch(:csrf_token)
  end

  def before_setup
    super
    clear_cookies
  end
end
