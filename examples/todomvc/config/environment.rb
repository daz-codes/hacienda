# frozen_string_literal: true

Lunula.env = ENV["LUNULA_ENV"] || ENV["RACK_ENV"] || "development"

environment_config = File.join(__dir__, "environments", "#{Lunula.env}.rb")
require environment_config if File.file?(environment_config)
