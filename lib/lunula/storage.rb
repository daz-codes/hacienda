# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"
require "stringio"
require "tempfile"

module Lunula
  class Storage
    class Error < Lunula::Error; end
    class InvalidUpload < Error; end
    class TooLarge < InvalidUpload; end
    class UnsupportedType < InvalidUpload; end
    class InvalidContent < InvalidUpload; end
    class InvalidKey < Error; end
    class AlreadyExists < Error; end
    class Unavailable < Error; end
    class NotFound < Lunula::NotFound; end

    Blob = Data.define(:key, :filename, :content_type, :byte_size, :checksum, :url)

    class ContentTypeInspector
      SIGNATURES = {
        "image/png" => ->(bytes) { bytes.start_with?("\x89PNG\r\n\x1a\n".b) },
        "image/jpeg" => ->(bytes) { bytes.start_with?("\xff\xd8\xff".b) },
        "image/gif" => ->(bytes) { bytes.start_with?("GIF87a".b) || bytes.start_with?("GIF89a".b) },
        "image/webp" => ->(bytes) { bytes.start_with?("RIFF".b) && bytes.byteslice(8, 4) == "WEBP".b },
        "image/avif" => ->(bytes) { %w[avif avis].include?(bytes.byteslice(8, 4)) && bytes.byteslice(4, 4) == "ftyp".b },
        "application/pdf" => ->(bytes) { bytes.start_with?("%PDF-".b) },
        "application/zip" => ->(bytes) {
          ["PK\x03\x04".b, "PK\x05\x06".b, "PK\x07\x08".b].any? { |signature| bytes.start_with?(signature) }
        }
      }.freeze
      EXTENSIONS = {
        "image/png" => %w[.png],
        "image/jpeg" => %w[.jpg .jpeg .jpe],
        "image/gif" => %w[.gif],
        "image/webp" => %w[.webp],
        "image/avif" => %w[.avif],
        "application/pdf" => %w[.pdf],
        "application/zip" => %w[.zip]
      }.freeze

      def initialize(check_extension: true, allow_unrecognized: false)
        @check_extension = check_extension
        @allow_unrecognized = allow_unrecognized
      end

      def call(upload)
        signature = SIGNATURES[upload.content_type]
        return @allow_unrecognized unless signature
        return false if @check_extension && !EXTENSIONS.fetch(upload.content_type).include?(File.extname(upload.filename).downcase)

        signature.call(upload.read_prefix(32))
      end
    end

    class Upload
      attr_reader :io, :filename, :content_type, :byte_size

      def self.present?(value)
        return true if value.is_a?(self)
        return false if value.nil?

        filename = if value.is_a?(Hash)
          value[:filename] || value["filename"]
        elsif value.respond_to?(:original_filename)
          value.original_filename
        elsif value.respond_to?(:filename)
          value.filename
        end
        !filename.to_s.strip.empty?
      end

      def self.wrap(value)
        return value if value.is_a?(self)

        if value.is_a?(Hash)
          io = value[:tempfile] || value["tempfile"]
          filename = value[:filename] || value["filename"]
          content_type = value[:type] || value["type"] ||
            value[:content_type] || value["content_type"]
        elsif value
          io = value.tempfile if value.respond_to?(:tempfile)
          filename = value.original_filename if value.respond_to?(:original_filename)
          filename ||= value.filename if value.respond_to?(:filename)
          content_type = value.content_type if value.respond_to?(:content_type)
        end

        new(io:, filename:, content_type:)
      end

      def initialize(io:, filename:, content_type: nil)
        unless io.respond_to?(:read) && io.respond_to?(:rewind)
          raise InvalidUpload, "upload is missing file data"
        end

        @io = io
        @filename = sanitize_filename(filename)
        @content_type = normalize_content_type(content_type)
        @byte_size = measure
      end

      def validate!(max_bytes: nil, content_types: nil, content_inspector: nil)
        if max_bytes
          limit = Integer(max_bytes)
          raise ArgumentError, "max_bytes must be positive" unless limit.positive?
          raise TooLarge, "upload exceeds #{limit} bytes" if byte_size > limit
        end

        allowed = Array(content_types).compact.map { |type| normalize_content_type(type) }
        if !allowed.empty? && allowed.none? { |pattern| type_matches?(pattern) }
          raise UnsupportedType, "upload content type #{content_type.inspect} is not allowed"
        end

        inspect_content!(content_inspector) if content_inspector

        self
      end

      def read_prefix(max_bytes)
        limit = Integer(max_bytes)
        raise ArgumentError, "max_bytes must be positive" unless limit.positive?

        io.rewind
        io.read(limit).to_s.b
      ensure
        io.rewind
      end

      def checksum
        digest = Digest::SHA256.new
        io.rewind
        while (chunk = io.read(64 * 1024))
          digest << chunk
        end
        "sha256:#{digest.hexdigest}"
      ensure
        io.rewind
      end

      private

      def inspect_content!(inspector)
        unless inspector.respond_to?(:call)
          raise ArgumentError, "content_inspector must respond to call"
        end

        accepted = inspector.call(self)
        raise InvalidContent, "upload content does not match its declared type" unless accepted
      ensure
        io.rewind
      end

      def sanitize_filename(value)
        filename = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
        filename = File.basename(filename.tr("\\", "/")).delete("\0").strip
        filename = filename.gsub(/[[:cntrl:]]/, "")
        raise InvalidUpload, "upload filename is missing" if filename.empty? || [".", ".."].include?(filename)

        filename
      end

      def normalize_content_type(value)
        type = value.to_s.split(";", 2).first.to_s.strip.downcase
        type.empty? ? "application/octet-stream" : type
      end

      def measure
        io.rewind
        if io.respond_to?(:size)
          io.size
        else
          size = 0
          while (chunk = io.read(64 * 1024))
            size += chunk.bytesize
          end
          size
        end
      ensure
        io.rewind
      end

      def type_matches?(pattern)
        return content_type.start_with?(pattern.delete_suffix("*")) if pattern.end_with?("/*")

        content_type == pattern
      end
    end

    class DiskService
      attr_reader :root, :public_path

      def initialize(root:, public_path: "/uploads")
        @root = File.expand_path(root)
        @public_path = normalize_public_path(public_path)
        FileUtils.mkdir_p(@root)
      end

      def write(key, io, overwrite: false)
        destination = path_for(key)
        FileUtils.mkdir_p(File.dirname(destination))
        io.rewind
        Tempfile.create(["lunula-upload", ".tmp"], File.dirname(destination)) do |temporary|
          temporary.binmode
          IO.copy_stream(io, temporary)
          temporary.flush
          temporary.fsync
          temporary.close
          if overwrite
            File.rename(temporary.path, destination)
          else
            File.link(temporary.path, destination)
          end
        end
        destination
      rescue Errno::EEXIST
        raise AlreadyExists, "storage key already exists: #{key}"
      ensure
        io.rewind if io.respond_to?(:rewind)
      end

      def open(key)
        File.open(path_for(key), "rb")
      rescue Errno::ENOENT
        raise NotFound, "stored file not found"
      end

      def delete(key)
        File.delete(path_for(key))
        true
      rescue Errno::ENOENT
        false
      end

      def exist?(key)
        File.file?(path_for(key))
      end

      def url(key)
        escaped = Storage.validate_key!(key).split("/").map { |part| Rack::Utils.escape_path(part) }.join("/")
        "#{public_path}/#{escaped}"
      end

      def local?
        true
      end

      def path_for(key)
        valid_key = Storage.validate_key!(key)
        path = File.expand_path(valid_key, root)
        unless path.start_with?("#{root}#{File::SEPARATOR}")
          raise InvalidKey, "storage key escapes its root"
        end

        path
      end

      private

      def normalize_public_path(value)
        path = "/#{value}".gsub(%r{/+}, "/").delete_suffix("/")
        path.empty? ? "/uploads" : path
      end
    end

    class MemoryService
      attr_reader :public_path

      def initialize(public_path: "/uploads")
        @public_path = "/#{public_path}".gsub(%r{/+}, "/").delete_suffix("/")
        @files = {}
        @mutex = Mutex.new
      end

      def write(key, io, overwrite: false)
        key = Storage.validate_key!(key)
        io.rewind
        data = io.read.to_s.b
        @mutex.synchronize do
          raise AlreadyExists, "storage key already exists: #{key}" if !overwrite && @files.key?(key)

          @files[key] = data
        end
        key
      ensure
        io.rewind if io.respond_to?(:rewind)
      end

      def open(key)
        key = Storage.validate_key!(key)
        data = @mutex.synchronize { @files[key]&.dup }
        raise NotFound, "stored file not found" unless data

        StringIO.new(data)
      end

      def delete(key)
        key = Storage.validate_key!(key)
        @mutex.synchronize { !@files.delete(key).nil? }
      end

      def exist?(key)
        key = Storage.validate_key!(key)
        @mutex.synchronize { @files.key?(key) }
      end

      def url(key)
        escaped = Storage.validate_key!(key).split("/").map { |part| Rack::Utils.escape_path(part) }.join("/")
        "#{public_path}/#{escaped}"
      end

      def local?
        true
      end
    end

    class NullService
      def write(_key, _io, overwrite: false)
        raise Unavailable, "storage is not configured"
      end

      def open(_key)
        raise NotFound, "stored file not found"
      end

      def delete(_key)
        false
      end

      def exist?(_key)
        false
      end

      def url(_key)
        nil
      end

      def local?
        false
      end
    end

    attr_reader :service

    def initialize(service: NullService.new, clock: nil, key_generator: nil)
      @service = service
      @clock = clock || -> { Time.now }
      @key_generator = key_generator || -> { SecureRandom.uuid }
      %i[write open delete exist? url].each do |method|
        raise ArgumentError, "storage service must respond to #{method}" unless service.respond_to?(method)
      end
    end

    def store(value, key: nil, prefix: nil, max_bytes: nil, content_types: nil, content_inspector: nil, overwrite: false)
      upload = Upload.wrap(value).validate!(max_bytes:, content_types:, content_inspector:)
      key = key ? self.class.validate_key!(key) : generated_key(upload, prefix:)
      checksum = upload.checksum
      service.write(key, upload.io, overwrite:)
      Blob.new(
        key:,
        filename: upload.filename,
        content_type: upload.content_type,
        byte_size: upload.byte_size,
        checksum:,
        url: service.url(key)
      )
    end

    def open(key)
      io = service.open(self.class.validate_key!(key))
      return io unless block_given?

      begin
        yield io
      ensure
        io.close if io.respond_to?(:close)
      end
    end

    def read(key)
      open(key) { |io| io.read }
    end

    def delete(key)
      service.delete(self.class.validate_key!(key))
    end

    def exist?(key)
      service.exist?(self.class.validate_key!(key))
    end

    def url(key)
      service.url(self.class.validate_key!(key))
    end

    def local?
      service.respond_to?(:local?) && service.local?
    end

    def public_path
      service.public_path if service.respond_to?(:public_path)
    end

    def self.validate_key!(value)
      key = value.to_s
      parts = key.split("/", -1)
      invalid = key.empty? || key.start_with?("/") || key.include?("\\") || key.include?("\0") ||
        parts.any? { |part| part.empty? || part == "." || part == ".." }
      raise InvalidKey, "invalid storage key" if invalid

      key
    end

    private

    def generated_key(upload, prefix: nil)
      date = @clock.call.strftime("%Y/%m")
      extension = File.extname(upload.filename).downcase
      extension = "" unless extension.match?(/\A\.[a-z0-9]{1,10}\z/)
      parts = [prefix, date, "#{@key_generator.call}#{extension}"].compact
      self.class.validate_key!(parts.join("/"))
    end
  end
end
