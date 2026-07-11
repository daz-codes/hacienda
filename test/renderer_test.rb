# frozen_string_literal: true

require_relative "test_helper"

class RendererTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("hacienda-renderer")
    write "app/domains/posts/views/show.erb", <<~ERB
      <h1><%= title %></h1>
      <div data-title="<%= title %>"><%= h title %></div>
      <%= raw trusted_html %>
      <%= partial :details, title: title %>
      <%= component :card, title: title %>
      <%= link "Read <post>", "/posts?filter=<new>" %>
      <%= stylesheet_link "application.css" %>
    ERB
    write "app/domains/posts/views/details.erb", "<p><%= title %></p>"
    write "app/domains/posts/views/components/_card.erb", "<article><%= title %></article>"
    write "app/domains/posts/views/fragment.erb", <<~ERB
      <%= cache_fragment(["card", key], context: context, expires_in: 60) { component(:card, title: title) } %>
    ERB
    write "app/layouts/application.erb", "<main><%= content %></main>"

    @renderer = Hacienda::Renderer.new(root: @root)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_erb_escapes_interpolated_values_by_default
    html = render(title: %(<script>alert("xss")</script>))

    refute_includes html, %(<script>alert("xss")</script>)
    assert_includes html, %(&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;)
    assert_includes html, %(data-title="&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;")
  end

  def test_raw_is_an_explicit_escape_hatch
    html = render(trusted_html: "<strong>Trusted</strong>")

    assert_includes html, "<strong>Trusted</strong>"
  end

  def test_h_remains_compatible_without_double_escaping
    html = render(title: "A & B")

    assert_includes html, "<div data-title=\"A &amp; B\">A &amp; B</div>"
    refute_includes html, "&amp;amp;"
  end

  def test_layouts_partials_components_and_helpers_are_safe_html
    html = render(title: "A < B")

    assert_includes html, "<main>"
    assert_includes html, "<p>A &lt; B</p>"
    assert_includes html, "<article>A &lt; B</article>"
    assert_includes html, %(<a href="/posts?filter=&lt;new&gt;">Read &lt;post&gt;</a>)
    assert_includes html, %(<link rel="stylesheet" href="/assets/application.css">)
    refute_includes html, "&lt;main&gt;"
    refute_includes html, "&lt;article&gt;"
  end

  def test_safe_html_is_immutable
    html = Hacienda::HTML.safe("<strong>Safe</strong>")

    assert_instance_of Hacienda::SafeHTML, html
    assert_predicate html, :frozen?
    assert_same html, Hacienda::HTML.safe(html)
  end

  def test_cache_fragment_reuses_safe_component_html
    cache = Hacienda::Cache.new
    application = Struct.new(:cache).new(cache)
    context = Hacienda::Context.new(
      Rack::MockRequest.env_for("/posts"),
      application:
    )

    first = @renderer.render(
      domain: "posts",
      view: "fragment",
      locals: {context:, key: 1, title: "First"}
    )
    second = @renderer.render(
      domain: "posts",
      view: "fragment",
      locals: {context:, key: 1, title: "Second"}
    )

    assert_includes first, "<article>First</article>"
    assert_includes second, "<article>First</article>"
    refute_includes second, "Second"
    refute_includes second, "&lt;article&gt;"
  end

  def test_invalid_locals_keys_raise_a_clear_error
    error = assert_raises(ArgumentError) do
      @renderer.render(
        domain: "posts",
        view: "show",
        locals: {"title" => "ok", "post-count" => 2, trusted_html: ""}
      )
    end

    assert_includes error.message, '"post-count"'
    assert_includes error.message, "valid Ruby local variable names"
  end

  def test_cache_fragment_escapes_plain_string_results
    cache = Hacienda::Cache.new
    application = Struct.new(:cache).new(cache)
    context = Hacienda::Context.new(Rack::MockRequest.env_for("/"), application:)
    view = Hacienda::Renderer::ViewContext.new(nil, "posts", {})

    html = view.cache_fragment("unsafe", context:) { "<script>alert(1)</script>" }

    assert_equal "&lt;script&gt;alert(1)&lt;/script&gt;", html
  end

  private

  def render(title: "Safe title", trusted_html: "")
    @renderer.render(
      domain: "posts",
      view: "show",
      locals: {title:, trusted_html:}
    )
  end

  def write(path, content)
    destination = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(destination))
    File.write(destination, content)
  end
end
