Sequel.migration do
  change do
    create_table(:posts) do
      primary_key :id
      String :title, null: false
      String :body, text: true, null: false
      Integer :author_id, null: false
      DateTime :published_at
      DateTime :archived_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
  end
end
