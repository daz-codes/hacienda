# frozen_string_literal: true

require_relative "test_helper"
require "sequel"

class SessionStoreTest < Minitest::Test
  def setup
    @database = Sequel.sqlite
    Hacienda::SessionStore.create_table(@database)
  end

  def teardown
    @database.disconnect
  end

  def test_persists_session_data_server_side
    app = Hacienda::SessionStore.new(
      ->(env) {
        request = Rack::Request.new(env)
        request.session[:count] = request.session.fetch(:count, 0) + 1
        [200, {"content-type" => "text/plain"}, [request.session[:count].to_s]]
      },
      database: @database,
      key: "hacienda.session",
      expire_after: 3600
    )
    request = Rack::MockRequest.new(app)

    first = request.get("/")
    second = request.get("/", "HTTP_COOKIE" => first["set-cookie"])

    assert_equal "1", first.body
    assert_equal "2", second.body
    assert_equal 1, @database[:hacienda_sessions].count
    refute_includes first["set-cookie"], "count"
  end

  def test_revoke_deletes_a_session_by_public_cookie_id
    app = Hacienda::SessionStore.new(
      ->(env) {
        request = Rack::Request.new(env)
        request.session[:user_id] ||= 1
        [200, {"content-type" => "text/plain"}, [request.session[:user_id].to_s]]
      },
      database: @database,
      key: "hacienda.session"
    )
    request = Rack::MockRequest.new(app)
    first = request.get("/")
    public_id = Rack::Utils.parse_cookies_header(first["set-cookie"]).fetch("hacienda.session")

    assert Hacienda::SessionStore.new(->(_env) { [204, {}, []] }, database: @database).revoke(public_id)
    assert_equal 0, @database[:hacienda_sessions].count
  end

  def test_expired_sessions_are_ignored_and_can_be_pruned
    current_time = Time.utc(2026, 7, 10, 12, 0, 0)
    clock = -> { current_time }
    app = Hacienda::SessionStore.new(
      ->(env) {
        request = Rack::Request.new(env)
        request.session[:count] = request.session.fetch(:count, 0) + 1
        [200, {"content-type" => "text/plain"}, [request.session[:count].to_s]]
      },
      database: @database,
      key: "hacienda.session",
      expire_after: 10,
      clock: clock
    )
    request = Rack::MockRequest.new(app)

    first = request.get("/")
    current_time += 11
    second = request.get("/", "HTTP_COOKIE" => first["set-cookie"])

    assert_equal "1", first.body
    assert_equal "1", second.body
    assert_equal 2, @database[:hacienda_sessions].count
    assert_equal 1, app.prune_expired(before: current_time)
    assert_equal 1, @database[:hacienda_sessions].count
  end

  def test_drop_deletes_the_existing_session_without_replacing_it
    app = Hacienda::SessionStore.new(
      ->(env) {
        request = Rack::Request.new(env)
        if request.path_info == "/logout"
          request.session_options[:drop] = true
          request.session.clear
        else
          request.session[:user_id] = 1
        end
        [200, {"content-type" => "text/plain"}, ["OK"]]
      },
      database: @database,
      key: "hacienda.session"
    )
    request = Rack::MockRequest.new(app)
    first = request.get("/")
    request.get("/logout", "HTTP_COOKIE" => first["set-cookie"])

    assert_equal 0, @database[:hacienda_sessions].count
  end
end
