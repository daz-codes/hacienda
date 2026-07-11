# frozen_string_literal: true

module Hacienda
  module Middleware
    class StorageFiles
      INLINE_TYPES = %w[
        image/avif
        image/gif
        image/jpeg
        image/png
        image/webp
      ].freeze

      class Body
        def initialize(io)
          @io = io
        end

        def each
          while (chunk = @io.read(64 * 1024))
            yield chunk
          end
        ensure
          close
        end

        def close
          @io.close unless @io.closed?
        end
      end

      def initialize(app, storage:, max_age: 3_600)
        @app = app
        @storage = storage
        @prefix = storage.public_path
        @max_age = Integer(max_age)
      end

      def call(env)
        request = Rack::Request.new(env)
        return @app.call(env) unless serves?(request)

        key = Rack::Utils.unescape_path(request.path_info.delete_prefix("#{@prefix}/"))
        return not_found unless @storage.exist?(key)

        io = @storage.open(key)
        headers = response_headers(key, io)
        if request.head?
          io.close
          [200, headers, []]
        else
          [200, headers, Body.new(io)]
        end
      rescue Storage::InvalidKey, Storage::NotFound, ArgumentError
        not_found
      end

      private

      def serves?(request)
        @storage.local? && @prefix &&
          %w[GET HEAD].include?(request.request_method) &&
          request.path_info.start_with?("#{@prefix}/")
      end

      def response_headers(key, io)
        content_type = Rack::Mime.mime_type(File.extname(key), "application/octet-stream")
        headers = {
          "content-type" => content_type,
          "content-length" => io.size.to_s,
          "cache-control" => "public, max-age=#{@max_age}",
          "x-content-type-options" => "nosniff",
          "content-security-policy" => "default-src 'none'; sandbox"
        }
        unless INLINE_TYPES.include?(content_type)
          filename = File.basename(key).gsub(/["\\\r\n]/, "_")
          headers["content-disposition"] = %(attachment; filename="#{filename}")
        end
        headers
      end

      def not_found
        [404, {"content-type" => "text/plain; charset=utf-8"}, ["Not Found"]]
      end
    end
  end
end
