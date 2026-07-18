# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:lunula_jobs) do
      add_column :priority, Integer, null: false, default: 0
      add_index [:queue, :failed_at, :priority, :available_at],
        name: :lunula_jobs_priority_ready
    end

    alter_table(:lunula_job_outbox) do
      add_column :priority, Integer, null: false, default: 0
      add_index [:failed_at, :priority, :available_at],
        name: :lunula_job_outbox_priority_ready
    end
  end
end

