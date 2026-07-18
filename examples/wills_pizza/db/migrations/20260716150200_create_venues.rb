# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:venues) do
      primary_key :id
      String :name, null: false
      String :slug, null: false, unique: true
      String :address, text: true, null: false
      TrueClass :published, null: false, default: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
  end
end
