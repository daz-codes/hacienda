# frozen_string_literal: true

require_relative "test_helper"

class NavigationTest < Minitest::Test
  FakeApplication = Struct.new(:navigation, keyword_init: true)
  FakeContext = Struct.new(:application, :flash, keyword_init: true)

  def setup
    @view = Hacienda::Renderer::ViewContext.new(nil, "posts", {})
  end

  def test_navigation_is_enabled_with_bounded_intent_prefetch_by_default
    navigation = Hacienda::Navigation.new

    assert navigation.enabled?
    assert_equal :intent, navigation.prefetch
    assert_equal 20, navigation.cache_size
    assert_equal 15.0, navigation.cache_ttl
  end

  def test_navigation_can_be_disabled_or_configured
    refute Hacienda::Navigation.new(false).enabled?

    navigation = Hacienda::Navigation.new(
      prefetch: false,
      cache_size: 8,
      cache_ttl: 5,
      page_attributes: {class: "page-shell"}
    )

    assert navigation.enabled?
    assert_nil navigation.prefetch
    assert_equal 8, navigation.cache_size
    assert_equal 5.0, navigation.cache_ttl
    assert_equal({class: "page-shell"}, navigation.page_attributes)
  end

  def test_navigation_asset_helper_reflects_application_configuration
    context = FakeContext.new(application: FakeApplication.new(navigation: Hacienda::Navigation.new), flash: {})

    html = @view.hacienda_navigation(context)

    assert_includes html, %(src="/assets/hacienda-navigation.js")
    assert_includes html, %(data-hacienda-navigation)
    assert_includes html, %(data-prefetch="intent")
    assert_includes html, %(data-cache-size="20")
    assert_includes html, %(data-cache-ttl="15.0")
  end

  def test_navigation_asset_helper_is_empty_when_disabled
    context = FakeContext.new(application: FakeApplication.new(navigation: Hacienda::Navigation.new(false)), flash: {})

    assert_equal "", @view.hacienda_navigation(context)
  end

  def test_navigation_page_uses_configured_attributes_and_keeps_flash_inside_target
    flash = {notice: "Saved"}
    context = FakeContext.new(
      application: FakeApplication.new(
        navigation: Hacienda::Navigation.new(page_attributes: {class: "page-shell"})
      ),
      flash:
    )

    html = @view.navigation_page("<h1>Post</h1>", context:)

    assert_match(/\A<div class="page-shell" id="hacienda-page" data-hacienda-page>/, html)
    assert_includes html, "Saved"
    assert_includes html, "<h1>Post</h1>"
  end

  def test_invalid_configuration_fails_loudly
    assert_raises(ArgumentError) { Hacienda::Navigation.new(prefetch: :visible) }
    assert_raises(ArgumentError) { Hacienda::Navigation.new(cache_size: 0) }
    assert_raises(ArgumentError) { Hacienda::Navigation.new(cache_ttl: 0) }
  end
end
