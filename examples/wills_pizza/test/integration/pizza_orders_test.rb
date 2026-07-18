# frozen_string_literal: true

require_relative "../test_helper"

class PizzaOrdersTest < ApplicationTest
  def setup
    database[:order_items].delete
    database[:orders].delete
    database[:pizzas].delete
    database[:users].delete
  end

  def test_public_menu_and_menu_management_require_the_right_access
    pizza = create_pizza(name: "Margherita", price_cents: 1_050)

    get "/pizzas"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Margherita"
    assert_includes last_response.body, "&pound;10.50"

    get "/pizzas/new"
    assert_equal 303, last_response.status
    assert_equal "/login", last_response["location"]

    login
    get "/pizzas/new"
    assert_equal 200, last_response.status

    post "/pizzas", {
      _csrf: csrf_token,
      name: "Courgette & Lemon",
      description: "Courgette, ricotta, lemon and mint.",
      price: "12.75",
      vegetarian: "1",
      available: "1"
    }
    assert_equal 303, last_response.status

    created = Pizzas::Repository.dataset.where(name: "Courgette & Lemon").first
    assert_equal 1_275, created.fetch(:price_cents)
    assert created.fetch(:vegetarian)
    assert_equal "/pizzas/#{created.fetch(:id)}", last_response["location"]
    assert_equal pizza.id, Pizzas::Repository.find(pizza.id).id
  end

  def test_public_customer_can_order_multiple_pizzas
    margherita = create_pizza(name: "Margherita", price_cents: 1_050)
    pepperoni = create_pizza(name: "Pepperoni", price_cents: 1_350, vegetarian: false)

    get "/orders/new"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Margherita"
    assert_includes last_response.body, "Pepperoni"

    post "/orders", {
      _csrf: csrf_token,
      customer_name: "Ruby Friend",
      email: "friend@example.com",
      delivery_address: "1 Gem Lane\nLondon",
      quantities: {margherita.id.to_s => "2", pepperoni.id.to_s => "1"}
    }
    assert_equal 303, last_response.status
    assert_match(%r{\A/orders/[a-f0-9]{32}\z}, last_response["location"])

    follow_redirect!
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Thanks, Ruby Friend."
    assert_includes last_response.body, "2 &times; Margherita"
    assert_includes last_response.body, "&pound;34.50"
    assert_includes last_response.body, "1 Gem Lane"

    order = database[:orders].first
    assert_equal 3_450, order.fetch(:total_cents)
    assert_equal 2, database[:order_items].count

    database[:pizzas].where(id: margherita.id).update(name: "Renamed", price_cents: 99_999)
    get last_request.path
    assert_includes last_response.body, "Margherita"
    assert_includes last_response.body, "&pound;34.50"
    refute_includes last_response.body, "Renamed"
  end

  def test_order_validation_returns_the_form_without_persisting
    create_pizza

    post "/orders", {
      _csrf: csrf_token,
      customer_name: "",
      email: "not-an-email",
      delivery_address: "",
      quantities: {}
    }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "choose at least one pizza"
    assert_equal 0, database[:orders].count
  end

  def test_order_rejects_an_excessive_quantity
    pizza = create_pizza

    post "/orders", {
      _csrf: csrf_token,
      customer_name: "Ruby Friend",
      email: "friend@example.com",
      delivery_address: "1 Gem Lane",
      quantities: {pizza.id.to_s => "21"}
    }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "Quantity must be between 1 and 20"
    assert_equal 0, database[:orders].count
  end

  private

  def create_pizza(name: "Test Pizza", price_cents: 1_100, vegetarian: true)
    Pizzas::Pizza.new(
      name:,
      description: "Fresh from the test oven.",
      price_cents:,
      vegetarian:,
      available: true
    ).tap { |pizza| Pizzas::Repository.save(pizza) }
  end

  def login
    user = Auth::User.new(email: "will@example.com")
    user.password = "wood-fired-pizza"
    user.verify_email
    Auth::Repository.save(user)

    post "/login", {
      _csrf: fresh_csrf("/login"),
      email: "will@example.com",
      password: "wood-fired-pizza"
    }
    assert_equal 303, last_response.status
  end

  def fresh_csrf(path)
    get path
    last_request.env.fetch("rack.session").fetch(:csrf_token)
  end
end
