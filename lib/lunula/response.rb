# frozen_string_literal: true

require "uri"

module Lunula
  class UnsafeRedirect < Error; end

  class View
    attr_reader :name, :locals, :status, :layout

    def initialize(name, locals: {}, status: 200, layout: nil)
      @name = name.to_s
      @locals = locals
      @status = status
      @layout = layout
    end
  end

  class Response
    attr_reader :status, :headers, :body

    def initialize(body = "", status: 200, headers: {})
      @status = status
      @headers = {"content-type" => "text/html; charset=utf-8"}.merge(headers)
      @body = body
    end

    def finish
      [status, headers, body.respond_to?(:each) ? body : [body.to_s]]
    end
  end

  module Responses
    def render(view, locals = {}, status: 200, layout: nil, **keyword_locals)
      View.new(
        view,
        locals: locals.merge(keyword_locals),
        status: status,
        layout: layout
      )
    end

    def redirect(location, status: 303, allow_other_host: false)
      Response.new(
        "",
        status: status,
        headers: {"location" => safe_redirect_location(location, allow_other_host:)}
      )
    end

    def json(value, status: 200, headers: {})
      require "json"
      Response.new(
        JSON.generate(value),
        status: status,
        headers: {"content-type" => "application/json; charset=utf-8"}.merge(headers)
      )
    end

    def text(value, status: 200, headers: {})
      Response.new(
        value.to_s,
        status: status,
        headers: {"content-type" => "text/plain; charset=utf-8"}.merge(headers)
      )
    end

    def response(body = "", status: 200, headers: {})
      Response.new(body, status: status, headers: headers)
    end

    private

    def safe_redirect_location(location, allow_other_host:)
      value = location.to_s.delete("\r\n")
      uri = URI.parse(value)
      return value if allow_other_host || relative_redirect?(uri) || same_origin_redirect?(uri)

      raise UnsafeRedirect, "redirect to another host is not allowed: #{uri.host}"
    rescue URI::InvalidURIError
      raise UnsafeRedirect, "invalid redirect location"
    end

    def relative_redirect?(uri)
      uri.host.nil? && uri.scheme.nil? && !uri.to_s.start_with?("//")
    end

    def same_origin_redirect?(uri)
      app_uri = URI(Lunula.canonical_app_url)
      uri.scheme.to_s.downcase == app_uri.scheme.to_s.downcase &&
        uri.host.to_s.downcase == app_uri.host.to_s.downcase &&
        uri.port == app_uri.port
    end
  end
end
