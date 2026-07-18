# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:hacienda_jobs) do
      primary_key :id
      String :queue, null: false, default: "default"
      Integer :priority, null: false, default: 0
      String :job_class, null: false
      String :payload, text: true, null: false
      Integer :attempts, null: false, default: 0
      Integer :max_attempts, null: false, default: 10
      DateTime :available_at, null: false
      DateTime :locked_at
      String :locked_by
      String :worker_id
      String :last_error, text: true
      String :failure_kind
      DateTime :cancel_requested_at
      DateTime :cancelled_at
      DateTime :failed_at
      DateTime :completed_at
      DateTime :discarded_at
      String :unique_key
      DateTime :unique_until
      String :concurrency_key
      Integer :concurrency_limit
      DateTime :blocked_at
      String :blocked_reason
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index [:queue, :failed_at, :priority, :available_at], name: :hacienda_jobs_ready
      index :worker_id, name: :hacienda_jobs_worker
      index :unique_key, name: :hacienda_jobs_unique_key
      index :concurrency_key, name: :hacienda_jobs_concurrency_key
      index :blocked_at, name: :hacienda_jobs_blocked
    end

    create_table(:hacienda_outbox) do
      primary_key :id
      String :event_class, null: false
      String :payload, text: true, null: false
      Integer :attempts, null: false, default: 0
      Integer :max_attempts, null: false, default: 10
      DateTime :available_at, null: false
      DateTime :locked_at
      String :locked_by
      String :last_error, text: true
      String :failure_kind
      DateTime :failed_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index [:failed_at, :available_at], name: :hacienda_outbox_ready
    end

    create_table(:hacienda_job_outbox) do
      primary_key :id
      String :handoff_id, null: false, unique: true
      String :queue, null: false, default: "default"
      Integer :priority, null: false, default: 0
      String :job_class, null: false
      String :payload, text: true, null: false
      Integer :attempts, null: false, default: 0
      Integer :max_attempts, null: false, default: 10
      DateTime :available_at, null: false
      DateTime :locked_at
      String :locked_by
      String :last_error, text: true
      String :failure_kind
      DateTime :failed_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index [:failed_at, :priority, :available_at], name: :hacienda_job_outbox_ready
    end

    create_table(:hacienda_sessions) do
      String :id, primary_key: true
      String :data, text: true, null: false
      DateTime :expires_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index :expires_at, name: :hacienda_sessions_expires_at
    end

    create_table(:hacienda_job_workers) do
      String :id, primary_key: true
      Integer :process_id, null: false
      String :hostname, null: false
      String :queues, text: true, null: false
      Integer :thread_count, null: false
      Integer :batch_size, null: false
      DateTime :started_at, null: false
      DateTime :last_heartbeat_at, null: false
      Integer :current_workload, null: false, default: 0
      index :last_heartbeat_at, name: :hacienda_job_workers_heartbeat
    end

    create_table(:hacienda_job_queues) do
      String :queue, primary_key: true
      DateTime :paused_at, null: false
      String :paused_by
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end

    create_table(:hacienda_recurring_runs) do
      primary_key :id
      String :task_name, null: false
      DateTime :scheduled_at, null: false
      TrueClass :manual, null: false, default: false
      Integer :enqueued_job_id
      DateTime :created_at, null: false
      unique [:task_name, :scheduled_at], name: :hacienda_recurring_runs_unique
      index :created_at, name: :hacienda_recurring_runs_created
    end
  end
end
