# frozen_string_literal: true

require "securerandom"

module Hacienda
  class Context
    CSP_NONCE_ENV = "hacienda.csp_nonce"

    attr_reader :request, :assigns, :application, :response_headers
    attr_accessor :current_user

    def initialize(env, application: nil)
      @request = Rack::Request.new(env)
      @application = application
      @assigns = {}
      @response_headers = {}
    end

    def assign(name, value)
      assigns[name.to_sym] = value
      self
    end

    def [](name)
      assigns[name.to_sym]
    end

    def fetch(name, ...)
      assigns.fetch(name.to_sym, ...)
    end

    def session
      request.session
    end

    def reset_session!
      request.session_options[:renew] = true if request.respond_to?(:session_options)
      session.clear
      @flash = nil
      self
    end

    def flash
      @flash ||= Flash.new(session, consume: !prefetch?)
    end

    def csrf_token
      session[:csrf_token] ||= SecureRandom.hex(32)
    end

    def csp_nonce
      env[CSP_NONCE_ENV] ||= SecureRandom.base64(16)
    end

    def cookies
      request.cookies
    end

    def headers
      request.env.each_with_object({}) do |(name, value), result|
        next unless name.start_with?("HTTP_")

        header = name.delete_prefix("HTTP_").split("_").map(&:capitalize).join("-")
        result[header] = value
      end
    end

    def method
      request.request_method
    end

    def path
      request.path_info
    end

    def env
      request.env
    end

    def navigation_request?
      request.get_header("HTTP_X_HACIENDA_NAVIGATION") == "true"
    end

    def prefetch?
      request.get_header("HTTP_X_HACIENDA_PREFETCH") == "true"
    end

    def navigation_reload!
      @navigation_reload = true
      self
    end

    def navigation_reload?
      !!@navigation_reload
    end

    def transaction(**options, &block)
      raise Error, "application transaction support is unavailable" unless application

      application.transaction(**options, &block)
    end

    def cache
      application&.cache || Hacienda.cache
    end

    def storage
      application&.storage || Hacienda.storage
    end

    def stale?(etag: nil, last_modified: nil, public: nil, max_age: nil)
      headers = Cache::HTTP.headers(etag:, last_modified:, public:, max_age:)
      response_headers.merge!(headers)
      !Cache::HTTP.fresh?(
        request,
        etag: headers["etag"],
        last_modified: headers["last-modified"]
      )
    end
  end
end
