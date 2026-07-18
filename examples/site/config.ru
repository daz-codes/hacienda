# frozen_string_literal: true

require_relative "config/application"
require "rack/head"

use Hacienda::Middleware::RequestLimits,
  max_body_bytes: Integer(ENV.fetch("HACIENDA_MAX_REQUEST_BYTES", 10 * 1024 * 1024)),
  max_query_bytes: Integer(ENV.fetch("HACIENDA_MAX_QUERY_BYTES", 64 * 1024)),
  max_multipart_files: Integer(ENV.fetch("HACIENDA_MAX_MULTIPART_FILES", 16)),
  max_multipart_parts: Integer(ENV.fetch("HACIENDA_MAX_MULTIPART_PARTS", 128)),
  max_parameters: Integer(ENV.fetch("HACIENDA_MAX_PARAMETERS", 1024)),
  max_parameter_depth: Integer(ENV.fetch("HACIENDA_MAX_PARAMETER_DEPTH", 16))
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
use Rack::Static, **Hacienda::Assets.rack_options(root: APP_ROOT)
use Hacienda::Middleware::RequestLogger
run APP
