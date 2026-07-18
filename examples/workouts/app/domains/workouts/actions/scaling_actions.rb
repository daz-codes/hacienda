# frozen_string_literal: true

module Workouts
  class ScalingActions < Hacienda::Actions
    def scale_up(context, params)
      scale(context, params[:id], :scale_up)
    end

    def scale_down(context, params)
      scale(context, params[:id], :scale_down)
    end

    private

    def scale(context, id, operation)
      workout = Repository.find(id)
      success = workout.public_send(operation)
      Repository.save(workout) if success
      scale_response(context, workout, success)
    end

    def scale_response(context, workout, success)
      if context.request.get_header("HTTP_ACCEPT").to_s.include?("text/vnd.turbo-stream.html")
        render(:program, workout:, status: success ? 200 : 422, layout: false)
      elsif success
        context.flash[:notice] = "Workout scaled to #{workout.scale_level}."
        redirect "/workouts/#{workout.id}"
      else
        render(:show, workout:, status: 422)
      end
    end
  end
end
