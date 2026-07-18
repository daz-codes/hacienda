# frozen_string_literal: true

require_relative "test_helper"
require "lunula/cli"
require "open3"
require "stringio"
require "yaml"

class CLITest < Minitest::Test
  module DurableCLIJob
    module_function

    def perform(value)
      DB_TASKS_DATABASE[:performed_jobs].insert(value:)
    end
  end

  module FailedCLIJob
    module_function

    def max_attempts = 1
    def perform = raise("CLI failure")
  end

  def setup
    @directory = Dir.mktmpdir("lunula-cli")
    @out = StringIO.new
    @err = StringIO.new
  end

  def teardown
    cleanup_loaded_app_constant
    FileUtils.rm_rf(@directory)
  end

  def test_luna_new_generates_a_bootable_html_first_application
    status = Lunula::CLI.start(
      ["new", "weekend"],
      out: @out,
      err: @err,
      cwd: @directory
    )

    root = File.join(@directory, "weekend")
    assert_equal 0, status, @err.string
    assert File.file?(File.join(root, "public", "assets", "helium.js"))
    assert File.file?(File.join(root, "public", "assets", "helium-csp.js"))
    assert File.file?(File.join(root, "public", "assets", "helium-sse.js"))
    assert File.file?(File.join(root, "public", "assets", "helium-csp-sse.js"))
    assert File.file?(File.join(root, "public", "assets", "jexpr.js"))
    assert File.file?(File.join(root, "public", "assets", "HELIUM-LICENSE.txt"))
    assert File.file?(File.join(root, "public", "assets", "morpheus.js"))
    assert File.file?(File.join(root, "public", "assets", "idiomorph.esm.js"))
    assert File.file?(File.join(root, "public", "assets", "application.css"))
    assert File.file?(File.join(root, "Procfile.dev"))
    assert File.file?(File.join(root, "config", "credentials.yml.enc"))
    assert File.file?(File.join(root, "config", "master.key"))
    assert File.file?(File.join(root, "config", "jobs.rb"))
    assert File.file?(File.join(root, "config", "litestream.yml.example"))
    assert File.file?(File.join(root, "config", "recurring.yml"))
    assert File.file?(File.join(root, "config", "cache.rb"))
    assert File.file?(File.join(root, "config", "storage.rb"))
    assert File.file?(File.join(root, "config", "mail.rb"))
    assert File.file?(File.join(root, "app", "errors", "404.erb"))
    assert File.file?(File.join(root, "app", "errors", "500.erb"))
    assert File.file?(File.join(root, "db", "migrations", "20260629000000_create_lunula_runtime.rb"))
    assert File.file?(File.join(root, "Dockerfile"))
    assert File.file?(File.join(root, ".dockerignore"))
    assert File.file?(File.join(root, "config", "deploy.yml"))
    assert File.file?(File.join(root, ".kamal", "secrets"))
    assert File.file?(File.join(root, "DEPLOYMENT.md"))
    assert File.file?(File.join(root, "config", "environment.rb"))
    assert File.file?(File.join(root, "config", "environments", "development.rb"))
    assert File.file?(File.join(root, "config", "environments", "test.rb"))
    assert File.file?(File.join(root, "config", "environments", "production.rb"))
    assert File.file?(File.join(root, "test", "test_helper.rb"))
    assert File.file?(File.join(root, "test", "domains", "home", "actions_test.rb"))
    assert File.file?(File.join(root, "test", "integration", ".keep"))
    assert_includes File.read(File.join(root, "config", "environments", "development.rb")),
      "Lunula.reload = true"
    assert_includes File.read(File.join(root, "config/application.rb")),
      "reload: Lunula.reload"
    assert_includes File.read(File.join(root, "config/application.rb")),
      "cache: Lunula.cache"
    assert_includes File.read(File.join(root, "config/cache.rb")),
      "Lunula::Cache::NullStore"
    assert_includes File.read(File.join(root, "config/application.rb")),
      "storage: Lunula.storage"
    assert_includes File.read(File.join(root, "config/application.rb")),
      "outbox: event_outbox"
    assert_includes File.read(File.join(root, "config/jobs.rb")),
      "Lunula::Jobs::Adapters::Database"
    assert_includes File.read(File.join(root, "config/storage.rb")),
      "Lunula::Storage::DiskService"
    assert_includes File.read(File.join(root, ".gitignore")), "/config/master.key"
    assert_includes File.read(File.join(root, "Gemfile")), %(gem "rake", "~> 13.2")
    assert_includes File.read(File.join(root, "Gemfile")), %(gem "kamal", "~> 2.0")
    assert_includes File.read(File.join(root, "Gemfile")), %(gem "rack-test", "~> 2.2")
    assert_includes File.read(File.join(root, "Rakefile")), "Rake::TestTask.new"
    assert_includes File.read(File.join(root, "Rakefile")), %(require "lunula")
    assert_includes File.read(File.join(root, "Procfile.dev")),
      "worker: bundle exec luna jobs:work"
    assert_includes File.read(File.join(root, "Procfile.dev")),
      "scheduler: bundle exec luna jobs:schedule"
    assert_includes File.read(File.join(root, "Dockerfile")), "USER lunula"
    assert_includes File.read(File.join(root, "Dockerfile")), %(EXPOSE 5151)
    assert_includes File.read(File.join(root, "Dockerfile")), "bundle exec luna assets:precompile"
    refute_includes File.read(File.join(root, "Dockerfile")), "config/master.key"
    assert_includes File.read(File.join(root, ".dockerignore")), "config/master.key"
    assert_includes File.read(File.join(root, "config", "environments", "production.rb")),
      'output: $stdout'
    deploy = YAML.safe_load(File.read(File.join(root, "config", "deploy.yml")))
    assert_equal "weekend", deploy.fetch("service")
    assert_equal 5151, deploy.dig("proxy", "app_port")
    assert_equal "/up", deploy.dig("proxy", "healthcheck", "path")
    assert_equal "bundle exec luna jobs:work", deploy.dig("servers", "job", "cmd")
    assert_equal "bundle exec luna jobs:schedule", deploy.dig("servers", "scheduler", "cmd")
    assert_equal "https://app.example.com", deploy.dig("env", "clear", "LUNULA_APP_URL")
    assert_includes deploy.fetch("volumes"), "weekend_db:/app/db"
    assert_equal "app exec --primary --reuse \"bundle exec luna db:migrate\"",
      deploy.dig("aliases", "migrate")
    bundled_assets = File.expand_path("../lib/lunula/assets", __dir__)
    assert_equal File.read(File.join(bundled_assets, "helium.js")),
      File.read(File.join(root, "public", "assets", "helium.js"))
    assert_equal File.read(File.join(bundled_assets, "helium-csp.js")),
      File.read(File.join(root, "public", "assets", "helium-csp.js"))
    assert_equal File.read(File.join(bundled_assets, "helium-sse.js")),
      File.read(File.join(root, "public", "assets", "helium-sse.js"))
    assert_equal File.read(File.join(bundled_assets, "helium-csp-sse.js")),
      File.read(File.join(root, "public", "assets", "helium-csp-sse.js"))
    assert_equal File.read(File.join(bundled_assets, "HELIUM-LICENSE.txt")),
      File.read(File.join(root, "public", "assets", "HELIUM-LICENSE.txt"))

    reset_cli_output
    assert_equal 0, run_cli(["assets:precompile"], root), @err.string
    assert_match(/Compiled \d+ assets\./, @out.string)
    asset_manifest = JSON.parse(File.read(File.join(root, "public", "assets", ".manifest.json")))
    navigation_asset = asset_manifest.fetch("assets").fetch("morpheus.js")
    idiomorph_asset = asset_manifest.fetch("assets").fetch("idiomorph.esm.js")
    assert_includes File.read(File.join(root, "public", "assets", navigation_asset)),
      %("./#{idiomorph_asset}")
    assert_match(%r{\A/assets/morpheus-[0-9a-f]{16}\.js\z},
      Lunula::Assets.path("morpheus.js", root:, environment: "production"))

    reset_cli_output
    assert_equal 0, run_cli(["db:migrate"], root), @err.string
    app = Rack::Builder.parse_file(File.join(root, "config.ru"))
    response = Rack::MockRequest.new(app).get("/")
    navigation_response = Rack::MockRequest.new(app).get(
      "/",
      "HTTP_X_LUNULA_NAVIGATION" => "true"
    )
    health = Rack::MockRequest.new(app).get("/up")
    helium = Rack::MockRequest.new(app).get("/assets/helium.js")
    helium_csp = Rack::MockRequest.new(app).get("/assets/helium-csp.js")
    jexpr = Rack::MockRequest.new(app).get("/assets/jexpr.js")
    navigation = Rack::MockRequest.new(app).get("/assets/morpheus.js")
    idiomorph = Rack::MockRequest.new(app).get("/assets/idiomorph.esm.js")
    stylesheet = Rack::MockRequest.new(app).get("/assets/application.css")
    dashboard = Rack::MockRequest.new(app).get("/luna/jobs", "REMOTE_ADDR" => "127.0.0.1")
    dashboard_health = Rack::MockRequest.new(app).get("/luna/jobs/health", "REMOTE_ADDR" => "127.0.0.1")
    mail_inbox = Rack::MockRequest.new(app).get("/luna/mail", "REMOTE_ADDR" => "127.0.0.1")

    assert_equal 200, response.status
    assert_includes response.body, "Lunula is running."
    assert_includes response.body, "Helium clicks"
    assert_includes response.body, %(id="morpheus-page")
    assert_includes response.body, %(/assets/morpheus.js)
    assert_equal 200, navigation_response.status
    assert_equal "morph", navigation_response["x-morpheus-navigation"]
    assert_equal "Home", navigation_response["x-morpheus-title"]
    assert_match(/\A<div id="morpheus-page" data-morpheus-page>/, navigation_response.body)
    assert_equal 200, health.status
    assert_equal "OK", health.body
    assert_equal "text/plain; charset=utf-8", health["content-type"]
    head_response = Rack::MockRequest.new(app).request("HEAD", "/")
    assert_equal 200, head_response.status
    assert_equal "", head_response.body
    assert_equal "SAMEORIGIN", response["x-frame-options"]
    assert_includes response["content-security-policy"], "default-src 'self'"
    assert_includes response["content-security-policy"], "script-src 'self' 'nonce-"
    assert_includes response["content-security-policy"], "style-src 'self' 'nonce-"
    refute_includes response["content-security-policy"], "unsafe-inline"
    assert_equal 200, helium.status
    assert_includes helium.body, "const parseEx"
    assert_equal 200, helium_csp.status
    assert_includes helium_csp.body, "CSP-safe"
    assert_equal 200, jexpr.status
    assert_includes jexpr.body, "class EvalAstFactory"
    assert_equal 200, navigation.status
    assert_includes navigation.body, "class Morpheus"
    assert_equal 200, idiomorph.status
    assert_includes idiomorph.body, "export {Idiomorph}"
    assert_equal 200, stylesheet.status
    assert_equal 200, dashboard.status
    assert_includes dashboard.body, "Lunula Jobs"
    assert_equal 200, dashboard_health.status
    assert_includes dashboard_health.body, %("status":"ok")
    assert_equal 200, mail_inbox.status
    assert_includes mail_inbox.body, "Lunula Mail"
    assert_includes File.read(File.join(root, "app/layouts/application.erb")),
      %(<%= stylesheet_link "application.css" %>)
    assert_includes File.read(File.join(root, "app/layouts/application.erb")),
      %(<%= morpheus_navigation context %>)
    assert_includes File.read(File.join(root, "app/layouts/application.erb")),
      %(<%= javascript_include "helium-csp.js", module: true %>)
    assert_includes File.read(File.join(root, "app/layouts/application.erb")),
      %(<%= navigation_page content, context: context %>)
    assert_includes File.read(File.join(root, "test/test_helper.rb")),
      "class ApplicationTest < Minitest::Test"

    begin
      Lunula.env = "production"
      production_response = Rack::MockRequest.new(app).get("/")
      assert_equal 200, production_response.status
      assert_includes production_response.body, "/assets/#{navigation_asset}"
      assert_includes production_response.body,
        "/assets/#{asset_manifest.fetch("assets").fetch("application.css")}"
      compiled_navigation = Rack::MockRequest.new(app).get("/assets/#{navigation_asset}")
      assert_equal 200, compiled_navigation.status
      assert_equal "public, max-age=31536000, immutable", compiled_navigation["cache-control"]
    ensure
      Lunula.env = "development"
    end

    cleanup_loaded_app_constant
    stdout, stderr, test_status = Open3.capture3(
      {"RUBYLIB" => File.expand_path("../lib", __dir__)},
      Gem.ruby,
      "-S",
      "rake",
      "test",
      chdir: root
    )
    assert test_status.success?, "#{stdout}\n#{stderr}"
    assert_includes stdout, "2 runs"
    assert_includes File.read(File.join(root, "config.ru")), "Lunula::Middleware::CSRF"
    assert_includes File.read(File.join(root, "config.ru")), "Lunula::Middleware::RequestLogger"
    assert_includes File.read(File.join(root, "config.ru")), "Lunula::Middleware::HostAuthorization"
    assert_includes File.read(File.join(root, "config.ru")), "Lunula::Middleware::RequestLimits"
    assert_includes File.read(File.join(root, "config.ru")), "LUNULA_MAX_REQUEST_BYTES"
    assert_includes File.read(File.join(root, "config.ru")), "LUNULA_ALLOWED_HOSTS"
    assert_includes File.read(File.join(root, "config.ru")), "Lunula::Middleware::SecurityHeaders"
    assert_includes File.read(File.join(root, "config.ru")), "hsts: Lunula.env.production?"
    assert_includes File.read(File.join(root, "config.ru")), "Lunula::Middleware::RateLimiter"
    assert_includes File.read(File.join(root, "config.ru")), "Lunula::Middleware::StorageFiles"
    assert_includes File.read(File.join(root, "config.ru")), %(map "/luna/jobs")
    assert_includes File.read(File.join(root, "config.ru")), "Lunula::Jobs::Dashboard"
    assert_includes File.read(File.join(root, "config.ru")), "use Rack::Head"
    assert_includes File.read(File.join(root, "config.ru")), %(path: ["/login", "/signup", "/magic-login", "/magic-login/confirm", "/password/forgot", "/password"])
    assert_includes File.read(File.join(root, "config.ru")), "LUNULA_SESSION_SECRET is required in production"
    assert_includes File.read(File.join(root, "config.ru")), "LUNULA_SESSION_SECRET_OLD"
    assert_includes File.read(File.join(root, "config.ru")), "LUNULA_SESSION_EXPIRE_AFTER"
    assert_includes File.read(File.join(root, "config.ru")), "LUNULA_SESSION_STORE"
    assert_includes File.read(File.join(root, "config.ru")), "Lunula::SessionStore"
    assert_includes File.read(File.join(root, "config.ru")), "table: :lunula_sessions"
    assert_includes File.read(File.join(root, "config.ru")), "secrets: [session_secret, *session_old_secrets]"
    assert_includes File.read(File.join(root, "config.ru")), "expire_after: session_expire_after"
    assert_includes File.read(File.join(root, "config.ru")), "secure: Lunula.env.production?"
    assert_includes File.read(File.join(root, "config", "database.rb")),
      "Lunula::SQLite.configure(DB, wal: environment != \"test\")"
    assert_includes File.read(File.join(root, "README.md")), "luna db:check"
    assert_includes File.read(File.join(root, "DEPLOYMENT.md")), "config/litestream.yml.example"
    assert_includes File.read(File.join(root, "DEPLOYMENT.md")).gsub(/\s+/, " "), "Back up local uploads separately"
    assert_equal "development", Lunula.env.name
    assert Lunula.env.development?
    assert_equal :file, Lunula.mail_config.delivery
    assert_instance_of Lunula::Jobs::Adapters::Async, Lunula.job_config.adapter
  end

  def test_luna_new_removes_partial_application_when_explicit_helium_override_is_invalid
    target = File.join(@directory, "incomplete")
    original_helium_path = ENV["HELIUM_PATH"]

    ENV["HELIUM_PATH"] = File.join(@directory, "missing", "helium.js")
    status = Lunula::CLI.start(
      ["new", "incomplete"],
      out: @out,
      err: @err,
      cwd: @directory
    )

    assert_equal 1, status
    assert_includes @err.string, "HELIUM_PATH does not point to helium.js"
    refute_path_exists target
  ensure
    original_helium_path ? ENV["HELIUM_PATH"] = original_helium_path : ENV.delete("HELIUM_PATH")
  end

  def test_credentials_can_be_read_and_shown
    assert_equal 0, Lunula::CLI.start(
      ["new", "secure"],
      out: @out,
      err: @err,
      cwd: @directory
    )
    root = File.join(@directory, "secure")
    credentials = Lunula::Credentials.new(root:)

    credentials.write_text(<<~YAML)
      mail:
        username: hello@example.com
        password: secret
    YAML

    assert_equal "hello@example.com", Lunula.credentials(root:).dig(:mail, :username)
    refute_includes File.read(File.join(root, "config", "credentials.yml.enc")), "hello@example.com"

    @out.truncate(0)
    @out.rewind
    status = Lunula::CLI.start(
      ["credentials:show"],
      out: @out,
      err: @err,
      cwd: root
    )

    assert_equal 0, status, @err.string
    assert_includes @out.string, "hello@example.com"
    assert_includes @out.string, "password: secret"
  end

  def test_luna_is_the_cli_name
    status = Lunula::CLI.start(["--version"], out: @out, err: @err, cwd: @directory)

    assert_equal 0, status
    assert_equal "luna #{Lunula::VERSION}\n", @out.string
  end

  def test_luna_executable_runs_the_cli
    stdout, stderr, status = Open3.capture3(
      {"RUBYLIB" => File.expand_path("../lib", __dir__)},
      Gem.ruby,
      File.expand_path("../exe/luna", __dir__),
      "--version"
    )

    assert status.success?, stderr
    assert_equal "luna #{Lunula::VERSION}\n", stdout
  end

  def test_luna_start_runs_rackup_on_port_5151
    File.write(File.join(@directory, "config.ru"), "run ->(_env) { [200, {}, []] }\n")
    command = nil

    status = Lunula::CLI.start(
      ["start", "--host", "127.0.0.1"],
      out: @out,
      err: @err,
      cwd: @directory,
      executor: ->(*arguments) { command = arguments }
    )

    assert_equal 0, status
    assert_equal [
      Gem.ruby, "-S", "rackup", "-p", "5151", "--host", "127.0.0.1"
    ], command
  end

  def test_luna_start_refuses_to_boot_with_pending_migrations
    root = database_app(
      "pending-start",
      "20260717090000_create_entries.rb" => <<~RUBY
        Sequel.migration do
          change do
            create_table(:entries) { primary_key :id }
          end
        end
      RUBY
    )
    File.write(File.join(root, "config.ru"), "run APP\n")

    with_isolated_app_constant do
      status = Lunula::CLI.start(
        ["start"],
        out: @out,
        err: @err,
        cwd: root,
        executor: ->(*) { flunk "rackup should not start" }
      )

      assert_equal 1, status
      assert_includes @err.string, "1 pending migration"
      assert_includes @err.string, "20260717090000_create_entries.rb"
      assert_includes @err.string, "bundle exec luna db:migrate"
    end
  end

  def test_luna_console_boots_the_application_in_irb
    root = File.join(@directory, "console_app")
    FileUtils.mkdir_p(File.join(root, "config"))
    File.write(File.join(root, "config", "application.rb"), "# application\n")

    command = nil
    command_cwd = nil

    status = Lunula::CLI.start(
      ["console"],
      out: @out,
      err: @err,
      cwd: root,
      executor: ->(*arguments) {
        command = arguments
        command_cwd = Dir.pwd
      }
    )

    assert_equal 0, status, @err.string
    assert_equal File.realpath(root), File.realpath(command_cwd)
    assert_equal [
      Gem.ruby,
      "-r",
      File.join(root, "config", "application"),
      "-r",
      "irb",
      "-e",
      "IRB.start"
    ], command
  end

  def test_luna_console_requires_a_lunula_application
    status = Lunula::CLI.start(
      ["console"],
      out: @out,
      err: @err,
      cwd: @directory,
      executor: ->(*) { flunk "should not boot console" }
    )

    assert_equal 1, status
    assert_includes @err.string, "not a Lunula application"
  end

  def test_luna_routes_lists_and_looks_up_domain_owned_routes
    root = File.join(@directory, "routes_app")
    FileUtils.mkdir_p(File.join(root, "config"))
    FileUtils.mkdir_p(File.join(root, "app", "domains", "catalog"))
    File.write(File.join(root, "config", "application.rb"), <<~RUBY)
      require "lunula"

      module RoutesTestAuth
        module Required
        end
      end

      root = File.expand_path("..", __dir__)
      APP = Lunula::Application.new(root: root)
    RUBY
    File.write(File.join(root, "app", "domains", "catalog", "routes.rb"), <<~RUBY)
      get "/products", :index
      get "/products/:id", :show

      guard RoutesTestAuth::Required do
        post "/products", :create
        delete "/products/:id", :destroy, actions: :admin
      end
    RUBY
    File.write(File.join(root, "app", "domains", "catalog", "actions.rb"), <<~RUBY)
      module Catalog
        class Actions < Lunula::Actions
          def index(_context, _params) = {}
          def show(_context, _params) = {}
          def create(_context, _params) = {}
        end
      end
    RUBY
    FileUtils.mkdir_p(File.join(root, "app", "domains", "catalog", "actions"))
    File.write(File.join(root, "app", "domains", "catalog", "actions", "admin_actions.rb"), <<~RUBY)
      module Catalog
        class AdminActions < Lunula::Actions
          def destroy(_context, _params) = {}
        end
      end
    RUBY
    FileUtils.mkdir_p(File.join(root, "app", "domains", "home"))
    File.write(File.join(root, "app", "domains", "home", "routes.rb"), %(get "/up", :show\n))
    File.write(File.join(root, "app", "domains", "home", "actions.rb"), <<~RUBY)
      module Home
        class Actions < Lunula::Actions
          def show(_context, _params) = "OK"
        end
      end
    RUBY

    with_isolated_app_constant do
      status = Lunula::CLI.start(["routes"], out: @out, err: @err, cwd: root)

      assert_equal 0, status, @err.string
      rows = @out.string.lines.map { |line| line.strip.split(/\s{2,}/) }
      assert_equal [
        %w[VERB PATH DOMAIN ACTION GUARDS SOURCE],
        ["GET", "/products", "catalog", "Catalog::Actions#index", "-", "app/domains/catalog/routes.rb:1"],
        ["GET", "/products/:id", "catalog", "Catalog::Actions#show", "-", "app/domains/catalog/routes.rb:2"],
        ["POST", "/products", "catalog", "Catalog::Actions#create", "RoutesTestAuth::Required", "app/domains/catalog/routes.rb:5"],
        ["DELETE", "/products/:id", "catalog", "Catalog::AdminActions#destroy", "RoutesTestAuth::Required", "app/domains/catalog/routes.rb:6"],
        ["GET", "/up", "home", "Home::Actions#show", "-", "app/domains/home/routes.rb:1"]
      ], rows

      reset_cli_output
      status = Lunula::CLI.start(["routes", "GET", "/products/42"], out: @out, err: @err, cwd: root)
      assert_equal 0, status, @err.string
      assert_includes @out.string, "Catalog::Actions#show"
      assert_includes @out.string, "app/domains/catalog/routes.rb:2"
      refute_includes @out.string, "Catalog::AdminActions#destroy"

      reset_cli_output
      status = Lunula::CLI.start(["routes", "HEAD", "/products/42"], out: @out, err: @err, cwd: root)
      assert_equal 0, status, @err.string
      assert_includes @out.string, "GET"
      assert_includes @out.string, "Catalog::Actions#show"

      reset_cli_output
      status = Lunula::CLI.start(["routes", "/products"], out: @out, err: @err, cwd: root)
      assert_equal 0, status, @err.string
      assert_includes @out.string, "Catalog::Actions#index"
      assert_includes @out.string, "Catalog::Actions#create"
      refute_includes @out.string, "Catalog::Actions#show"

      reset_cli_output
      status = Lunula::CLI.start(["routes", "--domain", "catalog"], out: @out, err: @err, cwd: root)
      assert_equal 0, status, @err.string
      assert_equal 4, @out.string.lines.length - 1
      refute_includes @out.string, "Home::Actions#show"

      reset_cli_output
      status = Lunula::CLI.start(["routes", "GET", "/missing"], out: @out, err: @err, cwd: root)
      assert_equal 1, status
      assert_equal "No route matches GET /missing.\n", @out.string
    end
  end

  def test_luna_routes_handles_an_application_without_routes
    root = File.join(@directory, "empty_routes_app")
    FileUtils.mkdir_p(File.join(root, "config"))
    FileUtils.mkdir_p(File.join(root, "app", "domains"))
    File.write(File.join(root, "config", "application.rb"), <<~RUBY)
      require "lunula"

      root = File.expand_path("..", __dir__)
      APP = Lunula::Application.new(root: root)
    RUBY

    with_isolated_app_constant do
      status = Lunula::CLI.start(["routes"], out: @out, err: @err, cwd: root)

      assert_equal 0, status, @err.string
      assert_equal "No routes defined.\n", @out.string
    end
  end

  def test_luna_database_commands_migrate_seed_and_rollback_timestamped_migrations
    root = database_app("timestamp_database_app", [
      ["20260101000000_create_widgets.rb", <<~RUBY],
        Sequel.migration do
          change do
            create_table(:widgets) { primary_key :id; String :name, null: false }
          end
        end
      RUBY
      ["20260101000001_create_notes.rb", <<~RUBY]
        Sequel.migration do
          change do
            create_table(:notes) { primary_key :id; String :body, null: false }
          end
        end
      RUBY
    ])
    File.write(File.join(root, "db", "seeds.rb"), <<~RUBY)
      APP.database[:widgets].insert(name: "Seeded") if APP.database[:widgets].empty?
    RUBY

    with_isolated_app_constant do
      assert_equal 0, run_cli(["db:migrate"], root)
      assert_equal "Applied 2 migrations.\n", @out.string
      database = Object.const_get(:DB_TASKS_DATABASE)
      assert database.table_exists?(:widgets)
      assert database.table_exists?(:notes)

      reset_cli_output
      assert_equal 0, run_cli(["db:migrate"], root)
      assert_equal "Database is already up to date.\n", @out.string

      reset_cli_output
      assert_equal 0, run_cli(["db:seed"], root)
      assert_equal "Database seed complete.\n", @out.string
      assert_equal ["Seeded"], database[:widgets].select_map(:name)

      reset_cli_output
      assert_equal 0, run_cli(["db:rollback"], root)
      assert_equal "Rolled back 1 migration.\n", @out.string
      assert database.table_exists?(:widgets)
      refute database.table_exists?(:notes)

      reset_cli_output
      assert_equal 0, run_cli(["db:rollback", "5"], root)
      assert_equal "Rolled back 1 migration.\n", @out.string
      refute database.table_exists?(:widgets)

      reset_cli_output
      assert_equal 0, run_cli(["db:rollback"], root)
      assert_equal "No migrations to roll back.\n", @out.string
    end
  end

  def test_luna_database_commands_support_integer_migrations
    root = database_app("integer_database_app", [
      ["001_create_entries.rb", <<~RUBY]
        Sequel.migration do
          change do
            create_table(:entries) { primary_key :id }
          end
        end
      RUBY
    ])

    with_isolated_app_constant do
      assert_equal 0, run_cli(["db:migrate"], root)
      database = Object.const_get(:DB_TASKS_DATABASE)
      assert database.table_exists?(:entries)

      reset_cli_output
      assert_equal 0, run_cli(["db:rollback"], root)
      refute database.table_exists?(:entries)
    end
  end

  def test_luna_database_check_and_checkpoint_report_sqlite_health
    root = database_app("sqlite_health_app", [
      ["001_create_entries.rb", <<~RUBY]
        Sequel.migration do
          change do
            create_table(:entries) { primary_key :id; String :name }
          end
        end
      RUBY
    ])

    with_isolated_app_constant do
      require File.join(root, "config", "application")
      Lunula::SQLite.configure(Object.const_get(:DB_TASKS_DATABASE), wal: true)

      assert_equal 0, run_cli(["db:check"], root)
      assert_includes @out.string, "journal_mode"
      assert_includes @out.string, "wal"
      assert_includes @out.string, "busy_timeout"
      assert_includes @out.string, "5000ms"
      assert_empty @err.string

      reset_cli_output
      assert_equal 0, run_cli(["db:checkpoint", "--mode", "TRUNCATE"], root)
      assert_includes @out.string, "TRUNCATE"
      assert_includes @out.string, "CHECKPOINTED_FRAMES"
    end
  end

  def test_luna_worker_runs_durable_jobs_and_manages_failures
    with_isolated_app_constant do
      root = durable_jobs_app
      require File.join(root, "config", "application")
      successful_id = Lunula.enqueue(DurableCLIJob, "worked")

      assert_equal 0, run_cli(["jobs:work", "--once"], root)
      assert_includes @out.string, "Completed job #{successful_id}."
      assert_equal ["worked"], DB_TASKS_DATABASE[:performed_jobs].select_map(:value)

      adapter = Lunula.job_adapter
      default_id = adapter.enqueue(DurableCLIJob, args: ["batch-default"], kwargs: {}, queue: "default")
      mailer_id = adapter.enqueue(DurableCLIJob, args: ["batch-mailer"], kwargs: {}, queue: "mailers")
      reset_cli_output
      assert_equal 0, run_cli(
        ["jobs:work", "--once", "--queue", "default,mailers", "--threads", "2", "--batch-size", "2"],
        root
      )
      assert_includes @out.string, "Completed job #{default_id}."
      assert_includes @out.string, "Completed job #{mailer_id}."

      reset_cli_output
      assert_equal 0, run_cli(["jobs:status"], root)
      assert_includes @out.string, "completed"
      assert_includes @out.string, "completed_last_hour"

      reset_cli_output
      assert_equal 0, run_cli(["jobs:health"], root)
      assert_includes @out.string, "status"
      assert_includes @out.string, "ok"

      reset_cli_output
      assert_equal 0, run_cli(["jobs:benchmark", "--jobs", "4", "--retry-jobs", "1", "--threads", "2", "--batch-size", "2", "--latency-samples", "2"], root)
      assert_includes @out.string, "work_per_second"
      assert_includes @out.string, "db_latency_p95_ms"
      assert_includes @out.string, "cleanup_deleted"
      assert_equal 0, DB_TASKS_DATABASE[:lunula_jobs].where(job_class: "Lunula::Jobs::BenchmarkJob").count
      assert_equal 0, DB_TASKS_DATABASE[:lunula_jobs].where(job_class: "Lunula::Jobs::RetryBenchmarkJob").count

      reset_cli_output
      assert_equal 0, run_cli(
        [
          "jobs:benchmark",
          "--jobs", "2",
          "--retry-jobs", "0",
          "--web-requests", "2",
          "--web-path", "/up",
          "--outbox-items", "1",
          "--checkpoint-mode", "PASSIVE",
          "--threads", "2",
          "--batch-size", "2",
          "--latency-samples", "1"
        ],
        root
      )
      assert_includes @out.string, "web_per_second"
      assert_includes @out.string, "web_failures"
      assert_includes @out.string, "job_outbox_processed"
      assert_includes @out.string, "event_outbox_processed"
      assert_includes @out.string, "checkpoint_seconds"
      assert_includes @out.string, "checkpointed"
      assert_equal 0, DB_TASKS_DATABASE[:lunula_job_outbox].count
      assert_equal 0, DB_TASKS_DATABASE[:lunula_outbox].count

      reset_cli_output
      assert_equal 0, run_cli(["jobs:list", "completed", "--limit", "2"], root)
      assert_includes @out.string, "DurableCLIJob"
      assert_includes @out.string, default_id.to_s

      scheduled_id = Lunula.enqueue_at(Time.now.utc + 3600, DurableCLIJob, "later")
      reset_cli_output
      assert_equal 0, run_cli(["jobs:scheduled"], root)
      assert_includes @out.string, "JOB"
      assert_includes @out.string, scheduled_id.to_s
      assert_includes @out.string, "DurableCLIJob"

      reset_cli_output
      assert_equal 0, run_cli(["jobs:cancel", scheduled_id.to_s], root)
      assert_equal "Requested cancellation for job #{scheduled_id}.\n", @out.string

      reset_cli_output
      failed_id = Lunula.enqueue(FailedCLIJob)
      assert_equal 0, run_cli(["jobs:work", "--once"], root)
      assert_includes @err.string, "Failed job #{failed_id}"

      reset_cli_output
      assert_equal 0, run_cli(["jobs:failed"], root)
      assert_includes @out.string, "CLI failure"

      reset_cli_output
      assert_equal 0, run_cli(["jobs:list", "discarded"], root)
      assert_includes @out.string, failed_id.to_s

      reset_cli_output
      assert_equal 0, run_cli(["jobs:retry", "job", failed_id.to_s], root)
      assert_equal "Queued job #{failed_id} for retry.\n", @out.string

      reset_cli_output
      assert_equal 0, run_cli(["jobs:prune", "--completed", "0"], root)
      assert_includes @out.string, "Pruned"

      paused_id = adapter.enqueue(DurableCLIJob, args: ["paused"], kwargs: {}, queue: "slow")
      reset_cli_output
      assert_equal 0, run_cli(["jobs:pause", "slow"], root)
      assert_equal "Paused queue slow.\n", @out.string

      reset_cli_output
      assert_equal 0, run_cli(["jobs:list", "blocked"], root)
      assert_includes @out.string, paused_id.to_s
      assert_includes @out.string, "queue slow is paused"

      reset_cli_output
      assert_equal 0, run_cli(["jobs:resume", "slow"], root)
      assert_equal "Resumed queue slow.\n", @out.string

      rescheduled_id = adapter.enqueue(DurableCLIJob, args: ["rescheduled"], kwargs: {})
      reset_cli_output
      assert_equal 0, run_cli(["jobs:reschedule", rescheduled_id.to_s, "60"], root)
      assert_includes @out.string, "Rescheduled job #{rescheduled_id}"

      discarded_id = adapter.enqueue(DurableCLIJob, args: ["discarded"], kwargs: {})
      reset_cli_output
      assert_equal 0, run_cli(["jobs:discard", discarded_id.to_s, "not needed"], root)
      assert_equal "Discarded job #{discarded_id}.\n", @out.string

      File.write(File.join(root, "config", "recurring.yml"), <<~YAML)
        tasks:
          cli_heartbeat:
            job: "CLITest::DurableCLIJob"
            every: "1 minute"
            args: ["recurring"]
      YAML

      reset_cli_output
      assert_equal 0, run_cli(["jobs:recurring"], root)
      assert_includes @out.string, "cli_heartbeat"
      assert_includes @out.string, "CLITest::DurableCLIJob"

      reset_cli_output
      assert_equal 0, run_cli(["jobs:schedule", "--once"], root)
      assert_includes @out.string, "Scheduled recurring task cli_heartbeat"

      reset_cli_output
      assert_equal 0, run_cli(["jobs:schedule", "--once"], root)
      assert_equal "No recurring tasks due.\n", @out.string

      reset_cli_output
      assert_equal 0, run_cli(["jobs:recurring", "disable", "cli_heartbeat"], root)
      assert_includes @out.string, "Disabled recurring task cli_heartbeat."

      reset_cli_output
      assert_equal 0, run_cli(["jobs:recurring", "enable", "cli_heartbeat"], root)
      assert_includes @out.string, "Enabled recurring task cli_heartbeat."

      reset_cli_output
      assert_equal 0, run_cli(["jobs:recurring", "run", "cli_heartbeat"], root)
      assert_includes @out.string, "Triggered recurring task cli_heartbeat"
    ensure
      Lunula.configure_jobs(adapter: :inline)
    end
  end

  def test_luna_database_commands_validate_arguments_and_database_configuration
    root = File.join(@directory, "database_errors_app")
    FileUtils.mkdir_p(File.join(root, "config"))
    FileUtils.mkdir_p(File.join(root, "app", "domains"))
    FileUtils.mkdir_p(File.join(root, "db", "migrations"))
    File.write(File.join(root, "config", "application.rb"), <<~RUBY)
      require "lunula"
      APP = Lunula::Application.new(root: File.expand_path("..", __dir__))
    RUBY
    File.write(File.join(root, "db", "migrations", "001_create_entries.rb"), <<~RUBY)
      Sequel.migration { change { create_table(:entries) { primary_key :id } } }
    RUBY

    with_isolated_app_constant do
      assert_equal 1, run_cli(["db:rollback", "zero"], root)
      assert_includes @err.string, "positive integer"

      reset_cli_output
      assert_equal 1, run_cli(["db:migrate"], root)
      assert_includes @err.string, "application database is not configured"

      reset_cli_output
      assert_equal 1, run_cli(["db:checkpoint", "--mode", "INVALID"], root)
      assert_includes @err.string, "checkpoint mode"
    end
  end

  def test_luna_new_does_not_overwrite_an_existing_destination
    destination = File.join(@directory, "existing")
    FileUtils.mkdir_p(destination)
    File.write(File.join(destination, "keep.txt"), "owned by the developer")

    status = Lunula::CLI.start(
      ["new", "existing"],
      out: @out,
      err: @err,
      cwd: @directory
    )

    assert_equal 1, status
    assert_equal "owned by the developer", File.read(File.join(destination, "keep.txt"))
    assert_includes @err.string, "destination already exists"
  end

  def test_generators_create_explicit_domain_rest_action_and_auth_code
    assert_equal 0, Lunula::CLI.start(
      ["new", "generated"],
      out: @out,
      err: @err,
      cwd: @directory
    )
    root = File.join(@directory, "generated")

    assert_equal 0, Lunula::CLI.start(
      ["generate", "domain", "comments"],
      out: @out,
      err: @err,
      cwd: root
    )
    assert File.file?(File.join(root, "test/domains/comments/.keep"))
    assert_equal 0, Lunula::CLI.start(
      ["generate", "action", "comments", "approve"],
      out: @out,
      err: @err,
      cwd: root
    )
    assert_equal 0, Lunula::CLI.start(
      ["generate", "rest", "posts"],
      out: @out,
      err: @err,
      cwd: root
    )
    assert_equal 0, Lunula::CLI.start(
      ["generate", "auth"],
      out: @out,
      err: @err,
      cwd: root
    )
    assert_equal 0, Lunula::CLI.start(
      ["generate", "migration", "add_excerpt_to_posts"],
      out: @out,
      err: @err,
      cwd: root
    )

    assert_includes File.read(File.join(root, "app/domains/comments/actions.rb")),
      "def approve(_context, _params)"
    refute_path_exists File.join(root, "app/domains/comments/repository.rb")
    assert_includes File.read(File.join(root, "app/domains/posts/routes.rb")),
      %(post "/posts", :create)
    assert_includes File.read(File.join(root, "app/domains/posts/actions.rb")),
      "def create(context, params)"
    assert_includes File.read(File.join(root, "app/domains/posts/actions.rb")),
      "attributes = params.permit(:title, :body)"
    assert_includes File.read(File.join(root, "app/domains/posts/post.rb")),
      "include Lunula::Validations"
    assert_includes File.read(File.join(root, "app/domains/posts/post.rb")),
      "include Lunula::Attributes"
    assert_includes File.read(File.join(root, "app/domains/posts/repository.rb")),
      "database: APP.database"
    assert_includes File.read(File.join(root, "app/domains/posts/repository.rb")),
      "extend Lunula::Repository"
    assert_includes File.read(File.join(root, "app/domains/posts/repository.rb")),
      "def all(scope = dataset.reverse_order(:created_at))"
    refute_includes File.read(File.join(root, "app/domains/posts/repository.rb")),
      "DB[:posts]"
    assert_includes File.read(File.join(root, "README.md")),
      "Lunula::Store"
    assert_includes File.read(File.join(root, "app/domains/posts/post.rb")),
      %(errors.add :title, "is required")
    assert_includes File.read(File.join(root, "app/domains/posts/views/form.erb")),
      %(<%= error_messages errors %>)
    assert_includes File.read(File.join(root, "app/domains/auth/password_authenticatable.rb")),
      "module PasswordAuthenticatable"
    assert_includes File.read(File.join(root, "app/domains/auth/user.rb")),
      "include Lunula::Validations"
    assert_includes File.read(File.join(root, "app/domains/auth/user.rb")),
      "include Lunula::Attributes"
    assert_includes File.read(File.join(root, "app/domains/auth/repository.rb")),
      "database: APP.database"
    assert_includes File.read(File.join(root, "app/domains/auth/actions.rb")),
      "attributes = params.permit(:email, :password)"
    assert_includes File.read(File.join(root, "app/domains/auth/actions.rb")),
      "deliver_later"
    assert_includes File.read(File.join(root, "app/domains/auth/mailer.rb")),
      "Lunula.app_url"
    assert_includes File.read(File.join(root, "app/domains/auth/mailer.rb")),
      "magic_login"
    assert_includes File.read(File.join(root, "app/domains/auth/user.rb")),
      "magic_login_version"
    refute_includes File.read(File.join(root, "app/domains/auth/mailer.rb")),
      "request.base_url"
    assert_includes File.read(File.join(root, "config/application.rb")),
      %(require_relative "jobs")
    assert_includes File.read(File.join(root, "config/jobs.rb")),
      "LUNULA_JOB_ADAPTER"
    assert_includes File.read(File.join(root, "app/domains/auth/required.rb")),
      "def check(context, _params)"
    assert File.file?(File.join(root, "app/domains/auth/mailer.rb"))
    auth_actions = File.read(File.join(root, "app/domains/auth/actions.rb"))
    %w[verify_email confirm_email magic_login send_magic_link confirm_magic_link complete_magic_login send_password_reset signup].each do |action|
      assert_includes auth_actions, "def #{action}("
    end
    assert File.file?(File.join(root, "app/domains/auth/token_verifier.rb"))
    assert File.file?(File.join(root, "app/domains/auth/views/verify_email.erb"))
    assert File.file?(File.join(root, "app/domains/auth/views/magic_login.erb"))
    assert File.file?(File.join(root, "app/domains/auth/views/magic_login_confirm.erb"))
    assert File.file?(File.join(root, "app/domains/auth/views/forgot_password.erb"))
    assert File.file?(File.join(root, "app/domains/auth/views/reset_password.erb"))
    assert File.file?(File.join(root, "app/domains/auth/views/signup.erb"))
    assert File.file?(File.join(root, "app/domains/auth/load_current_user.rb"))
    assert_includes File.read(File.join(root, "app/domains/auth/routes.rb")),
      %(get "/signup", :signup)
    assert_includes File.read(File.join(root, "app/domains/auth/routes.rb")),
      %(get "/magic-login", :magic_login)
    assert_includes File.read(File.join(root, "app/domains/auth/routes.rb")),
      %(post "/magic-login/confirm", :complete_magic_login)
    assert_includes File.read(File.join(root, "app/domains/auth/routes.rb")),
      %(get "/verify-email", :verify_email)
    assert_includes File.read(File.join(root, "app/domains/auth/routes.rb")),
      %(post "/verify-email", :confirm_email)
    assert_includes File.read(File.join(root, "app/domains/auth/routes.rb")),
      %(get "/password/reset", :reset_password)
    assert_includes File.read(File.join(root, "app/domains/auth/mailer.rb")),
      "password_reset_version"
    refute_includes File.read(File.join(root, "app/domains/auth/mailer.rb")),
      "password_digest: user.password_digest"
    assert_includes File.read(File.join(root, "config/application.rb")),
      %(context_loaders: ["Auth::LoadCurrentUser"])
    assert_includes File.read(File.join(root, "app/layouts/application.erb")),
      %(<%= navigation_page content, context: context %>)
    assert File.file?(File.join(root, "test/domains/comments/actions_test.rb"))
    assert_includes File.read(File.join(root, "test/domains/comments/actions_test.rb")),
      "Comments::Actions.new.approve"
    assert File.file?(File.join(root, "test/domains/posts/post_test.rb"))
    assert File.file?(File.join(root, "test/domains/posts/repository_test.rb"))
    assert File.file?(File.join(root, "test/domains/posts/actions_test.rb"))
    assert File.file?(File.join(root, "test/domains/auth/user_test.rb"))
    assert File.file?(File.join(root, "test/domains/auth/actions_test.rb"))
    refute File.exist?(File.join(root, "test/domains/comments/.keep"))

    migrations = Dir[File.join(root, "db/migrations/*.rb")].map { |path| File.basename(path) }
    assert_equal 4, migrations.length
    assert_equal migrations.length, migrations.map { |name| name.split("_").first }.uniq.length
    assert migrations.any? { |name| name.end_with?("_add_excerpt_to_posts.rb") }

    stdout, stderr, test_status = Open3.capture3(
      Gem.ruby,
      "-I",
      File.expand_path("../lib", __dir__),
      "-e",
      'Dir["test/**/*_test.rb"].sort.each { |file| require File.expand_path(file) }',
      chdir: root
    )
    assert test_status.success?, "generated tests failed:\n#{stdout}\n#{stderr}"
  end

  def test_action_generator_supports_multiple_methods_in_named_action_sets
    assert_equal 0, Lunula::CLI.start(
      ["new", "layouts"],
      out: @out,
      err: @err,
      cwd: @directory
    )
    root = File.join(@directory, "layouts")

    assert_equal 0, Lunula::CLI.start(
      ["generate", "rest", "posts"],
      out: @out,
      err: @err,
      cwd: root
    )
    assert_includes File.read(File.join(root, "app/domains/posts/actions.rb")), "def create(context, params)"

    assert_equal 0, Lunula::CLI.start(
      ["generate", "action", "posts", "publish", "--actions", "publishing"],
      out: @out,
      err: @err,
      cwd: root
    )
    assert_equal 0, Lunula::CLI.start(
      ["generate", "action", "posts", "archive", "--actions", "publishing"],
      out: @out,
      err: @err,
      cwd: root
    )
    actions = File.read(File.join(root, "app/domains/posts/actions/publishing_actions.rb"))
    assert_includes actions, "class PublishingActions < Lunula::Actions"
    assert_includes actions, "def publish(_context, _params)"
    assert_includes actions, "def archive(_context, _params)"
    assert_includes File.read(File.join(root, "app/domains/posts/routes.rb")),
      %(post "/posts/:id/publish", :publish, actions: :publishing)
    action_tests = File.read(File.join(root, "test/domains/posts/publishing_actions_test.rb"))
    assert_includes action_tests, "Posts::PublishingActions.new.publish"
    assert_includes action_tests, "Posts::PublishingActions.new.archive"

    reset_cli_output
    assert_equal 1, Lunula::CLI.start(
      ["generate", "rest", "comments", "--split-actions"],
      out: @out,
      err: @err,
      cwd: root
    )
    assert_includes @err.string, "unknown option: --split-actions"

    reset_cli_output
    assert_equal 1, Lunula::CLI.start(
      ["generate", "action", "posts", "preview", "--inline"],
      out: @out,
      err: @err,
      cwd: root
    )
    assert_includes @err.string, "unknown option: --inline"
  end

  private

  def cleanup_loaded_app_constant
    return unless Object.const_defined?(:APP, false)

    application = Object.const_get(:APP)
    application.database&.disconnect if application.respond_to?(:database) && application.database.respond_to?(:disconnect)
    cleanup_application_domain_constants(application)
    application.loader.unregister if application.respond_to?(:loader)
    Object.__send__(:remove_const, :APP)
  end

  def with_isolated_app_constant
    previous_app = Object.const_get(:APP) if Object.const_defined?(:APP, false)
    Object.__send__(:remove_const, :APP) if Object.const_defined?(:APP, false)

    yield
  ensure
    if Object.const_defined?(:APP, false)
      application = Object.const_get(:APP)
      cleanup_application_domain_constants(application)
      application.loader.unregister if application.respond_to?(:loader)
      Object.__send__(:remove_const, :APP)
    end
    Object.const_set(:APP, previous_app) if previous_app
    Object.__send__(:remove_const, :RoutesTestAuth) if Object.const_defined?(:RoutesTestAuth, false)
    if Object.const_defined?(:DB_TASKS_DATABASE, false)
      Object.const_get(:DB_TASKS_DATABASE).disconnect
      Object.__send__(:remove_const, :DB_TASKS_DATABASE)
    end
  end

  def cleanup_application_domain_constants(application)
    root = application.root if application.respond_to?(:root)
    constants = []

    if application.respond_to?(:routes)
      constants.concat(
        application.routes.entries.map do |route|
          route.domain_name.to_s.split("_").map(&:capitalize).join.to_sym
        end
      )
    end

    if root
      constants.concat(
        Object.constants.select do |constant|
          path = Object.autoload?(constant)
          path && File.expand_path(path).start_with?(root)
        end
      )
    end

    constants.uniq.each do |constant|
      Object.__send__(:remove_const, constant) if Object.const_defined?(constant, false)
    end
  end

  def database_app(name, migrations)
    root = File.join(@directory, name)
    FileUtils.mkdir_p(File.join(root, "config"))
    FileUtils.mkdir_p(File.join(root, "app", "domains"))
    FileUtils.mkdir_p(File.join(root, "db", "migrations"))
    database_path = File.join(root, "db", "test.sqlite3")
    File.write(File.join(root, "config", "application.rb"), <<~RUBY)
      require "lunula"
      require "sequel"

      DB_TASKS_DATABASE = Sequel.sqlite(#{database_path.inspect})
      APP = Lunula::Application.new(
        root: File.expand_path("..", __dir__),
        database: DB_TASKS_DATABASE
      )
    RUBY
    migrations.each do |filename, source|
      File.write(File.join(root, "db", "migrations", filename), source)
    end
    File.write(File.join(root, "db", "seeds.rb"), "# seeds\n")
    root
  end

  def durable_jobs_app
    root = File.join(@directory, "durable-jobs")
    FileUtils.mkdir_p(File.join(root, "config"))
    FileUtils.mkdir_p(File.join(root, "app", "domains"))
    database_path = File.join(root, "jobs.sqlite3")
    File.write(File.join(root, "config", "application.rb"), <<~RUBY)
      require "lunula"
      require "sequel"

      DB_TASKS_DATABASE = Sequel.sqlite(#{database_path.inspect})
      DB_TASKS_DATABASE.create_table?(:performed_jobs) do
        primary_key :id
        String :value
      end
      DB_TASKS_DATABASE.create_table?(:lunula_jobs) do
        primary_key :id
        String :queue, null: false
        Integer :priority, null: false, default: 0
        String :job_class, null: false
        String :payload, text: true, null: false
        Integer :attempts, null: false
        Integer :max_attempts, null: false
        DateTime :available_at, null: false
        DateTime :locked_at
        String :locked_by
        String :worker_id
        String :last_error, text: true
        String :failure_kind
        DateTime :cancel_requested_at
        DateTime :cancelled_at
        DateTime :failed_at
        DateTime :completed_at
        DateTime :discarded_at
        String :unique_key
        DateTime :unique_until
        String :concurrency_key
        Integer :concurrency_limit
        DateTime :blocked_at
        String :blocked_reason
        DateTime :created_at, null: false
        DateTime :updated_at, null: false
      end
      DB_TASKS_DATABASE.create_table?(:lunula_job_workers) do
        String :id, primary_key: true
        Integer :process_id, null: false
        String :hostname, null: false
        String :queues, text: true, null: false
        Integer :thread_count, null: false
        Integer :batch_size, null: false
        DateTime :started_at, null: false
        DateTime :last_heartbeat_at, null: false
        Integer :current_workload, null: false, default: 0
      end
      DB_TASKS_DATABASE.create_table?(:lunula_job_queues) do
        String :queue, primary_key: true
        DateTime :paused_at, null: false
        String :paused_by
        DateTime :created_at, null: false
        DateTime :updated_at, null: false
      end
      DB_TASKS_DATABASE.create_table?(:lunula_outbox) do
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
      DB_TASKS_DATABASE.create_table?(:lunula_job_outbox) do
        primary_key :id
        String :handoff_id, null: false
        String :queue, null: false
        Integer :priority, null: false, default: 0
        String :job_class, null: false
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
      DB_TASKS_DATABASE.create_table?(:lunula_recurring_runs) do
        primary_key :id
        String :task_name, null: false
        DateTime :scheduled_at, null: false
        TrueClass :manual, null: false, default: false
        Integer :enqueued_job_id
        DateTime :created_at, null: false
        unique [:task_name, :scheduled_at], name: :lunula_recurring_runs_unique
      end
      Lunula.configure_jobs(
        adapter: Lunula::Jobs::Adapters::Database.new(database: DB_TASKS_DATABASE, retry_delay: ->(_attempt) { 0 }),
        outbox: Lunula::Jobs::Outbox.new(database: DB_TASKS_DATABASE)
      )
      APP = Lunula::Application.new(
        root: File.expand_path("..", __dir__),
        database: DB_TASKS_DATABASE,
        outbox: Lunula::Events::Outbox.new(database: DB_TASKS_DATABASE),
        job_outbox: Lunula.job_outbox
      )
    RUBY
    FileUtils.mkdir_p(File.join(root, "app", "domains", "home"))
    File.write(File.join(root, "app", "domains", "home.rb"), "module Home; end\n")
    File.write(File.join(root, "app", "domains", "home", "routes.rb"), %(get "/up", :up\n))
    File.write(File.join(root, "app", "domains", "home", "actions.rb"), <<~RUBY)
      module Home
        class Actions < Lunula::Actions
          def up(_context, _params)
            text "OK"
          end
        end
      end
    RUBY
    File.write(File.join(root, "config", "recurring.yml"), "tasks: {}\n")
    root
  end

  def run_cli(arguments, root)
    Lunula::CLI.start(arguments, out: @out, err: @err, cwd: root)
  end

  def reset_cli_output
    [@out, @err].each do |stream|
      stream.truncate(0)
      stream.rewind
    end
  end
end
