# frozen_string_literal: true

require_relative "config/application"
require "rack/head"

use Lunula::Middleware::RequestLimits,
  max_body_bytes: Integer(ENV.fetch("LUNULA_MAX_REQUEST_BYTES", 10 * 1024 * 1024)),
  max_query_bytes: Integer(ENV.fetch("LUNULA_MAX_QUERY_BYTES", 64 * 1024)),
  max_multipart_files: Integer(ENV.fetch("LUNULA_MAX_MULTIPART_FILES", 16)),
  max_multipart_parts: Integer(ENV.fetch("LUNULA_MAX_MULTIPART_PARTS", 128)),
  max_parameters: Integer(ENV.fetch("LUNULA_MAX_PARAMETERS", 1024)),
  max_parameter_depth: Integer(ENV.fetch("LUNULA_MAX_PARAMETER_DEPTH", 16))
allowed_hosts = ENV.fetch("LUNULA_ALLOWED_HOSTS", "").split(",").map(&:strip).reject(&:empty?)
allowed_hosts = [Lunula.app_host] if allowed_hosts.empty? && Lunula.env.production?
use Lunula::Middleware::HostAuthorization, hosts: allowed_hosts
use Lunula::Middleware::SecurityHeaders,
  hsts: Lunula.env.production?,
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
use Rack::Static, **Lunula::Assets.rack_options(root: APP_ROOT)
use Lunula::Middleware::RequestLogger
run APP
