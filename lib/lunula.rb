# frozen_string_literal: true

require "rack"
require "uri"
require "zeitwerk"

module Lunula
  class Error < StandardError; end
  class NotFound < Error; end
  class BadRequest < Error; end
end

require_relative "lunula/version"
require_relative "lunula/environment"
require_relative "lunula/logger"
require_relative "lunula/response"
require_relative "lunula/actions"
require_relative "lunula/html"
require_relative "lunula/template"
require_relative "lunula/flash"
require_relative "lunula/validations"
require_relative "lunula/attributes"
require_relative "lunula/store"
require_relative "lunula/repository"
require_relative "lunula/cache"
require_relative "lunula/storage"
require_relative "lunula/navigation"
require_relative "lunula/sqlite"
require_relative "lunula/migrations"
require_relative "lunula/session_store"
require_relative "lunula/credentials"
require_relative "lunula/durable_queue"
require_relative "lunula/jobs/adapter"
require_relative "lunula/jobs"
require_relative "lunula/jobs/benchmark"
require_relative "lunula/jobs/dashboard"
require_relative "lunula/jobs/outbox"
require_relative "lunula/mailer"
require_relative "lunula/mailer/inbox"
require_relative "lunula/signed_token"
require_relative "lunula/events"
require_relative "lunula/transaction"
require_relative "lunula/context"
require_relative "lunula/params"
require_relative "lunula/route"
require_relative "lunula/routes"
require_relative "lunula/assets"
require_relative "lunula/renderer"
require_relative "lunula/errors"
require_relative "lunula/middleware/request_limits"
require_relative "lunula/middleware/pending_migrations"
require_relative "lunula/middleware/csrf"
require_relative "lunula/middleware/request_logger"
require_relative "lunula/middleware/host_authorization"
require_relative "lunula/middleware/security_headers"
require_relative "lunula/middleware/rate_limiter"
require_relative "lunula/middleware/storage_files"
require_relative "lunula/application"

module Lunula
  class << self
    attr_reader :root
    attr_accessor :filter_parameters, :reload

    def root=(value)
      @root = File.expand_path(value)
      @credentials = nil
      @signed_token = nil
      mail_config.root = @root if defined?(@mail_config) && @mail_config
    end

    def credentials(root: @root)
      raise Error, "Lunula.root is not configured" unless root

      if @credentials.nil? || @credentials.root != File.expand_path(root)
        @credentials = Credentials.new(root:)
      end

      @credentials
    end

    def signed_token
      @signed_token ||= SignedToken.new(secret: signed_token_secret, old_secrets: signed_token_old_secrets)
    end

    def signed_token_secret
      ENV["LUNULA_SECRET_KEY_BASE"] ||
        (@root && credentials.available? && credentials.dig(:lunula, :secret_key_base)) ||
        development_signed_token_secret
    end

    # Previous secrets stay valid for verification, so a rotated
    # LUNULA_SECRET_KEY_BASE doesn't invalidate outstanding tokens.
    # Comma-separated in the env var, an array in credentials.
    def signed_token_old_secrets
      from_env = ENV["LUNULA_SECRET_KEY_BASE_OLD"].to_s.split(",").map(&:strip)
      from_credentials = if @root && credentials.available?
        Array(credentials.dig(:lunula, :old_secret_key_bases))
      else
        []
      end

      (from_env + from_credentials).map(&:to_s).reject(&:empty?)
    end

    def development_signed_token_secret
      raise Error, "LUNULA_SECRET_KEY_BASE or credentials.lunula.secret_key_base is required in production" if env.production?

      "development-signed-token-secret-change-this-before-production"
    end

    def app_url(path = nil)
      base = canonical_app_url
      return base if path.nil? || path.to_s.empty?

      uri = URI(base)
      relative = path.to_s
      unless relative.start_with?("/")
        raise ArgumentError, "app_url path must start with /"
      end

      uri.path = relative.split("?", 2).first
      uri.query = relative.split("?", 2)[1]
      uri.fragment = nil
      uri.to_s
    end

    def canonical_app_url
      url = ENV["LUNULA_APP_URL"] ||
        ENV["APP_URL"] ||
        credentials_app_url ||
        development_app_url
      normalize_app_url(url)
    end

    def app_host
      URI(canonical_app_url).host
    end

    def env
      @env ||= Environment.new(ENV["LUNULA_ENV"] || ENV["RACK_ENV"] || "development")
    end

    def env=(value)
      @env = Environment.new(value)
      @logger = nil
      @signed_token = nil
    end

    def configure_logger(root: @root, level: nil, output: nil)
      @logger = Logging.build(
        root: root,
        env: env,
        level: level || (env.development? ? :debug : :info),
        output: output
      )
    end

    def logger
      @logger ||= Logging.build(root: @root, env: env, level: env.development? ? :debug : :info)
    end

    def configure_mail(root: @root, delivery: nil, from: nil, smtp: nil)
      mail_config.root = File.expand_path(root) if root
      mail_config.delivery = delivery if delivery
      mail_config.from = from if from
      mail_config.smtp = smtp if smtp

      yield mail_config if block_given?

      mail_config
    end

    def mail(...)
      Mailer.build(mail_config, ...)
    end

    def configure_jobs(adapter: nil, outbox: Jobs::Configuration::UNDEFINED)
      job_config.adapter = adapter if adapter
      job_config.outbox = outbox unless outbox.equal?(Jobs::Configuration::UNDEFINED)
      yield job_config if block_given?
      job_config
    end

    def configure_cache(store: Cache::MemoryStore.new, namespace: nil)
      @cache = Cache.new(store:, namespace:)
      yield @cache if block_given?
      @cache
    end

    def cache
      @cache ||= Cache.new
    end

    def configure_storage(service: Storage::NullService.new)
      @storage = Storage.new(service:)
      yield @storage if block_given?
      @storage
    end

    def storage
      @storage ||= Storage.new
    end

    def enqueue(job, *args, **kwargs)
      Jobs.enqueue(job_config.adapter, job, args:, kwargs:)
    end

    def enqueue_all(entries, &block)
      Jobs.enqueue_all(job_config.adapter, entries, &block)
    end

    def enqueue_at(time, job, *args, **kwargs)
      Jobs.enqueue(job_config.adapter, job, args:, kwargs:, scheduled_at: time)
    end

    def enqueue_in(duration, job, *args, **kwargs)
      seconds = Float(duration)
      raise Jobs::Error, "job delay must be finite and non-negative" unless seconds.finite? && seconds >= 0

      enqueue_at(Time.now.utc + seconds, job, *args, **kwargs)
    rescue ArgumentError, TypeError
      raise Jobs::Error, "job delay must be a number of seconds"
    end

    def cancel_job(id)
      adapter = job_config.adapter
      raise Jobs::Error, "job adapter #{adapter.inspect} does not support cancellation" unless adapter.respond_to?(:cancel)

      adapter.cancel(id)
    end

    def job_adapter
      job_config.adapter
    end

    def job_outbox
      job_config.outbox
    end

    def job_config
      @job_config ||= Jobs::Configuration.new
    end

    def enqueued_jobs
      Jobs::Adapters::Test.enqueued_jobs
    end

    def clear_enqueued_jobs
      Jobs::Adapters::Test.clear
    end

    def perform_enqueued_jobs
      Jobs::Adapters::Test.perform_enqueued_jobs
    end

    def shutdown_jobs
      job_config.adapter.shutdown if job_config.adapter.respond_to?(:shutdown)
    rescue Jobs::Error
      nil
    end

    def mail_config
      @mail_config ||= Mailer::Configuration.new(root: @root)
    end

    def mail_deliveries
      Mailer::TestDelivery.deliveries
    end

    def clear_mail_deliveries
      Mailer::TestDelivery.clear
    end

    private

    def credentials_app_url
      return unless @root && credentials.available?

      credentials.dig(:lunula, :app_url)
    end

    def development_app_url
      raise Error, "LUNULA_APP_URL, APP_URL, or credentials.lunula.app_url is required in production" if env.production?

      "http://localhost:5151"
    end

    def normalize_app_url(url)
      text = url.to_s.strip
      raise Error, "Lunula app URL is required" if text.empty?

      uri = URI(text)
      unless uri.is_a?(URI::HTTP) && uri.host
        raise Error, "Lunula app URL must be an absolute http:// or https:// URL"
      end

      uri.host = uri.host.downcase
      uri.path = uri.path.to_s.delete_suffix("/")
      uri.query = nil
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      raise Error, "Lunula app URL must be an absolute http:// or https:// URL"
    end
  end

  self.filter_parameters = Logging::DEFAULT_FILTERS.dup
  self.reload = false
end
