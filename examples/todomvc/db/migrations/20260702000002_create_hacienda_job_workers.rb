# frozen_string_literal: true

Sequel.migration do
  change do
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
  end
end

