# frozen_string_literal: true

module Franchises
  class Venue
    include Hacienda::Attributes
    include Hacienda::Validations

    BOOLEAN = ->(value) { value == true || %w[1 true on yes].include?(value.to_s.downcase) }

    attributes :id, :created_at, :updated_at
    attribute :name, default: ""
    attribute :slug, default: ""
    attribute :address, default: ""
    attribute :published, default: false, cast: BOOLEAN

    def validate
      errors.add :name, "is required" if name.to_s.strip.empty?
      errors.add :slug, "is required" if slug.to_s.strip.empty?
      errors.add :address, "is required" if address.to_s.strip.empty?
    end
  end
end
