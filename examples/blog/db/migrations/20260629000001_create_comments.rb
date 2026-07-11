Sequel.migration do
  change do
    create_table(:comments) do
      primary_key :id
      foreign_key :post_id, :posts, null: false, on_delete: :cascade
      String :author_name, null: false
      String :body, text: true, null: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :post_id
    end
  end
end
