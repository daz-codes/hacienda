# frozen_string_literal: true

module Todos
  module Repository
    extend Lunula::Repository

    store database: APP.database, table: :todos, record: Todo

    def all(scope = dataset.order(:created_at, :id))
      super(scope)
    end

    def active
      all(dataset.where(completed: false).order(:created_at, :id))
    end

    def completed
      all(dataset.where(completed: true).order(:created_at, :id))
    end

    def save(todo)
      todo.title = todo.title.to_s.strip
      super
    end

    def complete_all
      dataset.update(completed: true, updated_at: Time.now)
    end

    def activate_all
      dataset.update(completed: false, updated_at: Time.now)
    end

    def clear_completed
      dataset.where(completed: true).delete
    end

    def remaining_count
      dataset.where(completed: false).count
    end

    def completed_count
      dataset.where(completed: true).count
    end
  end
end
