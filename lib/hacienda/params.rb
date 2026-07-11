# frozen_string_literal: true

require "json"

module Hacienda
  class Params
    REQUEST_DATA_KEY = "hacienda.request_data"

    include Enumerable

    class << self
      def from_request(request, route_params = {})
        new(request_data(request), route_params)
      end

      def request_data(request)
        env = request.env
        return env[REQUEST_DATA_KEY] if env.key?(REQUEST_DATA_KEY)

        env[REQUEST_DATA_KEY] = if json_request?(request)
          request.GET.merge(parse_json_body(request))
        else
          request.params
        end
      end

      private

      def json_request?(request)
        media_type = request.media_type.to_s.downcase
        media_type == "application/json" || media_type.end_with?("+json")
      end

      def parse_json_body(request)
        input = request.body
        source = input.read
        return {} if source.strip.empty?

        value = JSON.parse(source)
        unless value.is_a?(Hash)
          raise BadRequest, "JSON request body must be an object"
        end

        value
      rescue JSON::ParserError, EncodingError
        raise BadRequest, "malformed JSON request body"
      ensure
        input&.rewind if input&.respond_to?(:rewind)
      end
    end

    def initialize(request_params, route_params = {})
      @values = normalize(request_params).merge(normalize(route_params))
    end

    def [](key)
      @values[key.to_sym]
    end

    def dig(*keys)
      @values.dig(*keys.map { |key| normalize_key(key) })
    end

    def fetch(key, ...)
      @values.fetch(key.to_sym, ...)
    end

    def key?(key)
      @values.key?(key.to_sym)
    end

    def each(&)
      @values.each(&)
    end

    def require(key)
      value = self[key]
      raise BadRequest, "param is missing or empty: #{key}" if required_blank?(value)

      value.is_a?(Hash) ? self.class.new(value) : value
    end

    def slice(*keys)
      keys.each_with_object({}) do |key, result|
        normalized_key = key.to_sym
        result[normalized_key] = deep_dup(@values[normalized_key]) if @values.key?(normalized_key)
      end
    end

    def permit(*filters)
      permit_hash(@values, filters)
    end

    def to_h
      deep_dup(@values)
    end
    alias to_hash to_h

    private

    def normalize(value)
      case value
      when Params
        value.to_h
      when Hash
        value.each_with_object({}) do |(key, nested_value), result|
          result[normalize_key(key)] = normalize(nested_value)
        end
      when Array
        value.map { |nested_value| normalize(nested_value) }
      else
        value
      end
    end

    def normalize_key(key)
      key.is_a?(String) || key.is_a?(Symbol) ? key.to_sym : key
    end

    def permit_hash(source, filters)
      filters.each_with_object({}) do |filter, result|
        case filter
        when Hash
          filter.each do |key, nested_filters|
            normalized_key = key.to_sym
            next unless source.key?(normalized_key)

            permitted = permit_nested(source[normalized_key], Array(nested_filters))
            result[normalized_key] = permitted unless permitted.nil?
          end
        else
          normalized_key = filter.to_sym
          next unless source.key?(normalized_key)

          value = source[normalized_key]
          result[normalized_key] = deep_dup(value) if permitted_scalar?(value)
        end
      end
    end

    def permit_nested(value, filters)
      if filters.empty?
        return value.select { |item| permitted_scalar?(item) } if value.is_a?(Array)

        return deep_dup(value) if permitted_scalar?(value)
        return
      end

      case value
      when Hash
        permit_hash(value, filters)
      when Array
        value.filter_map do |item|
          permit_hash(item, filters) if item.is_a?(Hash)
        end
      end
    end

    def permitted_scalar?(value)
      value.nil? ||
        value.is_a?(String) ||
        value.is_a?(Symbol) ||
        value.is_a?(Numeric) ||
        value == true ||
        value == false
    end

    def required_blank?(value)
      value.nil? ||
        (value.respond_to?(:empty?) && value.empty?)
    end

    def deep_dup(value)
      case value
      when Hash
        value.transform_values { |nested_value| deep_dup(nested_value) }
      when Array
        value.map { |nested_value| deep_dup(nested_value) }
      else
        value
      end
    end
  end
end
