# frozen_string_literal: true

module Lunula
  class Route
    ACTION_GROUP_PATTERN = /\A[a-z][a-z0-9_]*\z/

    attr_reader :verb, :path, :action_name, :domain_name, :action_group, :order, :guards,
      :source_file, :source_line

    def initialize(
      verb:,
      path:,
      action_name:,
      domain_name:,
      action_group: nil,
      order:,
      guards: [],
      source_file: nil,
      source_line: nil
    )
      @verb = verb.to_s.upcase
      @path = normalize(path)
      @action_name = action_name.to_s
      @domain_name = domain_name.to_s
      @action_group = action_group&.to_s
      if @action_group && !ACTION_GROUP_PATTERN.match?(@action_group)
        raise ArgumentError, "action group must use lowercase letters, numbers, and underscores: #{@action_group.inspect}"
      end
      @order = order
      @guards = Array(guards)
      @source_file = source_file && File.expand_path(source_file)
      @source_line = source_line && Integer(source_line)
      @segments = segments_for(@path).freeze
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
      [static_segment_count, -order]
    end

    def static_segment_count
      @segments.count { |segment| !dynamic_segment?(segment) }
    end

    def structural_path
      return "/" if @segments.empty?

      "/#{@segments.map { |segment| dynamic_segment?(segment) ? ":*" : segment }.join("/")}"
    end

    def overlap_path(other)
      return unless @segments.length == other.segments.length

      overlap = @segments.zip(other.segments).map do |left, right|
        if dynamic_segment?(left) && dynamic_segment?(right)
          "value"
        elsif dynamic_segment?(left)
          right
        elsif dynamic_segment?(right) || left == right
          left
        else
          return
        end
      end

      overlap.empty? ? "/" : "/#{overlap.join("/")}"
    end

    def action_set_name
      set = action_group ? "#{camelize(action_group)}Actions" : "Actions"
      "#{camelize(domain_name)}::#{set}"
    end

    def action_handler_name
      "#{action_set_name}##{action_name}"
    end

    def source_location
      return "(unknown source)" unless source_file

      source_line ? "#{source_file}:#{source_line}" : source_file
    end

    protected

    attr_reader :segments

    private

    def normalize(value)
      normalized = "/#{value}".gsub(%r{/+}, "/")
      normalized.length > 1 ? normalized.delete_suffix("/") : normalized
    end

    def compile(value)
      keys = []
      segments = segments_for(value).map do |segment|
        if dynamic_segment?(segment)
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

    def segments_for(value)
      value.split("/").reject(&:empty?)
    end

    def dynamic_segment?(segment)
      segment.start_with?(":")
    end

    def camelize(value)
      value.to_s.split("_").map(&:capitalize).join
    end

  end
end
