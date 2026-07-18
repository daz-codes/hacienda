# frozen_string_literal: true

module Orders
  LineItem = Data.define(:pizza_id, :pizza_name, :unit_price_cents, :quantity) do
    def total_cents
      unit_price_cents * quantity
    end

    def unit_price
      format("%.2f", unit_price_cents / 100.0)
    end

    def total
      format("%.2f", total_cents / 100.0)
    end
  end
end
