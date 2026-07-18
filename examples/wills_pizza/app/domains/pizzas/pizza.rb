# frozen_string_literal: true

module Pizzas
  class Pizza
    include Hacienda::Attributes
    include Hacienda::Validations

    BOOLEAN = ->(value) { value == true || %w[1 true on yes].include?(value.to_s.downcase) }

    attributes :id, :created_at, :updated_at
    attribute :name, default: ""
    attribute :description, default: ""
    attribute :price_cents,
      default: 0,
      cast: ->(value) { value.to_s.empty? ? 0 : Integer(value, exception: false) }
    attribute :vegetarian, default: false, cast: BOOLEAN
    attribute :available, default: true, cast: BOOLEAN

    def validate
      errors.add :name, "is required" if name.to_s.strip.empty?
      errors.add :description, "is required" if description.to_s.strip.empty?
      unless price_cents.is_a?(Integer) && price_cents.positive?
        errors.add :price, "must be greater than zero"
      end
    end

    def price
      format("%.2f", price_cents.to_i / 100.0)
    end
  end
end
