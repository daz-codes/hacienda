# frozen_string_literal: true

module Products
  module Events
    Restocked = Data.define(:product_id, :occurred_at)
  end
end
