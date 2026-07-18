# frozen_string_literal: true

module Lunula
  class Generator
    module NewApplicationTemplates
      private

      def gemfile
        lunula_dependency =
          if File.file?(File.join(@source_root, "lunula.gemspec"))
            %(gem "lunula", path: #{@source_root.inspect})
          else
            %(gem "lunula", "~> #{VERSION}")
          end

        <<~RUBY
          source "https://rubygems.org"

          #{lunula_dependency}
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

          ENV LUNULA_ENV="production" \
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
          RUN bundle exec luna assets:precompile

          FROM base

          RUN groupadd --system lunula && \
              useradd --system --gid lunula --create-home lunula

          COPY --from=build /usr/local/bundle /usr/local/bundle
          COPY --from=build --chown=lunula:lunula /app /app

          RUN mkdir -p db log tmp && chown -R lunula:lunula db log tmp

          USER lunula

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
          LUNULA_MASTER_KEY=$(cat config/master.key)
          LUNULA_SESSION_SECRET=$LUNULA_SESSION_SECRET
          # LUNULA_SESSION_SECRET_OLD=$LUNULA_SESSION_SECRET_OLD

          # Uncomment these if production mail uses environment variables.
          # LUNULA_DASHBOARD_PASSWORD=$LUNULA_DASHBOARD_PASSWORD
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
              cmd: bundle exec luna jobs:work
            scheduler:
              hosts:
                - 192.0.2.1
              cmd: bundle exec luna jobs:schedule

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
              LUNULA_ENV: production
              RACK_ENV: production
              DATABASE_URL: sqlite:///app/db/production.sqlite3
              LUNULA_APP_URL: https://app.example.com
            secret:
              - LUNULA_MASTER_KEY
              - LUNULA_SESSION_SECRET
              # - LUNULA_SESSION_SECRET_OLD
              # - LUNULA_DASHBOARD_PASSWORD
              # - SMTP_USERNAME
              # - SMTP_PASSWORD

          # This named volume makes the default SQLite database survive deployments.
          # Use this template on one server only; use an external database for multiple hosts.
          volumes:
            - "#{name}_db:/app/db"

          builder:
            arch: amd64

          aliases:
            console: app exec --primary -i --reuse "bundle exec luna console"
            migrate: app exec --primary --reuse "bundle exec luna db:migrate"
            seed: app exec --primary --reuse "bundle exec luna db:seed"
            logs: app logs
        YAML
      end

      def rakefile
        <<~RUBY
          # frozen_string_literal: true

          APP_ROOT = File.expand_path(__dir__) unless defined?(APP_ROOT)
          require "lunula"
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


          namespace :assets do
            desc "Compile fingerprinted production assets"
            task :precompile do
              manifest = Lunula::Assets.precompile(root: APP_ROOT)
              puts "Compiled \#{manifest.fetch("assets").length} assets."
            end

            desc "Remove fingerprinted production assets"
            task :clobber do
              count = Lunula::Assets.clobber(root: APP_ROOT)
              puts "Removed \#{count} compiled assets and the asset manifest."
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

          session_expire_after = Integer(ENV.fetch("LUNULA_SESSION_EXPIRE_AFTER", 60 * 60 * 24 * 30))
          raise "LUNULA_SESSION_EXPIRE_AFTER must be positive" unless session_expire_after.positive?
          session_store = ENV.fetch("LUNULA_SESSION_STORE", "cookie")

          use Lunula::Middleware::RequestLimits,
            max_body_bytes: Integer(ENV.fetch("LUNULA_MAX_REQUEST_BYTES", 10 * 1024 * 1024)),
            max_query_bytes: Integer(ENV.fetch("LUNULA_MAX_QUERY_BYTES", 64 * 1024)),
            max_multipart_files: Integer(ENV.fetch("LUNULA_MAX_MULTIPART_FILES", 16)),
            max_multipart_parts: Integer(ENV.fetch("LUNULA_MAX_MULTIPART_PARTS", 128)),
            max_parameters: Integer(ENV.fetch("LUNULA_MAX_PARAMETERS", 1024)),
            max_parameter_depth: Integer(ENV.fetch("LUNULA_MAX_PARAMETER_DEPTH", 16))
          allowed_hosts = ENV.fetch("LUNULA_ALLOWED_HOSTS", "").split(",").map(&:strip).reject(&:empty?)
          allowed_hosts = [Lunula.app_host] if allowed_hosts.empty? && Lunula.env.production?
          use Lunula::Middleware::HostAuthorization, hosts: allowed_hosts
          use Lunula::Middleware::SecurityHeaders,
            hsts: Lunula.env.production?,
            csp: {
              "default-src" => ["'self'"],
              "base-uri" => ["'self'"],
              "form-action" => ["'self'"],
              "frame-ancestors" => ["'self'"],
              "img-src" => ["'self'", "data:"],
              "script-src" => ["'self'", :nonce],
              "style-src" => ["'self'", :nonce]
            }
          use Lunula::Middleware::RateLimiter,
            rules: Lunula.env.test? ? [] : [
              {
                method: "POST",
                path: ["/login", "/signup", "/magic-login", "/magic-login/confirm", "/password/forgot", "/password"],
                limit: 10,
                period: 60
              }
            ]
          use Rack::Head
          use Lunula::Middleware::PendingMigrations,
            database: DB,
            directory: File.join(APP_ROOT, "db", "migrations")
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
          use Lunula::Middleware::CSRF
          use Rack::MethodOverride
          use Lunula::Middleware::StorageFiles, storage: APP.storage
          use Rack::Static, **Lunula::Assets.rack_options(root: APP_ROOT)
          use Lunula::Middleware::RequestLogger

          map "/luna/jobs" do
            run Lunula::Jobs::Dashboard.new(
              application: APP,
              recurring_path: File.join(APP_ROOT, "config", "recurring.yml")
            )
          end

          map "/luna/mail" do
            run Lunula::Mailer::Inbox.new(root: APP_ROOT)
          end

          map "/" do
            run APP
          end
        RUBY
      end

      def procfile_dev
        <<~TEXT
          web: bundle exec luna start
          worker: bundle exec luna jobs:work --queue default --threads 2 --batch-size 5
          scheduler: bundle exec luna jobs:schedule
        TEXT
      end

      def application_config
        <<~RUBY
          # frozen_string_literal: true

          require "lunula"

          APP_ROOT = File.expand_path("..", __dir__) unless defined?(APP_ROOT)
          Lunula.root = APP_ROOT
          require_relative "environment"
          require_relative "database"
          require_relative "cache"
          require_relative "storage"
          require_relative "jobs"
          require_relative "mail"

          event_delivery = ENV.fetch(
            "LUNULA_EVENT_OUTBOX",
            Lunula.env.production? ? "database" : "inline"
          )
          event_outbox = case event_delivery
          when "database" then Lunula::Events::Outbox.new(database: DB)
          when "inline" then nil
          else raise "unknown LUNULA_EVENT_OUTBOX; use database or inline"
          end

          APP = Lunula::Application.new(
            root: APP_ROOT,
            title: "#{application_title}",
            reload: Lunula.reload,
            database: DB,
            outbox: event_outbox,
            job_outbox: Lunula.job_outbox,
            cache: Lunula.cache,
            storage: Lunula.storage,
            navigation: true
          )
        RUBY
      end

      def environment_config
        <<~RUBY
          # frozen_string_literal: true

          Lunula.env = ENV["LUNULA_ENV"] || ENV["RACK_ENV"] || "development"

          environment_config = File.join(__dir__, "environments", "\#{Lunula.env}.rb")
          require environment_config if File.file?(environment_config)
        RUBY
      end

      def development_environment_config
        <<~RUBY
          # frozen_string_literal: true

          Lunula.reload = true
          Lunula.configure_logger(root: APP_ROOT, level: :debug)
        RUBY
      end

      def test_environment_config
        <<~RUBY
          # frozen_string_literal: true

          Lunula.configure_logger(output: File::NULL, level: :warn)
          Lunula.configure_mail(root: APP_ROOT, delivery: :test)
        RUBY
      end

      def production_environment_config
        <<~RUBY
          # frozen_string_literal: true

          Lunula.configure_logger(output: $stdout, level: :info)
        RUBY
      end

      def mail_config
        <<~RUBY
          # frozen_string_literal: true

          mail_delivery = ENV.fetch(
            "LUNULA_MAIL_DELIVERY",
            Lunula.env.test? ? "test" : Lunula.env.production? ? "smtp" : "file"
          )
          mail_credentials = File.file?(File.join(APP_ROOT, "config", "credentials.yml.enc")) ? Lunula.credentials : {}

          Lunula.configure_mail(
            root: APP_ROOT,
            delivery: mail_delivery.to_sym,
            from: ENV.fetch("LUNULA_MAIL_FROM", "hello@example.test"),
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
            "LUNULA_JOB_ADAPTER",
            Lunula.env.test? ? "inline" : Lunula.env.production? ? "database" : "async"
          )

          job_adapter = case job_adapter_name
          when "database"
            Lunula::Jobs::Adapters::Database.new(
              database: DB,
              lease_seconds: Float(ENV.fetch("LUNULA_JOB_LEASE_SECONDS", 300)),
              heartbeat_interval: ENV["LUNULA_JOB_HEARTBEAT_INTERVAL"]&.then { |value| Float(value) },
              execution_timeout: ENV["LUNULA_JOB_TIMEOUT"]&.then { |value| Float(value) },
              worker_timeout: ENV["LUNULA_JOB_WORKER_TIMEOUT"]&.then { |value| Float(value) },
              completed_retention: ENV.fetch("LUNULA_JOB_COMPLETED_RETENTION", 7 * 24 * 60 * 60),
              discarded_retention: ENV.fetch("LUNULA_JOB_DISCARDED_RETENTION", 30 * 24 * 60 * 60),
              failed_retention: ENV.fetch("LUNULA_JOB_FAILED_RETENTION", 30 * 24 * 60 * 60)
            )
          else
            job_adapter_name.to_sym
          end

          Lunula.configure_jobs(
            adapter: job_adapter,
            outbox: Lunula::Jobs::Outbox.new(database: DB)
          )
        RUBY
      end

      def durable_runtime_migration
        <<~RUBY
          # frozen_string_literal: true

          Sequel.migration do
            change do
              create_table(:lunula_jobs) do
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
                index [:queue, :failed_at, :priority, :available_at], name: :lunula_jobs_ready
                index :worker_id, name: :lunula_jobs_worker
                index :unique_key, name: :lunula_jobs_unique_key
                index :concurrency_key, name: :lunula_jobs_concurrency_key
                index :blocked_at, name: :lunula_jobs_blocked
              end

              create_table(:lunula_outbox) do
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
                index [:failed_at, :available_at], name: :lunula_outbox_ready
              end

              create_table(:lunula_job_outbox) do
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
                index [:failed_at, :priority, :available_at], name: :lunula_job_outbox_ready
              end

              create_table(:lunula_sessions) do
                String :id, primary_key: true
                String :data, text: true, null: false
                DateTime :expires_at
                DateTime :created_at, null: false
                DateTime :updated_at, null: false
                index :expires_at, name: :lunula_sessions_expires_at
              end

              create_table(:lunula_job_workers) do
                String :id, primary_key: true
                Integer :process_id, null: false
                String :hostname, null: false
                String :queues, text: true, null: false
                Integer :thread_count, null: false
                Integer :batch_size, null: false
                DateTime :started_at, null: false
                DateTime :last_heartbeat_at, null: false
                Integer :current_workload, null: false, default: 0
                index :last_heartbeat_at, name: :lunula_job_workers_heartbeat
              end

              create_table(:lunula_job_queues) do
                String :queue, primary_key: true
                DateTime :paused_at, null: false
                String :paused_by
                DateTime :created_at, null: false
                DateTime :updated_at, null: false
              end

              create_table(:lunula_recurring_runs) do
                primary_key :id
                String :task_name, null: false
                DateTime :scheduled_at, null: false
                TrueClass :manual, null: false, default: false
                Integer :enqueued_job_id
                DateTime :created_at, null: false
                unique [:task_name, :scheduled_at], name: :lunula_recurring_runs_unique
                index :created_at, name: :lunula_recurring_runs_created
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
            "LUNULA_CACHE_STORE",
            Lunula.env.production? ? "null" : "memory"
          )
          when "memory"
            Lunula::Cache::MemoryStore.new(
              max_size: Integer(ENV.fetch("LUNULA_CACHE_SIZE", 1_000))
            )
          when "null"
            Lunula::Cache::NullStore.new
          else
            raise "unknown LUNULA_CACHE_STORE; configure a store in config/cache.rb"
          end

          Lunula.configure_cache(
            store: cache_store,
            namespace: File.basename(APP_ROOT)
          )
        RUBY
      end

      def storage_config
        <<~RUBY
          # frozen_string_literal: true

          storage_service = case ENV.fetch(
            "LUNULA_STORAGE_SERVICE",
            Lunula.env.test? ? "memory" : Lunula.env.production? ? "null" : "disk"
          )
          when "disk"
            Lunula::Storage::DiskService.new(
              root: ENV.fetch("LUNULA_STORAGE_ROOT", File.join(APP_ROOT, "storage"))
            )
          when "memory"
            Lunula::Storage::MemoryService.new
          when "null"
            Lunula::Storage::NullService.new
          else
            raise "unknown LUNULA_STORAGE_SERVICE; configure a service in config/storage.rb"
          end

          Lunula.configure_storage(service: storage_service)
        RUBY
      end

      def database_config
        <<~RUBY
          # frozen_string_literal: true

          require "sequel"

          environment = Lunula.env.name
          default_url = "sqlite://\#{File.join(APP_ROOT, "db", "\#{environment}.sqlite3")}"

          DB = Sequel.connect(ENV.fetch("DATABASE_URL", default_url))
          if DB.database_type == :sqlite
            Lunula::SQLite.configure(DB, wal: environment != "test")
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

      def home_actions
        action_set_template("Home", <<~RUBY)
          def index(_context, _params)
            {framework: "Lunula", command: "luna"}
          end

          def up(_context, _params)
            text "OK"
          end
        RUBY
      end

      def test_helper
        <<~RUBY
          # frozen_string_literal: true

          ENV["LUNULA_ENV"] = "test"
          ENV["RACK_ENV"] = "test"

          require "minitest/autorun"
          require "rack"
          require "rack/test"
          require "securerandom"
          require "sequel"
          require "sequel/extensions/migration"
          require "tmpdir"
          require "fileutils"

          TEST_ROOT = File.expand_path("..", __dir__) unless defined?(TEST_ROOT)
          test_database_directory = unless ENV["DATABASE_URL"]
            Dir.mktmpdir("lunula-test").tap do |directory|
              ENV["DATABASE_URL"] = "sqlite://\#{File.join(directory, "test.sqlite3")}"
            end
          end
          TEST_APP = Rack::Builder.parse_file(File.join(TEST_ROOT, "config.ru")) unless defined?(TEST_APP)

          Minitest.after_run do
            APP.database&.disconnect
            FileUtils.rm_rf(test_database_directory) if test_database_directory
          end

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

      def home_actions_test
        <<~RUBY
          # frozen_string_literal: true

          require_relative "../../test_helper"

          class HomeActionsTest < ApplicationTest
            def test_home_page
              get "/"

              assert_equal 200, last_response.status
              assert_includes last_response.body, "Lunula is running."
            end

            def test_health_check
              get "/up"

              assert_equal 200, last_response.status
              assert_equal "OK", last_response.body
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
              <%= morpheus_navigation context %>
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
    end
  end
end
