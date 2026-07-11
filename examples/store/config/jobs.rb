# frozen_string_literal: true

job_adapter_name = ENV.fetch(
  "HACIENDA_JOB_ADAPTER",
  Hacienda.env.test? ? "inline" : Hacienda.env.production? ? "database" : "async"
)

job_adapter = case job_adapter_name
when "database"
  Hacienda::Jobs::Adapters::Database.new(
    database: DB,
    lease_seconds: Float(ENV.fetch("HACIENDA_JOB_LEASE_SECONDS", 300)),
    heartbeat_interval: ENV["HACIENDA_JOB_HEARTBEAT_INTERVAL"]&.then { |value| Float(value) },
    execution_timeout: ENV["HACIENDA_JOB_TIMEOUT"]&.then { |value| Float(value) },
    worker_timeout: ENV["HACIENDA_JOB_WORKER_TIMEOUT"]&.then { |value| Float(value) }
  )
else
  job_adapter_name.to_sym
end

Hacienda.configure_jobs(
  adapter: job_adapter,
  outbox: Hacienda::Jobs::Outbox.new(database: DB)
)
