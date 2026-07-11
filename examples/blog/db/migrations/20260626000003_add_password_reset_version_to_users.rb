# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:users) do
      add_column :password_reset_version, Integer, null: false, default: 0
    end
  end
end
