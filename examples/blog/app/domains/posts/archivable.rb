# frozen_string_literal: true

module Posts
  module Archivable
    def archive(at: Time.now)
      self.archived_at = at
      self
    end

    def restore
      self.archived_at = nil
      self
    end

    def archived?
      !archived_at.nil?
    end
  end
end
