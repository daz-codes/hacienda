# frozen_string_literal: true

module Auth
  class MagicLoginActions < Actions
    INVALID_LINK = "Login link is invalid or expired."

    def magic_login(_context, _params)
      {email: ""}
    end

    def send_magic_link(context, params)
      user = Repository.find_by_email(params.permit(:email)[:email])
      send_link(context, user) if user&.email_verified?
      context.flash[:notice] = "If that email can sign in, we sent a login link."
      redirect "/login"
    end

    def confirm_magic_link(_context, params)
      token = params.permit(:token)[:token].to_s
      return invalid_link unless TokenVerifier.magic_login(token)

      render :magic_login_confirm, token:, errors: []
    end

    def complete_magic_login(context, params)
      user = TokenVerifier.magic_login(params.permit(:token)[:token])
      return invalid_link unless user

      user.rotate_magic_login_version
      Repository.save(user)
      sign_in(context, user, "Logged in.")
    end

    private

    def send_link(context, user)
      user.rotate_magic_login_version
      Repository.save(user)
      Mailer.magic_login_email(context, user).deliver_later
    end

    def invalid_link
      render :magic_login_confirm, token: "", errors: [INVALID_LINK], status: 422
    end
  end
end
