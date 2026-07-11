# frozen_string_literal: true

module Comments
  class Comment
    include Hacienda::Attributes
    include Hacienda::Validations

    attributes :id, :post_id, :created_at, :updated_at
    attribute :author_name, default: ""
    attribute :body, default: ""

    def validate
      errors.add :author_name, "is required" if author_name.to_s.strip.empty?
      errors.add :body, "is required" if body.to_s.strip.empty?
    end
  end
end
