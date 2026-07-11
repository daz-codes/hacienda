# frozen_string_literal: true

module Todos
  class Todo
    include Hacienda::Attributes
    include Hacienda::Validations

    attributes :id, :created_at, :updated_at
    attribute :title, default: ""
    attribute :completed, default: false

    def complete
      self.completed = true
      self
    end

    def activate
      self.completed = false
      self
    end

    def toggle
      completed ? activate : complete
    end

    def completed?
      !!completed
    end

    def validate
      errors.add :title, "is required" if title.to_s.strip.empty?
    end

    def to_h
      {
        id: id,
        title: title,
        completed: completed?
      }
    end
  end
end
