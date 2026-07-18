# frozen_string_literal: true

require "digest"
require "time"

module Lunula
  class Cache
    class MemoryStore
      Entry = Struct.new(:value, :expires_at, :accessed_at)

      attr_reader :max_size

      def initialize(max_size: 1_000, clock: nil)
        @max_size = Integer(max_size)
        raise ArgumentError, "cache max_size must be positive" unless @max_size.positive?

        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @entries = {}
        @sequence = 0
        @mutex = Mutex.new
      end

      def read(key)
        @mutex.synchronize do
          entry = @entries[key]
          return unless entry

          if expired?(entry, now)
            @entries.delete(key)
            return
          end

          entry.accessed_at = next_sequence
          entry.value
        end
      end

      def write(key, value, expires_in: nil)
        ttl = normalize_expiry(expires_in)
        @mutex.synchronize do
          current_time = now
          sweep_expired(current_time)
          @entries[key] = Entry.new(
            value,
            ttl && current_time + ttl,
            next_sequence
          )
          trim_to_max_size
        end
        value
      end

      def delete(key)
        @mutex.synchronize { !@entries.delete(key).nil? }
      end

      def clear
        @mutex.synchronize { @entries.clear }
        self
      end

      def size
        @mutex.synchronize do
          sweep_expired(now)
          @entries.size
        end
      end

      private

      def now
        @clock.call.to_f
      end

      def next_sequence
        @sequence += 1
      end

      def normalize_expiry(expires_in)
        return if expires_in.nil?

        value = Float(expires_in)
        raise ArgumentError, "cache expires_in must be positive" unless value.positive?

        value
      end

      def expired?(entry, current_time)
        entry.expires_at && entry.expires_at <= current_time
      end

      def sweep_expired(current_time)
        @entries.delete_if { |_key, entry| expired?(entry, current_time) }
      end

      def trim_to_max_size
        while @entries.size > max_size
          least_recent_key, = @entries.min_by { |_key, entry| entry.accessed_at }
          @entries.delete(least_recent_key)
        end
      end
    end

    class NullStore
      def read(_key)
        nil
      end

      def write(_key, value, expires_in: nil)
        value
      end

      def delete(_key)
        false
      end

      def clear
        self
      end
    end

    module HTTP
      module_function

      def headers(etag: nil, last_modified: nil, public: nil, max_age: nil)
        headers = {}
        headers["etag"] = etag_header(etag) unless etag.nil?
        headers["last-modified"] = time_for(last_modified).httpdate unless last_modified.nil?

        directives = []
        directives << (public ? "public" : "private") unless public.nil?
        unless max_age.nil?
          seconds = Integer(max_age)
          raise ArgumentError, "cache max_age must not be negative" if seconds.negative?

          directives << "max-age=#{seconds}"
        end
        headers["cache-control"] = directives.join(", ") unless directives.empty?
        headers
      end

      def fresh?(request, etag: nil, last_modified: nil)
        return false unless %w[GET HEAD].include?(request.request_method)

        if etag && (submitted = request.get_header("HTTP_IF_NONE_MATCH"))
          return etag_matches?(submitted, etag)
        end

        if last_modified && (submitted = request.get_header("HTTP_IF_MODIFIED_SINCE"))
          return Time.httpdate(submitted).to_i >= time_for(last_modified).to_i
        end

        false
      rescue ArgumentError
        false
      end

      def etag_header(value)
        %("#{Digest::SHA256.hexdigest(expand_etag(value))}")
      end

      def expand_etag(value)
        Array(value).flatten.map do |part|
          part.respond_to?(:cache_key) ? part.cache_key : part.to_s
        end.join("\0")
      end
      private_class_method :expand_etag

      def etag_matches?(submitted, current)
        expected = current.to_s.delete_prefix("W/")
        submitted.split(",").map(&:strip).any? do |candidate|
          candidate == "*" || candidate.delete_prefix("W/") == expected
        end
      end
      private_class_method :etag_matches?

      def time_for(value)
        return value.utc if value.is_a?(Time)
        return value.to_time.utc if value.respond_to?(:to_time)
        return Time.httpdate(value).utc if value.is_a?(String)

        Time.at(Float(value)).utc
      end
      private_class_method :time_for
    end

    attr_reader :store, :namespace

    def initialize(store: MemoryStore.new, namespace: nil)
      @store = store
      @namespace = namespace.to_s unless namespace.nil? || namespace.to_s.empty?
      %i[read write delete].each do |method|
        raise ArgumentError, "cache store must respond to #{method}" unless store.respond_to?(method)
      end
    end

    def read(key)
      store.read(expand_key(key))
    end

    def write(key, value, expires_in: nil)
      store.write(expand_key(key), value, expires_in: normalize_expiry(expires_in))
    end

    def fetch(key, expires_in: nil)
      expires_in = normalize_expiry(expires_in)
      value = read(key)
      return value unless value.nil?

      value = yield
      write(key, value, expires_in:) unless value.nil?
      value
    end

    def delete(key)
      store.delete(expand_key(key))
    end

    def clear
      raise Error, "cache store does not support clear" unless store.respond_to?(:clear)

      store.clear
      self
    end

    def expand_key(key)
      parts = Array(key).flatten.map do |part|
        part.respond_to?(:cache_key) ? part.cache_key : part.to_s
      end
      parts.unshift(namespace) if namespace
      raise ArgumentError, "cache key must not be empty" if parts.empty? || parts.all?(&:empty?)

      parts.join("/")
    end

    private

    def normalize_expiry(expires_in)
      return if expires_in.nil?

      value = Float(expires_in)
      raise ArgumentError, "cache expires_in must be positive" unless value.positive?

      value
    end
  end
end
