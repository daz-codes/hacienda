# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:lunula_job_queues) do
      String :queue, primary_key: true
      DateTime :paused_at, null: false
      String :paused_by
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
  end
end
