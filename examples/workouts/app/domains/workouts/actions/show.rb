# frozen_string_literal: true

module Workouts
  module Show
    def self.respond(_context, params)
      {workout: Repository.find(params[:id])}
    end
  end
end
