# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:todos) do
      primary_key :id
      String :title, null: false
      TrueClass :completed, null: false, default: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
  end
end
