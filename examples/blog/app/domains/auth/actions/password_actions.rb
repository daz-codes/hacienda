# frozen_string_literal: true

module Auth
  class PasswordActions < Actions
    INVALID_LINK = "Password reset link is invalid or expired."

    def forgot_password(_context, _params)
      {email: ""}
    end

    def send_password_reset(context, params)
      user = Repository.find_by_email(params.permit(:email)[:email])
      Mailer.password_reset_email(context, user).deliver_later if user
      context.flash[:notice] = "If that email exists, we sent a password reset link."
      redirect "/login"
    end

    def reset_password(_context, params)
      token = params.permit(:token)[:token].to_s
      return invalid_link unless TokenVerifier.password_reset(token)

      {token:, errors: []}
    end

    def update_password(context, params)
      attributes = params.permit(:token, :password)
      user = TokenVerifier.password_reset(attributes[:token])
      return invalid_link unless user

      password = attributes[:password].to_s
      return invalid_password(attributes[:token], user) if user.invalid?(password:)

      user.password = password
      user.rotate_password_reset_version
      Repository.save(user)
      sign_in(context, user, "Password updated.")
    end

    private

    def invalid_link
      render :reset_password, token: "", errors: [INVALID_LINK], status: 422
    end

    def invalid_password(token, user)
      render :reset_password, token: token.to_s, errors: user.errors, status: 422
    end
  end
end
