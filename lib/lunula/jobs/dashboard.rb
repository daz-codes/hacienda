# frozen_string_literal: true

require "erb"
require "json"
require "rack/auth/basic"

module Lunula
  module Jobs
    class Dashboard
      DEFAULT_LIMIT = 10

      attr_reader :application, :adapter, :recurring_path, :authorized

      def initialize(application:, adapter: nil, recurring_path: nil, authorized: nil)
        @application = application
        @adapter = adapter || Lunula.job_adapter
        @recurring_path = recurring_path || File.join(application.root, "config", "recurring.yml")
        @authorized = authorized
      end

      def call(env)
        request = Rack::Request.new(env)
        return unauthorized unless authorized?(request)

        case [request.request_method, request.path_info]
        when ["GET", ""], ["GET", "/"]
          html_response(render)
        when ["GET", "/health"]
          json_response(health_payload)
        else
          [404, {"content-type" => "text/plain; charset=utf-8"}, ["Not Found"]]
        end
      rescue Jobs::Error, Durable::Error => error
        html_response(page("Queue unavailable", tag("p", h(error.message))), status: 503)
      end

      private

      def authorized?(request)
        return authorized.call(request) if authorized

        if dashboard_password?
          return basic_auth_authorized?(request)
        end

        Lunula.env.test? || (!Lunula.env.production? && local_request?(request))
      end

      def unauthorized
        if dashboard_password?
          [
            401,
            {
              "content-type" => "text/plain; charset=utf-8",
              "www-authenticate" => %(Basic realm="Lunula Jobs")
            },
            ["Authentication required"]
          ]
        else
          [403, {"content-type" => "text/plain; charset=utf-8"}, ["Forbidden"]]
        end
      end

      def dashboard_password?
        !ENV["LUNULA_DASHBOARD_PASSWORD"].to_s.empty?
      end

      def basic_auth_authorized?(request)
        auth = Rack::Auth::Basic::Request.new(request.env)
        return false unless auth.provided? && auth.basic? && auth.credentials

        username, password = auth.credentials
        secure_compare(username, ENV.fetch("LUNULA_DASHBOARD_USERNAME", "lunula")) &&
          secure_compare(password, ENV.fetch("LUNULA_DASHBOARD_PASSWORD"))
      end

      def secure_compare(left, right)
        left = left.to_s
        right = right.to_s
        return false unless left.bytesize == right.bytesize

        Rack::Utils.secure_compare(left, right)
      end

      def local_request?(request)
        ["127.0.0.1", "::1"].include?(request.env["REMOTE_ADDR"].to_s)
      end

      def render
        status = adapter_status
        page(
          "Lunula Jobs",
          [
            tag("section", metrics(status.fetch(:metrics), status.fetch(:health))),
            tag("section", workers),
            tag("section", recurring),
            tag("section", job_table("Pending", rows(:pending))),
            tag("section", job_table("Running", rows(:running))),
            tag("section", job_table("Failed", rows(:failed))),
            tag("section", job_table("Paused queues", paused_queue_rows, columns: ["Queue", "Paused at", "Paused by"]))
          ].join
        )
      end

      def adapter_status
        status = adapter.respond_to?(:status) ? adapter.status : {}
        health = adapter.respond_to?(:health) ? adapter.health : fallback_health(status)
        {metrics: status, health:}
      end

      def fallback_health(status)
        failed = status.fetch(:failed, 0).to_i
        {
          status: failed.positive? ? "warn" : "ok",
          generated_at: Time.now.utc,
          checks: {
            failed_jobs: failed,
            stale_workers: 0,
            oldest_pending_age: status[:oldest_pending_age],
            paused_queues: status.fetch(:paused_queues, 0)
          }
        }
      end

      def health_payload
        health = adapter.respond_to?(:health) ? adapter.health : adapter_status.fetch(:health)
        {
          status: health.fetch(:status),
          generated_at: health.fetch(:generated_at).to_s,
          checks: health.fetch(:checks),
          metrics: adapter.respond_to?(:status) ? adapter.status : {}
        }
      end

      def metrics(status, health)
        items = [
          ["Health", health.fetch(:status).to_s.upcase],
          ["Pending", status.fetch(:pending, "-")],
          ["Scheduled", status.fetch(:scheduled, "-")],
          ["Running", status.fetch(:running, "-")],
          ["Blocked", status.fetch(:blocked, "-")],
          ["Failed", status.fetch(:failed, "-")],
          ["Workers", status.fetch(:workers, "-")],
          ["Oldest pending", format_duration(status[:oldest_pending_age])]
        ]
        tag("h2", "Overview") + tag("dl", items.map { |name, value| tag("dt", name) + tag("dd", value) }.join)
      end

      def workers
        rows = if adapter.respond_to?(:workers)
          adapter.workers.map do |row|
            [
              row[:id],
              row[:hostname],
              row[:process_id],
              parse_queues(row[:queues]),
              row[:thread_count],
              row[:batch_size],
              row[:current_workload],
              row[:last_heartbeat_at]
            ]
          end
        else
          []
        end
        table("Workers", ["ID", "Host", "PID", "Queues", "Threads", "Batch", "Workload", "Heartbeat"], rows)
      end

      def recurring
        unless recurring_path && File.file?(recurring_path)
          return tag("h2", "Recurring tasks") + tag("p", "No config/recurring.yml found.")
        end

        schedule = RecurringSchedule.load(recurring_path)
        rows = schedule.entries.map do |entry|
          [entry.name, entry.job_class, "#{entry.interval}s", entry.queue || "default", entry.priority || 0, entry.enabled ? "yes" : "no"]
        end
        table("Recurring tasks", ["Task", "Job", "Every", "Queue", "Priority", "Enabled"], rows)
      rescue Jobs::Error => error
        tag("h2", "Recurring tasks") + tag("p", h(error.message))
      end

      def rows(state)
        return [] unless adapter.respond_to?(state)

        if %i[blocked completed discarded].include?(state)
          adapter.public_send(state, limit: DEFAULT_LIMIT)
        else
          adapter.public_send(state).first(DEFAULT_LIMIT)
        end
      end

      def paused_queue_rows
        return [] unless adapter.respond_to?(:paused_queues)

        adapter.paused_queues.map { |row| [row[:queue], row[:paused_at], row[:paused_by]] }
      end

      def job_table(title, rows, columns: ["ID", "Queue", "Priority", "Attempts", "Available at", "Job", "Detail"])
        values = rows.map do |row|
          [
            row[:id],
            row[:queue],
            row[:priority],
            "#{row[:attempts]}/#{row[:max_attempts]}",
            row[:available_at],
            row[:job_class],
            row[:last_error] || row[:blocked_reason] || "-"
          ]
        end
        table(title, columns, values)
      end

      def table(title, columns, rows)
        body = if rows.empty?
          tag("p", "No #{title.downcase}.")
        else
          header = tag("tr", columns.map { |column| tag("th", column) }.join)
          table_rows = rows.map do |row|
            tag("tr", row.map { |value| tag("td", truncate(value)) }.join)
          end.join
          "<table>#{tag("thead", header)}#{tag("tbody", table_rows)}</table>"
        end
        tag("h2", title) + body
      end

      def page(title, body)
        <<~HTML
          <!doctype html>
          <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>#{h(title)}</title>
            <style>
              body { margin: 0; font-family: system-ui, sans-serif; color: #161616; background: #f4f1e8; }
              header { background: #111; color: #ffd400; padding: 1rem 1.25rem; border-bottom: .5rem solid #ffd400; }
              main { max-width: 1100px; margin: 0 auto; padding: 1.25rem; }
              section { background: #fff; border: 2px solid #111; margin-bottom: 1rem; padding: 1rem; box-shadow: 4px 4px 0 #111; overflow-x: auto; }
              h1, h2 { margin: 0 0 .75rem; text-transform: uppercase; letter-spacing: .03em; }
              dl { display: grid; grid-template-columns: repeat(auto-fit, minmax(9rem, 1fr)); gap: .75rem; margin: 0; }
              dt { font-size: .75rem; text-transform: uppercase; color: #555; }
              dd { margin: .15rem 0 0; font-size: 1.35rem; font-weight: 800; }
              table { width: 100%; border-collapse: collapse; font-size: .9rem; }
              th, td { border-bottom: 1px solid #ddd; padding: .5rem; text-align: left; vertical-align: top; }
              th { background: #ffd400; color: #111; text-transform: uppercase; font-size: .75rem; }
              code { white-space: pre-wrap; }
            </style>
          </head>
          <body>
            <header><h1>#{h(title)}</h1></header>
            <main>#{body}</main>
          </body>
          </html>
        HTML
      end

      def tag(name, content)
        "<#{name}>#{content}</#{name}>"
      end

      def h(value)
        ERB::Util.html_escape(value)
      end

      def html_response(body, status: 200)
        [status, {"content-type" => "text/html; charset=utf-8", "cache-control" => "no-store"}, [body]]
      end

      def json_response(value, status: 200)
        status = 503 if value.is_a?(Hash) && value[:status] == "critical"
        [status, {"content-type" => "application/json; charset=utf-8", "cache-control" => "no-store"}, [JSON.generate(value)]]
      end

      def format_duration(seconds)
        seconds.nil? ? "-" : "#{seconds.to_i}s"
      end

      def parse_queues(value)
        JSON.parse(value.to_s).join(", ")
      rescue JSON::ParserError
        value.to_s
      end

      def truncate(value)
        text = value.to_s
        h(text.length > 180 ? "#{text[0, 177]}..." : text)
      end
    end
  end
end
