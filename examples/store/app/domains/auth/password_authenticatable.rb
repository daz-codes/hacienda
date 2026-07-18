# frozen_string_literal: true

require "bcrypt"

module Auth
  module PasswordAuthenticatable
    DUMMY_PASSWORD_DIGEST = "$2a$12$GEDdi5Vp3yrzDzr9JV4kM.kmreQ90Btoz.Py/9ZJdy/g5IumqMy0q"

    def self.credentials_match?(user, value, password_class: BCrypt::Password)
      digest = user&.password_digest.to_s
      digest = DUMMY_PASSWORD_DIGEST unless password_class.valid_hash?(digest)
      matches = password_class.new(digest) == value.to_s
      !!user && matches
    end

    def password=(value)
      self.password_digest = BCrypt::Password.create(value).to_s
    end

    def authenticate(value)
      BCrypt::Password.new(password_digest) == value
    rescue BCrypt::Errors::InvalidHash
      false
    end
  end
end
