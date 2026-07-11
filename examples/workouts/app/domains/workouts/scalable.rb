# frozen_string_literal: true

module Workouts
  module Scalable
    LEVELS = %w[beginner intermediate advanced].freeze

    def scale_up
      scale_to(:up)
    end

    def scale_down
      scale_to(:down)
    end

    def can_scale_up?
      adjacent_variant(:up)
    end

    def can_scale_down?
      adjacent_variant(:down)
    end

    def variants_preloaded?
      LEVELS.all? { |level| program_variants.key?(level) }
    end

    private

    def scale_to(direction)
      target = adjacent_variant(direction)
      unless target
        errors.add :base, "This workout is already at the #{scale_level} level."
        return false
      end

      self.scale_level = target
      self.generated_plan = program_variants.fetch(target)
      true
    end

    def adjacent_variant(direction)
      offset = direction == :up ? 1 : -1
      target = LEVELS[LEVELS.index(scale_level) + offset]
      target if target && program_variants.key?(target)
    end
  end
end
