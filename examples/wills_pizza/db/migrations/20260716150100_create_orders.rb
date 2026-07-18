# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:orders) do
      primary_key :id
      String :public_token, null: false, unique: true
      String :customer_name, null: false
      String :email, null: false
      String :delivery_address, text: true, null: false
      Integer :total_cents, null: false
      String :status, null: false, default: "received"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end

    create_table(:order_items) do
      primary_key :id
      foreign_key :order_id, :orders, null: false, on_delete: :cascade
      foreign_key :pizza_id, :pizzas, null: false
      String :pizza_name, null: false
      Integer :unit_price_cents, null: false
      Integer :quantity, null: false
    end
  end
end
