# frozen_string_literal: true

require_relative "test_helper"

class SecurityMiddlewareTest < Minitest::Test
  def teardown
    Lunula::Middleware::RequestLimits.new(->(_env) { [200, {}, []] })
  end

  def test_request_limits_reject_declared_and_streamed_oversized_bodies
    app = Lunula::Middleware::RequestLimits.new(
      ->(env) { [200, {}, [env.fetch("rack.input").read]] },
      max_body_bytes: 4
    )
    request = Rack::MockRequest.new(app)

    declared = request.post("/", input: "12345", "CONTENT_TYPE" => "text/plain")
    assert_equal 413, declared.status
    assert_equal "Request body is too large", declared.body

    env = Rack::MockRequest.env_for("/", method: "POST", input: "12345")
    env.delete("CONTENT_LENGTH")
    status, _headers, body = app.call(env)
    assert_equal 413, status
    assert_equal "Request body is too large", body.join
  end

  def test_request_limits_bound_query_size_parameter_count_and_depth
    app = Lunula::Middleware::RequestLimits.new(
      ->(env) {
        Lunula::Params.from_request(Rack::Request.new(env))
        [200, {}, ["OK"]]
      },
      max_query_bytes: 100,
      max_parameters: 3,
      max_parameter_depth: 2
    )
    request = Rack::MockRequest.new(app)
    query_limited = Lunula::Middleware::RequestLimits.new(
      ->(_env) { [200, {}, ["OK"]] },
      max_query_bytes: 12
    )

    assert_equal 400, Rack::MockRequest.new(query_limited).get("/?long=12345678").status
    assert_equal 400, request.get("/?a=1&b=2&c=3&d=4").status
    assert_equal 400, request.get("/?a[b][c][d]=1").status
    assert_equal 200, request.get("/?a[b]=1&c=2").status
  end

  def test_request_limits_apply_to_json_and_hide_parser_details
    app = Lunula::Middleware::RequestLimits.new(
      ->(env) {
        Lunula::Params.from_request(Rack::Request.new(env))
        [200, {}, ["OK"]]
      },
      max_parameters: 3,
      max_parameter_depth: 2
    )
    request = Rack::MockRequest.new(app)

    too_many = request.post(
      "/",
      input: JSON.generate(a: 1, b: 2, c: 3, d: 4),
      "CONTENT_TYPE" => "application/json"
    )
    assert_equal 400, too_many.status
    assert_equal "Request parameters exceed configured limits", too_many.body

    malformed = request.post("/", input: "{secret:", "CONTENT_TYPE" => "application/json")
    assert_equal 400, malformed.status
    assert_equal "Malformed request parameters", malformed.body
  end

  def test_request_limits_bound_multipart_parts_and_files
    body = <<~MULTIPART.gsub("\n", "\r\n")
      --AaB03x
      Content-Disposition: form-data; name="first"

      one
      --AaB03x
      Content-Disposition: form-data; name="second"; filename="two.txt"
      Content-Type: text/plain

      two
      --AaB03x--
    MULTIPART
    app = Lunula::Middleware::RequestLimits.new(
      ->(env) {
        Rack::Request.new(env).params
        [200, {}, ["OK"]]
      },
      max_multipart_files: 1,
      max_multipart_parts: 1
    )

    response = Rack::MockRequest.new(app).post(
      "/",
      input: body,
      "CONTENT_TYPE" => "multipart/form-data; boundary=AaB03x"
    )

    assert_equal 413, response.status
    assert_equal "Multipart request has too many parts", response.body

    files_only = Lunula::Middleware::RequestLimits.new(
      ->(env) {
        Rack::Request.new(env).params
        [200, {}, ["OK"]]
      },
      max_multipart_files: 1,
      max_multipart_parts: 10
    )
    two_files = body.sub('name="first"', 'name="first"; filename="one.txt"')
    file_response = Rack::MockRequest.new(files_only).post(
      "/",
      input: two_files,
      "CONTENT_TYPE" => "multipart/form-data; boundary=AaB03x"
    )
    assert_equal 413, file_response.status
  end

  def test_csrf_rejects_array_tokens_without_crashing
    app = Lunula::Middleware::CSRF.new(
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
    app = Lunula::Middleware::CSRF.new(
      ->(_env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    )

    response = Rack::MockRequest.new(app).get("/", "rack.session" => session)

    assert_equal 200, response.status
    assert_empty session
  end

  def test_csrf_accepts_a_valid_token_on_unsafe_requests
    app = Lunula::Middleware::CSRF.new(
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
    app = Lunula::Middleware::CSRF.new(
      ->(_env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    )

    response = Rack::MockRequest.new(app).post("/", "rack.session" => session)

    assert_equal 403, response.status
    refute_nil session[:csrf_token]
  end

  def test_security_headers_adds_safe_defaults
    app = Lunula::Middleware::SecurityHeaders.new(
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
    app = Lunula::Middleware::SecurityHeaders.new(
      ->(_env) { [200, {}, ["OK"]] },
      hsts: true
    )

    response = Rack::MockRequest.new(app).get("/")

    assert_equal "max-age=31536000; includeSubDomains", response["strict-transport-security"]
  end

  def test_security_headers_allows_custom_hsts_options
    app = Lunula::Middleware::SecurityHeaders.new(
      ->(_env) { [200, {}, ["OK"]] },
      hsts: {max_age: 300, include_subdomains: false}
    )

    response = Rack::MockRequest.new(app).get("/")

    assert_equal "max-age=300", response["strict-transport-security"]
  end

  def test_security_headers_allows_custom_csp
    app = Lunula::Middleware::SecurityHeaders.new(
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
    app = Lunula::Middleware::SecurityHeaders.new(
      ->(env) {
        env[Lunula::Context::CSP_NONCE_ENV] = "known-nonce"
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
    app = Lunula::Middleware::SecurityHeaders.new(
      ->(env) {
        seen_env = env
        [200, {}, ["OK"]]
      },
      csp: {"script-src" => ["'self'", :nonce]}
    )

    response = Rack::MockRequest.new(app).get("/")
    nonce = seen_env.fetch(Lunula::Context::CSP_NONCE_ENV)

    assert_match(/\Ascript-src 'self' 'nonce-[A-Za-z0-9+\/]+=*'\z/, response["content-security-policy"])
    assert_includes response["content-security-policy"], nonce
  end

  def test_security_headers_renders_bare_csp_directives
    app = Lunula::Middleware::SecurityHeaders.new(
      ->(_env) { [200, {}, ["OK"]] },
      csp: {"upgrade-insecure-requests" => []}
    )

    response = Rack::MockRequest.new(app).get("/")

    assert_equal "upgrade-insecure-requests", response["content-security-policy"]
  end

  def test_security_headers_do_not_overwrite_existing_headers
    app = Lunula::Middleware::SecurityHeaders.new(
      ->(_env) { [200, {"x-frame-options" => "DENY"}, ["OK"]] }
    )

    response = Rack::MockRequest.new(app).get("/")

    assert_equal "DENY", response["x-frame-options"]
  end

  def test_host_authorization_allows_configured_hosts_and_strips_ports
    app = Lunula::Middleware::HostAuthorization.new(
      ->(_env) { [200, {}, ["OK"]] },
      hosts: ["Example.test"]
    )

    response = Rack::MockRequest.new(app).get("/", "HTTP_HOST" => "example.test:5151")

    assert_equal 200, response.status
  end

  def test_host_authorization_rejects_unknown_hosts
    app = Lunula::Middleware::HostAuthorization.new(
      ->(_env) { [200, {}, ["OK"]] },
      hosts: ["example.test"]
    )

    response = Rack::MockRequest.new(app).get("/", "HTTP_HOST" => "attacker.test")

    assert_equal 403, response.status
    assert_equal "Forbidden host", response.body
  end

  def test_host_authorization_handles_ipv6_and_url_config_values
    ipv6_app = Lunula::Middleware::HostAuthorization.new(
      ->(_env) { [200, {}, ["OK"]] },
      hosts: ["[::1]"]
    )
    url_app = Lunula::Middleware::HostAuthorization.new(
      ->(_env) { [200, {}, ["OK"]] },
      hosts: ["https://App.Example.test:443"]
    )

    assert_equal 200, Rack::MockRequest.new(ipv6_app).get("/", "HTTP_HOST" => "[::1]:5151").status
    assert_equal 200, Rack::MockRequest.new(url_app).get("/", "HTTP_HOST" => "app.example.test").status
  end

  def test_app_url_uses_canonical_configuration_and_rejects_relative_paths
    previous_app_url = ENV.delete("LUNULA_APP_URL")
    previous_legacy_url = ENV.delete("APP_URL")
    ENV["LUNULA_APP_URL"] = "https://App.Example.test/base/"

    assert_equal "https://app.example.test/base", Lunula.app_url
    assert_equal "https://app.example.test/posts/1?token=abc", Lunula.app_url("/posts/1?token=abc")
    assert_equal "app.example.test", Lunula.app_host
    assert_raises(ArgumentError) { Lunula.app_url("posts/1") }
  ensure
    ENV["LUNULA_APP_URL"] = previous_app_url if previous_app_url
    ENV.delete("LUNULA_APP_URL") unless previous_app_url
    ENV["APP_URL"] = previous_legacy_url if previous_legacy_url
    ENV.delete("APP_URL") unless previous_legacy_url
  end

  def test_rate_limiter_limits_matching_requests
    app = Lunula::Middleware::RateLimiter.new(
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
    app = Lunula::Middleware::RateLimiter.new(
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
    app = Lunula::Middleware::RateLimiter.new(
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
    app = Lunula::Middleware::RateLimiter.new(
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
