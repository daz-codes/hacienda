# frozen_string_literal: true

module Workouts
  module Index
    def self.respond(_context, _params)
      {workouts: Repository.all}
    end
  end
end
