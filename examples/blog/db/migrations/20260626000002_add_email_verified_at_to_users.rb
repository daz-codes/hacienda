# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:users) do
      add_column :email_verified_at, DateTime
    end
  end
end
