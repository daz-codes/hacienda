# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:hacienda_jobs) do
      add_column :worker_id, String
      add_column :failure_kind, String
      add_column :cancel_requested_at, DateTime
      add_column :cancelled_at, DateTime
      add_index :worker_id, name: :hacienda_jobs_worker
    end

    alter_table(:hacienda_outbox) do
      add_column :failure_kind, String
    end

    alter_table(:hacienda_job_outbox) do
      add_column :failure_kind, String
    end
  end
end

