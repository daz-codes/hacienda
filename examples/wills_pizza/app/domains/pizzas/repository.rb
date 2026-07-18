# frozen_string_literal: true

module Pizzas
  module Repository
    STORE = Hacienda::Store.new(database: APP.database, table: :pizzas, record: Pizza)

    module_function

    def available
      STORE.all(dataset.where(available: true).order(:name))
    end

    def all
      STORE.all(dataset.order(Sequel.desc(:available), :name))
    end

    def find(id)
      STORE.find(id)
    end

    def save(pizza)
      STORE.save(pizza)
    end

    def dataset
      STORE.dataset
    end
  end
end
