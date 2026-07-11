# frozen_string_literal: true

module Workouts
  class Workout
    include Hacienda::Attributes
    include Hacienda::Validations
    include Programmable
    include Scalable

    INTENSITIES = %w[low moderate high maximum].freeze

    attributes :id, :generated_plan, :created_at, :updated_at
    attribute :activity, default: ""
    attribute :training_notes, default: ""
    attribute :intensity, default: "high"
    attribute :duration, default: 60, cast: ->(value) { value.to_i }
    attribute :scale_level, default: "intermediate"
    attribute :program_variants, default: -> { {} }

    def validate
      errors.add :activity, "is required" if activity.to_s.strip.empty?
      errors.add :intensity, "is not supported" unless INTENSITIES.include?(intensity)
      errors.add :duration, "must be between 20 and 120 minutes" unless duration.to_i.between?(20, 120)
      errors.add :scale_level, "is not supported" unless Scalable::LEVELS.include?(scale_level)
    end

  end
end
