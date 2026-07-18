# frozen_string_literal: true

module Posts
  class CoverUpload
    CONTENT_TYPES = %w[image/jpeg image/png image/webp image/avif].freeze
    CONTENT_INSPECTOR = Hacienda::Storage::ContentTypeInspector.new

    def initialize(storage:, upload:, post:)
      @storage = storage
      @upload = upload
      @post = post
    end

    def attach
      return self unless Hacienda::Storage::Upload.present?(@upload)

      @blob = @storage.store(
        @upload,
        prefix: "post-covers",
        max_bytes: 5 * 1024 * 1024,
        content_types: CONTENT_TYPES,
        content_inspector: CONTENT_INSPECTOR
      )
      @post.attach_cover(@blob)
      self
    rescue Hacienda::Storage::InvalidUpload => error
      @post.errors.add(:cover, error.message)
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
