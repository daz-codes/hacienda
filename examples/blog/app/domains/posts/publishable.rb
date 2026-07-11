# frozen_string_literal: true

module Posts
  module Publishable
    def publish(at: Time.now)
      raise "Archived posts cannot be published" if archived?

      self.published_at = at
      self
    end

    def unpublish
      self.published_at = nil
      self
    end

    def published?
      !published_at.nil?
    end
  end
end
