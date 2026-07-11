# frozen_string_literal: true

module Posts
  class Post
    include Hacienda::Attributes
    include Hacienda::Validations
    include Publishable
    include Archivable
    include Coverable

    attributes :id, :author_id, :published_at, :archived_at, :created_at, :updated_at,
      :cover_key, :cover_filename, :cover_content_type, :cover_byte_size
    attribute :title, default: ""
    attribute :body, default: ""
    attr_accessor :comments

    def validate
      errors.add :title, "is required" if title.to_s.strip.empty?
      errors.add :body, "is required" if body.to_s.strip.empty?
    end
  end
end
