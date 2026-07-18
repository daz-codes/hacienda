# frozen_string_literal: true

ENV["LUNULA_ENV"] = "test"
ENV["RACK_ENV"] = "test"

require "minitest/autorun"
require "rack"
require "rack/test"

TEST_ROOT = File.expand_path("..", __dir__) unless defined?(TEST_ROOT)
TEST_APP = Rack::Builder.parse_file(File.join(TEST_ROOT, "config.ru")) unless defined?(TEST_APP)

class ApplicationTest < Minitest::Test
  include Rack::Test::Methods

  def app
    TEST_APP
  end

  def before_setup
    super
    clear_cookies
  end
end
