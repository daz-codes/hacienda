# frozen_string_literal: true

require_relative "test_helper"

class ResponseTest < Minitest::Test
  include Lunula::Responses

  def setup
    @previous_app_url = ENV.delete("LUNULA_APP_URL")
    @previous_legacy_url = ENV.delete("APP_URL")
    ENV["LUNULA_APP_URL"] = "https://example.test"
  end

  def teardown
    ENV["LUNULA_APP_URL"] = @previous_app_url if @previous_app_url
    ENV.delete("LUNULA_APP_URL") unless @previous_app_url
    ENV["APP_URL"] = @previous_legacy_url if @previous_legacy_url
    ENV.delete("APP_URL") unless @previous_legacy_url
  end

  def test_redirect_allows_relative_locations
    response = redirect("/posts")

    assert_equal 303, response.status
    assert_equal "/posts", response.headers["location"]
  end

  def test_redirect_strips_crlf_from_location
    response = redirect("/posts\r\n")

    assert_equal "/posts", response.headers["location"]
  end

  def test_redirect_allows_same_origin_absolute_locations
    response = redirect("https://EXAMPLE.test/posts")

    assert_equal "https://EXAMPLE.test/posts", response.headers["location"]
  end

  def test_redirect_rejects_other_hosts_by_default
    error = assert_raises(Lunula::UnsafeRedirect) do
      redirect("https://evil.test/phish")
    end

    assert_includes error.message, "another host"
  end

  def test_redirect_allows_other_hosts_explicitly
    response = redirect("https://example.org/docs", allow_other_host: true)

    assert_equal "https://example.org/docs", response.headers["location"]
  end
end
