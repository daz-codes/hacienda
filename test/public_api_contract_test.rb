# frozen_string_literal: true

require_relative "test_helper"
require "hacienda/cli"
require "hacienda/generator"
require "rubygems"
require "stringio"
require "yaml"

class PublicAPIContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  MANIFEST_PATH = File.join(ROOT, "docs", "public-api.yml")

  def setup
    @manifest = YAML.safe_load_file(MANIFEST_PATH, aliases: false)
  end

  def test_manifest_matches_framework_version
    assert_equal 1, @manifest.fetch("schema")
    assert_equal Hacienda::VERSION, @manifest.fetch("framework_version")
  end

  def test_documented_ruby_api_exists_and_is_public
    @manifest.fetch("ruby").each do |name, contract|
      object = constantize(name)
      Array(contract["singleton_methods"]).each do |method|
        assert_respond_to object, method.to_sym, "#{name}.#{method} is documented as public"
      end
      Array(contract["instance_methods"]).each do |method|
        assert_includes object.public_instance_methods, method.to_sym,
          "#{name}##{method} is documented as public"
      end
    end

    @manifest.fetch("exceptions").each do |name|
      exception = constantize(name)
      assert_operator exception, :<=, Exception, "#{name} must remain an exception class"
    end
  end

  def test_cli_executables_and_commands_are_present
    specification = Gem::Specification.load(File.join(ROOT, "hacienda.gemspec"))
    expected_executables = @manifest.dig("cli", "executables")
    assert_equal expected_executables.sort, specification.executables.sort
    expected_executables.each { |name| assert_path_exists File.join(ROOT, "exe", name) }

    output = StringIO.new
    assert_equal 0, Hacienda::CLI.start(["help"], out: output, err: StringIO.new)
    @manifest.dig("cli", "commands").each do |command|
      assert_includes output.string, "hac #{command}"
    end
  end

  def test_generated_application_file_contract_is_exact
    Dir.mktmpdir("hacienda-public-api") do |directory|
      target = File.join(directory, "application")
      Hacienda::Generator.new(target:, source_root: ROOT, cwd: directory).new_app
      actual = Dir.glob(File.join(target, "**", "*"), File::FNM_DOTMATCH)
        .reject { |path| File.directory?(path) || %w[. ..].include?(File.basename(path)) }
        .map { |path| path.delete_prefix("#{target}/") }
        .sort

      assert_equal @manifest.fetch("generated_files").sort, actual
    end
  end

  def test_environment_protocol_and_persistence_names_remain_present
    source = Dir[File.join(ROOT, "lib", "**", "*.rb")].sort.map { |path| File.read(path) }.join("\n")
    snapshots = Dir[File.join(ROOT, "test", "snapshots", "*.snap")].sort.map { |path| File.read(path) }.join("\n")
    navigation = File.read(File.join(ROOT, "lib", "hacienda", "assets", "hacienda-navigation.js"))

    @manifest.fetch("environment_variables").each do |name|
      assert_includes source, name, "#{name} must remain represented in framework or generated configuration"
    end
    @manifest.dig("persistence", "tables").each do |name|
      assert_includes snapshots, name, "#{name} must remain represented in generated migrations"
    end
    @manifest.dig("persistence", "payload_keys").each do |name|
      assert_includes source, name, "#{name} must remain represented in durable serialization"
    end
    @manifest.dig("navigation_protocol", "headers").each do |name|
      assert_includes navigation.downcase, name.downcase
    end
    @manifest.dig("navigation_protocol", "events").each do |name|
      assert_includes navigation, name
    end
    @manifest.dig("navigation_protocol", "attributes").each do |name|
      assert_includes navigation, name
    end
    @manifest.dig("navigation_protocol", "paths").each do |name|
      assert_includes source, name
    end
  end

  def test_release_documentation_and_gem_metadata_are_present
    changelog = File.read(File.join(ROOT, "CHANGELOG.md"))
    assert_includes changelog, "## [#{Hacienda::VERSION}]"

    %w[public-api.md upgrading.md support.md generated-diffs/README.md].each do |path|
      assert_path_exists File.join(ROOT, "docs", path)
    end

    specification = Gem::Specification.load(File.join(ROOT, "hacienda.gemspec"))
    assert_equal "true", specification.metadata.fetch("rubygems_mfa_required")
    assert_includes specification.files, "CHANGELOG.md"

    if Hacienda::VERSION.match?(/\.rc\d+\z/)
      assert_path_exists File.join(ROOT, "docs", "generated-diffs", "#{Hacienda::VERSION}.md")
    end
  end

  private

  def constantize(name)
    name.split("::").reject(&:empty?).reduce(Object) { |scope, constant| scope.const_get(constant) }
  end
end
