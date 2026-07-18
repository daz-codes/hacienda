# frozen_string_literal: true

module Lunula
  module Middleware
    class RateLimiter
      Rule = Struct.new(:method, :path, :limit, :period, keyword_init: true)

      DEFAULT_MAX_KEYS = 10_000

      def initialize(app, rules:, store: nil, key: nil, max_keys: DEFAULT_MAX_KEYS)
        @app = app
        @rules = rules.map { |rule| build_rule(rule) }
        @store = store || {}
        @key = key || method(:default_key)
        @max_keys = max_keys
        @mutex = Mutex.new
      end

      def call(env)
        request = Rack::Request.new(env)
        rule = matching_rule(request)
        return @app.call(env) unless rule

        identity = @key.call(request)
        allowed, retry_after = allowed?(rule, identity)
        return too_many_requests(retry_after) unless allowed

        @app.call(env)
      end

      private

      def build_rule(rule)
        Rule.new(
          method: rule.fetch(:method, nil)&.to_s&.upcase,
          path: rule.fetch(:path),
          limit: rule.fetch(:limit),
          period: rule.fetch(:period)
        )
      end

      def matching_rule(request)
        @rules.find do |rule|
          method_matches?(rule, request) && path_matches?(rule, request)
        end
      end

      def method_matches?(rule, request)
        rule.method.nil? || rule.method == request.request_method
      end

      def path_matches?(rule, request)
        case rule.path
        when String
          rule.path == request.path_info
        when Regexp
          rule.path.match?(request.path_info)
        when Array
          rule.path.any? { |path| path_matches?(Rule.new(path:), request) }
        else
          false
        end
      end

      def allowed?(rule, identity)
        now = Time.now.to_f
        key = [rule.method, rule.path, identity]

        @mutex.synchronize do
          sweep_expired(now)
          bucket = @store[key]

          if bucket.nil? || bucket[:reset_at] <= now
            evict_oldest_key if bucket.nil? && over_key_limit?
            @store[key] = {count: 1, reset_at: now + rule.period}
            return [true, rule.period]
          end

          return [true, (bucket[:reset_at] - now).ceil] if (bucket[:count] += 1) <= rule.limit

          [false, (bucket[:reset_at] - now).ceil]
        end
      end

      def sweep_expired(now)
        @store.delete_if { |_key, bucket| bucket[:reset_at] <= now }
      end

      def over_key_limit?
        @max_keys && @store.respond_to?(:size) && @store.size >= @max_keys
      end

      def evict_oldest_key
        return unless @store.respond_to?(:min_by)

        oldest = @store.min_by { |_key, bucket| bucket[:reset_at] }
        @store.delete(oldest.first) if oldest
      end

      def default_key(request)
        request.ip
      end

      def too_many_requests(retry_after)
        [
          429,
          {
            "content-type" => "text/plain; charset=utf-8",
            "retry-after" => retry_after.to_s
          },
          ["Too many requests"]
        ]
      end
    end
  end
end
