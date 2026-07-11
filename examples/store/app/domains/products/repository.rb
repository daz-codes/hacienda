# frozen_string_literal: true

module Products
  module Repository
    STORE = Hacienda::Store.new(
      database: APP.database,
      table: :products,
      record: Product
    )

    module_function

    def all
      STORE.all(dataset.order(:name))
    end

    def find(id)
      STORE.find(id)
    end

    def save(record)
      STORE.save(record)
    end

    def delete(record)
      STORE.delete(record)
    end

    def dataset
      STORE.dataset
    end
  end
end
