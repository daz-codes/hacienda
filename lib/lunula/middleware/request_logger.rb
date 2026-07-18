# frozen_string_literal: true

module Lunula
  module Middleware
    class RequestLogger
      def initialize(app)
        @app = app
      end

      def call(env)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        status, headers, body = @app.call(env)
        duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
        request = Rack::Request.new(env)

        Lunula.logger.info(
          "method=#{request.request_method} path=#{request.path_info} status=#{status} duration=#{duration}ms params=#{filtered_params(request).inspect}"
        )

        [status, headers, body]
      rescue StandardError => error
        duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
        request = Rack::Request.new(env)
        Lunula.logger.error(
          "method=#{request.request_method} path=#{request.path_info} error=#{error.class} duration=#{duration}ms params=#{filtered_params(request).inspect}"
        )
        raise
      end

      private

      def filtered_params(request)
        Lunula::Logging.filter(Lunula::Params.request_data(request))
      rescue StandardError
        {}
      end
    end
  end
end
