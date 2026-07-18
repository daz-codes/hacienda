# frozen_string_literal: true

module Auth
  class User
    include Lunula::Attributes
    include Lunula::Validations
    include PasswordAuthenticatable

    attributes :id, :password_digest, :email_verified_at, :created_at, :updated_at
    attribute :email, default: ""
    attribute :password_reset_version, default: 0, cast: ->(value) { value.to_i }
    attribute :magic_login_version, default: 0, cast: ->(value) { value.to_i }

    def validate(password: nil)
      errors.add :email, "is required" if email.to_s.strip.empty?
      errors.add :password, "must be at least 12 characters" if password && password.length < 12
    end

    def email_verified?
      !!email_verified_at
    end

    def verify_email(at: Time.now)
      self.email_verified_at = at
      self
    end

    def rotate_password_reset_version
      self.password_reset_version = password_reset_version.to_i + 1
      self
    end

    def rotate_magic_login_version
      self.magic_login_version = magic_login_version.to_i + 1
      self
    end
  end
end
