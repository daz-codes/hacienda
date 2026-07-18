# frozen_string_literal: true

require_relative "test_helper"
require "json"

class AssetsTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("hacienda-assets")
    @assets_root = File.join(@root, "public", "assets")
    FileUtils.mkdir_p(File.join(@assets_root, "modules"))
    File.binwrite(File.join(@assets_root, "modules", "dependency.js"), "export const value = 1;\n")
    File.binwrite(
      File.join(@assets_root, "application.js"),
      %(import { value } from "./modules/dependency.js";\nconsole.log(value);\n)
    )
    File.binwrite(File.join(@assets_root, "logo.svg"), "<svg>first</svg>\n")
    File.binwrite(File.join(@assets_root, "theme.css"), ":root { color: black; }\n")
    File.binwrite(
      File.join(@assets_root, "application.css"),
      %(@import "./theme.css";\nbody { background: url("./logo.svg?v=1"); }\n)
    )
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_precompile_fingerprints_assets_and_rewrites_dependencies
    manifest = Hacienda::Assets.precompile(root: @root)

    application = manifest.fetch("assets").fetch("application.js")
    dependency = manifest.fetch("assets").fetch("modules/dependency.js")
    stylesheet = manifest.fetch("assets").fetch("application.css")
    logo = manifest.fetch("assets").fetch("logo.svg")
    theme = manifest.fetch("assets").fetch("theme.css")

    assert_match(/application-[0-9a-f]{16}\.js\z/, application)
    assert_match(%r{modules/dependency-[0-9a-f]{16}\.js\z}, dependency)
    assert_includes File.read(File.join(@assets_root, application)), %("./#{dependency}")
    assert_includes File.read(File.join(@assets_root, stylesheet)), %(url("./#{logo}?v=1"))
    assert_includes File.read(File.join(@assets_root, stylesheet)), %(@import "./#{theme}")
    assert_equal %(import { value } from "./modules/dependency.js";\nconsole.log(value);\n),
      File.read(File.join(@assets_root, "application.js"))
    assert_equal manifest, JSON.parse(File.read(File.join(@assets_root, ".manifest.json")))
  end

  def test_dependency_changes_update_parent_fingerprint_and_remove_old_outputs
    first = Hacienda::Assets.precompile(root: @root)
    old_application = first.fetch("assets").fetch("application.js")
    old_dependency = first.fetch("assets").fetch("modules/dependency.js")

    File.binwrite(File.join(@assets_root, "modules", "dependency.js"), "export const value = 2;\n")
    second = Hacienda::Assets.precompile(root: @root)

    refute_equal old_application, second.fetch("assets").fetch("application.js")
    refute_equal old_dependency, second.fetch("assets").fetch("modules/dependency.js")
    refute_path_exists File.join(@assets_root, old_application)
    refute_path_exists File.join(@assets_root, old_dependency)
  end

  def test_path_uses_manifest_only_in_production_and_preserves_suffixes
    manifest = Hacienda::Assets.precompile(root: @root)
    compiled = manifest.fetch("assets").fetch("application.js")

    assert_equal "/assets/application.js?v=1#module",
      Hacienda::Assets.path("application.js?v=1#module", root: @root, environment: "development")
    assert_equal "/assets/#{compiled}?v=1#module",
      Hacienda::Assets.path("/assets/application.js?v=1#module", root: @root, environment: "production")
  end

  def test_production_path_requires_a_valid_manifest_entry
    error = assert_raises(Hacienda::Assets::Error) do
      Hacienda::Assets.path("missing.js", root: @root, environment: "production")
    end
    assert_includes error.message, "asset manifest not found"

    Hacienda::Assets.precompile(root: @root)
    error = assert_raises(Hacienda::Assets::Error) do
      Hacienda::Assets.path("missing.js", root: @root, environment: "production")
    end
    assert_includes error.message, "assets:precompile"
  end

  def test_clobber_removes_compiled_assets_but_preserves_sources
    manifest = Hacienda::Assets.precompile(root: @root)
    orphan = File.join(@assets_root, "orphan-0123456789abcdef.js")
    File.binwrite(orphan, "stale")

    assert_equal manifest.fetch("assets").length + 1, Hacienda::Assets.clobber(root: @root)
    manifest.fetch("assets").each_value do |compiled|
      refute_path_exists File.join(@assets_root, compiled)
    end
    assert_path_exists File.join(@assets_root, "application.js")
    refute_path_exists orphan
    refute_path_exists File.join(@assets_root, ".manifest.json")
  end

  def test_rack_options_set_immutable_headers_only_for_fingerprinted_assets
    manifest = Hacienda::Assets.precompile(root: @root)
    compiled = manifest.fetch("assets").fetch("application.js")
    app = Rack::Static.new(->(_env) { [404, {}, []] }, **Hacienda::Assets.rack_options(root: @root))
    request = Rack::MockRequest.new(app)

    logical_response = request.get("/assets/application.js")
    compiled_response = request.get("/assets/#{compiled}")

    assert_equal "no-cache", logical_response["cache-control"]
    assert_equal "public, max-age=31536000, immutable", compiled_response["cache-control"]
  end

  def test_rejects_traversal_and_cyclic_dependencies
    assert_raises(Hacienda::Assets::Error) do
      Hacienda::Assets.path("../secret", root: @root, environment: "development")
    end

    File.binwrite(File.join(@assets_root, "first.js"), %(import "./second.js";\n))
    File.binwrite(File.join(@assets_root, "second.js"), %(import "./first.js";\n))
    error = assert_raises(Hacienda::Assets::Error) { Hacienda::Assets.precompile(root: @root) }
    assert_includes error.message, "cyclic asset dependency"
  end
end
