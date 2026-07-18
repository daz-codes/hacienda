# frozen_string_literal: true

module Workouts
  class Actions < Lunula::Actions
    def index(_context, _params)
      {workouts: Repository.all}
    end

    def show(_context, params)
      {workout: Repository.find(params[:id])}
    end

    def new(_context, _params)
      {workout: Workout.new, errors: []}
    end

    def create(context, params)
      workout = Workout.new(**workout_attributes(params))
      return render(:new, workout:, errors: workout.errors, status: 422) unless workout.generate

      Repository.save(workout)
      context.flash[:notice] = "Workout generated successfully."
      redirect "/workouts/#{workout.id}"
    end

    def edit(_context, params)
      {workout: Repository.find(params[:id]), errors: []}
    end

    def update(context, params)
      workout = Repository.find(params[:id])
      workout.assign(workout_attributes(params))
      return render(:edit, workout:, errors: workout.errors, status: 422) unless workout.generate

      Repository.save(workout)
      context.flash[:notice] = "Workout regenerated successfully."
      redirect "/workouts/#{workout.id}"
    end

    def destroy(context, params)
      Repository.delete(Repository.find(params[:id]))
      context.flash[:notice] = "Workout deleted."
      redirect "/workouts"
    end

    private

    def workout_attributes(params)
      permitted = params.require(:workout).permit(:activity, :training_notes, :intensity, :duration)
      permitted[:duration] = permitted[:duration].to_i
      permitted.transform_values { |value| value.is_a?(String) ? value.strip : value }
    end
  end
end
