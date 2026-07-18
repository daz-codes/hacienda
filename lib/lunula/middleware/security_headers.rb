# frozen_string_literal: true

require "securerandom"

module Lunula
  module Middleware
    class SecurityHeaders
      DEFAULT_HEADERS = {
        "x-frame-options" => "SAMEORIGIN",
        "x-content-type-options" => "nosniff",
        "referrer-policy" => "strict-origin-when-cross-origin",
        "permissions-policy" => "camera=(), geolocation=(), microphone=()"
      }.freeze

      DEFAULT_CSP = {
        "default-src" => ["'self'"],
        "base-uri" => ["'self'"],
        "form-action" => ["'self'"],
        "frame-ancestors" => ["'self'"],
        "img-src" => ["'self'", "data:"],
        "script-src" => ["'self'"],
        "style-src" => ["'self'", "'unsafe-inline'"]
      }.freeze
      DEFAULT_HSTS = "max-age=31536000; includeSubDomains"
      CSP_NONCE_ENV = "lunula.csp_nonce"

      def initialize(app, headers: {}, csp: DEFAULT_CSP, hsts: false)
        @app = app
        @headers = DEFAULT_HEADERS.merge(normalize_headers(headers))
        @csp = csp
        @hsts = hsts
      end

      def call(env)
        status, headers, body = @app.call(env)
        response_headers = headers.dup

        @headers.each { |name, value| response_headers[name] ||= value }
        response_headers["content-security-policy"] ||= build_csp(@csp, env) if @csp
        response_headers["strict-transport-security"] ||= build_hsts(@hsts) if @hsts

        [status, response_headers, body]
      end

      private

      def normalize_headers(headers)
        headers.transform_keys { |name| name.to_s.tr("_", "-").downcase }
      end

      def build_csp(csp, env)
        case csp
        when String
          replace_nonce_placeholders(csp, env)
        when Hash
          csp.filter_map do |directive, values|
            next if values.nil? || values == false

            tokens = Array(values).map { |value| csp_value(value, env) }
            [directive.to_s, *tokens].join(" ")
          end.join("; ")
        else
          csp.to_s
        end
      end

      def csp_value(value, env)
        return "'nonce-#{csp_nonce(env)}'" if value == :nonce

        replace_nonce_placeholders(value.to_s, env)
      end

      def csp_nonce(env)
        env[CSP_NONCE_ENV] ||= SecureRandom.base64(16)
      end

      def replace_nonce_placeholders(value, env)
        return value unless value.include?("%{nonce}")

        value.gsub("%{nonce}", csp_nonce(env))
      end

      def build_hsts(hsts)
        case hsts
        when true
          DEFAULT_HSTS
        when Hash
          max_age = Integer(hsts.fetch(:max_age, 31_536_000))
          tokens = ["max-age=#{max_age}"]
          tokens << "includeSubDomains" if hsts.fetch(:include_subdomains, true)
          tokens << "preload" if hsts[:preload]
          tokens.join("; ")
        else
          hsts.to_s
        end
      end
    end
  end
end
