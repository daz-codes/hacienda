# frozen_string_literal: true

module Workouts
  module Destroy
    def self.respond(context, params)
      Repository.delete(Repository.find(params[:id]))
      context.flash[:notice] = "Workout deleted."
      redirect "/workouts"
    end
  end
end
