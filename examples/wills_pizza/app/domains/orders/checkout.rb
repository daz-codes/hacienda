# frozen_string_literal: true

require "securerandom"

module Orders
  class Checkout
    MAX_QUANTITY = 20

    attr_reader :order

    def initialize(menu:, attributes:, quantities:)
      @order = Order.new(
        public_token: SecureRandom.hex(16),
        customer_name: attributes[:customer_name].to_s.strip,
        email: attributes[:email].to_s.strip.downcase,
        delivery_address: attributes[:delivery_address].to_s.strip,
        status: "received"
      )
      @order.line_items, quantity_errors = build_items(menu, quantities)
      @order.total_cents = @order.line_items.sum(&:total_cents)
      @order.valid?
      quantity_errors.each { |message| @order.errors.add :quantity, message }
    end

    def valid?
      order.errors.empty?
    end

    private

    def build_items(menu, quantities)
      quantities = quantities.is_a?(Hash) ? quantities : {}
      errors = []
      items = menu.filter_map do |pizza|
        quantity = Integer(quantities[pizza.id.to_s.to_sym], exception: false).to_i
        next if quantity.zero?

        if quantity.negative? || quantity > MAX_QUANTITY
          errors << "must be between 1 and #{MAX_QUANTITY}"
          next
        end

        LineItem.new(
          pizza_id: pizza.id,
          pizza_name: pizza.name,
          unit_price_cents: pizza.price_cents,
          quantity:
        )
      end

      [items, errors]
    end
  end
end
