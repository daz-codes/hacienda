# frozen_string_literal: true

require_relative "../test_helper"
require "json"

class HomeTest < ApplicationTest
  def test_home_page
    get "/"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "The Lunula"
    assert_includes last_response.body, "must be built"
    assert_includes last_response.body, "Build a blog in 10 minutes"
    assert_includes last_response.body, "Posts.publish(post)"
  end

  def test_health_check
    get "/up"

    assert_equal 200, last_response.status
    assert_equal "OK", last_response.body
  end


  def test_blog_quick_start
    get "/guides/blog"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Build a working blog"
    assert_includes last_response.body, "luna generate rest posts"
    assert_includes last_response.body, "module Posts"
  end

  def test_complete_store_guide
    get "/guides/store"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Build Lunula Supply"
    assert_includes last_response.body, "Authentication and guarded routes"
    assert_includes last_response.body, "Deployment"
    assert_includes last_response.body, "id=\"1-prerequisites\""
  end

  def test_helium_cookbook
    get "/guides/helium"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Helium cookbook"
    assert_includes last_response.body, "Filter a product table"
    assert_includes last_response.body, "@bind=\"productQuery\""
    assert_includes last_response.body, "@post.prevent=\"/guides/helium/comment-preview\""
    assert_includes last_response.body, "@import=\"/assets/time_ago.js\""
    assert_includes last_response.body, "Ajax form feedback"
  end

  def test_helium_cookbook_ajax_fragments
    post_json "/guides/helium/comment-preview", body: "Server-rendered comment"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "New comment added"
    assert_includes last_response.body, "time_ago_in_words(timestamp -"
    assert_includes last_response.body, "Server-rendered comment"

    post_json "/guides/helium/post-preview", message: "Ajax post"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Message posted"
    assert_includes last_response.body, ">Just now</time>"
    assert_includes last_response.body, "Ajax post"
  end

  def test_time_ago_module
    get "/assets/time_ago.js"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "time_ago_in_words"
    assert_includes last_response.body, "start_time_ago_clock"
  end

  def test_navigation_response_morphs_the_guide_content
    get "/guides/blog", {}, "HTTP_X_LUNULA_NAVIGATION" => "true"

    assert_equal 200, last_response.status
    assert_equal "morph", last_response.headers["x-morpheus-navigation"]
    assert_match(/\A<div id="morpheus-page"/, last_response.body)
  end

  private

  def post_json(path, payload)
    post path, JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}
  end
end
