# frozen_string_literal: true

module Workouts
  module ScaleUp
    def self.respond(context, params)
      workout = Repository.find(params[:id])
      success = workout.scale_up
      Repository.save(workout) if success
      finish(context, workout, success)
    end

    def self.finish(context, workout, success)
      if context.request.get_header("HTTP_ACCEPT").to_s.include?("text/vnd.turbo-stream.html")
        render(:program, workout:, status: success ? 200 : 422, layout: false)
      elsif success
        context.flash[:notice] = "Workout scaled to #{workout.scale_level}."
        redirect "/workouts/#{workout.id}"
      else
        render(:show, workout:, status: 422)
      end
    end
    private_class_method :finish
  end
end
