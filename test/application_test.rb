# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rack/session"
require "stringio"

class ApplicationTest < Minitest::Test
  def setup
    @previous_environment = Hacienda.env.to_s
    @previous_root = Hacienda.root
    Hacienda.env = "test"
    Hacienda.configure_logger(output: File::NULL, level: :warn)
    @root = Dir.mktmpdir("hacienda-app")
    write "app/domains/posts/routes.rb", <<~RUBY
      get "/posts/:id", :show
      get "/posts/new", :new
      post "/posts", :create
      post "/require-post", :require_post
      post "/echo/:id", :echo
      get "/full-load", :full_load
      get "/cached/:id", :cached
      get "/boom", :boom
      get "/busy", :busy
      guard Auth::Required do
        get "/posts/:id/edit", :edit
      end
    RUBY
    write "app/domains/posts/actions.rb", <<~RUBY
      module Posts
        class Actions < Hacienda::Actions
          LAST_MODIFIED = Time.utc(2026, 6, 28, 12, 0, 0)

          def show(_context, params)
            {post: {id: params[:id], title: "Explicit Ruby"}}
          end

          def boom(_context, _params)
            raise "Exploded"
          end

          def busy(_context, _params)
            raise Sequel::DatabaseError, "SQLite3::BusyException: database is locked"
          end

          def full_load(context, _params)
            context.navigation_reload!
            {title: "Full load"}
          end

          def cached(context, params)
            stale = context.stale?(
              etag: ["post", params[:id], LAST_MODIFIED.to_i],
              last_modified: LAST_MODIFIED,
              public: true,
              max_age: 60
            )
            return response("", status: 304) unless stale

            {post: {id: params[:id], title: "Cached post"}}
          end

          def new(_context, _params)
            render :new, title: "New post"
          end

          def create(context, _params)
            context.flash[:notice] = "Post created."
            redirect "/posts/1"
          end

          def require_post(_context, params)
            params.require(:post)
            "OK"
          end

          def echo(context, params)
            json(
              {params: params.to_h, raw_body: context.request.body.read},
              status: 200
            )
          end

          def edit(context, params)
            {title: "Editing \#{params[:id]} as \#{context.current_user}"}
          end
        end
      end
    RUBY
    write "app/domains/auth/load_current_user.rb", <<~RUBY
      module Auth
        module LoadCurrentUser
          module_function

          def load(context)
            context.current_user = "developer" if context.headers["Authorization"] == "Bearer secret"
          end
        end
      end
    RUBY
    write "app/domains/auth/required.rb", <<~RUBY
      module Auth
        module Required
          module_function

          def check(context, _params)
            redirect("/login") unless context.current_user
          end
        end
      end
    RUBY
    write "app/domains/posts/views/show.erb",
      %(<% page_title "Post \#{post[:id]}" %><h1><%= post[:title] %></h1><%= component :card, post: post %>)
    write "app/domains/posts/views/full_load.erb", "<h1><%= title %></h1>"
    write "app/domains/posts/views/cached.erb", "<h1><%= post[:title] %></h1>"
    write "app/domains/posts/views/new.erb", "<h1><%= title %></h1>"
    write "app/domains/posts/views/edit.erb", "<h1><%= title %></h1>"
    write "app/domains/posts/views/components/_card.erb", "<p>Post <%= post[:id] %></p>"
    write "app/layouts/application.erb", "<%= flash_messages context %><main><%= content %></main>"
    write "app/layouts/custom.erb", "<%= flash_messages context %><article><%= content %></article>"

    @app = Hacienda::Application.new(
      root: @root,
      layout: "custom",
      reload: true,
      context_loaders: ["Auth::LoadCurrentUser"]
    )
  end

  def teardown
    Hacienda::SQLite.busy_monitor = nil
    @app.loader.unload
    @app.loader.unregister
    FileUtils.rm_rf(@root)
    Hacienda.root = @previous_root if @previous_root
    Hacienda.env = @previous_environment
  end

  def test_hash_result_renders_matching_view_with_layout_and_components
    response = Rack::MockRequest.new(@app).get("/posts/42")

    assert_equal 200, response.status
    assert_includes response.body, "<article>"
    assert_includes response.body, "<h1>Explicit Ruby</h1>"
    assert_includes response.body, "<p>Post 42</p>"
  end

  def test_navigation_request_renders_one_page_target_without_the_layout
    response = Rack::MockRequest.new(@app).get(
      "/posts/42",
      "HTTP_X_HACIENDA_NAVIGATION" => "true"
    )

    assert_equal 200, response.status
    assert_equal "morph", response["x-hacienda-navigation"]
    assert_equal "Post 42", response["x-hacienda-title"]
    assert_equal "X-Hacienda-Navigation", response["vary"]
    assert_match(/\A<div id="hacienda-page" data-hacienda-page>/, response.body)
    refute_includes response.body, "<main>"
    assert_includes response.body, "<h1>Explicit Ruby</h1>"
  end

  def test_action_can_force_navigation_to_fall_back_to_a_full_load
    response = Rack::MockRequest.new(@app).get(
      "/full-load",
      "HTTP_X_HACIENDA_NAVIGATION" => "true"
    )

    assert_equal 200, response.status
    assert_equal "reload", response["x-hacienda-navigation"]
    assert_includes response.body, "<article>"
  end

  def test_context_adds_http_cache_headers_to_rendered_responses
    response = Rack::MockRequest.new(@app).get("/cached/1")

    assert_equal 200, response.status
    assert_includes response.body, "Cached post"
    assert_match(/\A"[a-f0-9]{64}"\z/, response["etag"])
    assert_equal "Sun, 28 Jun 2026 12:00:00 GMT", response["last-modified"]
    assert_equal "public, max-age=60", response["cache-control"]
  end

  def test_matching_etag_returns_not_modified_with_cache_headers
    request = Rack::MockRequest.new(@app)
    first = request.get("/cached/1")
    cached = request.get("/cached/1", "HTTP_IF_NONE_MATCH" => first["etag"])

    assert_equal 304, cached.status
    assert_equal "", cached.body
    assert_equal first["etag"], cached["etag"]
    assert_equal first["cache-control"], cached["cache-control"]
  end

  def test_matching_last_modified_returns_not_modified
    response = Rack::MockRequest.new(@app).get(
      "/cached/1",
      "HTTP_IF_MODIFIED_SINCE" => "Sun, 28 Jun 2026 12:00:00 GMT"
    )

    assert_equal 304, response.status
    assert_equal "Sun, 28 Jun 2026 12:00:00 GMT", response["last-modified"]
  end

  def test_head_matches_get_routes
    response = Rack::MockRequest.new(@app).request("HEAD", "/posts/42")

    assert_equal 200, response.status
  end

  def test_actions_can_be_grouped_in_domain_actions_file
    write "app/domains/comments/routes.rb", %(get "/comments", :index\n)
    write "app/domains/comments/actions.rb", <<~RUBY
      module Comments
        class Actions < Hacienda::Actions
          def index(_context, _params)
            "Inline comments"
          end
        end
      end
    RUBY
    response = Rack::MockRequest.new(@app).get("/comments")

    assert_equal 200, response.status
    assert_equal "Inline comments", response.body
  end

  def test_action_sets_use_a_fresh_instance_for_each_request
    write "app/domains/comments/routes.rb", %(get "/comments", :index\n)
    write "app/domains/comments/actions.rb", <<~RUBY
      module Comments
        class Actions < Hacienda::Actions
          def index(_context, _params)
            @calls = @calls.to_i + 1
            @calls.to_s
          end
        end
      end
    RUBY
    request = Rack::MockRequest.new(@app)

    assert_equal "1", request.get("/comments").body
    assert_equal "1", request.get("/comments").body
  end

  def test_action_set_does_not_dispatch_inherited_object_methods
    write "app/domains/comments/routes.rb", %(get "/comments", :inspect\n)
    write "app/domains/comments/actions.rb", <<~RUBY
      module Comments
        class Actions < Hacienda::Actions
          def index(_context, _params) = "Index"
        end
      end
    RUBY

    assert_equal 404, Rack::MockRequest.new(@app).get("/comments").status
  end

  def test_reserved_response_helper_names_fail_during_reload
    write "app/domains/comments/routes.rb", %(get "/comments", :render\n)
    write "app/domains/comments/actions.rb", <<~RUBY
      module Comments
        class Actions < Hacienda::Actions
          def render(_context, _params) = "Ambiguous"
        end
      end
    RUBY

    error = assert_raises(Hacienda::Error) { @app.reload! }
    assert_includes error.message, "reserved action name :render"
  end

  def test_private_reserved_names_fail_during_reload
    write "app/domains/comments/actions.rb", <<~RUBY
      module Comments
        class Actions < Hacienda::Actions
          private

          def initialize
          end
        end
      end
    RUBY

    error = assert_raises(Hacienda::Error) { @app.reload! }
    assert_includes error.message, "reserved action name :initialize"
  end

  def test_routes_can_select_an_additional_multi_method_action_set
    write "app/domains/comments/routes.rb", <<~RUBY
      post "/comments/:id/publish", :publish, actions: :moderation
      post "/comments/:id/archive", :archive, actions: :moderation
    RUBY
    write "app/domains/comments/actions.rb", <<~RUBY
      module Comments
        class Actions < Hacienda::Actions
        end
      end
    RUBY
    write "app/domains/comments/actions/moderation_actions.rb", <<~RUBY
      module Comments
        class ModerationActions < Hacienda::Actions
          def publish(_context, params) = "Published \#{params[:id]}"
          def archive(_context, params) = "Archived \#{params[:id]}"
        end
      end
    RUBY
    request = Rack::MockRequest.new(@app)

    assert_equal "Published 7", request.post("/comments/7/publish").body
    assert_equal "Archived 8", request.post("/comments/8/archive").body
  end

  def test_explicit_render_uses_configured_layout_by_default
    response = Rack::MockRequest.new(@app).get("/posts/new")

    assert_equal 200, response.status
    assert_includes response.body, "<article>"
    assert_includes response.body, "<h1>New post</h1>"
  end

  def test_reload_mode_does_not_warn_when_reloading_action_modules
    _, stderr = capture_io do
      2.times { Rack::MockRequest.new(@app).get("/posts/42") }
    end

    refute_includes stderr, "method redefined"
  end

  def test_zeitwerk_manages_action_sets_in_the_domain_namespace
    action = File.join(@root, "app/domains/posts/actions.rb")
    routes = File.join(@root, "app/domains/posts/routes.rb")

    assert_equal "Posts::Actions", @app.loader.cpath_expected_at(action)
    assert_nil @app.loader.cpath_expected_at(routes)

    Rack::MockRequest.new(@app).get("/posts/1")

    assert_operator Posts::Actions, :<, Hacienda::Actions
  end

  def test_reload_replaces_action_sets_and_their_nested_constants
    request = Rack::MockRequest.new(@app)
    request.get("/posts/1")
    previous_action = Posts::Actions

    write "app/domains/posts/actions.rb", <<~RUBY
      module Posts
        class Actions < Hacienda::Actions
          FORMAT = "Reloaded"

          def show(_context, params)
            {post: {id: params[:id], title: "\#{FORMAT} action"}}
          end
        end
      end
    RUBY

    response = request.get("/posts/1")

    refute_same previous_action, Posts::Actions
    assert_equal "Reloaded", Posts::Actions::FORMAT
    assert_includes response.body, "Reloaded action"
  end

  def test_reload_replaces_cross_domain_references_as_one_generation
    routes = File.read(File.join(@root, "app/domains/posts/routes.rb"))
    write "app/domains/posts/routes.rb", routes + %(get "/greeting", :greeting\n)
    write "app/domains/shared/greeting.rb", <<~RUBY
      module Shared
        module Greeting
          def self.text = "First"
        end
      end
    RUBY
    write "app/domains/posts/presentation.rb", <<~RUBY
      module Posts
        module Presentation
          SOURCE = Shared::Greeting

          def self.text = SOURCE.text
        end
      end
    RUBY
    write "app/domains/posts/actions.rb", <<~RUBY
      module Posts
        class Actions < Hacienda::Actions
          def greeting(_context, _params) = Presentation.text
        end
      end
    RUBY
    request = Rack::MockRequest.new(@app)

    assert_equal "First", request.get("/greeting").body
    previous_presentation = Posts::Presentation
    previous_source = Posts::Presentation::SOURCE

    write "app/domains/shared/greeting.rb", <<~RUBY
      module Shared
        module Greeting
          def self.text = "Second"
        end
      end
    RUBY

    assert_equal "Second", request.get("/greeting").body
    refute_same previous_presentation, Posts::Presentation
    refute_same previous_source, Posts::Presentation::SOURCE
  end

  def test_reload_discovers_new_domains_and_ignores_their_route_files
    write "app/domains/comments/routes.rb", %(get "/comments", :index\n)
    write "app/domains/comments/actions.rb", <<~RUBY
      module Comments
        class Actions < Hacienda::Actions
          def index(_context, _params) = "Comments"
        end
      end
    RUBY

    response = Rack::MockRequest.new(@app).get("/comments")

    assert_equal 200, response.status
    assert_equal "Comments", response.body
    assert_equal "Comments::Actions", @app.loader.cpath_expected_at(
      File.join(@root, "app/domains/comments/actions.rb")
    )
    assert_nil @app.loader.cpath_expected_at(
      File.join(@root, "app/domains/comments/routes.rb")
    )
  end

  def test_route_with_missing_action_method_returns_not_found
    routes = File.read(File.join(@root, "app/domains/posts/routes.rb"))
    write "app/domains/posts/routes.rb", routes + %(get "/missing-action", :missing\n)

    assert_equal 404, Rack::MockRequest.new(@app).get("/missing-action").status
  end

  def test_reload_mode_reloads_route_files
    assert_equal 404, Rack::MockRequest.new(@app).get("/health").status

    write "app/domains/posts/routes.rb", <<~RUBY
      get "/posts/:id", :show
      get "/posts/new", :new
      post "/posts", :create
      get "/health", :health
      guard Auth::Required do
        get "/posts/:id/edit", :edit
      end
    RUBY
    write "app/domains/posts/actions.rb", <<~RUBY
      module Posts
        class Actions < Hacienda::Actions
          def health(_context, _params)
            "OK"
          end
        end
      end
    RUBY

    assert_equal 200, Rack::MockRequest.new(@app).get("/health").status

    write "app/domains/posts/routes.rb", <<~RUBY
      get "/posts/:id", :show
      get "/posts/new", :new
      post "/posts", :create
      guard Auth::Required do
        get "/posts/:id/edit", :edit
      end
    RUBY

    assert_equal 404, Rack::MockRequest.new(@app).get("/health").status
  end

  def test_reload_rejects_cross_domain_route_collisions_and_recovers_after_they_are_fixed
    write "app/domains/comments/routes.rb", %(get "/posts/:slug", :show\n)
    write "app/domains/comments/actions.rb", <<~RUBY
      module Comments
        class Actions < Hacienda::Actions
          def show(_context, params) = "Comment \#{params[:slug]}"
        end
      end
    RUBY

    error = assert_raises(Hacienda::Routes::CollisionError) { @app.reload! }
    assert_includes error.message, "Posts::Actions#show"
    assert_includes error.message, "Comments::Actions#show"

    write "app/domains/comments/routes.rb", %(get "/comments/:slug", :show\n)
    @app.reload!

    assert_equal "Comment first", Rack::MockRequest.new(@app).get("/comments/first").body
  end

  def test_static_route_wins_over_parameter_route
    response = Rack::MockRequest.new(@app).get("/posts/new")

    assert_equal 200, response.status
    assert_includes response.body, "<h1>New post</h1>"
  end

  def test_action_can_redirect
    response = Rack::MockRequest.new(@app).post("/posts")

    assert_equal 303, response.status
    assert_equal "/posts/1", response["location"]
  end

  def test_missing_required_params_return_bad_request
    response = Rack::MockRequest.new(@app).post("/require-post")

    assert_equal 400, response.status
    assert_equal "param is missing or empty: post", response.body
  end

  def test_json_body_and_query_are_exposed_through_params
    source = JSON.generate(
      id: "body",
      source: "body",
      post: {title: "JSON post", tags: [{name: "ruby"}]}
    )
    response = Rack::MockRequest.new(@app).post(
      "/echo/route?source=query&page=2",
      "CONTENT_TYPE" => "application/json; charset=utf-8",
      input: source
    )
    body = JSON.parse(response.body)

    assert_equal 200, response.status
    assert_equal "route", body.dig("params", "id")
    assert_equal "body", body.dig("params", "source")
    assert_equal "2", body.dig("params", "page")
    assert_equal "JSON post", body.dig("params", "post", "title")
    assert_equal "ruby", body.dig("params", "post", "tags", 0, "name")
    assert_equal source, body["raw_body"]
  end

  def test_vendor_json_media_types_are_supported
    response = Rack::MockRequest.new(@app).post(
      "/echo/1",
      "CONTENT_TYPE" => "application/vnd.api+json",
      input: JSON.generate(active: true)
    )

    assert_equal true, JSON.parse(response.body).dig("params", "active")
  end

  def test_empty_json_body_is_treated_as_no_body_params
    response = Rack::MockRequest.new(@app).post(
      "/echo/1?page=2",
      "CONTENT_TYPE" => "application/json",
      input: ""
    )

    assert_equal({"id" => "1", "page" => "2"}, JSON.parse(response.body)["params"])
  end

  def test_malformed_json_body_returns_bad_request
    response = Rack::MockRequest.new(@app).post(
      "/echo/1",
      "CONTENT_TYPE" => "application/json",
      input: %({"title":)
    )

    assert_equal 400, response.status
    assert_equal "malformed JSON request body", response.body
  end

  def test_non_object_json_body_returns_bad_request
    response = Rack::MockRequest.new(@app).post(
      "/echo/1",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(["not", "an", "object"])
    )

    assert_equal 400, response.status
    assert_equal "JSON request body must be an object", response.body
  end

  def test_flash_messages_survive_one_redirect
    stack = Rack::Session::Cookie.new(
      @app,
      key: "hacienda.session",
      secret: "test-session-secret-with-enough-entropy-to-satisfy-rack-session-0000"
    )
    request = Rack::MockRequest.new(stack)

    redirect = request.post("/posts")
    response = request.get(redirect["location"], "HTTP_COOKIE" => redirect["set-cookie"])
    consumed = request.get(redirect["location"], "HTTP_COOKIE" => response["set-cookie"])

    assert_equal 200, response.status
    assert_includes response.body, "Post created."
    refute_includes consumed.body, "Post created."
  end

  def test_prefetch_does_not_consume_flash_and_is_not_cached_when_flash_is_present
    stack = Rack::Session::Cookie.new(
      @app,
      key: "hacienda.session",
      secret: "test-session-secret-with-enough-entropy-to-satisfy-rack-session-0000"
    )
    request = Rack::MockRequest.new(stack)

    redirect = request.post("/posts")
    prefetch = request.get(
      redirect["location"],
      "HTTP_COOKIE" => redirect["set-cookie"],
      "HTTP_X_HACIENDA_NAVIGATION" => "true",
      "HTTP_X_HACIENDA_PREFETCH" => "true"
    )
    navigation = request.get(
      redirect["location"],
      "HTTP_COOKIE" => prefetch["set-cookie"] || redirect["set-cookie"],
      "HTTP_X_HACIENDA_NAVIGATION" => "true"
    )
    consumed = request.get(
      redirect["location"],
      "HTTP_COOKIE" => navigation["set-cookie"]
    )

    assert_equal "no-store", prefetch["x-hacienda-prefetch-cache"]
    assert_includes prefetch.body, "Post created."
    assert_includes navigation.body, "Post created."
    refute_includes consumed.body, "Post created."
  end

  def test_unknown_route_is_404
    assert_equal 404, Rack::MockRequest.new(@app).get("/missing").status
  end

  def test_custom_not_found_page_uses_application_layout
    write "app/errors/404.erb", <<~ERB
      <% page_title title %>
      <h1>Custom <%= status %></h1>
      <p><%= message %></p>
      <p><%= context.path %></p>
    ERB

    response = Rack::MockRequest.new(@app).get("/missing")

    assert_equal 404, response.status
    assert_equal "text/html; charset=utf-8", response["content-type"]
    assert_includes response.body, "<article>"
    assert_includes response.body, "<h1>Custom 404</h1>"
    assert_includes response.body, "<p>/missing</p>"
  end

  def test_development_errors_show_details
    Hacienda.env = "development"
    Hacienda.configure_logger(output: File::NULL, level: :debug)
    write "app/errors/500.erb", "<h1>Custom production error</h1>"

    response = Rack::MockRequest.new(@app).get("/boom")

    assert_equal 500, response.status
    assert_includes response.body, "Application error"
    assert_includes response.body, "RuntimeError: Exploded"
    refute_includes response.body, "Custom production error"
  end

  def test_sqlite_busy_request_errors_are_reported_to_the_busy_monitor
    messages = []
    Hacienda::SQLite.busy_monitor = Hacienda::SQLite::BusyMonitor.new(
      threshold: 1,
      logger: Struct.new(:messages) do
        def warn(message) = messages << message
      end.new(messages)
    )

    response = Rack::MockRequest.new(@app).get("/busy")

    assert_equal 500, response.status
    assert_equal 1, messages.length
    assert_includes messages.first, "sqlite_busy_contention"
    assert_includes messages.first, %(source="request")
    assert_includes messages.first, %(method="GET")
    assert_includes messages.first, %(path="/busy")
  end

  def test_production_errors_hide_details
    Hacienda.env = "production"
    Hacienda.configure_logger(output: File::NULL, level: :info)

    response = Rack::MockRequest.new(@app).get("/boom")

    assert_equal 500, response.status
    assert_includes response.body, "Something went wrong"
    refute_includes response.body, "RuntimeError: Exploded"
  end

  def test_custom_production_error_page_uses_application_layout
    Hacienda.env = "production"
    Hacienda.configure_logger(output: File::NULL, level: :info)
    write "app/errors/500.erb", <<~ERB
      <% page_title title %>
      <h1>Custom <%= status %></h1>
      <p><%= message %></p>
      <p><%= context.path %></p>
    ERB

    response = Rack::MockRequest.new(@app).get("/boom")

    assert_equal 500, response.status
    assert_equal "text/html; charset=utf-8", response["content-type"]
    assert_includes response.body, "<article>"
    assert_includes response.body, "<h1>Custom 500</h1>"
    assert_includes response.body, "<p>/boom</p>"
    refute_includes response.body, "RuntimeError: Exploded"
  end

  def test_request_logger_filters_sensitive_params
    output = StringIO.new
    Hacienda.configure_logger(output: output, level: :info)
    stack = Hacienda::Middleware::RequestLogger.new(@app)

    Rack::MockRequest.new(stack).post("/posts", params: {
      title: "Visible",
      password: "secret",
      _csrf: "token"
    })

    log = output.string
    assert_includes log, "method=POST"
    assert_includes log, "title"
    assert_includes log, "[FILTERED]"
    refute_includes log, "secret"
    refute_includes log, "token"
  end

  def test_request_logger_filters_json_params
    output = StringIO.new
    Hacienda.configure_logger(output: output, level: :info)
    stack = Hacienda::Middleware::RequestLogger.new(@app)

    Rack::MockRequest.new(stack).post(
      "/echo/1",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(title: "Visible", password: "json-secret")
    )

    log = output.string
    assert_includes log, "title"
    assert_includes log, "Visible"
    assert_includes log, "[FILTERED]"
    refute_includes log, "json-secret"
  end

  def test_guard_can_stop_dispatch
    response = Rack::MockRequest.new(@app).get("/posts/42/edit")

    assert_equal 303, response.status
    assert_equal "/login", response["location"]
  end

  def test_guard_assigns_request_scoped_current_user
    response = Rack::MockRequest.new(@app).get(
      "/posts/42/edit",
      "HTTP_AUTHORIZATION" => "Bearer secret"
    )

    assert_equal 200, response.status
    assert_includes response.body, "Editing 42 as developer"
  end

  private

  def write(path, content)
    destination = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(destination))
    File.write(destination, content)
  end
end
