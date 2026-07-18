# frozen_string_literal: true

module Auth
  module TokenVerifier
    module_function

    def magic_login(token)
      verified_user(token, purpose: "magic_login") do |user, payload|
        user.email_verified? && user.magic_login_version.to_i == payload["magic_login_version"].to_i
      end
    end

    def email_verification(token)
      verified_user(token, purpose: "email_verification") do |user, payload|
        !user.email_verified? && user.email == payload["email"]
      end
    end

    def password_reset(token)
      verified_user(token, purpose: "password_reset") do |user, payload|
        user.password_reset_version.to_i == payload["password_reset_version"].to_i
      end
    end

    def verified_user(token, purpose:)
      payload = Lunula.signed_token.verify(token, purpose:)
      user = payload && Repository.find_by(id: payload["user_id"])
      user if user && yield(user, payload)
    end
    private_class_method :verified_user
  end
end
