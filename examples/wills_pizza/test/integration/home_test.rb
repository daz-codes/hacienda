# frozen_string_literal: true

require_relative "../test_helper"

class HomeTest < ApplicationTest
  def test_home_page
    get "/"

    assert_equal 303, last_response.status
    assert_equal "/pizzas", last_response["location"]
  end

  def test_health_check
    get "/up"

    assert_equal 200, last_response.status
    assert_equal "OK", last_response.body
  end
end
