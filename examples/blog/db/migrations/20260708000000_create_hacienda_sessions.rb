Sequel.migration do
  change do
    create_table(:hacienda_sessions) do
      String :id, primary_key: true
      String :data, text: true, null: false
      DateTime :expires_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index :expires_at, name: :hacienda_sessions_expires_at
    end
  end
end
