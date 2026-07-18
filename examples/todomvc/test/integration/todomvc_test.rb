# frozen_string_literal: true

ENV["RACK_ENV"] = "test"

require "minitest/autorun"
require "rack"
require "rack/test"
require "sequel"
require "sequel/extensions/migration"
require "tmpdir"
require "fileutils"

TODOMVC_ROOT = File.expand_path("../..", __dir__)
test_database_directory = unless ENV["DATABASE_URL"]
  Dir.mktmpdir("hacienda-todomvc-test").tap do |directory|
    ENV["DATABASE_URL"] = "sqlite://#{File.join(directory, "test.sqlite3")}"
  end
end
TODOMVC_APP = Rack::Builder.parse_file(File.join(TODOMVC_ROOT, "config.ru"))

Minitest.after_run do
  DB.disconnect
  FileUtils.rm_rf(test_database_directory) if test_database_directory
end

Sequel::Migrator.run(DB, File.join(TODOMVC_ROOT, "db", "migrations"))

class TodoMVCTest < Minitest::Test
  include Rack::Test::Methods

  def app
    TODOMVC_APP
  end

  def setup
    DB[:todos].delete
    clear_cookies
  end

  def test_user_can_create_toggle_rename_and_clear_todos
    get "/"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Hacienda + Helium"

    post "/todos", {_csrf: csrf_token, title: "Write a TodoMVC clone"}
    assert_equal 303, last_response.status

    todo = DB[:todos].first
    refute todo[:completed]

    patch "/todos/#{todo[:id]}", {_csrf: csrf_token}
    assert_equal 303, last_response.status
    assert DB[:todos].where(id: todo[:id]).first[:completed]

    patch "/todos/#{todo[:id]}/title", {_csrf: csrf_token, title: "Ship TodoMVC"}
    assert_equal 303, last_response.status
    assert_equal "Ship TodoMVC", DB[:todos].where(id: todo[:id]).first[:title]

    delete "/todos/completed", {_csrf: csrf_token}
    assert_equal 303, last_response.status
    assert_equal 0, DB[:todos].count
  end

  def test_layout_and_view_are_heavily_enhanced_with_helium
    get "/"

    assert_includes last_response.body, %(@import="/assets/todos.js")
    assert_includes last_response.body, %(@calculate:remaining)
    assert_includes last_response.body, %(@keydown.document.ctrl.k.prevent)
    assert_includes last_response.body, %(@effect:remaining)
    assert_includes last_response.body, %(@bind="draft")
    assert_includes last_response.body, %(@visible="showHelp")
    assert_includes last_response.body, %(:class="{ selected: filter === 'all' }")

    get "/assets/todos.js"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "export function visibleTodos"
  end

  def test_csrf_protection_rejects_unsafe_writes
    post "/todos", {title: "No token"}

    assert_equal 403, last_response.status
  end

  private

  def csrf_token
    last_response.body.match(/name="_csrf" value="([^"]+)"/)&.captures&.first || begin
      get "/"
      last_response.body.match(/name="_csrf" value="([^"]+)"/).captures.first
    end
  end
end
