# frozen_string_literal: true

job_adapter_name = ENV.fetch(
  "LUNULA_JOB_ADAPTER",
  Lunula.env.test? ? "inline" : Lunula.env.production? ? "database" : "async"
)

job_adapter = case job_adapter_name
when "database"
  Lunula::Jobs::Adapters::Database.new(
    database: DB,
    lease_seconds: Float(ENV.fetch("LUNULA_JOB_LEASE_SECONDS", 300)),
    heartbeat_interval: ENV["LUNULA_JOB_HEARTBEAT_INTERVAL"]&.then { |value| Float(value) },
    execution_timeout: ENV["LUNULA_JOB_TIMEOUT"]&.then { |value| Float(value) },
    worker_timeout: ENV["LUNULA_JOB_WORKER_TIMEOUT"]&.then { |value| Float(value) },
    completed_retention: ENV.fetch("LUNULA_JOB_COMPLETED_RETENTION", 7 * 24 * 60 * 60),
    discarded_retention: ENV.fetch("LUNULA_JOB_DISCARDED_RETENTION", 30 * 24 * 60 * 60),
    failed_retention: ENV.fetch("LUNULA_JOB_FAILED_RETENTION", 30 * 24 * 60 * 60)
  )
else
  job_adapter_name.to_sym
end

Lunula.configure_jobs(
  adapter: job_adapter,
  outbox: Lunula::Jobs::Outbox.new(database: DB)
)
