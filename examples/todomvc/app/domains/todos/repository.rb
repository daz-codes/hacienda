# frozen_string_literal: true

module Todos
  module Repository
    STORE = Hacienda::Store.new(database: APP.database, table: :todos, record: Todo)

    module_function

    def all
      STORE.all(dataset.order(:created_at, :id))
    end

    def active
      STORE.all(dataset.where(completed: false).order(:created_at, :id))
    end

    def completed
      STORE.all(dataset.where(completed: true).order(:created_at, :id))
    end

    def find(id)
      STORE.find(id)
    end

    def save(todo)
      todo.title = todo.title.to_s.strip
      STORE.save(todo)
    end

    def delete(todo)
      STORE.delete(todo)
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

    def dataset
      STORE.dataset
    end
  end
end
