# frozen_string_literal: true

module Posts
  module Coverable
    def attach_cover(blob)
      self.cover_key = blob.key
      self.cover_filename = blob.filename
      self.cover_content_type = blob.content_type
      self.cover_byte_size = blob.byte_size
      self
    end

    def cover?
      !cover_key.to_s.empty?
    end
  end
end
