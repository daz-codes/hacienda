# frozen_string_literal: true

module Todos
  class Actions < Hacienda::Actions
    def index(context, _params)
      IndexPage.new(filter: filter_for(context.path)).locals
    end

    def create(context, params)
      todo = Todo.new(title: params.permit(:title)[:title].to_s)
      return render_index(new_todo: todo, errors: todo.errors) if todo.invalid?

      Repository.save(todo)
      context.flash[:notice] = "Todo added."
      redirect "/"
    end

    def update_title(context, params)
      todo = Repository.find(params[:id])
      todo.title = params.permit(:title)[:title].to_s
      return render_index(editing_todo: todo, errors: todo.errors) if todo.invalid?

      Repository.save(todo)
      context.flash[:notice] = "Todo renamed."
      redirect_back(context)
    end

    def destroy(context, params)
      Repository.delete(Repository.find(params[:id]))
      context.flash[:notice] = "Todo deleted."
      redirect_back(context)
    end

    private

    def filter_for(path)
      return "active" if path == "/active"
      return "completed" if path == "/completed"

      "all"
    end

    def render_index(**locals)
      render :index, **IndexPage.new(**locals).locals, status: 422
    end

    def redirect_back(context)
      redirect context.request.referer || "/"
    end
  end
end
