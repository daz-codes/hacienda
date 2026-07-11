# frozen_string_literal: true

Hacienda.env = ENV["HACIENDA_ENV"] || ENV["RACK_ENV"] || "development"

environment_config = File.join(__dir__, "environments", "#{Hacienda.env}.rb")
require environment_config if File.file?(environment_config)
