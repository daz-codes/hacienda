# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:lunula_recurring_runs) do
      primary_key :id
      String :task_name, null: false
      DateTime :scheduled_at, null: false
      TrueClass :manual, null: false, default: false
      Integer :enqueued_job_id
      DateTime :created_at, null: false
      unique [:task_name, :scheduled_at], name: :lunula_recurring_runs_unique
      index :created_at, name: :lunula_recurring_runs_created
    end
  end
end
