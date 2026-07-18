# frozen_string_literal: true

require_relative "config/application"
require "rack/head"
require "rack/session"

session_expire_after = Integer(ENV.fetch("HACIENDA_SESSION_EXPIRE_AFTER", 60 * 60 * 24 * 30))
raise "HACIENDA_SESSION_EXPIRE_AFTER must be positive" unless session_expire_after.positive?
session_store = ENV.fetch("HACIENDA_SESSION_STORE", "cookie")

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
use Hacienda::Middleware::RateLimiter,
  rules: []
use Rack::Head
use Hacienda::Middleware::PendingMigrations,
  database: DB,
  directory: File.join(APP_ROOT, "db", "migrations")
case session_store
when "cookie"
  session_secret = ENV["HACIENDA_SESSION_SECRET"] || ENV["SESSION_SECRET"]
  if session_secret.to_s.empty?
    raise "HACIENDA_SESSION_SECRET is required in production" if Hacienda.env.production?

    session_secret = "development-session-secret-change-this-before-production-000000000000"
  end
  session_old_secrets = ENV.fetch("HACIENDA_SESSION_SECRET_OLD", ENV.fetch("SESSION_SECRET_OLD", ""))
    .split(",")
    .map(&:strip)
    .reject(&:empty?)
  use Rack::Session::Cookie,
    key: "hacienda.session",
    secrets: [session_secret, *session_old_secrets],
    expire_after: session_expire_after,
    same_site: :lax,
    secure: Hacienda.env.production?,
    httponly: true
when "database", "db"
  use Hacienda::SessionStore,
    database: DB,
    table: :hacienda_sessions,
    key: "hacienda.session",
    expire_after: session_expire_after,
    same_site: :lax,
    secure: Hacienda.env.production?,
    httponly: true
else
  raise "HACIENDA_SESSION_STORE must be cookie or database"
end
use Hacienda::Middleware::CSRF
use Rack::MethodOverride
use Hacienda::Middleware::StorageFiles, storage: APP.storage
use Rack::Static, **Hacienda::Assets.rack_options(root: APP_ROOT)
use Hacienda::Middleware::RequestLogger

map "/hac/mail" do
  run Hacienda::Mailer::Inbox.new(root: APP_ROOT)
end

map "/" do
  run APP
end
