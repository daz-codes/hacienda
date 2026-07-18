# frozen_string_literal: true

module Products
  module Repository
    extend Lunula::Repository

    store(
      database: APP.database,
      table: :products,
      record: Product
    )

    def all(scope = dataset.order(:name))
      super(scope)
    end
  end
end
