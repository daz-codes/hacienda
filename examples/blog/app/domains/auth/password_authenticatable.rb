# frozen_string_literal: true

require "bcrypt"

module Auth
  module PasswordAuthenticatable
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
