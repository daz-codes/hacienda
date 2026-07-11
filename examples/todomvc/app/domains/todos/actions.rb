# frozen_string_literal: true

require "json"

module Todos
  module Index
    def self.respond(context, _params)
      path = context.path
      filter = path == "/active" ? "active" : path == "/completed" ? "completed" : "all"
      todos = Repository.all

      {
        todos: todos,
        todos_json: JSON.generate(todos.map(&:to_h)),
        filter: filter,
        new_todo: Todo.new,
        errors: [],
        remaining_count: Repository.remaining_count,
        completed_count: Repository.completed_count
      }
    end
  end

  module Create
    def self.respond(context, params)
      attributes = params.permit(:title)
      todo = Todo.new(title: attributes[:title].to_s)
      return render_index(context, todo, todo.errors) if todo.invalid?

      Repository.save(todo)
      context.flash[:notice] = "Todo added."
      redirect "/"
    end

    def self.render_index(context, todo, errors)
      todos = Repository.all
      render :index,
        todos: todos,
        todos_json: JSON.generate(todos.map(&:to_h)),
        filter: "all",
        new_todo: todo,
        errors: errors,
        remaining_count: Repository.remaining_count,
        completed_count: Repository.completed_count,
        status: 422
    end
  end

  module Toggle
    def self.respond(context, params)
      todo = Repository.find(params[:id])
      todo.toggle
      Repository.save(todo)

      context.flash[:notice] = todo.completed? ? "Todo completed." : "Todo reactivated."
      redirect context.request.referer || "/"
    end
  end

  module ToggleAll
    def self.respond(context, _params)
      if Repository.remaining_count.zero?
        Repository.activate_all
        context.flash[:notice] = "All todos are active."
      else
        Repository.complete_all
        context.flash[:notice] = "All todos are complete."
      end

      redirect context.request.referer || "/"
    end
  end

  module UpdateTitle
    def self.respond(context, params)
      todo = Repository.find(params[:id])
      attributes = params.permit(:title)
      todo.title = attributes[:title].to_s
      return render_index(context, todo, todo.errors) if todo.invalid?

      Repository.save(todo)
      context.flash[:notice] = "Todo renamed."
      redirect context.request.referer || "/"
    end

    def self.render_index(_context, todo, errors)
      todos = Repository.all
      render :index,
        todos: todos,
        todos_json: JSON.generate(todos.map(&:to_h)),
        filter: "all",
        new_todo: Todo.new,
        editing_todo: todo,
        errors: errors,
        remaining_count: Repository.remaining_count,
        completed_count: Repository.completed_count,
        status: 422
    end
  end

  module Destroy
    def self.respond(context, params)
      Repository.delete(Repository.find(params[:id]))
      context.flash[:notice] = "Todo deleted."
      redirect context.request.referer || "/"
    end
  end

  module ClearCompleted
    def self.respond(context, _params)
      count = Repository.clear_completed
      context.flash[:notice] = "#{count} completed #{count == 1 ? "todo" : "todos"} cleared."
      redirect "/"
    end
  end
end
