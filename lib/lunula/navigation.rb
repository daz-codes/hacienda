# frozen_string_literal: true

module Lunula
  class Navigation
    DEFAULTS = {
      enabled: true,
      prefetch: :intent,
      cache_size: 20,
      cache_ttl: 15,
      page_attributes: {}
    }.freeze

    attr_reader :prefetch, :cache_size, :cache_ttl, :page_attributes

    def initialize(configuration = true)
      options = normalize(configuration)
      @enabled = options.fetch(:enabled)
      @prefetch = options.fetch(:prefetch).to_sym if options.fetch(:prefetch)
      @cache_size = Integer(options.fetch(:cache_size))
      @cache_ttl = Float(options.fetch(:cache_ttl))
      @page_attributes = options.fetch(:page_attributes).transform_keys(&:to_sym).freeze

      unless [nil, :intent].include?(@prefetch)
        raise ArgumentError, "navigation prefetch must be :intent or false"
      end
      raise ArgumentError, "navigation cache_size must be positive" unless @cache_size.positive?
      raise ArgumentError, "navigation cache_ttl must be positive" unless @cache_ttl.positive?
    end

    def enabled?
      @enabled
    end

    private

    def normalize(configuration)
      case configuration
      when true, nil
        DEFAULTS
      when false
        DEFAULTS.merge(enabled: false)
      when Hash
        DEFAULTS.merge(configuration.transform_keys(&:to_sym))
      else
        raise ArgumentError, "navigation must be true, false, or a Hash"
      end
    end
  end
end
