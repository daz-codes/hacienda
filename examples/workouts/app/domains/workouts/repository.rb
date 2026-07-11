# frozen_string_literal: true

require "json"

module Workouts
  module Repository
    STORE = Hacienda::Store.new(
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

    module_function

    def all
      STORE.all(dataset.reverse_order(:created_at))
    end

    def find(id)
      STORE.find(id)
    end

    def save(workout)
      STORE.save(workout)
    end

    def delete(workout)
      STORE.delete(workout)
    end

    def dataset
      STORE.dataset
    end
  end
end
