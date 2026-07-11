# frozen_string_literal: true

module Workouts
  module Update
    def self.respond(context, params)
      workout = Repository.find(params[:id])
      workout.assign(attributes(params))
      return render(:edit, workout:, errors: workout.errors, status: 422) unless workout.generate

      Repository.save(workout)
      context.flash[:notice] = "Workout regenerated successfully."
      redirect "/workouts/#{workout.id}"
    end

    def self.attributes(params)
      permitted = params.require(:workout).permit(:activity, :training_notes, :intensity, :duration)
      permitted[:duration] = permitted[:duration].to_i
      permitted.transform_values { |value| value.is_a?(String) ? value.strip : value }
    end
    private_class_method :attributes
  end
end
