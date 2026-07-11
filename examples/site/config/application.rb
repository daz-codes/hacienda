# frozen_string_literal: true

require "hacienda"

APP_ROOT = File.expand_path("..", __dir__) unless defined?(APP_ROOT)
Hacienda.root = APP_ROOT
require_relative "environment"

APP = Hacienda::Application.new(
  root: APP_ROOT,
  title: "Hacienda",
  reload: Hacienda.reload,
  navigation: {
    enabled: true,
    prefetch: :intent,
    cache_size: 30,
    cache_ttl: 30
  }
)
