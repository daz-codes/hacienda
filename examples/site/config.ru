# frozen_string_literal: true

require_relative "config/application"
require "rack/head"

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
use Rack::Head
use Rack::Static, urls: ["/assets"], root: File.join(APP_ROOT, "public")
use Hacienda::Middleware::RequestLogger
run APP
