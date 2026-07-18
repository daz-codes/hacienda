# frozen_string_literal: true

module Orders
  module Repository
    STORE = Hacienda::Store.new(database: APP.database, table: :orders, record: Order)

    module_function

    def save(order)
      STORE.save(order)
      APP.database[:order_items].multi_insert(
        order.line_items.map do |item|
          {
            order_id: order.id,
            pizza_id: item.pizza_id,
            pizza_name: item.pizza_name,
            unit_price_cents: item.unit_price_cents,
            quantity: item.quantity
          }
        end
      )
      order
    end

    def find_by_token(token)
      order = STORE.first(STORE.dataset.where(public_token: token.to_s)) || raise(Hacienda::NotFound)
      order.tap do |loaded_order|
        order.line_items = APP.database[:order_items]
          .where(order_id: loaded_order.id)
          .order(:id)
          .all
          .map do |row|
            LineItem.new(
              pizza_id: row.fetch(:pizza_id),
              pizza_name: row.fetch(:pizza_name),
              unit_price_cents: row.fetch(:unit_price_cents),
              quantity: row.fetch(:quantity)
            )
          end
      end
    end
  end
end
