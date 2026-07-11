# frozen_string_literal: true

module Products
  module Index
    def self.respond(_context, _params)
      {products: Repository.all}
    end
  end
end
