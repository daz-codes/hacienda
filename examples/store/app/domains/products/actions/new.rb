# frozen_string_literal: true

module Products
  module New
    def self.respond(_context, _params)
      {product: Product.new, errors: []}
    end
  end
end
