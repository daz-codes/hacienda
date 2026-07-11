# frozen_string_literal: true

require "hacienda"
require "json"

APP_ROOT = File.expand_path("..", __dir__) unless defined?(APP_ROOT)
Hacienda.root = APP_ROOT
require_relative "environment"
require_relative "database"
require_relative "cache"
require_relative "storage"
require_relative "jobs"

event_delivery = ENV.fetch("HACIENDA_EVENT_OUTBOX", Hacienda.env.production? ? "database" : "inline")
event_outbox = case event_delivery
when "database" then Hacienda::Events::Outbox.new(database: DB)
when "inline" then nil
else raise "unknown HACIENDA_EVENT_OUTBOX; use database or inline"
end

APP = Hacienda::Application.new(
  root: APP_ROOT,
  title: "Volt Workouts · Hacienda",
  reload: Hacienda.reload,
  database: DB,
  outbox: event_outbox,
  job_outbox: Hacienda.job_outbox,
  cache: Hacienda.cache,
  storage: Hacienda.storage,
  navigation: {page_attributes: {class: "page-shell"}}
)
