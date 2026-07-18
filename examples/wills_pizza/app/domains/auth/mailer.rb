# frozen_string_literal: true

require "rack/utils"

module Auth
  module Mailer
    module_function

    def verification_email(_context, user)
      token = Hacienda.signed_token.generate(
        {user_id: user.id, email: user.email},
        purpose: "email_verification",
        expires_in: 24 * 60 * 60
      )
      url = Hacienda.app_url("/verify-email?token=#{Rack::Utils.escape(token)}")

      Hacienda.mail(
        to: user.email,
        subject: "Verify your email",
        text: "Verify your email by visiting: #{url}"
      )
    end

    def password_reset_email(_context, user)
      token = Hacienda.signed_token.generate(
        {user_id: user.id, password_reset_version: user.password_reset_version},
        purpose: "password_reset",
        expires_in: 15 * 60
      )
      url = Hacienda.app_url("/password/reset?token=#{Rack::Utils.escape(token)}")

      Hacienda.mail(
        to: user.email,
        subject: "Reset your password",
        text: "Reset your password by visiting: #{url}"
      )
    end

    def magic_login_email(_context, user)
      token = Hacienda.signed_token.generate(
        {user_id: user.id, magic_login_version: user.magic_login_version},
        purpose: "magic_login",
        expires_in: 15 * 60
      )
      url = Hacienda.app_url("/magic-login/confirm?token=#{Rack::Utils.escape(token)}")

      Hacienda.mail(
        to: user.email,
        subject: "Log in to your account",
        text: "Log in by visiting: #{url}"
      )
    end
  end
end
