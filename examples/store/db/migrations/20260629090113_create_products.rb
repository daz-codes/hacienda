# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:products) do
      primary_key :id
      String :name, null: false
      String :description, text: true, null: false, default: ""
      Integer :inventory_count, null: false, default: 0
      String :featured_image_key
      String :featured_image_filename
      String :featured_image_content_type
      Integer :featured_image_byte_size
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
  end
end
