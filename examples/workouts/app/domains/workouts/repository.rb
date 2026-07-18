# frozen_string_literal: true

require "json"

module Workouts
  module Repository
    extend Lunula::Repository

    store(
      database: APP.database,
      table: :workouts,
      record: Workout,
      coercions: {
        generated_plan: {
          load: ->(value) { value.to_s.empty? ? nil : JSON.parse(value) },
          dump: ->(value) { value && JSON.generate(value) }
        },
        program_variants: {
          load: ->(value) { value.to_s.empty? ? {} : JSON.parse(value) },
          dump: ->(value) { JSON.generate(value || {}) }
        }
      }
    )

    def all(scope = dataset.reverse_order(:created_at))
      super(scope)
    end
  end
end
