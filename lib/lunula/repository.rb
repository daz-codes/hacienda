# frozen_string_literal: true

module Lunula
  module Repository
    def self.extended(repository)
      repository.extend(repository)
    end

    def all(scope = dataset)
      repository_store.all(scope)
    end

    def first(scope = dataset)
      repository_store.first(scope)
    end

    def find(id)
      repository_store.find(id)
    end

    def find_by(**attributes)
      require_finder_attributes!(attributes)
      first(dataset.where(attributes))
    end

    def find_by!(**attributes)
      find_by(**attributes) || raise(NotFound)
    end

    def save(record)
      repository_store.save(record)
    end

    def delete(record)
      repository_store.delete(record)
    end

    def load(row)
      repository_store.load(row)
    end

    def refresh(record)
      repository_store.refresh(record)
    end

    def dataset
      repository_store.dataset
    end

    private

    def store(**configuration)
      raise Error, "repository store is already configured" if defined?(@repository_store) && @repository_store

      @repository_store = Store.new(**configuration)
    end

    def database
      repository_store.database
    end

    def repository_store
      @repository_store || raise(Error, "repository store is not configured; call store in the repository module")
    end

    def require_finder_attributes!(attributes)
      return unless attributes.empty?

      raise ArgumentError, "find_by requires at least one attribute"
    end
  end
end
