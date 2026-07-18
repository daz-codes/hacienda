# frozen_string_literal: true

module Orders
  class Order
    include Lunula::Attributes
    include Lunula::Validations

    attributes :id, :public_token, :total_cents, :status, :created_at, :updated_at
    attribute :customer_name, default: ""
    attribute :email, default: ""
    attribute :delivery_address, default: ""
    attr_accessor :line_items

    def initialize(**attributes)
      super
      @line_items = []
    end

    def validate
      errors.add :customer_name, "is required" if customer_name.to_s.strip.empty?
      errors.add :email, "is required" unless email.to_s.match?(/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/)
      errors.add :delivery_address, "is required" if delivery_address.to_s.strip.empty?
      errors.add :pizzas, "choose at least one pizza" if line_items.empty?
    end

    def number
      "WP-%04d" % id.to_i
    end

    def total
      format("%.2f", total_cents.to_i / 100.0)
    end
  end
end
