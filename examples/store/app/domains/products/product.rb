# frozen_string_literal: true

module Products
  class Product
    include Lunula::Attributes
    include Lunula::Validations
    include Imageable
    include InventoryNotifications

    attributes :id, :created_at, :updated_at
    attributes :featured_image_key, :featured_image_filename,
      :featured_image_content_type, :featured_image_byte_size
    attribute :name, default: ""
    attribute :description, default: ""
    attribute :inventory_count,
      default: 0,
      cast: ->(value) { value.to_s.empty? ? 0 : Integer(value, exception: false) }

    def validate
      errors.add :name, "is required" if name.to_s.strip.empty?
      if !inventory_count.is_a?(Integer)
        errors.add :inventory_count, "must be a whole number"
      elsif inventory_count.negative?
        errors.add :inventory_count, "must be zero or greater"
      end
    end

    def cache_key
      version = updated_at&.utc&.strftime("%Y%m%d%H%M%S%6N") || "new"
      "products/#{id || "new"}-#{version}"
    end
  end
end
