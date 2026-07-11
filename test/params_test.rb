# frozen_string_literal: true

require_relative "test_helper"
require "json"

class ParamsTest < Minitest::Test
  def test_symbolizes_top_level_and_nested_keys
    params = Hacienda::Params.new(
      {
        "post" => {"title" => "Hello", "tags" => [{"name" => "ruby"}]},
        "page" => "1"
      },
      {"id" => "42"}
    )

    assert_equal "Hello", params[:post][:title]
    assert_equal "ruby", params.dig(:post, :tags, 0, :name)
    assert_equal "42", params[:id]
  end

  def test_slice_returns_only_requested_top_level_keys
    params = Hacienda::Params.new("title" => "Hello", "admin" => "1")

    assert_equal({title: "Hello"}, params.slice(:title, :body))
  end

  def test_permit_returns_only_scalar_top_level_keys
    params = Hacienda::Params.new(
      "title" => "Hello",
      "admin" => "1",
      "post" => {"body" => "Nested"}
    )

    assert_equal({title: "Hello"}, params.permit(:title, :post))
  end

  def test_require_returns_nested_params
    params = Hacienda::Params.new(
      "post" => {"title" => "Hello", "admin" => "1"}
    )

    assert_equal({title: "Hello"}, params.require(:post).permit(:title))
  end

  def test_require_raises_bad_request_when_missing
    params = Hacienda::Params.new({})

    error = assert_raises(Hacienda::BadRequest) { params.require(:post) }
    assert_equal "param is missing or empty: post", error.message
  end

  def test_permit_allows_declared_nested_hashes
    params = Hacienda::Params.new(
      "post" => {
        "title" => "Hello",
        "author" => {"name" => "Daz", "admin" => "1"}
      }
    )

    assert_equal(
      {post: {title: "Hello", author: {name: "Daz"}}},
      params.permit(post: [:title, {author: [:name]}])
    )
  end

  def test_permit_allows_declared_nested_arrays
    params = Hacienda::Params.new(
      "tags" => ["ruby", "web", {"unsafe" => "hash"}],
      "comments" => [
        {"body" => "First", "admin" => "1"},
        {"body" => "Second"}
      ]
    )

    assert_equal(
      {
        tags: ["ruby", "web"],
        comments: [{body: "First"}, {body: "Second"}]
      },
      params.permit(tags: [], comments: [:body])
    )
  end

  def test_from_request_preserves_form_encoded_params
    env = Rack::MockRequest.env_for(
      "/posts",
      method: "POST",
      params: {"post" => {"title" => "Form post"}}
    )

    params = Hacienda::Params.from_request(Rack::Request.new(env))

    assert_equal "Form post", params.dig(:post, :title)
  end

  def test_json_request_data_is_parsed_once_and_cached
    source = JSON.generate(password: "secret")
    env = Rack::MockRequest.env_for(
      "/posts",
      method: "POST",
      "CONTENT_TYPE" => "application/json",
      input: source
    )
    request = Rack::Request.new(env)

    first = Hacienda::Params.request_data(request)
    request.body.read
    second = Hacienda::Params.request_data(request)

    assert_same first, second
    assert_equal({"password" => "secret"}, second)
  end
end
