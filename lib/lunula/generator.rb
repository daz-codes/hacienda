# frozen_string_literal: true

require "fileutils"
require "securerandom"
require_relative "generator/application_templates"
require_relative "generator/domain_templates"
require_relative "generator/authentication_templates"
require_relative "generator/documentation_templates"

module Lunula
  class Generator
    class Error < StandardError; end

    include NewApplicationTemplates
    include DomainTemplates
    include AuthenticationTemplates
    include DocumentationTemplates

    HELIUM_ASSETS = %w[
      helium.js
      helium-csp.js
      helium-sse.js
      helium-csp-sse.js
      jexpr.js
    ].freeze
    FRAMEWORK_ASSETS = %w[
      morpheus.js
      idiomorph.esm.js
      MORPHEUS-LICENSE.txt
      IDIOMORPH-LICENSE.txt
    ].freeze

    def initialize(target:, source_root:, cwd:)
      @target = target
      @source_root = source_root
      @cwd = cwd
    end

    def new_app
      created_target = false
      refuse_existing_target
      created_target = true
      create_directories
      write_files
      write_credentials
      copy_helium
      copy_navigation_assets
      @target
    rescue
      FileUtils.rm_rf(@target) if created_target && File.directory?(@target)
      raise
    end

    def generate_domain(name)
      ensure_application!
      domain = normalize_name(name)
      namespace = camelize(domain)
      root = domain_root(domain)

      FileUtils.mkdir_p(File.join(root, "actions"))
      FileUtils.mkdir_p(File.join(root, "views", "components"))
      FileUtils.mkdir_p(domain_test_root(domain))
      write_new(File.join(root, "routes.rb"), "# Routes for #{namespace}\n")
      write_new(File.join(root, "actions.rb"), action_set_template(namespace))
      touch(File.join(root, "views", "components", ".keep"))
      touch(File.join(domain_test_root(domain), ".keep"))
      root
    end

    def generate_action(domain_name, action_name, group: nil)
      ensure_application!
      domain = normalize_name(domain_name)
      action = normalize_name(action_name)
      namespace = camelize(domain)
      group = normalize_name(group) if group
      generate_domain(domain) unless File.directory?(domain_root(domain))

      destination = if group
        class_name = "#{camelize(group)}Actions"
        actions_file = File.join(domain_root(domain), "actions", "#{group}_actions.rb")
        write_new(actions_file, action_set_template(namespace, class_name:)) unless File.exist?(actions_file)
        append_action_method(actions_file, action_method_template(action))
        actions_file
      else
        actions_file = File.join(domain_root(domain), "actions.rb")
        write_new(actions_file, action_set_template(namespace)) unless File.exist?(actions_file)
        append_action_method(actions_file, action_method_template(action))
        actions_file
      end
      append_route_example(domain, action, group:)
      write_action_test(domain, action, group:)
      destination
    end

    def generate_rest(name)
      ensure_application!
      domain = normalize_name(name)
      namespace = camelize(domain)
      entity = singularize(domain)
      entity_class = camelize(entity)
      generate_domain(domain) unless File.directory?(domain_root(domain))

      routes_file = File.join(domain_root(domain), "routes.rb")
      existing_routes = File.read(routes_file)
      unless existing_routes.strip.empty? || existing_routes.start_with?("# Routes for")
        raise Error, "routes already exist: #{routes_file}"
      end

      File.write(routes_file, rest_routes(domain))
      write_new(File.join(domain_root(domain), "#{entity}.rb"), entity_template(namespace, entity_class))
      File.write(File.join(domain_root(domain), "repository.rb"), rest_repository(namespace, entity_class, domain))

      File.write(
        File.join(domain_root(domain), "actions.rb"),
        rest_actions(namespace, entity, entity_class, domain)
      )

      rest_views(domain, entity).each do |view, content|
        write_new(File.join(domain_root(domain), "views", view), content)
      end

      write_new(migration_path("create_#{domain}"), rest_migration(domain))
      write_rest_tests(domain, namespace, entity, entity_class)
      domain_root(domain)
    end

    def generate_auth
      ensure_application!
      domain = "auth"
      root = domain_root(domain)
      FileUtils.mkdir_p(File.join(root, "actions"))
      FileUtils.mkdir_p(File.join(root, "views", "components"))

      write_new(File.join(root, "routes.rb"), auth_routes)
      write_new(File.join(root, "user.rb"), auth_user)
      write_new(File.join(root, "password_authenticatable.rb"), password_authenticatable)
      write_new(File.join(root, "repository.rb"), auth_repository)
      write_new(File.join(root, "session.rb"), auth_session)
      write_new(File.join(root, "mailer.rb"), auth_mailer)
      write_new(File.join(root, "token_verifier.rb"), auth_token_verifier)
      write_new(File.join(root, "load_current_user.rb"), auth_context_loader)
      write_new(File.join(root, "required.rb"), auth_guard)

      write_new(File.join(root, "actions.rb"), auth_action_set)
      auth_views.each do |name, content|
        write_new(File.join(root, "views", "#{name}.erb"), content)
      end

      write_new(migration_path("create_users"), users_migration)
      ensure_gem(%(gem "bcrypt", "~> 3.1"))
      ensure_session_middleware
      ensure_context_loader("Auth::LoadCurrentUser")
      write_auth_tests
      root
    end

    def generate_migration(name)
      ensure_application!
      migration = normalize_name(name)
      path = migration_path(migration)
      write_new(path, migration_template(migration))
      path
    end

    private

    def refuse_existing_target
      raise Error, "destination already exists: #{@target}" if File.exist?(@target)
    end

    def create_directories
      %w[
        app/domains/home/actions
        app/domains/home/views/components
        app/errors
        app/layouts
        .kamal
        config
        config/environments
        db/migrations
        log
        public/assets
        test/domains/home
        test/integration
      ].each { |path| FileUtils.mkdir_p(File.join(@target, path)) }
    end

    def write_files
      files.each do |path, content|
        File.write(File.join(@target, path), content)
      end
    end

    def copy_helium
      source_root, license = helium_asset_source
      sources = HELIUM_ASSETS.to_h { |name| [name, File.join(source_root, name)] }
      sources["HELIUM-LICENSE.txt"] = license
      missing = sources.reject { |_name, path| File.file?(path) }.keys
      unless missing.empty?
        raise Error, "Helium assets are incomplete in #{source_root}: #{missing.join(", ")}"
      end

      sources.each do |name, path|
        FileUtils.cp(path, File.join(@target, "public", "assets", name))
      end
    end

    def copy_navigation_assets
      source = File.join(@source_root, "lib", "lunula", "assets")
      FRAMEWORK_ASSETS.each do |name|
        FileUtils.cp(File.join(source, name), File.join(@target, "public", "assets", name))
      end
    end

    def helium_asset_source
      override = ENV["HELIUM_PATH"]
      if override
        helium = File.expand_path(override, @cwd)
        unless File.file?(helium)
          raise Error, "HELIUM_PATH does not point to helium.js: #{helium}"
        end

        root = File.dirname(helium)
        return [root, File.join(root, "LICENSE")]
      end

      root = File.join(@source_root, "lib", "lunula", "assets")
      [root, File.join(root, "HELIUM-LICENSE.txt")]
    end

    def files
      {
        "Gemfile" => gemfile,
        "Rakefile" => rakefile,
        "Procfile.dev" => procfile_dev,
        "Dockerfile" => dockerfile,
        ".dockerignore" => dockerignore,
        ".kamal/secrets" => kamal_secrets,
        "DEPLOYMENT.md" => deployment_readme,
        "config.ru" => config_ru,
        "config/deploy.yml" => deploy_config,
        "config/application.rb" => application_config,
        "config/environment.rb" => environment_config,
        "config/environments/development.rb" => development_environment_config,
        "config/environments/test.rb" => test_environment_config,
        "config/environments/production.rb" => production_environment_config,
        "config/database.rb" => database_config,
        "config/litestream.yml.example" => litestream_config,
        "config/cache.rb" => cache_config,
        "config/storage.rb" => storage_config,
        "config/jobs.rb" => jobs_config,
        "config/recurring.yml" => recurring_config,
        "config/mail.rb" => mail_config,
        "db/migrations/20260629000000_create_lunula_runtime.rb" => durable_runtime_migration,
        "db/seeds.rb" => "# Add explicit application seed data here.\n",
        "app/domains/home/routes.rb" => %(get "/", :index\nget "/up", :up\n),
        "app/domains/home/actions.rb" => home_actions,
        "app/domains/home/views/index.erb" => home_view,
        "app/domains/home/views/components/_feature.erb" => feature_component,
        "app/errors/404.erb" => not_found_view,
        "app/errors/500.erb" => application_error_view,
        "app/layouts/application.erb" => layout,
        "public/assets/application.css" => stylesheet,
        "test/test_helper.rb" => test_helper,
        "test/domains/home/actions_test.rb" => home_actions_test,
        "test/integration/.keep" => "",
        ".gitignore" => "/.bundle\n/db/*.sqlite3\n/log\n/storage\n/tmp\n/config/master.key\n",
        "README.md" => app_readme
      }
    end

    def write_credentials
      Credentials.new(root: @target).ensure_files(default: <<~YAML)
        lunula:
          secret_key_base: #{SecureRandom.hex(64)}
      YAML
    end

    def ensure_application!
      return if File.file?(File.join(@target, "config", "application.rb"))

      raise Error, "not a Lunula application: #{@target}"
    end

    def normalize_name(name)
      value = name.to_s.strip.downcase.tr("-", "_")
      unless value.match?(/\A[a-z][a-z0-9_]*\z/)
        raise Error, "invalid name: #{name.inspect}"
      end

      value
    end

    def deployment_name
      File.basename(@target)
        .downcase
        .gsub(/[^a-z0-9-]+/, "-")
        .gsub(/\A-+|-+\z/, "")
        .then { |name| name.empty? ? "lunula-app" : name }
    end

    def application_title
      deployment_name.split("-").map(&:capitalize).join(" ")
    end

    def camelize(value)
      value.split("_").map(&:capitalize).join
    end

    def singularize(value)
      value.end_with?("ies") ? "#{value.delete_suffix("ies")}y" : value.delete_suffix("s")
    end

    def domain_root(domain)
      File.join(@target, "app", "domains", domain)
    end

    def domain_test_root(domain)
      File.join(@target, "test", "domains", domain)
    end

    def write_new(path, content)
      raise Error, "file already exists: #{path}" if File.exist?(path)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end

    def touch(path)
      FileUtils.touch(path) unless File.exist?(path)
    end

    def ensure_gem(line)
      path = File.join(@target, "Gemfile")
      content = File.read(path)
      File.open(path, "a") { |file| file.puts(line) } unless content.include?(line)
    end

    def ensure_session_middleware
      path = File.join(@target, "config.ru")
      content = File.read(path)

      unless content.include?("Rack::Session::Cookie") || content.include?("Lunula::SessionStore")
        middleware = <<~RUBY
          require "rack/session"

          session_expire_after = Integer(ENV.fetch("LUNULA_SESSION_EXPIRE_AFTER", 60 * 60 * 24 * 30))
          raise "LUNULA_SESSION_EXPIRE_AFTER must be positive" unless session_expire_after.positive?
          session_store = ENV.fetch("LUNULA_SESSION_STORE", "cookie")

          case session_store
          when "cookie"
            session_secret = ENV["LUNULA_SESSION_SECRET"] || ENV["SESSION_SECRET"]
            if session_secret.to_s.empty?
              raise "LUNULA_SESSION_SECRET is required in production" if Lunula.env.production?

              session_secret = "development-session-secret-change-this-before-production-000000000000"
            end
            session_old_secrets = ENV.fetch("LUNULA_SESSION_SECRET_OLD", ENV.fetch("SESSION_SECRET_OLD", ""))
              .split(",")
              .map(&:strip)
              .reject(&:empty?)
            use Rack::Session::Cookie,
              key: "lunula.session",
              secrets: [session_secret, *session_old_secrets],
              expire_after: session_expire_after,
              same_site: :lax,
              secure: Lunula.env.production?,
              httponly: true
          when "database", "db"
            use Lunula::SessionStore,
              database: DB,
              table: :lunula_sessions,
              key: "lunula.session",
              expire_after: session_expire_after,
              same_site: :lax,
              secure: Lunula.env.production?,
              httponly: true
          else
            raise "LUNULA_SESSION_STORE must be cookie or database"
          end
        RUBY

        content.sub!("require_relative \"config/application\"\n", "require_relative \"config/application\"\n#{middleware}\n")
      end

      unless content.include?("Lunula::Middleware::CSRF")
        content.sub!("use Rack::MethodOverride", "use Lunula::Middleware::CSRF\nuse Rack::MethodOverride")
      end

      File.write(path, content)
      ensure_gem(%(gem "rack-session", "~> 2.1"))
    end

    def ensure_context_loader(loader)
      path = File.join(@target, "config", "application.rb")
      content = File.read(path)
      return if content.include?(loader)

      if content.include?("  navigation: true\n)")
        content.sub!(
          "  navigation: true\n)",
          "  navigation: true,\n  context_loaders: [#{loader.inspect}]\n)"
        )
      elsif content.include?("  database: DB\n)")
        content.sub!(
          "  database: DB\n)",
          "  database: DB,\n  context_loaders: [#{loader.inspect}]\n)"
        )
      elsif content.include?("reload: Lunula.reload")
        content.sub!(
          "  reload: Lunula.reload\n)",
          "  reload: Lunula.reload,\n  context_loaders: [#{loader.inspect}]\n)"
        )
      else
        content.sub!(
          "APP = Lunula::Application.new(root: APP_ROOT)",
          <<~RUBY.strip
            APP = Lunula::Application.new(
              root: APP_ROOT,
              context_loaders: [#{loader.inspect}]
            )
          RUBY
        )
      end
      File.write(path, content)
    end
  end
end
