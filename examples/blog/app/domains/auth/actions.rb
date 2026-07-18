# frozen_string_literal: true

module Auth
  class Actions < Lunula::Actions
    def login(_context, _params)
      {email: "", error: nil}
    end

    def authenticate(context, params)
      credentials = params.permit(:email, :password)
      user = Repository.find_by_email(credentials[:email])
      return sign_in(context, user, "Logged in.") if valid_credentials?(user, credentials[:password])

      render :login,
        email: credentials[:email].to_s,
        error: "Invalid email or password",
        status: 422
    end

    def logout(context, _params)
      Session.logout(context)
      context.flash[:notice] = "Logged out."
      redirect "/"
    end

    private

    def valid_credentials?(user, password)
      PasswordAuthenticatable.credentials_match?(user, password) && user.email_verified?
    end

    def sign_in(context, user, notice)
      Session.login(context, user)
      context.flash[:notice] = notice
      redirect "/"
    end
  end
end
