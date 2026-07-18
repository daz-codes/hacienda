# frozen_string_literal: true

require_relative "test_helper"

class HTMLHelpersTest < Minitest::Test
  FakeContext = Struct.new(:csrf_token, :csp_nonce, keyword_init: true)

  def setup
    @view = Lunula::Renderer::ViewContext.new(nil, "posts", {})
    @context = FakeContext.new(csrf_token: "secure-token", csp_nonce: "nonce-token")
  end

  def test_path_expands_segments_and_appends_query_params
    assert_equal(
      "/posts/hello%20world/edit?tab=settings",
      @view.path("/posts/:id/edit", id: "hello world", tab: "settings")
    )
  end

  def test_path_requires_named_segments
    error = assert_raises(KeyError) { @view.path("/posts/:id") }

    assert_equal "missing path param: id", error.message
  end

  def test_link_escapes_label_href_and_attributes
    html = @view.link(%(<Posts>), %(/posts?sort=<new>), class: ["nav", "active"], data_testid: "posts")

    assert_equal(
      %(<a href="/posts?sort=&lt;new&gt;" class="nav active" data-testid="posts">&lt;Posts&gt;</a>),
      html
    )
  end

  def test_link_rejects_javascript_urls
    error = assert_raises(ArgumentError) { @view.link("Click", "javascript:alert(1)") }

    assert_includes error.message, "unsafe URL"
  end

  def test_link_rejects_disguised_unsafe_schemes
    assert_raises(ArgumentError) { @view.link("Click", "JaVaScRiPt:alert(1)") }
    assert_raises(ArgumentError) { @view.link("Click", " javascript:alert(1)") }
    assert_raises(ArgumentError) { @view.link("Click", "java\tscript:alert(1)") }
    assert_raises(ArgumentError) { @view.link("Click", "data:text/html,<script>alert(1)</script>") }
    assert_raises(ArgumentError) { @view.link("Click", "vbscript:msgbox") }
  end

  def test_link_allows_ordinary_urls
    @view.link("Home", "/")
    @view.link("Site", "https://example.com/path")
    @view.link("Mail", "mailto:hello@example.com")
    @view.link("Search", "/search?q=javascript:void")
    @view.link("File", "https://example.com/data:report.pdf")
  end

  def test_form_start_rejects_unsafe_actions
    assert_raises(ArgumentError) { @view.form_start("javascript:alert(1)", context: @context) }
  end

  def test_form_start_adds_csrf_and_method_override_for_non_post_methods
    html = @view.form_start(
      "/posts/1",
      method: "delete",
      context: @context,
      class: "inline",
      "@submit": "pending = true"
    )

    assert_equal(
      %(<form method="post" action="/posts/1" class="inline" @submit="pending = true">) +
        %(<input type="hidden" name="_csrf" value="secure-token">) +
        %(<input type="hidden" name="_method" value="delete">),
      html
    )
  end

  def test_button_to_builds_a_csrf_protected_form
    html = @view.button_to(
      "Delete",
      "/posts/1",
      method: "delete",
      context: @context,
      form: {class: "inline"},
      button: {class: "danger", disabled: true}
    )

    assert_equal(
      %(<form method="post" action="/posts/1" class="inline">) +
        %(<input type="hidden" name="_csrf" value="secure-token">) +
        %(<input type="hidden" name="_method" value="delete">) +
        %(<button type="submit" class="danger" disabled>Delete</button></form>),
      html
    )
  end

  def test_csp_nonce_helper_returns_the_context_nonce
    assert_equal "nonce-token", @view.csp_nonce(@context)
  end

  def test_asset_helpers_can_include_a_context_nonce
    assert_equal(
      %(<script src="/assets/app.js" nonce="nonce-token"></script>),
      @view.javascript_include("app.js", nonce: true, context: @context)
    )
    assert_equal(
      %(<link rel="stylesheet" href="/assets/app.css" nonce="nonce-token">),
      @view.stylesheet_link("app.css", nonce: true, context: @context)
    )
  end

  def test_nonce_true_requires_context
    assert_raises(ArgumentError) { @view.javascript_include("app.js", nonce: true) }
  end
end
