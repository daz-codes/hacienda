# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"

module Hacienda
  module Assets
    class Error < Hacienda::Error; end

    MANIFEST_FILENAME = ".manifest.json"
    DIGEST_LENGTH = 16
    FINGERPRINT_PATTERN = /-[0-9a-f]{#{DIGEST_LENGTH}}(?=\.[^\/]+\z|\z)/
    IMMUTABLE_CACHE_CONTROL = "public, max-age=31536000, immutable"
    SOURCE_CACHE_CONTROL = "no-cache"

    module_function

    def precompile(root: Hacienda.root)
      Compiler.new(root: required_root(root)).compile
    end

    def clobber(root: Hacienda.root)
      root = required_root(root)
      assets_root = File.join(root, "public", "assets")
      manifest = read_manifest(assets_root, required: false)
      manifest_outputs = manifest ? manifest.fetch("assets", {}).values : []
      discovered_outputs = Dir.glob(File.join(assets_root, "**", "*"))
        .select { |path| File.file?(path) }
        .map { |path| Pathname.new(path).relative_path_from(Pathname.new(assets_root)).to_s }
        .select { |path| FINGERPRINT_PATTERN.match?(path) }
      outputs = (manifest_outputs + discovered_outputs).uniq

      outputs.each do |logical_path|
        path = asset_file(assets_root, logical_path)
        FileUtils.rm_f(path)
        remove_empty_parent_directories(path, stop_at: assets_root)
      end
      FileUtils.rm_f(File.join(assets_root, MANIFEST_FILENAME))
      outputs.length
    end

    def path(source, root: Hacienda.root, environment: Hacienda.env)
      logical_path, suffix = split_source(source)
      return "/assets/#{logical_path}#{suffix}" unless production?(environment)

      assets_root = File.join(required_root(root), "public", "assets")
      manifest = read_manifest(assets_root, required: true)
      compiled_path = manifest.fetch("assets", {}).fetch(logical_path) do
        raise Error,
          "asset #{logical_path.inspect} is not in #{File.join(assets_root, MANIFEST_FILENAME)}; " \
          "run `bundle exec hac assets:precompile`"
      end
      validate_logical_path!(compiled_path)
      "/assets/#{compiled_path}#{suffix}"
    end

    def rack_options(root: Hacienda.root)
      assets_root = File.join(required_root(root), "public")
      {
        urls: ["/assets"],
        root: assets_root,
        header_rules: [
          ["/assets", {"cache-control" => SOURCE_CACHE_CONTROL}],
          [FINGERPRINT_PATTERN, {"cache-control" => IMMUTABLE_CACHE_CONTROL}]
        ]
      }
    end

    def manifest(root: Hacienda.root, required: true)
      read_manifest(File.join(required_root(root), "public", "assets"), required:)
    end

    def required_root(root)
      raise Error, "Hacienda.root is not configured" if root.to_s.empty?

      File.expand_path(root)
    end
    private_class_method :required_root

    def production?(environment)
      environment.respond_to?(:production?) ? environment.production? : environment.to_s == "production"
    end
    private_class_method :production?

    def split_source(source)
      value = source.to_s
      path, suffix = value.match(/\A([^?#]*)(.*)\z/).captures
      path = path.delete_prefix("/assets/").delete_prefix("/")
      validate_logical_path!(path)
      [path, suffix]
    end
    private_class_method :split_source

    def validate_logical_path!(path)
      value = path.to_s
      pathname = Pathname.new(value)
      invalid = value.empty? || value.include?("\\") || value.include?("\0") ||
        pathname.absolute? || pathname.cleanpath.to_s != value || value == "." || value.start_with?("../")
      raise Error, "invalid asset path: #{path.inspect}" if invalid

      value
    end
    private_class_method :validate_logical_path!

    def read_manifest(assets_root, required:)
      path = File.join(assets_root, MANIFEST_FILENAME)
      unless File.file?(path)
        return nil unless required

        raise Error, "asset manifest not found at #{path}; run `bundle exec hac assets:precompile`"
      end

      manifest = JSON.parse(File.read(path))
      unless manifest.is_a?(Hash) && manifest["schema"] == 1 && manifest["assets"].is_a?(Hash)
        raise Error, "invalid asset manifest at #{path}"
      end

      manifest
    rescue JSON::ParserError => error
      raise Error, "invalid asset manifest at #{path}: #{error.message}"
    end
    private_class_method :read_manifest

    def asset_file(assets_root, logical_path)
      validate_logical_path!(logical_path)
      path = File.expand_path(logical_path, assets_root)
      prefix = "#{File.expand_path(assets_root)}#{File::SEPARATOR}"
      raise Error, "invalid asset path: #{logical_path.inspect}" unless path.start_with?(prefix)

      path
    end
    private_class_method :asset_file

    def remove_empty_parent_directories(path, stop_at:)
      directory = File.dirname(path)
      stop_at = File.expand_path(stop_at)
      while directory.start_with?("#{stop_at}#{File::SEPARATOR}") && Dir.empty?(directory)
        Dir.rmdir(directory)
        directory = File.dirname(directory)
      end
    end
    private_class_method :remove_empty_parent_directories

    class Compiler
      TEXT_EXTENSIONS = %w[.css .js .mjs].freeze
      QUOTED_RELATIVE_REFERENCE = /(?<quote>["'])(?<path>\.\.?\/[^"'?#]+)(?<suffix>[?#][^"']*)?\k<quote>/
      CSS_URL_REFERENCE = /url\(\s*(?<quote>["']?)(?<path>[^)"'?#]+)(?<suffix>[?#][^)"']*)?\k<quote>\s*\)/

      def initialize(root:)
        @root = root
        @assets_root = File.join(root, "public", "assets")
        @compiled = {}
        @compiling = []
      end

      def compile
        FileUtils.mkdir_p(@assets_root)
        Assets.clobber(root: @root)
        @sources = source_paths.to_h { |logical_path| [logical_path, Assets.send(:asset_file, @assets_root, logical_path)] }
        @sources.each_key { |logical_path| compile_asset(logical_path) }

        manifest = {"schema" => 1, "assets" => @compiled.sort.to_h}
        write(File.join(@assets_root, MANIFEST_FILENAME), JSON.pretty_generate(manifest) + "\n")
        manifest
      rescue SystemCallError => error
        raise Error, "asset compilation failed: #{error.message}"
      end

      private

      def source_paths
        Dir.glob(File.join(@assets_root, "**", "*"), File::FNM_DOTMATCH)
          .select { |path| File.file?(path) }
          .map { |path| Pathname.new(path).relative_path_from(Pathname.new(@assets_root)).to_s }
          .reject { |path| path == MANIFEST_FILENAME || path.split("/").any? { |part| part.start_with?(".") } }
          .reject { |path| FINGERPRINT_PATTERN.match?(path) }
          .sort
      end

      def compile_asset(logical_path)
        return @compiled.fetch(logical_path) if @compiled.key?(logical_path)
        if @compiling.include?(logical_path)
          cycle = [*@compiling.drop_while { |path| path != logical_path }, logical_path]
          raise Error, "cyclic asset dependency: #{cycle.join(" -> ")}"
        end

        @compiling << logical_path
        source_path = @sources.fetch(logical_path)
        content = File.binread(source_path)
        content = rewrite_references(content, logical_path) if TEXT_EXTENSIONS.include?(File.extname(logical_path).downcase)
        digest = Digest::SHA256.hexdigest(content).slice(0, DIGEST_LENGTH)
        compiled_path = fingerprinted_path(logical_path, digest)
        destination = Assets.send(:asset_file, @assets_root, compiled_path)
        write(destination, content, mode: File.stat(source_path).mode & 0o777)
        @compiled[logical_path] = compiled_path
      ensure
        @compiling.pop if @compiling.last == logical_path
      end

      def rewrite_references(content, logical_path)
        extension = File.extname(logical_path).downcase
        rewritten = content.dup.force_encoding(Encoding::UTF_8)
        unless rewritten.valid_encoding?
          raise Error, "asset #{logical_path.inspect} is not valid UTF-8"
        end

        if extension == ".css"
          rewritten = rewritten.gsub(CSS_URL_REFERENCE) do
            quote = Regexp.last_match(:quote)
            path = Regexp.last_match(:path).strip
            suffix = Regexp.last_match(:suffix).to_s
            replacement = rewrite_reference(logical_path, path)
            replacement ? "url(#{quote}#{replacement}#{suffix}#{quote})" : Regexp.last_match(0)
          end
          rewrite_quoted_references(rewritten, logical_path)
        else
          rewrite_quoted_references(rewritten, logical_path)
        end
      end

      def rewrite_quoted_references(content, logical_path)
        content.gsub(QUOTED_RELATIVE_REFERENCE) do
          quote = Regexp.last_match(:quote)
          path = Regexp.last_match(:path)
          suffix = Regexp.last_match(:suffix).to_s
          replacement = rewrite_reference(logical_path, path)
          replacement ? "#{quote}#{replacement}#{suffix}#{quote}" : Regexp.last_match(0)
        end
      end

      def rewrite_reference(from_logical_path, reference)
        return if reference.start_with?("/", "data:", "http:", "https:", "#")

        source_directory = File.dirname(from_logical_path)
        dependency = Pathname.new(File.join(source_directory, reference)).cleanpath.to_s
        return unless @sources.key?(dependency)

        compiled_dependency = compile_asset(dependency)
        from_directory = Pathname.new(source_directory)
        relative = Pathname.new(compiled_dependency).relative_path_from(from_directory).to_s
        relative.start_with?(".") ? relative : "./#{relative}"
      end

      def fingerprinted_path(logical_path, digest)
        extension = File.extname(logical_path)
        base = extension.empty? ? logical_path : logical_path.delete_suffix(extension)
        "#{base}-#{digest}#{extension}"
      end

      def write(path, content, mode: nil)
        FileUtils.mkdir_p(File.dirname(path))
        temporary = "#{path}.tmp-#{Process.pid}"
        File.binwrite(temporary, content)
        File.chmod(mode, temporary) if mode
        File.rename(temporary, path)
      ensure
        FileUtils.rm_f(temporary) if defined?(temporary)
      end
    end
  end
end
