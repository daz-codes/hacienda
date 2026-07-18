# frozen_string_literal: true

require_relative "test_helper"
require "lunula/generator"
require "bundler"
require "digest"
require "open3"
require "rubygems/package"

class PackageTest < Minitest::Test
  def setup
    @root = File.expand_path("..", __dir__)
    @directory = Dir.mktmpdir("lunula-package")
    @gem_home = File.join(@directory, "gems")
    @bin = File.join(@directory, "bin")
    @gem_path = [@gem_home, *Gem.path].join(File::PATH_SEPARATOR)
  end

  def teardown
    FileUtils.rm_rf(@directory)
  end

  def test_packed_gem_generates_migrates_and_tests_an_application
    gem_file = File.join(@directory, "lunula.gem")
    run!(Gem.ruby, "-S", "gem", "build", "lunula.gemspec", "--output", gem_file, chdir: @root)
    dependency_names = Gem::Package.new(gem_file).spec.runtime_dependencies.map(&:name).sort
    assert_equal %w[mail rack rack-session rackup sequel zeitwerk], dependency_names
    packaged_files = Gem::Package.new(gem_file).contents
    assert_includes packaged_files, "CHANGELOG.md"
    assert_includes packaged_files, "docs/public-api.yml"
    assert_includes packaged_files, "docs/upgrading.md"
    expected_assets.each do |name|
      assert_includes packaged_files, "lib/lunula/assets/#{name}"
    end
    run!(
      Gem.ruby,
      "-S",
      "gem",
      "install",
      gem_file,
      "--install-dir",
      @gem_home,
      "--bindir",
      @bin,
      "--local",
      "--ignore-dependencies",
      "--no-document"
    )

    installed_root = Dir[File.join(@gem_home, "gems", "lunula-*")].fetch(0)
    expected_assets.each do |name|
      installed = File.join(installed_root, "lib", "lunula", "assets", name)
      source = File.join(@root, "lib", "lunula", "assets", name)
      assert_path_exists installed
      assert_equal Digest::SHA256.file(source).hexdigest, Digest::SHA256.file(installed).hexdigest
    end

    assert_includes run!(File.join(@bin, "luna"), "--version"), "luna #{Lunula::VERSION}"
    run!(File.join(@bin, "luna"), "new", "packed_app", chdir: @directory)

    app_root = File.join(@directory, "packed_app")
    assert_includes File.read(File.join(app_root, "Gemfile")), %(gem "lunula", "~> #{Lunula::VERSION}")
    expected_assets.each do |name|
      generated = File.join(app_root, "public", "assets", name)
      installed = File.join(installed_root, "lib", "lunula", "assets", name)
      assert_path_exists generated
      assert_equal Digest::SHA256.file(installed).hexdigest, Digest::SHA256.file(generated).hexdigest
    end

    assert_includes run!(File.join(@bin, "luna"), "assets:precompile", chdir: app_root), "Compiled"
    manifest = JSON.parse(File.read(File.join(app_root, "public", "assets", ".manifest.json")))
    navigation = manifest.fetch("assets").fetch("morpheus.js")
    idiomorph = manifest.fetch("assets").fetch("idiomorph.esm.js")
    assert_includes File.read(File.join(app_root, "public", "assets", navigation)), %("./#{idiomorph}")

    run!(File.join(@bin, "luna"), "db:migrate", chdir: app_root)
    output = run!(
      Gem.ruby,
      "-Itest",
      "-e",
      'Dir["test/**/*_test.rb"].sort.each { |file| require File.expand_path(file) }',
      chdir: app_root
    )
    assert_includes output, "2 runs"
  end

  private

  def expected_assets
    Lunula::Generator::HELIUM_ASSETS + [
      "HELIUM-LICENSE.txt",
      *Lunula::Generator::FRAMEWORK_ASSETS
    ]
  end

  def run!(*command, chdir: nil)
    environment = {"GEM_HOME" => @gem_home, "GEM_PATH" => @gem_path, "HELIUM_PATH" => nil}
    stdout, stderr, status = Bundler.with_unbundled_env do
      Open3.capture3(environment, *command, chdir: chdir || @directory)
    end
    assert status.success?, <<~MESSAGE
      Command failed: #{command.join(" ")}
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MESSAGE
    stdout
  end
end
