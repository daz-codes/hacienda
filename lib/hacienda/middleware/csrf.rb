# frozen_string_literal: true

require "securerandom"

module Hacienda
  module Middleware
    class CSRF
      SAFE_METHODS = %w[GET HEAD OPTIONS TRACE].freeze

      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)

        # Only touch the session on unsafe requests; writing a token on GETs
        # would give every anonymous visitor a session cookie and defeat
        # shared caching of public pages. Context#csrf_token generates the
        # token lazily when a form actually renders one.
        return @app.call(env) if SAFE_METHODS.include?(request.request_method)

        token = request.session[:csrf_token] ||= SecureRandom.hex(32)
        submitted = request.get_header("HTTP_X_CSRF_TOKEN") || request.params["_csrf"]
        return forbidden unless valid?(token, submitted)

        @app.call(env)
      end

      private

      def valid?(expected, submitted)
        submitted.is_a?(String) &&
          expected.bytesize == submitted.bytesize &&
          Rack::Utils.secure_compare(expected, submitted)
      end

      def forbidden
        [403, {"content-type" => "text/plain; charset=utf-8"}, ["Invalid CSRF token"]]
      end
    end
  end
end
