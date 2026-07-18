# frozen_string_literal: true

module Todos
  class CompletionActions < Actions
    def toggle(context, params)
      todo = Repository.find(params[:id])
      todo.toggle
      Repository.save(todo)
      context.flash[:notice] = todo.completed? ? "Todo completed." : "Todo reactivated."
      redirect_back(context)
    end

    def toggle_all(context, _params)
      message = if Repository.remaining_count.zero?
        Repository.activate_all
        "All todos are active."
      else
        Repository.complete_all
        "All todos are complete."
      end
      context.flash[:notice] = message
      redirect_back(context)
    end

    def clear_completed(context, _params)
      count = Repository.clear_completed
      noun = count == 1 ? "todo" : "todos"
      context.flash[:notice] = "#{count} completed #{noun} cleared."
      redirect "/"
    end
  end
end
