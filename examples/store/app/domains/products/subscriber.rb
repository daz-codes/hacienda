# frozen_string_literal: true

module Products
  class Subscriber
    include Lunula::Attributes
    include Lunula::Validations

    attributes :id, :product_id, :created_at, :updated_at
    attribute :email, default: ""

    def validate
      errors.add :product_id, "is required" unless product_id
      errors.add :email, "is invalid" unless email.to_s.match?(/\A[^\s@]+@[^\s@]+\z/)
    end
  end
end
