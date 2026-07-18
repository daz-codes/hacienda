# frozen_string_literal: true

require "lunula"

APP_ROOT = File.expand_path("..", __dir__) unless defined?(APP_ROOT)
Lunula.root = APP_ROOT
require_relative "environment"
require_relative "database"
require_relative "cache"
require_relative "storage"
require_relative "jobs"
require_relative "mail"

event_delivery = ENV.fetch("LUNULA_EVENT_OUTBOX", Lunula.env.production? ? "database" : "inline")
event_outbox = case event_delivery
when "database" then Lunula::Events::Outbox.new(database: DB)
when "inline" then nil
else raise "unknown LUNULA_EVENT_OUTBOX; use database or inline"
end

APP = Lunula::Application.new(
  root: APP_ROOT,
  title: "Lunula TodoMVC",
  reload: Lunula.reload,
  database: DB,
  outbox: event_outbox,
  job_outbox: Lunula.job_outbox,
  cache: Lunula.cache,
  storage: Lunula.storage,
  navigation: true
)
