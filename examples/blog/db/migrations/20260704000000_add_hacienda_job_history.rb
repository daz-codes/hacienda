# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:hacienda_jobs) do
      add_column :completed_at, DateTime
      add_column :discarded_at, DateTime
    end
  end
end
