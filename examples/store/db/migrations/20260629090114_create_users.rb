Sequel.migration do
  change do
    create_table(:users) do
      primary_key :id
      String :email, null: false, unique: true
      String :password_digest, null: false
      DateTime :email_verified_at
      Integer :password_reset_version, null: false, default: 0
      Integer :magic_login_version, null: false, default: 0
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
  end
end
