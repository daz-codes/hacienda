# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:lunula_jobs) do
      primary_key :id
      String :queue, null: false, default: "default"
      String :job_class, null: false
      String :payload, text: true, null: false
      Integer :attempts, null: false, default: 0
      Integer :max_attempts, null: false, default: 10
      DateTime :available_at, null: false
      DateTime :locked_at
      String :locked_by
      String :last_error, text: true
      DateTime :failed_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index [:queue, :failed_at, :available_at], name: :lunula_jobs_ready
    end

    create_table(:lunula_outbox) do
      primary_key :id
      String :event_class, null: false
      String :payload, text: true, null: false
      Integer :attempts, null: false, default: 0
      Integer :max_attempts, null: false, default: 10
      DateTime :available_at, null: false
      DateTime :locked_at
      String :locked_by
      String :last_error, text: true
      DateTime :failed_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index [:failed_at, :available_at], name: :lunula_outbox_ready
    end
  end
end
