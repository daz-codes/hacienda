Sequel.migration do
  change do
    alter_table(:posts) do
      add_column :cover_key, String
      add_column :cover_filename, String
      add_column :cover_content_type, String
      add_column :cover_byte_size, Integer
    end
  end
end
