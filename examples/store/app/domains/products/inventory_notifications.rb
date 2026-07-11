# frozen_string_literal: true

module Products
  module InventoryNotifications
    def back_in_stock?
      attribute_was(:inventory_count).to_i.zero? && inventory_count.to_i.positive?
    end

    def in_stock?
      inventory_count.to_i.positive?
    end
  end
end
