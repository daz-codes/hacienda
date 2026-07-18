# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:pizzas) do
      primary_key :id
      String :name, null: false
      String :description, text: true, null: false, default: ""
      Integer :price_cents, null: false
      TrueClass :vegetarian, null: false, default: false
      TrueClass :available, null: false, default: true
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
  end
end
