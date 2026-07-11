# frozen_string_literal: true

require_relative "test_helper"

class SecurityMiddlewareTest < Minitest::Test
  def test_csrf_rejects_array_tokens_without_crashing
    app = Hacienda::Middleware::CSRF.new(
      ->(_env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    )

    response = Rack::MockRequest.new(app).post(
      "/",
      params: {"_csrf" => ["invalid"]},
      "rack.session" => {csrf_token: "expected"}
    )

    assert_equal 403, response.status
    assert_equal "Invalid CSRF token", response.body
  end

  def test_csrf_does_not_touch_the_session_on_safe_requests
    session = {}
    app = Hacienda::Middleware::CSRF.new(
      ->(_env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    )

    response = Rack::MockRequest.new(app).get("/", "rack.session" => session)

    assert_equal 200, response.status
    assert_empty session
  end

  def test_csrf_accepts_a_valid_token_on_unsafe_requests
    app = Hacienda::Middleware::CSRF.new(
      ->(_env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    )

    response = Rack::MockRequest.new(app).post(
      "/",
      params: {"_csrf" => "expected"},
      "rack.session" => {csrf_token: "expected"}
    )

    assert_equal 200, response.status
  end

  def test_csrf_generates_a_token_on_unsafe_requests_without_one
    session = {}
    app = Hacienda::Middleware::CSRF.new(
      ->(_env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    )

    response = Rack::MockRequest.new(app).post("/", "rack.session" => session)

    assert_equal 403, response.status
    refute_nil session[:csrf_token]
  end

  def test_security_headers_adds_safe_defaults
    app = Hacienda::Middleware::SecurityHeaders.new(
      ->(_env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    )

    response = Rack::MockRequest.new(app).get("/")

    assert_equal "SAMEORIGIN", response["x-frame-options"]
    assert_equal "nosniff", response["x-content-type-options"]
    assert_equal "strict-origin-when-cross-origin", response["referrer-policy"]
    assert_includes response["content-security-policy"], "default-src 'self'"
    assert_includes response["content-security-policy"], "script-src 'self'"
    assert_nil response["strict-transport-security"]
  end

  def test_security_headers_adds_hsts_when_enabled
    app = Hacienda::Middleware::SecurityHeaders.new(
      ->(_env) { [200, {}, ["OK"]] },
      hsts: true
    )

    response = Rack::MockRequest.new(app).get("/")

    assert_equal "max-age=31536000; includeSubDomains", response["strict-transport-security"]
  end

  def test_security_headers_allows_custom_hsts_options
    app = Hacienda::Middleware::SecurityHeaders.new(
      ->(_env) { [200, {}, ["OK"]] },
      hsts: {max_age: 300, include_subdomains: false}
    )

    response = Rack::MockRequest.new(app).get("/")

    assert_equal "max-age=300", response["strict-transport-security"]
  end

  def test_security_headers_allows_custom_csp
    app = Hacienda::Middleware::SecurityHeaders.new(
      ->(_env) { [200, {}, ["OK"]] },
      csp: {
        "default-src" => ["'self'"],
        "connect-src" => ["'self'", "https://api.example.test"]
      }
    )

    response = Rack::MockRequest.new(app).get("/")

    assert_equal(
      "default-src 'self'; connect-src 'self' https://api.example.test",
      response["content-security-policy"]
    )
  end

  def test_security_headers_replaces_nonce_tokens_with_a_request_nonce
    app = Hacienda::Middleware::SecurityHeaders.new(
      ->(env) {
        env[Hacienda::Context::CSP_NONCE_ENV] = "known-nonce"
        [200, {}, ["OK"]]
      },
      csp: {
        "default-src" => ["'self'"],
        "script-src" => ["'self'", :nonce],
        "style-src" => ["'self'", "'nonce-%{nonce}'"]
      }
    )

    response = Rack::MockRequest.new(app).get("/")

    assert_equal(
      "default-src 'self'; script-src 'self' 'nonce-known-nonce'; style-src 'self' 'nonce-known-nonce'",
      response["content-security-policy"]
    )
  end

  def test_security_headers_generates_a_nonce_when_csp_requests_one
    seen_env = nil
    app = Hacienda::Middleware::SecurityHeaders.new(
      ->(env) {
        seen_env = env
        [200, {}, ["OK"]]
      },
      csp: {"script-src" => ["'self'", :nonce]}
    )

    response = Rack::MockRequest.new(app).get("/")
    nonce = seen_env.fetch(Hacienda::Context::CSP_NONCE_ENV)

    assert_match(/\Ascript-src 'self' 'nonce-[A-Za-z0-9+\/]+=*'\z/, response["content-security-policy"])
    assert_includes response["content-security-policy"], nonce
  end

  def test_security_headers_renders_bare_csp_directives
    app = Hacienda::Middleware::SecurityHeaders.new(
      ->(_env) { [200, {}, ["OK"]] },
      csp: {"upgrade-insecure-requests" => []}
    )

    response = Rack::MockRequest.new(app).get("/")

    assert_equal "upgrade-insecure-requests", response["content-security-policy"]
  end

  def test_security_headers_do_not_overwrite_existing_headers
    app = Hacienda::Middleware::SecurityHeaders.new(
      ->(_env) { [200, {"x-frame-options" => "DENY"}, ["OK"]] }
    )

    response = Rack::MockRequest.new(app).get("/")

    assert_equal "DENY", response["x-frame-options"]
  end

  def test_host_authorization_allows_configured_hosts_and_strips_ports
    app = Hacienda::Middleware::HostAuthorization.new(
      ->(_env) { [200, {}, ["OK"]] },
      hosts: ["Example.test"]
    )

    response = Rack::MockRequest.new(app).get("/", "HTTP_HOST" => "example.test:5151")

    assert_equal 200, response.status
  end

  def test_host_authorization_rejects_unknown_hosts
    app = Hacienda::Middleware::HostAuthorization.new(
      ->(_env) { [200, {}, ["OK"]] },
      hosts: ["example.test"]
    )

    response = Rack::MockRequest.new(app).get("/", "HTTP_HOST" => "attacker.test")

    assert_equal 403, response.status
    assert_equal "Forbidden host", response.body
  end

  def test_host_authorization_handles_ipv6_and_url_config_values
    ipv6_app = Hacienda::Middleware::HostAuthorization.new(
      ->(_env) { [200, {}, ["OK"]] },
      hosts: ["[::1]"]
    )
    url_app = Hacienda::Middleware::HostAuthorization.new(
      ->(_env) { [200, {}, ["OK"]] },
      hosts: ["https://App.Example.test:443"]
    )

    assert_equal 200, Rack::MockRequest.new(ipv6_app).get("/", "HTTP_HOST" => "[::1]:5151").status
    assert_equal 200, Rack::MockRequest.new(url_app).get("/", "HTTP_HOST" => "app.example.test").status
  end

  def test_app_url_uses_canonical_configuration_and_rejects_relative_paths
    previous_app_url = ENV.delete("HACIENDA_APP_URL")
    previous_legacy_url = ENV.delete("APP_URL")
    ENV["HACIENDA_APP_URL"] = "https://App.Example.test/base/"

    assert_equal "https://app.example.test/base", Hacienda.app_url
    assert_equal "https://app.example.test/posts/1?token=abc", Hacienda.app_url("/posts/1?token=abc")
    assert_equal "app.example.test", Hacienda.app_host
    assert_raises(ArgumentError) { Hacienda.app_url("posts/1") }
  ensure
    ENV["HACIENDA_APP_URL"] = previous_app_url if previous_app_url
    ENV.delete("HACIENDA_APP_URL") unless previous_app_url
    ENV["APP_URL"] = previous_legacy_url if previous_legacy_url
    ENV.delete("APP_URL") unless previous_legacy_url
  end

  def test_rate_limiter_limits_matching_requests
    app = Hacienda::Middleware::RateLimiter.new(
      ->(_env) { [200, {}, ["OK"]] },
      rules: [{method: "POST", path: "/login", limit: 2, period: 60}],
      key: ->(_request) { "client" }
    )
    request = Rack::MockRequest.new(app)

    assert_equal 200, request.post("/login").status
    assert_equal 200, request.post("/login").status

    limited = request.post("/login")
    assert_equal 429, limited.status
    assert_equal "Too many requests", limited.body
    assert_equal "60", limited["retry-after"]
  end

  def test_rate_limiter_ignores_non_matching_requests
    app = Hacienda::Middleware::RateLimiter.new(
      ->(_env) { [200, {}, ["OK"]] },
      rules: [{method: "POST", path: "/login", limit: 1, period: 60}],
      key: ->(_request) { "client" }
    )
    request = Rack::MockRequest.new(app)

    assert_equal 200, request.get("/login").status
    assert_equal 200, request.post("/signup").status
  end

  def test_rate_limiter_sweeps_expired_buckets
    store = {
      ["POST", "/login", "expired"] => {count: 99, reset_at: Time.now.to_f - 1}
    }
    app = Hacienda::Middleware::RateLimiter.new(
      ->(_env) { [200, {}, ["OK"]] },
      rules: [{method: "POST", path: "/login", limit: 1, period: 60}],
      store: store,
      key: ->(_request) { "client" }
    )

    assert_equal 200, Rack::MockRequest.new(app).post("/login").status
    refute store.key?(["POST", "/login", "expired"])
  end

  def test_rate_limiter_evicts_the_oldest_bucket_at_the_key_limit
    now = Time.now.to_f
    store = {
      ["POST", "/login", "old"] => {count: 1, reset_at: now + 10},
      ["POST", "/login", "new"] => {count: 1, reset_at: now + 20}
    }
    app = Hacienda::Middleware::RateLimiter.new(
      ->(_env) { [200, {}, ["OK"]] },
      rules: [{method: "POST", path: "/login", limit: 1, period: 60}],
      store: store,
      key: ->(request) { request.get_header("HTTP_X_CLIENT") },
      max_keys: 2
    )

    assert_equal 200, Rack::MockRequest.new(app).post("/login", "HTTP_X_CLIENT" => "fresh").status
    refute store.key?(["POST", "/login", "old"])
    assert store.key?(["POST", "/login", "new"])
    assert store.key?(["POST", "/login", "fresh"])
  end
end
