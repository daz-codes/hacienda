# frozen_string_literal: true

module Pizzas
  module Repository
    extend Lunula::Repository

    store database: APP.database, table: :pizzas, record: Pizza

    def available
      all(dataset.where(available: true).order(:name))
    end

    def all(scope = dataset.order(Sequel.desc(:available), :name))
      super(scope)
    end
  end
end
