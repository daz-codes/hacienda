# frozen_string_literal: true

require_relative "lib/hacienda/version"

Gem::Specification.new do |spec|
  spec.name = "hacienda"
  spec.version = Hacienda::VERSION
  spec.authors = ["Hacienda contributors"]
  spec.summary = "A lightweight, domain-oriented Ruby web framework"
  spec.description = "Explicit Rack applications organized around business domains."
  spec.homepage = "https://github.com/hacienda-rb/hacienda"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*", "exe/*", "docs/**/*", "README.md", "LICENSE.txt"]
  spec.bindir = "exe"
  spec.executables = %w[hac fac]
  spec.require_paths = ["lib"]

  spec.add_dependency "mail", ">= 2.8", "< 3"
  spec.add_dependency "rack", ">= 3.1", "< 4"
  spec.add_dependency "rack-session", ">= 2.1", "< 3"
  spec.add_dependency "rackup", ">= 2.2", "< 3"
  spec.add_dependency "sequel", ">= 5.80", "< 6"
  spec.add_dependency "zeitwerk", ">= 2.7", "< 3"
end
