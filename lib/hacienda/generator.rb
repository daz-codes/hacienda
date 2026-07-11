# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Hacienda
  class Generator
    class Error < StandardError; end

    def initialize(target:, source_root:, cwd:)
      @target = target
      @source_root = source_root
      @cwd = cwd
    end

    def new_app
      refuse_existing_target
      @created_target = true
      create_directories
      write_files
      write_credentials
      copy_helium
      copy_navigation_assets
      @target
    rescue
      FileUtils.rm_rf(@target) if @created_target && File.directory?(@target)
      raise
    end

    def generate_domain(name)
      ensure_application!
      domain = normalize_name(name)
      namespace = camelize(domain)
      root = domain_root(domain)

      FileUtils.mkdir_p(File.join(root, "actions"))
      FileUtils.mkdir_p(File.join(root, "views", "components"))
      write_new(File.join(root, "routes.rb"), "# Routes for #{namespace}\n")
      write_new(File.join(root, "repository.rb"), repository_stub(namespace))
      touch(File.join(root, "actions", ".keep"))
      touch(File.join(root, "views", "components", ".keep"))
      root
    end

    def generate_action(domain_name, action_name, inline: false)
      ensure_application!
      domain = normalize_name(domain_name)
      action = normalize_name(action_name)
      namespace = camelize(domain)
      generate_domain(domain) unless File.directory?(domain_root(domain))

      destination = if inline
        actions_file = File.join(domain_root(domain), "actions.rb")
        append_inline_action(actions_file, action_template(namespace, camelize(action), wrapper: false))
        actions_file
      else
        File.join(domain_root(domain), "actions", "#{action}.rb").tap do |path|
          write_new(path, action_template(namespace, camelize(action)))
        end
      end
      append_route_example(domain, action)
      destination
    end

    def generate_rest(name, split_actions: false)
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

      if split_actions
        %w[index show new create edit update destroy].each do |action|
          write_new(
            File.join(domain_root(domain), "actions", "#{action}.rb"),
            rest_action(namespace, entity, entity_class, domain, action)
          )
        end
      else
        File.write(
          File.join(domain_root(domain), "actions.rb"),
          rest_actions(namespace, entity, entity_class, domain)
        )
      end

      rest_views(domain, entity).each do |view, content|
        write_new(File.join(domain_root(domain), "views", view), content)
      end

      write_new(migration_path("create_#{domain}"), rest_migration(domain))
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
      write_new(File.join(root, "load_current_user.rb"), auth_context_loader)
      write_new(File.join(root, "required.rb"), auth_guard)

      auth_actions.each do |name, content|
        write_new(File.join(root, "actions", "#{name}.rb"), content)
      end
      auth_views.each do |name, content|
        write_new(File.join(root, "views", "#{name}.erb"), content)
      end

      write_new(migration_path("create_users"), users_migration)
      ensure_gem(%(gem "bcrypt", "~> 3.1"))
      ensure_session_middleware
      ensure_context_loader("Auth::LoadCurrentUser")
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
        test/integration
      ].each { |path| FileUtils.mkdir_p(File.join(@target, path)) }
    end

    def write_files
      files.each do |path, content|
        File.write(File.join(@target, path), content)
      end
    end

    def copy_helium
      source = helium_source
      unless source
        raise Error, <<~MESSAGE.strip
          Helium was not found. Set HELIUM_PATH to helium.js, place the Helium
          repository beside Hacienda, or run: npm install @daz4126/helium
        MESSAGE
      end

      sources = %w[
        helium.js
        helium-csp.js
        helium-sse.js
        helium-csp-sse.js
        jexpr.js
      ].to_h do |name|
        [name, File.join(File.dirname(source), name)]
      end
      missing = sources.reject { |_name, path| File.file?(path) }.keys
      unless missing.empty?
        raise Error, "Helium CSP assets were not found beside #{source}: #{missing.join(", ")}"
      end

      sources.each do |name, path|
        FileUtils.cp(path, File.join(@target, "public", "assets", name))
      end
    end

    def copy_navigation_assets
      source = File.join(@source_root, "lib", "hacienda", "assets")
      %w[hacienda-navigation.js idiomorph.esm.js IDIOMORPH-LICENSE.txt].each do |name|
        FileUtils.cp(File.join(source, name), File.join(@target, "public", "assets", name))
      end
    end

    def helium_source
      candidates = [
        ENV["HELIUM_PATH"],
        File.join(@source_root, "..", "helium", "helium.js"),
        File.join(@cwd, "helium", "helium.js"),
        File.join(@cwd, "..", "helium", "helium.js"),
        File.join(@cwd, "node_modules", "@daz4126", "helium", "helium.js")
      ].compact

      candidates.find { |path| File.file?(path) }
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
        "db/migrations/20260629000000_create_hacienda_runtime.rb" => durable_runtime_migration,
        "db/seeds.rb" => "# Add explicit application seed data here.\n",
        "app/domains/home/routes.rb" => %(get "/", :index\nget "/up", :up\n),
        "app/domains/home/actions/index.rb" => home_action,
        "app/domains/home/actions/up.rb" => health_action,
        "app/domains/home/views/index.erb" => home_view,
        "app/domains/home/views/components/_feature.erb" => feature_component,
        "app/errors/404.erb" => not_found_view,
        "app/errors/500.erb" => application_error_view,
        "app/layouts/application.erb" => layout,
        "public/assets/application.css" => stylesheet,
        "test/test_helper.rb" => test_helper,
        "test/integration/home_test.rb" => home_integration_test,
        ".gitignore" => "/.bundle\n/db/*.sqlite3\n/log\n/storage\n/tmp\n/config/master.key\n",
        "README.md" => app_readme
      }
    end

    def write_credentials
      Credentials.new(root: @target).ensure_files(default: <<~YAML)
        hacienda:
          secret_key_base: #{SecureRandom.hex(64)}
      YAML
    end

    def gemfile
      hacienda_dependency =
        if File.file?(File.join(@source_root, "hacienda.gemspec"))
          %(gem "hacienda", path: #{@source_root.inspect})
        else
          %(gem "hacienda", "~> #{VERSION}")
        end

      <<~RUBY
        source "https://rubygems.org"

        #{hacienda_dependency}
        gem "puma", "~> 7.0"
        gem "rake", "~> 13.2"
        gem "rack-session", "~> 2.1"
        gem "sqlite3", "~> 2.0"

        group :development do
          gem "kamal", "~> 2.0", require: false
        end

        group :test do
          gem "minitest", "~> 6.0"
          gem "rack-test", "~> 2.2"
        end
      RUBY
    end

    def dockerfile
      <<~'DOCKERFILE'
        # syntax=docker/dockerfile:1

        ARG RUBY_VERSION=3.3.6
        FROM ruby:${RUBY_VERSION}-slim AS base

        WORKDIR /app

        ENV HACIENDA_ENV="production" \
            RACK_ENV="production" \
            BUNDLE_DEPLOYMENT="1" \
            BUNDLE_PATH="/usr/local/bundle" \
            BUNDLE_WITHOUT="development:test"

        RUN apt-get update -qq && \
            apt-get install --no-install-recommends -y ca-certificates libsqlite3-0 && \
            rm -rf /var/lib/apt/lists/*

        FROM base AS build

        RUN apt-get update -qq && \
            apt-get install --no-install-recommends -y build-essential git libsqlite3-dev pkg-config && \
            rm -rf /var/lib/apt/lists/*

        COPY Gemfile Gemfile.lock ./
        RUN bundle install && \
            rm -rf /usr/local/bundle/cache /usr/local/bundle/ruby/*/cache

        COPY . .

        FROM base

        RUN groupadd --system hacienda && \
            useradd --system --gid hacienda --create-home hacienda

        COPY --from=build /usr/local/bundle /usr/local/bundle
        COPY --from=build --chown=hacienda:hacienda /app /app

        RUN mkdir -p db log tmp && chown -R hacienda:hacienda db log tmp

        USER hacienda

        EXPOSE 5151

        CMD ["bundle", "exec", "rackup", "--host", "0.0.0.0", "--port", "5151"]
      DOCKERFILE
    end

    def dockerignore
      <<~TEXT
        .git
        .bundle
        .kamal
        .env*
        config/master.key
        config/deploy*.yml
        db/*.sqlite3
        log/*
        storage/*
        tmp/*
        vendor/bundle
      TEXT
    end

    def kamal_secrets
      <<~TEXT
        # Keep secret values in the environment or a password manager, not here.
        # Keep this file owner-readable only: chmod 600 .kamal/secrets
        KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
        HACIENDA_MASTER_KEY=$(cat config/master.key)
        HACIENDA_SESSION_SECRET=$HACIENDA_SESSION_SECRET
        # HACIENDA_SESSION_SECRET_OLD=$HACIENDA_SESSION_SECRET_OLD

        # Uncomment these if production mail uses environment variables.
        # HACIENDA_DASHBOARD_PASSWORD=$HACIENDA_DASHBOARD_PASSWORD
        # SMTP_USERNAME=$SMTP_USERNAME
        # SMTP_PASSWORD=$SMTP_PASSWORD
      TEXT
    end

    def deploy_config
      name = deployment_name

      <<~YAML
        # Replace the example host, domain, registry username, and image before setup.
        service: #{name}
        image: your-registry-user/#{name}
        minimum_version: 2.0.0

        servers:
          web:
            - 192.0.2.1
          job:
            hosts:
              - 192.0.2.1
            cmd: bundle exec hac jobs:work
          scheduler:
            hosts:
              - 192.0.2.1
            cmd: bundle exec hac jobs:schedule

        proxy:
          ssl: true
          host: app.example.com
          app_port: 5151
          forward_headers: true
          healthcheck:
            path: /up
            interval: 3
            timeout: 3

        registry:
          username: your-registry-user
          password:
            - KAMAL_REGISTRY_PASSWORD

        env:
          clear:
            HACIENDA_ENV: production
            RACK_ENV: production
            DATABASE_URL: sqlite:///app/db/production.sqlite3
            HACIENDA_APP_URL: https://app.example.com
          secret:
            - HACIENDA_MASTER_KEY
            - HACIENDA_SESSION_SECRET
            # - HACIENDA_SESSION_SECRET_OLD
            # - HACIENDA_DASHBOARD_PASSWORD
            # - SMTP_USERNAME
            # - SMTP_PASSWORD

        # This named volume makes the default SQLite database survive deployments.
        # Use this template on one server only; use an external database for multiple hosts.
        volumes:
          - "#{name}_db:/app/db"

        builder:
          arch: amd64

        aliases:
          console: app exec --primary -i --reuse "bundle exec hac console"
          migrate: app exec --primary --reuse "bundle exec hac db:migrate"
          seed: app exec --primary --reuse "bundle exec hac db:seed"
          logs: app logs
      YAML
    end

    def rakefile
      <<~RUBY
        # frozen_string_literal: true

        APP_ROOT = File.expand_path(__dir__) unless defined?(APP_ROOT)
        require "hacienda"
        require "rake/testtask"
        require "sequel"
        require "sequel/extensions/migration"

        Rake::TestTask.new do |task|
          task.libs << "test"
          task.pattern = "test/**/*_test.rb"
        end

        task default: :test

        namespace :db do
          desc "Run database migrations"
          task :migrate do
            require_relative "config/database"
            Sequel::Migrator.run(DB, File.join(APP_ROOT, "db", "migrations"))
            puts "Database migrations complete."
          end

          desc "Load database seed data"
          task seed: :migrate do
            require_relative "config/application"
            load File.join(APP_ROOT, "db", "seeds.rb")
            puts "Database seed complete."
          end
        end
      RUBY
    end

    def config_ru
      <<~RUBY
        # frozen_string_literal: true

        require_relative "config/application"
        require "rack/head"
        require "rack/session"

        session_expire_after = Integer(ENV.fetch("HACIENDA_SESSION_EXPIRE_AFTER", 60 * 60 * 24 * 30))
        raise "HACIENDA_SESSION_EXPIRE_AFTER must be positive" unless session_expire_after.positive?
        session_store = ENV.fetch("HACIENDA_SESSION_STORE", "cookie")

        allowed_hosts = ENV.fetch("HACIENDA_ALLOWED_HOSTS", "").split(",").map(&:strip).reject(&:empty?)
        allowed_hosts = [Hacienda.app_host] if allowed_hosts.empty? && Hacienda.env.production?
        use Hacienda::Middleware::HostAuthorization, hosts: allowed_hosts
        use Hacienda::Middleware::SecurityHeaders,
          hsts: Hacienda.env.production?,
          csp: {
            "default-src" => ["'self'"],
            "base-uri" => ["'self'"],
            "form-action" => ["'self'"],
            "frame-ancestors" => ["'self'"],
            "img-src" => ["'self'", "data:"],
            "script-src" => ["'self'", :nonce],
            "style-src" => ["'self'", :nonce]
          }
        use Hacienda::Middleware::RateLimiter,
          rules: Hacienda.env.test? ? [] : [
            {
              method: "POST",
              path: ["/login", "/signup", "/magic-login", "/magic-login/confirm", "/password/forgot", "/password"],
              limit: 10,
              period: 60
            }
          ]
        use Rack::Head
        case session_store
        when "cookie"
          session_secret = ENV["HACIENDA_SESSION_SECRET"] || ENV["SESSION_SECRET"]
          if session_secret.to_s.empty?
            raise "HACIENDA_SESSION_SECRET is required in production" if Hacienda.env.production?

            session_secret = "development-session-secret-change-this-before-production-000000000000"
          end
          session_old_secrets = ENV.fetch("HACIENDA_SESSION_SECRET_OLD", ENV.fetch("SESSION_SECRET_OLD", ""))
            .split(",")
            .map(&:strip)
            .reject(&:empty?)
          use Rack::Session::Cookie,
            key: "hacienda.session",
            secrets: [session_secret, *session_old_secrets],
            expire_after: session_expire_after,
            same_site: :lax,
            secure: Hacienda.env.production?,
            httponly: true
        when "database", "db"
          use Hacienda::SessionStore,
            database: DB,
            table: :hacienda_sessions,
            key: "hacienda.session",
            expire_after: session_expire_after,
            same_site: :lax,
            secure: Hacienda.env.production?,
            httponly: true
        else
          raise "HACIENDA_SESSION_STORE must be cookie or database"
        end
        use Hacienda::Middleware::CSRF
        use Rack::MethodOverride
        use Hacienda::Middleware::StorageFiles, storage: APP.storage
        use Rack::Static, urls: ["/assets"], root: File.join(APP_ROOT, "public")
        use Hacienda::Middleware::RequestLogger

        map "/hac/jobs" do
          run Hacienda::Jobs::Dashboard.new(
            application: APP,
            recurring_path: File.join(APP_ROOT, "config", "recurring.yml")
          )
        end

        map "/" do
          run APP
        end
      RUBY
    end

    def procfile_dev
      <<~TEXT
        web: bundle exec hac start
        worker: bundle exec hac jobs:work --queue default --threads 2 --batch-size 5
        scheduler: bundle exec hac jobs:schedule
      TEXT
    end

    def application_config
      <<~RUBY
        # frozen_string_literal: true

        require "hacienda"

        APP_ROOT = File.expand_path("..", __dir__) unless defined?(APP_ROOT)
        Hacienda.root = APP_ROOT
        require_relative "environment"
        require_relative "database"
        require_relative "cache"
        require_relative "storage"
        require_relative "jobs"
        require_relative "mail"

        event_delivery = ENV.fetch(
          "HACIENDA_EVENT_OUTBOX",
          Hacienda.env.production? ? "database" : "inline"
        )
        event_outbox = case event_delivery
        when "database" then Hacienda::Events::Outbox.new(database: DB)
        when "inline" then nil
        else raise "unknown HACIENDA_EVENT_OUTBOX; use database or inline"
        end

        APP = Hacienda::Application.new(
          root: APP_ROOT,
          title: "#{application_title}",
          reload: Hacienda.reload,
          database: DB,
          outbox: event_outbox,
          job_outbox: Hacienda.job_outbox,
          cache: Hacienda.cache,
          storage: Hacienda.storage,
          navigation: true
        )
      RUBY
    end

    def environment_config
      <<~RUBY
        # frozen_string_literal: true

        Hacienda.env = ENV["HACIENDA_ENV"] || ENV["RACK_ENV"] || "development"

        environment_config = File.join(__dir__, "environments", "\#{Hacienda.env}.rb")
        require environment_config if File.file?(environment_config)
      RUBY
    end

    def development_environment_config
      <<~RUBY
        # frozen_string_literal: true

        Hacienda.reload = true
        Hacienda.configure_logger(root: APP_ROOT, level: :debug)
      RUBY
    end

    def test_environment_config
      <<~RUBY
        # frozen_string_literal: true

        Hacienda.configure_logger(output: File::NULL, level: :warn)
        Hacienda.configure_mail(root: APP_ROOT, delivery: :test)
      RUBY
    end

    def production_environment_config
      <<~RUBY
        # frozen_string_literal: true

        Hacienda.configure_logger(output: $stdout, level: :info)
      RUBY
    end

    def mail_config
      <<~RUBY
        # frozen_string_literal: true

        mail_delivery = ENV.fetch(
          "HACIENDA_MAIL_DELIVERY",
          Hacienda.env.test? ? "test" : Hacienda.env.production? ? "smtp" : "file"
        )
        mail_credentials = File.file?(File.join(APP_ROOT, "config", "credentials.yml.enc")) ? Hacienda.credentials : {}

        Hacienda.configure_mail(
          root: APP_ROOT,
          delivery: mail_delivery.to_sym,
          from: ENV.fetch("HACIENDA_MAIL_FROM", "hello@example.test"),
          smtp: {
            address: ENV["SMTP_ADDRESS"] || mail_credentials.dig(:mail, :smtp_address),
            port: (ENV["SMTP_PORT"] || mail_credentials.dig(:mail, :smtp_port) || 587).to_i,
            user_name: ENV["SMTP_USERNAME"] || mail_credentials.dig(:mail, :smtp_username),
            password: ENV["SMTP_PASSWORD"] || mail_credentials.dig(:mail, :smtp_password),
            authentication: ENV.fetch("SMTP_AUTHENTICATION", "plain"),
            enable_starttls_auto: ENV.fetch("SMTP_STARTTLS", "true") != "false"
          }.compact
        )
      RUBY
    end

    def jobs_config
      <<~RUBY
        # frozen_string_literal: true

        job_adapter_name = ENV.fetch(
          "HACIENDA_JOB_ADAPTER",
          Hacienda.env.test? ? "inline" : Hacienda.env.production? ? "database" : "async"
        )

        job_adapter = case job_adapter_name
        when "database"
          Hacienda::Jobs::Adapters::Database.new(
            database: DB,
            lease_seconds: Float(ENV.fetch("HACIENDA_JOB_LEASE_SECONDS", 300)),
            heartbeat_interval: ENV["HACIENDA_JOB_HEARTBEAT_INTERVAL"]&.then { |value| Float(value) },
            execution_timeout: ENV["HACIENDA_JOB_TIMEOUT"]&.then { |value| Float(value) },
            worker_timeout: ENV["HACIENDA_JOB_WORKER_TIMEOUT"]&.then { |value| Float(value) },
            completed_retention: ENV.fetch("HACIENDA_JOB_COMPLETED_RETENTION", 7 * 24 * 60 * 60),
            discarded_retention: ENV.fetch("HACIENDA_JOB_DISCARDED_RETENTION", 30 * 24 * 60 * 60),
            failed_retention: ENV.fetch("HACIENDA_JOB_FAILED_RETENTION", 30 * 24 * 60 * 60)
          )
        else
          job_adapter_name.to_sym
        end

        Hacienda.configure_jobs(
          adapter: job_adapter,
          outbox: Hacienda::Jobs::Outbox.new(database: DB)
        )
      RUBY
    end

    def durable_runtime_migration
      <<~RUBY
        # frozen_string_literal: true

        Sequel.migration do
          change do
            create_table(:hacienda_jobs) do
              primary_key :id
              String :queue, null: false, default: "default"
              Integer :priority, null: false, default: 0
              String :job_class, null: false
              String :payload, text: true, null: false
              Integer :attempts, null: false, default: 0
              Integer :max_attempts, null: false, default: 10
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
              index [:queue, :failed_at, :priority, :available_at], name: :hacienda_jobs_ready
              index :worker_id, name: :hacienda_jobs_worker
              index :unique_key, name: :hacienda_jobs_unique_key
              index :concurrency_key, name: :hacienda_jobs_concurrency_key
              index :blocked_at, name: :hacienda_jobs_blocked
            end

            create_table(:hacienda_outbox) do
              primary_key :id
              String :event_class, null: false
              String :payload, text: true, null: false
              Integer :attempts, null: false, default: 0
              Integer :max_attempts, null: false, default: 10
              DateTime :available_at, null: false
              DateTime :locked_at
              String :locked_by
              String :last_error, text: true
              String :failure_kind
              DateTime :failed_at
              DateTime :created_at, null: false
              DateTime :updated_at, null: false
              index [:failed_at, :available_at], name: :hacienda_outbox_ready
            end

            create_table(:hacienda_job_outbox) do
              primary_key :id
              String :handoff_id, null: false, unique: true
              String :queue, null: false, default: "default"
              Integer :priority, null: false, default: 0
              String :job_class, null: false
              String :payload, text: true, null: false
              Integer :attempts, null: false, default: 0
              Integer :max_attempts, null: false, default: 10
              DateTime :available_at, null: false
              DateTime :locked_at
              String :locked_by
              String :last_error, text: true
              String :failure_kind
              DateTime :failed_at
              DateTime :created_at, null: false
              DateTime :updated_at, null: false
              index [:failed_at, :priority, :available_at], name: :hacienda_job_outbox_ready
            end

            create_table(:hacienda_sessions) do
              String :id, primary_key: true
              String :data, text: true, null: false
              DateTime :expires_at
              DateTime :created_at, null: false
              DateTime :updated_at, null: false
              index :expires_at, name: :hacienda_sessions_expires_at
            end

            create_table(:hacienda_job_workers) do
              String :id, primary_key: true
              Integer :process_id, null: false
              String :hostname, null: false
              String :queues, text: true, null: false
              Integer :thread_count, null: false
              Integer :batch_size, null: false
              DateTime :started_at, null: false
              DateTime :last_heartbeat_at, null: false
              Integer :current_workload, null: false, default: 0
              index :last_heartbeat_at, name: :hacienda_job_workers_heartbeat
            end

            create_table(:hacienda_job_queues) do
              String :queue, primary_key: true
              DateTime :paused_at, null: false
              String :paused_by
              DateTime :created_at, null: false
              DateTime :updated_at, null: false
            end

            create_table(:hacienda_recurring_runs) do
              primary_key :id
              String :task_name, null: false
              DateTime :scheduled_at, null: false
              TrueClass :manual, null: false, default: false
              Integer :enqueued_job_id
              DateTime :created_at, null: false
              unique [:task_name, :scheduled_at], name: :hacienda_recurring_runs_unique
              index :created_at, name: :hacienda_recurring_runs_created
            end
          end
        end
      RUBY
    end

    def recurring_config
      <<~YAML
        # Recurring jobs use a deliberately small interval syntax:
        #
        # tasks:
        #   cleanup:
        #     job: "Maintenance::CleanupJob"
        #     every: "1 hour"
        #     queue: "default"
        #     priority: 0
        #     enabled: true
        #     args: []
        #     kwargs: {}
        tasks: {}
      YAML
    end

    def cache_config
      <<~RUBY
        # frozen_string_literal: true

        cache_store = case ENV.fetch(
          "HACIENDA_CACHE_STORE",
          Hacienda.env.production? ? "null" : "memory"
        )
        when "memory"
          Hacienda::Cache::MemoryStore.new(
            max_size: Integer(ENV.fetch("HACIENDA_CACHE_SIZE", 1_000))
          )
        when "null"
          Hacienda::Cache::NullStore.new
        else
          raise "unknown HACIENDA_CACHE_STORE; configure a store in config/cache.rb"
        end

        Hacienda.configure_cache(
          store: cache_store,
          namespace: File.basename(APP_ROOT)
        )
      RUBY
    end

    def storage_config
      <<~RUBY
        # frozen_string_literal: true

        storage_service = case ENV.fetch(
          "HACIENDA_STORAGE_SERVICE",
          Hacienda.env.test? ? "memory" : Hacienda.env.production? ? "null" : "disk"
        )
        when "disk"
          Hacienda::Storage::DiskService.new(
            root: ENV.fetch("HACIENDA_STORAGE_ROOT", File.join(APP_ROOT, "storage"))
          )
        when "memory"
          Hacienda::Storage::MemoryService.new
        when "null"
          Hacienda::Storage::NullService.new
        else
          raise "unknown HACIENDA_STORAGE_SERVICE; configure a service in config/storage.rb"
        end

        Hacienda.configure_storage(service: storage_service)
      RUBY
    end

    def database_config
      <<~RUBY
        # frozen_string_literal: true

        require "sequel"

        environment = Hacienda.env.name
        default_url = "sqlite://\#{File.join(APP_ROOT, "db", "\#{environment}.sqlite3")}"

        DB = Sequel.connect(ENV.fetch("DATABASE_URL", default_url))
        if DB.database_type == :sqlite
          Hacienda::SQLite.configure(DB, wal: environment != "test")
        end
      RUBY
    end

    def litestream_config
      name = deployment_name

      <<~YAML
        # Example Litestream configuration for single-host SQLite backups.
        # Install Litestream separately and provide destination credentials
        # through the environment or your host supervisor.
        #
        # Restore before starting the app:
        #   litestream restore -if-replica-exists -o db/production.sqlite3 db/production.sqlite3
        #
        # Run beside the app:
        #   litestream replicate -config config/litestream.yml
        dbs:
          - path: /app/db/production.sqlite3
            replicas:
              - type: s3
                bucket: CHANGE_ME
                path: #{name}/production.sqlite3
                endpoint: https://s3.amazonaws.com
                region: CHANGE_ME
      YAML
    end

    def home_action
      <<~RUBY
        # frozen_string_literal: true

        module Home
          module Index
            def self.respond(_context, _params)
              {framework: "Hacienda", command: "hac"}
            end
          end
        end
      RUBY
    end

    def test_helper
      <<~RUBY
        # frozen_string_literal: true

        ENV["HACIENDA_ENV"] = "test"
        ENV["RACK_ENV"] = "test"

        require "minitest/autorun"
        require "rack"
        require "rack/test"
        require "securerandom"
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

          # Tokens are only generated on demand (unsafe requests or rendered
          # forms), so seed the session with one instead of reading it back
          # from a GET.
          def csrf_token(_path = "/")
            @csrf_token ||= SecureRandom.hex(32).tap do |token|
              env "rack.session", {csrf_token: token}
            end
          end

          def before_setup
            super
            clear_cookies
            @csrf_token = nil
          end
        end
      RUBY
    end

    def home_integration_test
      <<~RUBY
        # frozen_string_literal: true

        require_relative "../test_helper"

        class HomeTest < ApplicationTest
          def test_home_page
            get "/"

            assert_equal 200, last_response.status
            assert_includes last_response.body, "Hacienda is running."
          end

          def test_health_check
            get "/up"

            assert_equal 200, last_response.status
            assert_equal "OK", last_response.body
          end
        end
      RUBY
    end

    def health_action
      <<~RUBY
        # frozen_string_literal: true

        module Home
          module Up
            def self.respond(_context, _params)
              text "OK"
            end
          end
        end
      RUBY
    end

    def home_view
      <<~ERB
        <% page_title "Home" %>

        <section>
          <p class="eyebrow">Domain-oriented Ruby</p>
          <h1><%= framework %> is running.</h1>
          <p>Your application is explicit, HTML-first, and ready for a domain.</p>

          <%= component :feature,
                title: "No controllers required",
                detail: "This page came from Home::Index and views/index.erb." %>

          <button @click="count++">
            Helium clicks: <strong @text="count">0</strong>
          </button>

          <p><code><%= command %> generate domain posts</code> is coming next.</p>
        </section>
      ERB
    end

    def feature_component
      <<~ERB
        <article class="feature">
          <h2><%= title %></h2>
          <p><%= detail %></p>
        </article>
      ERB
    end

    def not_found_view
      <<~ERB
        <% page_title title %>

        <section>
          <p class="eyebrow">404</p>
          <h1>Page not found.</h1>
          <p><%= message %></p>
          <p><a href="/">Go home</a></p>
        </section>
      ERB
    end

    def application_error_view
      <<~ERB
        <% page_title title %>

        <section>
          <p class="eyebrow">500</p>
          <h1>Something went wrong.</h1>
          <p><%= message %></p>
        </section>
      ERB
    end

    def layout
      <<~ERB
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title><%= document_title %></title>
            <%= stylesheet_link "application.css" %>
            <%= hacienda_navigation context %>
            <%= javascript_include "helium-csp.js", module: true %>
          </head>
          <body @data="{ count: 0 }">
            <%= navigation_page content, context: context %>
          </body>
        </html>
      ERB
    end

    def stylesheet
      <<~CSS
        :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
        body { max-width: 48rem; margin: 0 auto; padding: 4rem 1.5rem; line-height: 1.6; }
        h1 { font-size: clamp(2.5rem, 8vw, 5rem); line-height: 1; margin: .25em 0; }
        .eyebrow { color: #c96b35; font-weight: 700; text-transform: uppercase; }
        .feature { border-left: .25rem solid #c96b35; padding-left: 1rem; margin: 2rem 0; }
        .flash-messages { margin: 0 0 1.5rem; }
        .flash { padding: .75rem 1rem; border: 1px solid currentColor; }
        button { font: inherit; padding: .65rem 1rem; cursor: pointer; }
        [hidden] { display: none !important; }
      CSS
    end

    def ensure_application!
      return if File.file?(File.join(@target, "config", "application.rb"))

      raise Error, "not a Hacienda application: #{@target}"
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
        .then { |name| name.empty? ? "hacienda-app" : name }
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

    def write_new(path, content)
      raise Error, "file already exists: #{path}" if File.exist?(path)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end

    def touch(path)
      FileUtils.touch(path) unless File.exist?(path)
    end

    def repository_stub(namespace)
      <<~RUBY
        # frozen_string_literal: true

        module #{namespace}
          module Repository
            module_function
          end
        end
      RUBY
    end

    def action_template(namespace, action, wrapper: true)
      action_body = <<~RUBY
        module #{action}
          def self.respond(_context, _params)
            {}
          end
        end
      RUBY
      return action_body unless wrapper

      wrap_domain_module(namespace, action_body)
    end

    def append_inline_action(actions_file, action_body)
      if File.exist?(actions_file) && !File.read(actions_file).strip.empty?
        existing = File.read(actions_file)
        insertion = "\n#{indent(action_body, 2)}"
        closing_end = existing.rindex(/^end\s*$/)
        raise Error, "could not append action to malformed file: #{actions_file}" unless closing_end

        File.write(actions_file, "#{existing[0...closing_end]}#{insertion}#{existing[closing_end..]}")
      else
        namespace = camelize(File.basename(File.dirname(actions_file)))
        write_new(actions_file, wrap_domain_module(namespace, action_body))
      end
    end

    def wrap_domain_module(namespace, body)
      <<~RUBY
        # frozen_string_literal: true

        module #{namespace}
        #{indent(body.rstrip, 2)}
        end
      RUBY
    end

    def indent(text, spaces)
      padding = " " * spaces
      text.lines.map { |line| line.strip.empty? ? line : "#{padding}#{line}" }.join
    end

    def append_route_example(domain, action)
      routes = File.join(domain_root(domain), "routes.rb")
      example = <<~RUBY

        # Choose the HTTP verb and path for this action:
        # post "/#{domain}/:id/#{action}", :#{action}
      RUBY
      File.open(routes, "a") { |file| file.write(example) }
    end

    def rest_routes(domain)
      <<~RUBY
        get "/#{domain}", :index
        get "/#{domain}/new", :new
        post "/#{domain}", :create
        get "/#{domain}/:id", :show
        get "/#{domain}/:id/edit", :edit
        patch "/#{domain}/:id", :update
        delete "/#{domain}/:id", :destroy
      RUBY
    end

    def entity_template(namespace, entity_class)
      <<~RUBY
        # frozen_string_literal: true

        module #{namespace}
          class #{entity_class}
            include Hacienda::Attributes
            include Hacienda::Validations

            attributes :id, :created_at, :updated_at
            attribute :title, default: ""
            attribute :body, default: ""

            def validate
              errors.add :title, "is required" if title.to_s.strip.empty?
              errors.add :body, "is required" if body.to_s.strip.empty?
            end
          end
        end
      RUBY
    end

    def rest_repository(namespace, entity_class, table)
      <<~RUBY
        # frozen_string_literal: true

        module #{namespace}
          module Repository
            STORE = Hacienda::Store.new(
              database: APP.database,
              table: :#{table},
              record: #{entity_class}
            )

            module_function

            def all
              STORE.all(dataset.reverse_order(:created_at))
            end

            def find(id)
              STORE.find(id)
            end

            def save(record)
              STORE.save(record)
            end

            def delete(record)
              STORE.delete(record)
            end

            def dataset
              STORE.dataset
            end
          end
        end
      RUBY
    end

    def rest_action(namespace, entity, entity_class, domain, action)
      wrap_domain_module(namespace, rest_action_body(entity, entity_class, domain, action))
    end

    def rest_actions(namespace, entity, entity_class, domain)
      actions = %w[index show new create edit update destroy].map do |action|
        rest_action_body(entity, entity_class, domain, action)
      end.join("\n")
      wrap_domain_module(namespace, actions)
    end

    def rest_action_body(entity, entity_class, domain, action)
      body = case action
      when "index"
        "{#{domain}: Repository.all}"
      when "show"
        "{#{entity}: Repository.find(params[:id])}"
      when "new"
        "{#{entity}: #{entity_class}.new, errors: []}"
      when "create"
        <<~RUBY.chomp
          attributes = params.permit(:title, :body).transform_values { |value| value.to_s.strip }
          #{entity} = #{entity_class}.new(
            title: attributes[:title],
            body: attributes[:body]
          )
          return render(:new, #{entity}:, errors: #{entity}.errors, status: 422) if #{entity}.invalid?

          Repository.save(#{entity})
          context.flash[:notice] = "#{entity_class} created."
          redirect "/#{domain}/\#{#{entity}.id}"
        RUBY
      when "edit"
        "{#{entity}: Repository.find(params[:id]), errors: []}"
      when "update"
        <<~RUBY.chomp
          #{entity} = Repository.find(params[:id])
          attributes = params.permit(:title, :body).transform_values { |value| value.to_s.strip }
          #{entity}.title = attributes[:title]
          #{entity}.body = attributes[:body]
          return render(:edit, #{entity}:, errors: #{entity}.errors, status: 422) if #{entity}.invalid?

          Repository.save(#{entity})
          context.flash[:notice] = "#{entity_class} updated."
          redirect "/#{domain}/\#{#{entity}.id}"
        RUBY
      when "destroy"
        <<~RUBY.chomp
          #{entity} = Repository.find(params[:id])
          Repository.delete(#{entity})
          context.flash[:notice] = "#{entity_class} deleted."
          redirect "/#{domain}"
        RUBY
      end
      context_argument = body.include?("context.") ? "context" : "_context"

      <<~RUBY
        module #{camelize(action)}
          def self.respond(#{context_argument}, params)
        #{indent(body, 4)}
          end
        end
      RUBY
    end

    def rest_views(domain, entity)
      {
        "index.erb" => <<~ERB,
          <% page_title "#{camelize(domain)}" %>

          <header>
            <h1>#{camelize(domain)}</h1>
            <%= link "New #{entity}", "/#{domain}/new" %>
          </header>

          <% #{domain}.each do |#{entity}| %>
            <%= component :#{entity}_card, #{entity}: #{entity} %>
          <% end %>
        ERB
        "show.erb" => <<~ERB,
          <% page_title #{entity}.title %>

          <article>
            <h1><%= #{entity}.title %></h1>
            <p><%= #{entity}.body %></p>
            <%= link "Edit", path("/#{domain}/:id/edit", id: #{entity}.id) %>
          </article>
        ERB
        "new.erb" => <<~ERB,
          <% page_title "New #{entity}" %>

          <h1>New #{entity}</h1>
          <%= partial :form, #{entity}:, errors:, action: "/#{domain}", method: "post" %>
        ERB
        "edit.erb" => <<~ERB,
          <% page_title "Edit \#{#{entity}.title}" %>

          <h1>Edit #{entity}</h1>
          <%= partial :form,
                #{entity}:,
                errors:,
                action: "/#{domain}/\#{#{entity}.id}",
                method: "patch" %>
        ERB
        "form.erb" => <<~ERB,
          <%= error_messages errors %>

          <%= form_start action, method:, context: %>

            <label>
              Title
              <input name="title" value="<%= #{entity}.title %>" required>
            </label>

            <label>
              Body
              <textarea name="body" required><%= #{entity}.body %></textarea>
            </label>

            <button type="submit">Save</button>
          <%= form_end %>
        ERB
        "components/_#{entity}_card.erb" => <<~ERB
          <article>
            <h2>
              <%= link #{entity}.title, path("/#{domain}/:id", id: #{entity}.id) %>
            </h2>
          </article>
        ERB
      }
    end

    def rest_migration(table)
      <<~RUBY
        Sequel.migration do
          change do
            create_table(:#{table}) do
              primary_key :id
              String :title, null: false
              String :body, text: true, null: false
              DateTime :created_at, null: false
              DateTime :updated_at, null: false
            end
          end
        end
      RUBY
    end

    def migration_template(name)
      <<~RUBY
        # frozen_string_literal: true

        Sequel.migration do
          change do
            # Example:
            # create_table(:#{name.delete_prefix("create_")}) do
            #   primary_key :id
            #   String :title, null: false
            # end
          end
        end
      RUBY
    end

    def migration_path(name)
      directory = File.join(@target, "db", "migrations")
      existing_versions = Dir[File.join(directory, "*.rb")].filter_map do |path|
        File.basename(path)[/\A\d+/]&.to_i
      end
      current_version = Time.now.utc.strftime("%Y%m%d%H%M%S").to_i
      version = [current_version, existing_versions.max.to_i + 1].max
      File.join(directory, "#{version}_#{name}.rb")
    end

    def auth_routes
      <<~RUBY
        get "/login", :login
        post "/login", :authenticate
        get "/magic-login", :magic_login
        post "/magic-login", :send_magic_link
        get "/magic-login/confirm", :confirm_magic_link
        post "/magic-login/confirm", :complete_magic_login
        get "/signup", :signup
        post "/signup", :create_account
        get "/verify-email", :verify_email
        post "/verify-email", :confirm_email
        post "/email-verification", :send_verification_email

        get "/password/forgot", :forgot_password
        post "/password/forgot", :send_password_reset
        get "/password/reset", :reset_password
        patch "/password", :update_password

        guard Auth::Required do
          delete "/logout", :logout
        end
      RUBY
    end

    def password_authenticatable
      <<~RUBY
        # frozen_string_literal: true

        require "bcrypt"

        module Auth
          module PasswordAuthenticatable
            def password=(value)
              self.password_digest = BCrypt::Password.create(value).to_s
            end

            def authenticate(value)
              BCrypt::Password.new(password_digest) == value
            rescue BCrypt::Errors::InvalidHash
              false
            end
          end
        end
      RUBY
    end

    def auth_user
      <<~RUBY
        # frozen_string_literal: true

        module Auth
          class User
            include Hacienda::Attributes
            include Hacienda::Validations
            include PasswordAuthenticatable

            attributes :id, :password_digest, :email_verified_at, :created_at, :updated_at
            attribute :email, default: ""
            attribute :password_reset_version, default: 0, cast: ->(value) { value.to_i }
            attribute :magic_login_version, default: 0, cast: ->(value) { value.to_i }

            def validate(password: nil)
              errors.add :email, "is required" if email.to_s.strip.empty?
              errors.add :password, "must be at least 12 characters" if password && password.length < 12
            end

            def email_verified?
              !!email_verified_at
            end

            def verify_email(at: Time.now)
              self.email_verified_at = at
              self
            end

            def rotate_password_reset_version
              self.password_reset_version = password_reset_version.to_i + 1
              self
            end

            def rotate_magic_login_version
              self.magic_login_version = magic_login_version.to_i + 1
              self
            end
          end
        end
      RUBY
    end

    def auth_repository
      <<~RUBY
        # frozen_string_literal: true

        module Auth
          module Repository
            STORE = Hacienda::Store.new(database: APP.database, table: :users, record: User)

            module_function

            def find(id)
              STORE.first(dataset.where(id: id))
            end

            def find_by_email(email)
              STORE.first(dataset.where(email: normalize(email)))
            end

            def save(user)
              user.email = normalize(user.email)
              STORE.save(user)
            end

            def dataset
              STORE.dataset
            end

            def normalize(email)
              email.to_s.strip.downcase
            end
          end
        end
      RUBY
    end

    def auth_mailer
      <<~RUBY
        # frozen_string_literal: true

        require "rack/utils"

        module Auth
          module Mailer
            module_function

            def verification_email(_context, user)
              token = Hacienda.signed_token.generate(
                {user_id: user.id, email: user.email},
                purpose: "email_verification",
                expires_in: 24 * 60 * 60
              )
              url = Hacienda.app_url("/verify-email?token=\#{Rack::Utils.escape(token)}")

              Hacienda.mail(
                to: user.email,
                subject: "Verify your email",
                text: "Verify your email by visiting: \#{url}"
              )
            end

            def password_reset_email(_context, user)
              token = Hacienda.signed_token.generate(
                {user_id: user.id, password_reset_version: user.password_reset_version},
                purpose: "password_reset",
                expires_in: 15 * 60
              )
              url = Hacienda.app_url("/password/reset?token=\#{Rack::Utils.escape(token)}")

              Hacienda.mail(
                to: user.email,
                subject: "Reset your password",
                text: "Reset your password by visiting: \#{url}"
              )
            end

            def magic_login_email(_context, user)
              token = Hacienda.signed_token.generate(
                {user_id: user.id, magic_login_version: user.magic_login_version},
                purpose: "magic_login",
                expires_in: 15 * 60
              )
              url = Hacienda.app_url("/magic-login/confirm?token=\#{Rack::Utils.escape(token)}")

              Hacienda.mail(
                to: user.email,
                subject: "Log in to your account",
                text: "Log in by visiting: \#{url}"
              )
            end
          end
        end
      RUBY
    end

    def auth_session
      <<~RUBY
        # frozen_string_literal: true

        module Auth
          module Session
            module_function

            def login(context, user)
              context.reset_session!
              context.session[:user_id] = user.id
              context.current_user = user
            end

            def logout(context)
              context.reset_session!
              context.current_user = nil
            end

          end
        end
      RUBY
    end

    def auth_context_loader
      <<~RUBY
        # frozen_string_literal: true

        module Auth
          module LoadCurrentUser
            module_function

            def load(context)
              user_id = context.session[:user_id]
              context.current_user = Repository.find(user_id) if user_id
            end
          end
        end
      RUBY
    end

    def auth_guard
      <<~RUBY
        # frozen_string_literal: true

        module Auth
          module Required
            module_function

            def check(context, _params)
              redirect("/login") unless context.current_user
            end
          end
        end
      RUBY
    end

    def auth_actions
      {
        "login" => <<~RUBY,
          module Auth
            module Login
              def self.respond(_context, _params)
                {email: "", error: nil}
              end
            end
          end
        RUBY
        "authenticate" => <<~RUBY,
          module Auth
            module Authenticate
              def self.respond(context, params)
                credentials = params.permit(:email, :password)
                user = Repository.find_by_email(credentials[:email])

                if user&.authenticate(credentials[:password].to_s) && user.email_verified?
                  Session.login(context, user)
                  context.flash[:notice] = "Logged in."
                  redirect "/"
                else
                  render :login,
                    email: credentials[:email].to_s,
                    error: "Invalid email or password",
                    status: 422
                end
              end
            end
          end
        RUBY
        "magic_login" => <<~RUBY,
          module Auth
            module MagicLogin
              def self.respond(_context, _params)
                {email: ""}
              end
            end
          end
        RUBY
        "send_magic_link" => <<~RUBY,
          module Auth
            module SendMagicLink
              def self.respond(context, params)
                attributes = params.permit(:email)
                user = Repository.find_by_email(attributes[:email])

                if user&.email_verified?
                  user.rotate_magic_login_version
                  Repository.save(user)
                  Mailer.magic_login_email(context, user).deliver_later
                end

                context.flash[:notice] = "If that email can sign in, we sent a login link."
                redirect "/login"
              end
            end
          end
        RUBY
        "confirm_magic_link" => <<~RUBY,
          module Auth
            module ConfirmMagicLink
              def self.respond(_context, params)
                attributes = params.permit(:token)
                payload = Hacienda.signed_token.verify(attributes[:token], purpose: "magic_login")
                user = payload && Repository.find(payload["user_id"])

                unless user&.email_verified? && user.magic_login_version.to_i == payload["magic_login_version"].to_i
                  return render(:magic_login_confirm, token: "", errors: ["Login link is invalid or expired."], status: 422)
                end

                {token: attributes[:token].to_s, errors: []}
              end
            end
          end
        RUBY
        "complete_magic_login" => <<~RUBY,
          module Auth
            module CompleteMagicLogin
              def self.respond(context, params)
                attributes = params.permit(:token)
                payload = Hacienda.signed_token.verify(attributes[:token], purpose: "magic_login")
                user = payload && Repository.find(payload["user_id"])

                unless user&.email_verified? && user.magic_login_version.to_i == payload["magic_login_version"].to_i
                  return render(:magic_login_confirm, token: "", errors: ["Login link is invalid or expired."], status: 422)
                end

                user.rotate_magic_login_version
                Repository.save(user)
                Session.login(context, user)
                context.flash[:notice] = "Logged in."
                redirect "/"
              end
            end
          end
        RUBY
        "signup" => <<~RUBY,
          module Auth
            module Signup
              def self.respond(_context, _params)
                {email: "", errors: []}
              end
            end
          end
        RUBY
        "create_account" => <<~RUBY,
          module Auth
            module CreateAccount
              def self.respond(context, params)
                attributes = params.permit(:email, :password)
                password = attributes[:password].to_s
                user = User.new(email: attributes[:email].to_s)
                user.valid?(password:)
                user.errors.add :email, "is already in use" if Repository.find_by_email(user.email)
                return render(:signup, email: user.email, errors: user.errors, status: 422) if user.errors.any?

                user.password = password
                Repository.save(user)
                Mailer.verification_email(context, user).deliver_later
                context.flash[:notice] = "Account created. Check your email to verify your account."
                redirect "/login"
              end
            end
          end
        RUBY
        "verify_email" => <<~RUBY,
          module Auth
            module VerifyEmail
              def self.respond(context, params)
                attributes = params.permit(:token)
                payload = Hacienda.signed_token.verify(attributes[:token], purpose: "email_verification")
                user = payload && Repository.find(payload["user_id"])

                unless user && user.email == payload["email"]
                  return render(:verify_email, token: "", errors: ["Verification link is invalid or expired."], status: 422)
                end

                {token: attributes[:token].to_s, errors: []}
              end
            end
          end
        RUBY
        "confirm_email" => <<~RUBY,
          module Auth
            module ConfirmEmail
              def self.respond(context, params)
                attributes = params.permit(:token)
                payload = Hacienda.signed_token.verify(attributes[:token], purpose: "email_verification")
                user = payload && Repository.find(payload["user_id"])

                unless user && user.email == payload["email"]
                  return render(:verify_email, token: "", errors: ["Verification link is invalid or expired."], status: 422)
                end

                user.verify_email
                Repository.save(user)
                Session.login(context, user)
                context.flash[:notice] = "Email verified."
                redirect "/"
              end
            end
          end
        RUBY
        "send_verification_email" => <<~RUBY,
          module Auth
            module SendVerificationEmail
              def self.respond(context, params)
                attributes = params.permit(:email)
                user = Repository.find_by_email(attributes[:email])
                Mailer.verification_email(context, user).deliver_later if user && !user.email_verified?
                context.flash[:notice] = "If that email needs verification, we sent a link."
                redirect "/login"
              end
            end
          end
        RUBY
        "forgot_password" => <<~RUBY,
          module Auth
            module ForgotPassword
              def self.respond(_context, _params)
                {email: ""}
              end
            end
          end
        RUBY
        "send_password_reset" => <<~RUBY,
          module Auth
            module SendPasswordReset
              def self.respond(context, params)
                attributes = params.permit(:email)
                user = Repository.find_by_email(attributes[:email])
                Mailer.password_reset_email(context, user).deliver_later if user
                context.flash[:notice] = "If that email exists, we sent a password reset link."
                redirect "/login"
              end
            end
          end
        RUBY
        "reset_password" => <<~RUBY,
          module Auth
            module ResetPassword
              def self.respond(_context, params)
                attributes = params.permit(:token)
                payload = Hacienda.signed_token.verify(attributes[:token], purpose: "password_reset")
                user = payload && Repository.find(payload["user_id"])

                unless user && user.password_reset_version.to_i == payload["password_reset_version"].to_i
                  return render(:reset_password, token: "", errors: ["Password reset link is invalid or expired."], status: 422)
                end

                {token: attributes[:token].to_s, errors: []}
              end
            end
          end
        RUBY
        "update_password" => <<~RUBY,
          module Auth
            module UpdatePassword
              def self.respond(context, params)
                attributes = params.permit(:token, :password)
                payload = Hacienda.signed_token.verify(attributes[:token], purpose: "password_reset")
                user = payload && Repository.find(payload["user_id"])

                unless user && user.password_reset_version.to_i == payload["password_reset_version"].to_i
                  return render(:reset_password, token: "", errors: ["Password reset link is invalid or expired."], status: 422)
                end

                password = attributes[:password].to_s
                return render(:reset_password, token: attributes[:token].to_s, errors: user.errors, status: 422) if user.invalid?(password:)

                user.password = password
                user.rotate_password_reset_version
                Repository.save(user)
                Session.login(context, user)
                context.flash[:notice] = "Password updated."
                redirect "/"
              end
            end
          end
        RUBY
        "logout" => <<~RUBY
          module Auth
            module Logout
              def self.respond(context, _params)
                Session.logout(context)
                context.flash[:notice] = "Logged out."
                redirect "/"
              end
            end
          end
        RUBY
      }
    end

    def auth_views
      {
        "login" => <<~ERB,
          <% page_title "Log in" %>

          <h1>Log in</h1>
          <%= error_messages [error].compact %>
          <%= form_start "/login", context: %>
            <label>Email <input type="email" name="email" value="<%= email %>" required></label>
            <label>Password <input type="password" name="password" required></label>
            <button type="submit">Log in</button>
          <%= form_end %>
          <p><%= link "Email me a login link", "/magic-login" %></p>
          <p><%= link "Forgot your password?", "/password/forgot" %></p>
        ERB
        "magic_login" => <<~ERB,
          <% page_title "Email login link" %>

          <h1>Email login link</h1>
          <%= form_start "/magic-login", context: %>
            <label>Email <input type="email" name="email" value="<%= email %>" required></label>
            <button type="submit">Send login link</button>
          <%= form_end %>
        ERB
        "magic_login_confirm" => <<~ERB,
          <% page_title "Log in with email" %>

          <h1>Log in with email</h1>
          <%= error_messages errors %>
          <% unless token.to_s.empty? %>
            <%= form_start "/magic-login/confirm", context: %>
              <input type="hidden" name="token" value="<%= token %>">
              <button type="submit">Log in</button>
            <%= form_end %>
          <% end %>
        ERB
        "signup" => <<~ERB,
          <% page_title "Sign up" %>

          <h1>Sign up</h1>
          <%= error_messages errors %>
          <%= form_start "/signup", context: %>
            <label>Email <input type="email" name="email" value="<%= email %>" required></label>
            <label>Password <input type="password" name="password" minlength="12" required></label>
            <button type="submit">Sign up</button>
          <%= form_end %>
        ERB
        "verify_email" => <<~ERB,
          <% page_title "Verify your email" %>

          <h1>Verify your email</h1>
          <%= error_messages errors %>
          <% unless token.to_s.empty? %>
            <%= form_start "/verify-email", context: %>
              <input type="hidden" name="token" value="<%= token %>">
              <button type="submit">Verify email</button>
            <%= form_end %>
          <% end %>
        ERB
        "forgot_password" => <<~ERB,
          <% page_title "Reset your password" %>

          <h1>Reset your password</h1>
          <%= form_start "/password/forgot", context: %>
            <label>Email <input type="email" name="email" value="<%= email %>" required></label>
            <button type="submit">Send reset link</button>
          <%= form_end %>
        ERB
        "reset_password" => <<~ERB
          <% page_title "Choose a new password" %>

          <h1>Choose a new password</h1>
          <%= error_messages errors %>
          <% unless token.to_s.empty? %>
            <%= form_start "/password", method: "patch", context: %>
              <input type="hidden" name="token" value="<%= token %>">
              <label>New password <input type="password" name="password" minlength="12" required></label>
              <button type="submit">Update password</button>
            <%= form_end %>
          <% end %>
        ERB
      }
    end

    def users_migration
      <<~RUBY
        Sequel.migration do
          change do
            create_table(:users) do
              primary_key :id
              String :email, null: false, unique: true
              String :password_digest, null: false
              DateTime :email_verified_at
              Integer :password_reset_version, null: false, default: 0
              Integer :magic_login_version, null: false, default: 0
              DateTime :created_at, null: false
              DateTime :updated_at, null: false
            end
          end
        end
      RUBY
    end

    def ensure_gem(line)
      path = File.join(@target, "Gemfile")
      content = File.read(path)
      File.open(path, "a") { |file| file.puts(line) } unless content.include?(line)
    end

    def ensure_session_middleware
      path = File.join(@target, "config.ru")
      content = File.read(path)

      unless content.include?("Rack::Session::Cookie") || content.include?("Hacienda::SessionStore")
        middleware = <<~RUBY
          require "rack/session"

          session_expire_after = Integer(ENV.fetch("HACIENDA_SESSION_EXPIRE_AFTER", 60 * 60 * 24 * 30))
          raise "HACIENDA_SESSION_EXPIRE_AFTER must be positive" unless session_expire_after.positive?
          session_store = ENV.fetch("HACIENDA_SESSION_STORE", "cookie")

          case session_store
          when "cookie"
            session_secret = ENV["HACIENDA_SESSION_SECRET"] || ENV["SESSION_SECRET"]
            if session_secret.to_s.empty?
              raise "HACIENDA_SESSION_SECRET is required in production" if Hacienda.env.production?

              session_secret = "development-session-secret-change-this-before-production-000000000000"
            end
            session_old_secrets = ENV.fetch("HACIENDA_SESSION_SECRET_OLD", ENV.fetch("SESSION_SECRET_OLD", ""))
              .split(",")
              .map(&:strip)
              .reject(&:empty?)
            use Rack::Session::Cookie,
              key: "hacienda.session",
              secrets: [session_secret, *session_old_secrets],
              expire_after: session_expire_after,
              same_site: :lax,
              secure: Hacienda.env.production?,
              httponly: true
          when "database", "db"
            use Hacienda::SessionStore,
              database: DB,
              table: :hacienda_sessions,
              key: "hacienda.session",
              expire_after: session_expire_after,
              same_site: :lax,
              secure: Hacienda.env.production?,
              httponly: true
          else
            raise "HACIENDA_SESSION_STORE must be cookie or database"
          end
        RUBY

        content.sub!("require_relative \"config/application\"\n", "require_relative \"config/application\"\n#{middleware}\n")
      end

      unless content.include?("Hacienda::Middleware::CSRF")
        content.sub!("use Rack::MethodOverride", "use Hacienda::Middleware::CSRF\nuse Rack::MethodOverride")
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
      elsif content.include?("reload: Hacienda.reload")
        content.sub!(
          "  reload: Hacienda.reload\n)",
          "  reload: Hacienda.reload,\n  context_loaders: [#{loader.inspect}]\n)"
        )
      else
        content.sub!(
          "APP = Hacienda::Application.new(root: APP_ROOT)",
          <<~RUBY.strip
            APP = Hacienda::Application.new(
              root: APP_ROOT,
              context_loaders: [#{loader.inspect}]
            )
          RUBY
        )
      end
      File.write(path, content)
    end

    def deployment_readme
      <<~'MARKDOWN'.gsub("%APP%", deployment_name)
        # Deploying %APP%

        The generated Docker and Kamal files provide a production starting
        point for one Linux server using SQLite. Edit `config/deploy.yml`
        before using it.

        ## Prepare the application

        Install dependencies and commit `Gemfile.lock`; the Docker build is
        intentionally locked and will fail without it:

        ```sh
        bundle install
        git add Gemfile.lock
        ```

        If Hacienda is referenced through a local `path:` in `Gemfile`, replace
        it with a released gem version before building outside the framework
        checkout.

        ## Test the image locally

        ```sh
        docker build -t %APP% .
        docker volume create %APP%_db
        export HACIENDA_SESSION_SECRET=$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')
        docker run --rm \
          -e HACIENDA_MASTER_KEY="$(cat config/master.key)" \
          -e HACIENDA_SESSION_SECRET \
          -e DATABASE_URL=sqlite:///app/db/production.sqlite3 \
          -v %APP%_db:/app/db \
          %APP% bundle exec hac db:migrate
        docker run --rm -p 5151:5151 \
          -e HACIENDA_MASTER_KEY="$(cat config/master.key)" \
          -e HACIENDA_SESSION_SECRET \
          -e DATABASE_URL=sqlite:///app/db/production.sqlite3 \
          -v %APP%_db:/app/db \
          %APP%
        ```

        Open <http://localhost:5151/up>; it should return `OK`.

        ## Deploy with Kamal

        You need a Linux server reachable over SSH, a container registry, and
        a domain whose DNS points to the server.

        1. Replace `192.0.2.1`, `app.example.com`, and
           `your-registry-user` in `config/deploy.yml`.
        2. Keep local deployment secret files owner-readable only:

           ```sh
           chmod 600 config/master.key .kamal/secrets
           ```

        3. Export the registry and session secrets:

           ```sh
           export KAMAL_REGISTRY_PASSWORD="registry-access-token"
           export HACIENDA_SESSION_SECRET=$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')
           # During rotation only:
           # export HACIENDA_SESSION_SECRET_OLD="previous-secret"
           ```

        Sessions use encrypted client-side cookies by default. They expire
        after 30 days; set `HACIENDA_SESSION_EXPIRE_AFTER` to a positive number
        of seconds to change that. To rotate `HACIENDA_SESSION_SECRET`, deploy
        the new value and keep the previous value in
        `HACIENDA_SESSION_SECRET_OLD` until old cookies have expired. Logout
        removes the browser's current cookie, but a stolen copy remains
        replayable until expiry or secret rotation because the default store
        has no server-side revocation list.

        Set `HACIENDA_SESSION_STORE=database` to store session payloads in
        Sequel instead. That keeps only an opaque id in the browser, uses the
        generated `hacienda_sessions` table, and allows server-side revocation
        by deleting rows. Run migrations before enabling it.

        3. Run the first deployment and migrate the database:

           ```sh
           bundle exec kamal setup
           bundle exec kamal migrate
           ```

        Later deployments use `bundle exec kamal deploy`. Other generated
        aliases include `kamal console`, `kamal seed`, and `kamal logs`.

        Kamal Proxy terminates TLS and checks `/up` before routing traffic to a
        new container. Production logs go to stdout so `kamal logs` can read
        them.

        ## Database and migration constraints

        The named `%APP%_db` volume persists SQLite data across deployments.
        Generated apps configure SQLite with WAL mode, foreign-key enforcement,
        `synchronous = NORMAL`, and a 5 second busy-timeout outside test. This
        is a single-server configuration: keep web, worker, scheduler, SQLite,
        and local uploads on the same host and persistent volumes.

        Run `bundle exec hac db:check` after deployment to verify WAL,
        busy-timeout, foreign keys, and storage-path assumptions. Run
        `bundle exec hac db:checkpoint --mode TRUNCATE` during maintenance if
        the WAL file grows unexpectedly after a burst of writes.

        Use an external PostgreSQL or MySQL database and update `DATABASE_URL`
        before adding another web host.

        A container rollback does not roll back database migrations. Prefer
        additive, backwards-compatible migrations; use separate
        expand/migrate/contract deployments for destructive schema changes.
        Back up the database volume before significant migrations. SQLite
        backups must include WAL state; use a SQLite-aware tool such as
        Litestream or the SQLite online backup API rather than copying only the
        main database file while the app is running. The generated
        `config/litestream.yml.example` is a starting point; copy it to
        `config/litestream.yml`, fill in the replica destination, and run
        Litestream beside the app through your host supervisor. Back up local
        uploads separately from SQLite.

        ## Jobs and event delivery

        Production uses Hacienda's durable database job adapter and the
        transactional event outbox. The generated `job` server role runs
        `hac jobs:work` on the same host and volume; that worker also relays
        durable job hand-offs and event outbox deliveries. The generated
        `scheduler` role runs `hac jobs:schedule` for recurring tasks.
        Delivery is at least once, so jobs and event subscribers must be
        idempotent.

        Qualify the queue on the deployed host after `hac db:check`:

        ```sh
        bundle exec hac jobs:benchmark --jobs 1000 --retry-jobs 25 --web-requests 250 --web-path /up --outbox-items 100 --threads 2 --batch-size 10
        ```

        The benchmark uses the real database job adapter, worker
        claim/complete path, failed-job retry path, optional web requests,
        durable outbox relays, a WAL checkpoint, and simple database latency
        samples. It deletes only its own benchmark rows unless `--keep` is
        passed. For the generated single-host SQLite shape, start with one
        worker process, `--threads 2`, `--batch-size 5..10`, and
        `--poll 0.25..1.0`. Lower worker concurrency if web requests or
        benchmark p95 database latency degrade under load.

        Inspect terminal failures with
        `kamal app exec --role job "bundle exec hac jobs:failed"` and check
        worker health with
        `kamal app exec --role job "bundle exec hac jobs:health"`.

        The mounted dashboard at `/hac/jobs` is read-only. In development it is
        local-only. In production it returns forbidden unless
        `HACIENDA_DASHBOARD_PASSWORD` is set, in which case it uses HTTP Basic
        auth with username `hacienda` unless `HACIENDA_DASHBOARD_USERNAME` is
        also set. Development local-only checks use the direct `REMOTE_ADDR`
        socket address, not forwarding headers.

        Configure SMTP secrets in `.kamal/secrets` and `config/deploy.yml` if
        the application sends mail.

        Production storage defaults to `NullService`. Configure an object-store
        adapter in `config/storage.rb`. If disk storage is deliberately used on
        one server, mount `HACIENDA_STORAGE_ROOT` as a separate persistent
        volume; do not bake uploaded files into the image.

        The local `/uploads` middleware serves public capability URLs without
        authorization. Private files need guarded application routes or signed
        remote URLs. Database and storage writes are not one transaction, so
        applications with strict retention requirements should run a periodic
        orphan-file sweep.

        See the [Kamal documentation](https://kamal-deploy.org/docs/installation/)
        for server, registry, proxy, and command details.
      MARKDOWN
    end

    def app_readme
      <<~MARKDOWN
        # Hacienda application

        Start the application:

        ```sh
        bundle install
        bundle exec hac db:migrate
        # Optional application seed data:
        bundle exec hac db:seed
        bundle exec hac start
        ```

        `hac start` runs Rackup on port 5151. The equivalent direct command is:

        ```sh
        bundle exec rackup -p 5151
        ```

        Open a console with the application environment loaded:

        ```sh
        bundle exec hac console
        ```

        Manage the database through the same application environment:

        ```sh
        bundle exec hac db:migrate
        bundle exec hac db:rollback       # one migration
        bundle exec hac db:rollback 3     # three migrations
        bundle exec hac db:seed
        bundle exec hac db:check
        bundle exec hac db:checkpoint --mode TRUNCATE
        ```

        `db:seed` loads `db/seeds.rb` without implicitly running migrations.
        `db:check` reports SQLite production settings such as WAL mode,
        busy-timeout, foreign keys, and unsafe synced-storage paths.
        `db:checkpoint` runs an explicit SQLite WAL checkpoint.

        Run the generated Rack::Test integration suite:

        ```sh
        bundle exec rake test
        ```

        `test/test_helper.rb` boots the complete `config.ru` middleware stack in
        the test environment, applies pending test-database migrations, and
        provides `ApplicationTest`, `database`, and `csrf_token` helpers.

        List routes with their action modules and guards:

        ```sh
        bundle exec hac routes
        ```

        Routes live in `app/domains/*/routes.rb`. A route maps directly to an
        action module and renders its matching ERB view when it returns a Hash.
        Actions can be grouped in `app/domains/posts/actions.rb` or split into
        `app/domains/posts/actions/show.rb` files. Hacienda checks `actions.rb`
        first, then falls back to the split action file.

        Branded error pages live in `app/errors/404.erb` and
        `app/errors/500.erb`. They render through the application layout and
        receive `status`, `title`, `message`, `context`, and `error` locals.
        Development 500s keep the framework debug page.

        Generated REST resources use `Hacienda::Attributes` and
        `Hacienda::Store`. Repositories receive the application database through
        `APP.database`, while `STORE.dataset` remains available for custom
        Sequel queries.

        Actions receive request-scoped context separately from parameters:

        ```ruby
        def self.respond(context, params)
        end
        ```

        Form, query, route, and top-level JSON object parameters all use the
        same nested `Params` API. Whitelist input explicitly:

        ```ruby
        attributes = params.require(:post).permit(:title, :body)
        ```

        Malformed JSON returns `400 Bad Request`. Session-authenticated JSON
        writes send their CSRF token in the `X-CSRF-Token` header.

        The application cache is available as `context.cache` in actions and
        `APP.cache` elsewhere. Development and test use a bounded memory store;
        production defaults to the null store until `config/cache.rb` is wired
        to a shared adapter.

        ```ruby
        value = context.cache.fetch(["posts", post.id], expires_in: 60) { expensive_value }
        ```

        Multipart uploads are stored explicitly through `context.storage`.
        Development uses `storage/`, tests use memory, and production defaults
        to a null service until `config/storage.rb` is connected to object
        storage:

        ```ruby
        blob = context.storage.store(
          params[:file],
          max_bytes: 5 * 1024 * 1024,
          content_types: ["image/*"]
        )
        ```

        Local `/uploads` URLs are public and unguarded. Store private files
        behind an authenticated route or a remote service with signed URLs.

        Encrypted credentials live in `config/credentials.yml.enc`. Keep
        `config/master.key` local, or set `HACIENDA_MASTER_KEY` in production.
        Keep `config/master.key` and `.kamal/secrets` owner-readable only
        (`chmod 600`).

        ```sh
        bundle exec hac credentials:show
        bundle exec hac credentials:edit
        ```

        Security headers, CSRF protection, host authorization, and auth route
        rate limits are wired in `config.ru`. HSTS is enabled only in
        production, assuming HTTPS terminates at your proxy. The default rate
        limiter keys on `request.ip`, so the proxy must overwrite untrusted
        forwarding headers rather than passing client-supplied
        `X-Forwarded-For` through unchanged. CSRF tokens are unmasked; avoid
        compressing pages that reflect secrets if BREACH-style attacks are in
        scope. CSP directives can use `:nonce`, and views can read the matching
        value with `csp_nonce context` for inline scripts or styles.

        Mail writes to `tmp/mail` in development. Configure SMTP with env vars
        or encrypted credentials in `config/mail.rb`.

        Background jobs are configured in `config/jobs.rb`. Development uses
        the async in-process adapter, tests run inline, and production persists
        jobs in the database. Run production work with:

        ```sh
        bundle exec hac jobs:work
        bundle exec hac jobs:work --queue critical,default --threads 4 --batch-size 20
        bundle exec hac jobs:health
        bundle exec hac jobs:benchmark --jobs 1000 --web-requests 250 --web-path /up --outbox-items 100 --threads 2 --batch-size 10
        bundle exec hac jobs:failed
        bundle exec hac jobs:scheduled
        bundle exec hac jobs:recurring
        bundle exec hac jobs:schedule
        ```

        For the generated single-host SQLite deployment, start with one worker
        process, two worker threads, a batch size between 5 and 10, and a poll
        interval between 0.25 and 1.0 seconds. Treat sustained `SQLITE_BUSY`
        errors, oldest pending age above your user-visible SLA, frequent manual
        WAL checkpoints, or benchmark p95 database latency above roughly
        100-250ms as signs to reduce worker concurrency or move jobs to an
        external database through Sequel. Repeated SQLite busy/locked errors
        are logged as throttled `sqlite_busy_contention` warnings with request,
        job, outbox, or table metadata.

        For local development with a web process, worker, and recurring
        scheduler, use `Procfile.dev` with a process runner such as Overmind,
        Foreman, or Hivemind. The production shape is the same: web serves
        requests, `hac jobs:work` performs queued jobs and outbox delivery, and
        `hac jobs:schedule` enqueues recurring tasks.

        The read-only jobs dashboard is mounted at `/hac/jobs`; its JSON health
        endpoint is `/hac/jobs/health`. Development access is local-only.
        Production access requires `HACIENDA_DASHBOARD_PASSWORD` and uses HTTP
        Basic auth. Development local-only checks use the direct `REMOTE_ADDR`
        socket address, not forwarding headers.

        Use `Hacienda.enqueue` for independent work. Enqueue work that depends
        on a database write through the transaction so rollback remains safe:

        ```ruby
        context.transaction do |transaction|
          # persist domain changes
          transaction.enqueue MyDomain::Jobs::Notify, record_id
        end
        ```

        The generated `hacienda_job_outbox` provides a crash-safe hand-off when
        a durable external adapter cannot share the Sequel transaction.

        Schedule work with `Hacienda.enqueue_in(seconds, Job, ...)` or
        `Hacienda.enqueue_at(time, Job, ...)`. Jobs may declare an integer
        `priority`; lower numbers run first, then scheduled time and insertion
        order.

        Workers atomically claim configurable batches. Ordered queue lists are
        served fairly, while `--all-queues` uses global priority ordering.
        Active worker identity, process, host, queues, heartbeat, concurrency,
        and current workload are stored in `hacienda_job_workers`; graceful
        shutdown drains the claimed batch without taking more work.

        Running jobs renew their leases, and dead-worker heartbeats allow early
        recovery after a crash or `SIGKILL`. Configure lease, heartbeat, default
        execution timeout, and worker expiry through `HACIENDA_JOB_LEASE_SECONDS`,
        `HACIENDA_JOB_HEARTBEAT_INTERVAL`, `HACIENDA_JOB_TIMEOUT`, and
        `HACIENDA_JOB_WORKER_TIMEOUT`.

        Timeouts and cancellation are cooperative: long loops call
        `Hacienda::Jobs.checkpoint!`, while external I/O keeps its own native
        timeout. Jobs can override the default with `def self.timeout = 30`.

        Recurring jobs are declared in `config/recurring.yml` with a narrow
        interval syntax such as `every: "5 minutes"` or `every: "1 hour"`.
        `hac jobs:schedule` enqueues due tasks and uses
        `hacienda_recurring_runs` to prevent duplicate runs across scheduler
        processes. Use `hac jobs:recurring` to inspect the schedule,
        `hac jobs:recurring run NAME` to trigger a task now, and
        `hac jobs:recurring enable NAME` / `disable NAME` to toggle a task.

        The worker handles `SIGTERM` and `SIGINT` by finishing its current item
        before exiting. Durable arguments use JSON hash semantics: top-level
        keyword keys are symbols when performed, while nested hash keys are
        strings.

        The application is configured with `database: DB`, so actions can use
        explicit transactions and emit events only after commit:

        ```ruby
        context.transaction do |transaction|
          # persist domain changes
          transaction.emit MyDomain::Events::Changed.new(record_id: 1)
        end
        ```

        Register event subscribers explicitly with `APP.events.configure` after
        creating `APP`. Production writes emitted events to a transactional
        database outbox; the same worker delivers them after commit. Delivery
        is at least once, so jobs and subscribers must be idempotent.

        Environment-specific config lives in `config/environments`. Logs are
        written to `log/<environment>.log` in development and stdout in
        production.

        ```ruby
        Hacienda.env.development?
        Hacienda.logger.info "Application event"
        ```

        See `DEPLOYMENT.md` for the generated Docker and Kamal production
        template.
      MARKDOWN
    end
  end
end
