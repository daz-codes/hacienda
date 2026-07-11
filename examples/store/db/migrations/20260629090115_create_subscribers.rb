# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:subscribers) do
      primary_key :id
      foreign_key :product_id, :products, null: false, on_delete: :cascade
      String :email, null: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index [:product_id, :email], unique: true
    end
  end
end
