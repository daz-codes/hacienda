# frozen_string_literal: true

module Products
  class FeaturedImageUpload
    CONTENT_TYPES = %w[image/jpeg image/png image/webp image/avif].freeze
    CONTENT_INSPECTOR = Hacienda::Storage::ContentTypeInspector.new

    def initialize(storage:, upload:, product:)
      @storage = storage
      @upload = upload
      @product = product
    end

    def attach
      return self unless Hacienda::Storage::Upload.present?(@upload)

      @blob = @storage.store(
        @upload,
        prefix: "product-images",
        max_bytes: 5 * 1024 * 1024,
        content_types: CONTENT_TYPES,
        content_inspector: CONTENT_INSPECTOR
      )
      @product.attach_featured_image(@blob)
      self
    rescue Hacienda::Storage::InvalidUpload => error
      @product.errors.add(:featured_image, error.message)
      self
    end

    def persist
      yield
    rescue StandardError
      @storage.delete(@blob.key) if @blob
      raise
    end

    def delete_replaced(key)
      @storage.delete(key) if @blob && key
    end
  end
end
