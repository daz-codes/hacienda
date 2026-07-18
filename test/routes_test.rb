# frozen_string_literal: true

require_relative "test_helper"

class RoutesTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("hacienda-routes")
    @routes = Hacienda::Routes.new
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_rejects_normalized_duplicates_across_domains
    draw("pizzas", %(get "/pizzas/", :index\n))

    error = assert_raises(Hacienda::Routes::CollisionError) do
      draw("menu", %(get "//pizzas", :index\n))
    end

    assert_includes error.message, "duplicate normalized verb and path"
    assert_route_owners(error.message, "pizzas", "menu")
  end

  def test_rejects_structurally_equivalent_dynamic_routes
    draw("pizzas", %(get "/pizzas/:id", :show\n))

    error = assert_raises(Hacienda::Routes::CollisionError) do
      draw("menu", %(get "/pizzas/:slug", :show\n))
    end

    assert_includes error.message, "structurally equivalent dynamic paths (/pizzas/:*)"
    assert_route_owners(error.message, "pizzas", "menu")
  end

  def test_rejects_same_specificity_patterns_with_a_shared_concrete_path
    draw("sections", %(get "/:section/new", :new\n))

    error = assert_raises(Hacienda::Routes::CollisionError) do
      draw("pizzas", %(get "/pizzas/:id", :show\n))
    end

    assert_includes error.message, "same-specificity patterns can both match /pizzas/new"
    assert_route_owners(error.message, "sections", "pizzas")
  end

  def test_allows_static_precedence_and_the_same_path_for_different_verbs
    draw("pizzas", <<~RUBY)
      get "/pizzas/new", :new
      get "/pizzas/:id", :show
      post "/pizzas/:id", :update
    RUBY

    route, params = @routes.find("GET", "/pizzas/new")
    assert_equal "new", route.action_name
    assert_empty params

    route, params = @routes.find("GET", "/pizzas/42")
    assert_equal "show", route.action_name
    assert_equal({"id" => "42"}, params)

    route, = @routes.find("POST", "/pizzas/42")
    assert_equal "update", route.action_name
  end

  def test_head_uses_get_without_creating_a_separate_collision
    draw("pizzas", %(get "/pizzas/:id", :show\n))

    route, params = @routes.find("HEAD", "/pizzas/7")

    assert_equal "GET", route.verb
    assert_equal({"id" => "7"}, params)
  end

  def test_collision_reports_action_groups_files_and_lines
    draw("pizzas", <<~RUBY)
      # menu route
      get "/pizzas/:id", :show
    RUBY

    error = assert_raises(Hacienda::Routes::CollisionError) do
      draw("admin", <<~RUBY)
        guard String do
          get "/pizzas/:slug", :edit, actions: :management
        end
      RUBY
    end

    assert_includes error.message, "pizzas/routes.rb:2"
    assert_includes error.message, "admin/routes.rb:2"
    assert_includes error.message, "Pizzas::Actions#show"
    assert_includes error.message, "Admin::ManagementActions#edit"
  end

  private

  def draw(domain, source)
    file = File.join(@root, domain, "routes.rb")
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, source)
    @routes.draw(file, domain:)
  end

  def assert_route_owners(message, *domains)
    domains.each { |domain| assert_includes message, "[#{domain}]" }
  end
end
