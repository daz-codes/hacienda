# frozen_string_literal: true

module Workouts
  module New
    def self.respond(_context, _params)
      {workout: Workout.new, errors: []}
    end
  end
end
