# frozen_string_literal: true

require "uri"

module Hacienda
  module Middleware
    class HostAuthorization
      DEFAULT_RESPONSE = [403, {"content-type" => "text/plain; charset=utf-8"}, ["Forbidden host"]].freeze

      attr_reader :hosts

      def initialize(app, hosts:)
        @app = app
        @hosts = Array(hosts).flat_map { |host| host.to_s.split(",") }
          .map { |host| normalize_host(host) }
          .reject(&:empty?)
          .uniq
      end

      def call(env)
        return @app.call(env) if hosts.empty?

        request = Rack::Request.new(env)
        return @app.call(env) if allowed?(request.host)

        DEFAULT_RESPONSE
      end

      private

      def allowed?(host)
        normalized = normalize_host(host)
        hosts.include?(normalized)
      end

      def normalize_host(host)
        value = host.to_s.strip.downcase
        return "" if value.empty?

        uri_host = host_from_uri(value)
        return uri_host if uri_host

        if value.start_with?("[")
          closing = value.index("]")
          return closing ? value[1...closing] : value.delete_prefix("[")
        end

        return value if value.count(":") > 1

        value.split(":", 2).first
      end

      def host_from_uri(value)
        uri = URI(value)
        uri.host&.downcase
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
