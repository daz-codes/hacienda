# frozen_string_literal: true

ENV["HACIENDA_ENV"] = "test"
ENV["RACK_ENV"] = "test"

require "minitest/autorun"
require "rack"
require "rack/test"
require "sequel"
require "sequel/extensions/migration"

TEST_ROOT = File.expand_path("..", __dir__) unless defined?(TEST_ROOT)
TEST_APP = Rack::Builder.parse_file(File.join(TEST_ROOT, "config.ru")) unless defined?(TEST_APP)

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
