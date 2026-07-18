# frozen_string_literal: true

require "lunula"

APP_ROOT = File.expand_path("..", __dir__) unless defined?(APP_ROOT)
Lunula.root = APP_ROOT
require_relative "environment"

APP = Lunula::Application.new(
  root: APP_ROOT,
  title: "Lunula",
  reload: Lunula.reload,
  navigation: {
    enabled: true,
    prefetch: :intent,
    cache_size: 30,
    cache_ttl: 30
  }
)
