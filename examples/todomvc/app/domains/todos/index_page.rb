# frozen_string_literal: true

require "json"

module Todos
  class IndexPage
    def initialize(filter: "all", new_todo: Todo.new, editing_todo: nil, errors: [])
      @filter = filter
      @new_todo = new_todo
      @editing_todo = editing_todo
      @errors = errors
    end

    def locals
      todos = Repository.all
      {
        todos:,
        todos_json: JSON.generate(todos.map(&:to_h)),
        filter: @filter,
        new_todo: @new_todo,
        editing_todo: @editing_todo,
        errors: @errors,
        remaining_count: Repository.remaining_count,
        completed_count: Repository.completed_count
      }
    end
  end
end
