# frozen_string_literal: true

module Hacienda
  class Route
    attr_reader :verb, :path, :action_name, :domain_name, :order, :guards

    def initialize(verb:, path:, action_name:, domain_name:, order:, guards: [])
      @verb = verb.to_s.upcase
      @path = normalize(path)
      @action_name = action_name.to_s
      @domain_name = domain_name
      @order = order
      @guards = Array(guards)
      @pattern, @keys = compile(@path)
    end

    def match(request_method, request_path)
      request_method = request_method.to_s.upcase
      return unless verb == request_method || (request_method == "HEAD" && verb == "GET")

      match = @pattern.match(normalize(request_path))
      return unless match

      @keys.to_h { |key| [key, Rack::Utils.unescape_path(match[key])] }
    end

    def specificity
      [path.split("/").count { |segment| !segment.empty? && !segment.start_with?(":") }, -order]
    end

    def action
      constantize(action_module_name)
    end

    def action_module_name
      "#{camelize(domain_name)}::#{camelize(action_name)}"
    end

    private

    def normalize(value)
      normalized = "/#{value}".gsub(%r{/+}, "/")
      normalized.length > 1 ? normalized.delete_suffix("/") : normalized
    end

    def compile(value)
      keys = []
      segments = value.split("/").reject(&:empty?).map do |segment|
        if segment.start_with?(":")
          key = segment.delete_prefix(":")
          keys << key
          "(?<#{key}>[^/]+)"
        else
          Regexp.escape(segment)
        end
      end

      pattern = segments.empty? ? %r{\A/\z} : Regexp.new("\\A/#{segments.join("/")}\\z")
      [pattern, keys]
    end

    def camelize(value)
      value.to_s.split("_").map(&:capitalize).join
    end

    def constantize(name)
      name.split("::").inject(Object) { |scope, constant| scope.const_get(constant) }
    end
  end
end
