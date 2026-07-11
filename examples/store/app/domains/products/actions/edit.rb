# frozen_string_literal: true

module Products
  module Edit
    def self.respond(_context, params)
      {product: Repository.find(params[:id]), errors: []}
    end
  end
end
