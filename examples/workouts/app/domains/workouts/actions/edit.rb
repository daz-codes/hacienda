# frozen_string_literal: true

module Workouts
  module Edit
    def self.respond(_context, params)
      {workout: Repository.find(params[:id]), errors: []}
    end
  end
end
