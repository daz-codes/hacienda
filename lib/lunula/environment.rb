# frozen_string_literal: true

module Lunula
  class Environment
    attr_reader :name

    def initialize(name)
      @name = name.to_s.strip.empty? ? "development" : name.to_s
    end

    def development?
      name == "development"
    end

    def test?
      name == "test"
    end

    def production?
      name == "production"
    end

    def to_s
      name
    end

    def inspect
      "#<Lunula::Environment #{name}>"
    end
  end
end
