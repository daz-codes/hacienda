# frozen_string_literal: true

require_relative "../test_helper"
require "tempfile"

class ProductsTest < ApplicationTest
  def setup
    database[:subscribers].delete
    database[:products].delete
    database[:users].delete
    database[:lunula_outbox].delete
    database[:lunula_jobs].delete
    APP.cache.clear
    Lunula.clear_mail_deliveries
  end

  def test_products_are_public_but_management_requires_login
    product = create_product(name: "T-Shirt", inventory_count: 4)

    get "/products"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "T-Shirt"

    get "/products/#{product.id}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "4</strong> in stock"

    get "/products/new"
    assert_equal 303, last_response.status
    assert_equal "/login", last_response["location"]
  end

  def test_authenticated_user_can_create_a_product_with_an_image
    login

    Tempfile.create(["featured", ".png"]) do |file|
      file.binmode
      file.write("\x89PNG\r\n\x1a\n")
      file.flush
      upload = Rack::Test::UploadedFile.new(file.path, "image/png", original_filename: "featured.png")

      post "/products", {
        _csrf: fresh_csrf("/products/new"),
        name: "Canvas Tote",
        description: "Heavy canvas",
        inventory_count: "3",
        featured_image: upload
      }
    end

    assert_equal 303, last_response.status
    product = Products::Repository.first(Products::Repository.dataset.where(name: "Canvas Tote"))
    assert product.featured_image?
    assert APP.storage.exist?(product.featured_image_key)
  end

  def test_restocking_notifies_subscribers_after_commit
    product = create_product(name: "Record Bag", inventory_count: 0)
    Products::Subscribers.save Products::Subscriber.new(product_id: product.id, email: "listener@example.com")
    login

    patch "/products/#{product.id}", {
      _csrf: fresh_csrf("/products/#{product.id}/edit"),
      name: product.name,
      description: product.description,
      inventory_count: "5"
    }

    assert_equal 303, last_response.status
    assert_equal 1, Lunula.mail_deliveries.length
    assert_equal ["listener@example.com"], Lunula.mail_deliveries.first.to
    assert_includes Lunula.mail_deliveries.first.subject, "back in stock"
  end

  def test_unsubscribe_requires_confirmation_post
    product = create_product(name: "Record Bag", inventory_count: 0)
    subscriber = Products::Subscriber.new(product_id: product.id, email: "listener@example.com")
    Products::Subscribers.save(subscriber)
    token = Products::Mailer.unsubscribe_token(subscriber)

    get "/unsubscribe", token: token
    assert_equal 200, last_response.status
    assert Products::Subscribers.find(subscriber.id)

    post "/unsubscribe", token: token, _csrf: fresh_csrf("/unsubscribe?token=#{Rack::Utils.escape(token)}")
    assert_equal 303, last_response.status
    assert_nil Products::Subscribers.find_by(id: subscriber.id)
  end

  private

  def create_product(name:, inventory_count:)
    Products::Product.new(
      name:,
      description: "A guide product",
      inventory_count:
    ).tap { |product| Products::Repository.save(product) }
  end

  def login
    password = "a-secure-password"
    user = Auth::User.new(email: "admin@example.com")
    user.password = password
    user.verify_email
    Auth::Repository.save(user)

    post "/login", {
      _csrf: fresh_csrf("/login"),
      email: user.email,
      password:
    }
    assert_equal 303, last_response.status
  end

  def fresh_csrf(path)
    get path
    last_request.env.fetch("rack.session").fetch(:csrf_token)
  end
end
