# frozen_string_literal: true

module Workouts
  class << self
    attr_writer :programmer

    def programmer
      @programmer ||= ->(workout) { OpenAIProgrammer.generate(workout) }
    end

    def reset_programmer!
      @programmer = nil
    end
  end

  module Programmable
    class GenerationError < StandardError; end

    def generate(programmer: Workouts.programmer)
      return false unless valid?

      variants = programmer.call(self)
      self.program_variants = normalize_variants(variants)
      validate_variants!
      self.generated_plan = program_variants.fetch(scale_level)
      true
    rescue GenerationError, KeyError => error
      errors.add :base, error.message
      false
    end

    private

    def normalize_variants(variants)
      variants.transform_keys(&:to_s).each_value do |plan|
        main_set = plan.fetch("main_set")
        main_set["format"] = nil if main_set["format"].to_s.match?(/\Amain[\s_-]*set\z/i)
        main_set["sections"] = main_set.fetch("sections").select do |section|
          section.fetch("duration_minutes").to_i.positive?
        end
      end
    end

    def validate_variants!
      Scalable::LEVELS.each do |level|
        plan = program_variants.fetch(level)
        main_set = plan.fetch("main_set")
        section_minutes = main_set.fetch("sections").sum do |section|
          section.fetch("duration_minutes").to_i
        end

        next if section_minutes == main_set.fetch("total_minutes").to_i

        raise GenerationError, "The generated workout timing did not add up. Please try again."
      end
    rescue KeyError
      raise GenerationError, "The model returned an incomplete workout. Please try again."
    end
  end
end
