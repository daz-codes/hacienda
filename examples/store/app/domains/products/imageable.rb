# frozen_string_literal: true

module Products
  module Imageable
    def attach_featured_image(blob)
      self.featured_image_key = blob.key
      self.featured_image_filename = blob.filename
      self.featured_image_content_type = blob.content_type
      self.featured_image_byte_size = blob.byte_size
      self
    end

    def featured_image?
      !featured_image_key.to_s.empty?
    end
  end
end
