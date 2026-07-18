# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:lunula_jobs) do
      add_column :unique_key, String
      add_column :unique_until, DateTime
      add_column :concurrency_key, String
      add_column :concurrency_limit, Integer
      add_column :blocked_at, DateTime
      add_column :blocked_reason, String
      add_index :unique_key, name: :lunula_jobs_unique_key
      add_index :concurrency_key, name: :lunula_jobs_concurrency_key
      add_index :blocked_at, name: :lunula_jobs_blocked
    end
  end
end
