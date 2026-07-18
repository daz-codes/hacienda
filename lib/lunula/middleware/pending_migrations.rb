# frozen_string_literal: true

require "erb"
require "thread"

module Lunula
  module Middleware
    class PendingMigrations
      DEFAULT_CHECK_INTERVAL = 1.0

      def initialize(
        app,
        database:,
        directory:,
        environment: Lunula.env,
        check_interval: DEFAULT_CHECK_INTERVAL,
        clock: nil
      )
        @app = app
        @database = database
        @directory = directory
        @environment = environment
        @check_interval = Float(check_interval)
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @mutex = Mutex.new
        @checked_at = nil
        @pending = []
        @logged_signature = nil
      end

      def call(env)
        pending = pending_migrations
        return @app.call(env) if pending.empty?

        log_pending(pending)
        response(env, pending)
      end

      private

      def pending_migrations
        now = @clock.call
        @mutex.synchronize do
          if @checked_at.nil? || now - @checked_at >= @check_interval
            @pending = Migrations.pending(database: @database, directory: @directory)
            @checked_at = now
            @logged_signature = nil if @pending.empty?
          end
          @pending.dup
        end
      end

      def response(env, pending)
        body = production? ? production_body : development_body(pending)
        body = "" if env["REQUEST_METHOD"] == "HEAD"
        [
          503,
          {
            "content-type" => "text/html; charset=utf-8",
            "cache-control" => "no-store",
            "retry-after" => "5",
            "content-length" => body.bytesize.to_s
          },
          [body]
        ]
      end

      def production?
        @environment.respond_to?(:production?) ? @environment.production? : @environment.to_s == "production"
      end

      def production_body
        <<~HTML
          <!doctype html>
          <html lang="en">
          <head><meta charset="utf-8"><title>Service unavailable</title></head>
          <body><h1>Service unavailable</h1><p>The application is not ready to serve requests.</p></body>
          </html>
        HTML
      end

      def development_body(pending)
        items = pending.map { |path| "<li><code>#{escape(File.basename(path))}</code></li>" }.join
        <<~HTML
          <!doctype html>
          <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Pending database migrations</title>
            <style>
              body { max-width: 52rem; margin: 4rem auto; padding: 0 1.25rem; color: #1d1d1b; font: 16px/1.55 system-ui, sans-serif; }
              h1 { font-size: 2rem; letter-spacing: 0; }
              code { padding: .15rem .35rem; background: #f1f1ed; }
              pre { overflow-x: auto; padding: 1rem; background: #1d1d1b; color: #fff; }
            </style>
          </head>
          <body>
            <h1>Database migrations need running</h1>
            <p>#{pending.length} #{pending.length == 1 ? "migration is" : "migrations are"} pending:</p>
            <ul>#{items}</ul>
            <p>Apply them, then reload this page:</p>
            <pre><code>bundle exec luna db:migrate</code></pre>
          </body>
          </html>
        HTML
      end

      def log_pending(pending)
        signature = pending.map { |path| File.basename(path) }.join(",")
        should_log = @mutex.synchronize do
          next false if @logged_signature == signature

          @logged_signature = signature
          true
        end
        return unless should_log

        Lunula.logger.error(
          "pending_migrations count=#{pending.length} migrations=#{signature.inspect}"
        )
      end

      def escape(value)
        ERB::Util.html_escape(value)
      end
    end
  end
end
