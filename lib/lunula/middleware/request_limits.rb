# frozen_string_literal: true

require "stringio"

module Lunula
  class PayloadTooLarge < Error; end
  class RequestLimitExceeded < BadRequest; end

  module Middleware
    class RequestLimits
      LIMITS_ENV = "lunula.request_limits"

      DEFAULT_MAX_BODY_BYTES = 10 * 1024 * 1024
      DEFAULT_MAX_QUERY_BYTES = 64 * 1024
      DEFAULT_MAX_MULTIPART_FILES = 16
      DEFAULT_MAX_MULTIPART_PARTS = 128
      DEFAULT_MAX_PARAMETERS = 1024
      DEFAULT_MAX_PARAMETER_DEPTH = 16

      Limits = Data.define(
        :max_body_bytes,
        :max_query_bytes,
        :max_multipart_files,
        :max_multipart_parts,
        :max_parameters,
        :max_parameter_depth
      )

      class LimitedInput
        def initialize(input, limit)
          @input = input
          @limit = limit
          @position = 0
        end

        def read(length = nil, outbuf = nil)
          return replace_outbuf(outbuf, "") if length == 0

          allowance = @limit - @position + 1
          data = @input.read(length ? [length, allowance].min : allowance)
          checked(data, outbuf)
        end

        def gets(separator = $/, limit = nil)
          if separator.is_a?(Integer)
            limit = separator
            separator = $/
          end

          allowance = @limit - @position + 1
          data = @input.gets(separator, [limit || allowance, allowance].min)
          checked(data)
        end

        def each
          return enum_for(:each) unless block_given?

          while (line = gets)
            yield line
          end
        end

        def rewind
          @input.rewind
          @position = 0
          0
        end

        def close
          @input.close if @input.respond_to?(:close)
        end

        def closed?
          @input.respond_to?(:closed?) && @input.closed?
        end

        private

        def checked(data, outbuf = nil)
          return replace_outbuf(outbuf, data) unless data

          @position += data.bytesize
          raise PayloadTooLarge, "request body is too large" if @position > @limit

          replace_outbuf(outbuf, data)
        end

        def replace_outbuf(outbuf, data)
          return data unless outbuf
          return if data.nil?

          outbuf.replace(data)
        end
      end

      class << self
        def validate_parameters!(value, limits)
          count = 0
          pending = [[value, 0]]

          until pending.empty?
            current, depth = pending.pop
            if current.is_a?(Hash) || current.is_a?(Array)
              raise RequestLimitExceeded, "parameters are nested too deeply" if depth > limits.max_parameter_depth

              children = current.is_a?(Hash) ? current.values : current
              count += current.length
              raise RequestLimitExceeded, "too many parameters" if count > limits.max_parameters
              children.each { |child| pending << [child, depth + 1] }
            end
          end

          value
        end
      end

      def initialize(
        app,
        max_body_bytes: DEFAULT_MAX_BODY_BYTES,
        max_query_bytes: DEFAULT_MAX_QUERY_BYTES,
        max_multipart_files: DEFAULT_MAX_MULTIPART_FILES,
        max_multipart_parts: DEFAULT_MAX_MULTIPART_PARTS,
        max_parameters: DEFAULT_MAX_PARAMETERS,
        max_parameter_depth: DEFAULT_MAX_PARAMETER_DEPTH
      )
        @app = app
        @limits = Limits.new(
          max_body_bytes: positive_integer(max_body_bytes, :max_body_bytes),
          max_query_bytes: positive_integer(max_query_bytes, :max_query_bytes),
          max_multipart_files: positive_integer(max_multipart_files, :max_multipart_files),
          max_multipart_parts: positive_integer(max_multipart_parts, :max_multipart_parts),
          max_parameters: positive_integer(max_parameters, :max_parameters),
          max_parameter_depth: positive_integer(max_parameter_depth, :max_parameter_depth)
        )
        configure_rack!
      end

      def call(env)
        validate_declared_sizes!(env)
        env[LIMITS_ENV] = @limits
        env["rack.input"] = LimitedInput.new(env["rack.input"] || StringIO.new, @limits.max_body_bytes)
        @app.call(env)
      rescue PayloadTooLarge
        error_response(413, "Request body is too large")
      rescue Rack::QueryParser::QueryLimitError
        error_response(400, "Request parameters exceed configured limits")
      rescue Rack::Multipart::MultipartPartLimitError, Rack::Multipart::MultipartTotalPartLimitError
        error_response(413, "Multipart request has too many parts")
      rescue RequestLimitExceeded
        error_response(400, "Request parameters exceed configured limits")
      rescue BadRequest
        error_response(400, "Malformed request parameters")
      rescue StandardError => error
        raise unless error.class.ancestors.include?(Rack::BadRequest)

        error_response(400, "Malformed request parameters")
      end

      private

      def positive_integer(value, name)
        integer = Integer(value)
        raise ArgumentError, "#{name} must be positive" unless integer.positive?

        integer
      end

      def configure_rack!
        # Rack exposes multipart and structured parameter limits process-wide.
        # A Rack process should therefore host applications with the same limits.
        Rack::Utils.default_query_parser = Rack::QueryParser.make_default(
          @limits.max_parameter_depth,
          bytesize_limit: @limits.max_body_bytes,
          params_limit: @limits.max_parameters
        )
        # Rack raises when its counter reaches the configured threshold, so add
        # one to make Lunula's values the number of parts that are accepted.
        Rack::Utils.multipart_file_limit = @limits.max_multipart_files + 1
        Rack::Utils.multipart_total_part_limit = @limits.max_multipart_parts + 1
      end

      def validate_declared_sizes!(env)
        query = env.fetch("QUERY_STRING", "")
        raise RequestLimitExceeded, "query string is too large" if query.bytesize > @limits.max_query_bytes

        content_length = env["CONTENT_LENGTH"]
        return if content_length.nil? || content_length.empty?

        length = Integer(content_length, 10)
        raise BadRequest, "invalid content length" if length.negative?
        raise PayloadTooLarge, "request body is too large" if length > @limits.max_body_bytes
      rescue ArgumentError
        raise BadRequest, "invalid content length"
      end

      def error_response(status, message)
        [
          status,
          {
            "content-type" => "text/plain; charset=utf-8",
            "content-length" => message.bytesize.to_s
          },
          [message]
        ]
      end
    end
  end
end
