# frozen_string_literal: true

require "fileutils"
require "logger"

module Hacienda
  module Logging
    DEFAULT_FILTERS = %w[
      _csrf
      password
      password_confirmation
      token
      secret
      key
      authorization
    ].freeze

    module_function

    def build(root: nil, env: Hacienda.env, level: :info, output: nil)
      io =
        if output
          output
        elsif root
          FileUtils.mkdir_p(File.join(root, "log"))
          File.open(File.join(root, "log", "#{env}.log"), "a")
        else
          $stderr
        end

      ::Logger.new(io).tap do |logger|
        logger.level = level_for(level)
        logger.progname = "hacienda"
      end
    end

    def level_for(value)
      return value if value.is_a?(Integer)

      ::Logger.const_get(value.to_s.upcase)
    rescue NameError
      ::Logger::INFO
    end

    def filter(value, filters: Hacienda.filter_parameters)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested), result|
          result[key] = filtered_key?(key, filters) ? "[FILTERED]" : filter(nested, filters:)
        end
      when Array
        value.map { |nested| filter(nested, filters:) }
      else
        value
      end
    end

    def filtered_key?(key, filters)
      normalized = key.to_s.downcase
      filters.any? { |filter| normalized.include?(filter.to_s.downcase) }
    end
  end
end
