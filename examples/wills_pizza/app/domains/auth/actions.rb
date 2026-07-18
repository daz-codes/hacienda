# frozen_string_literal: true

module Auth
  class Actions < Hacienda::Actions
    def login(_context, _params)
      {email: "", error: nil}
    end

    def authenticate(context, params)
      credentials = params.permit(:email, :password)
      user = Repository.find_by_email(credentials[:email])

      if PasswordAuthenticatable.credentials_match?(user, credentials[:password]) && user.email_verified?
        Session.login(context, user)
        context.flash[:notice] = "Logged in."
        redirect "/"
      else
        render :login,
          email: credentials[:email].to_s,
          error: "Invalid email or password",
          status: 422
      end
    end

    def magic_login(_context, _params)
      {email: ""}
    end

    def send_magic_link(context, params)
      attributes = params.permit(:email)
      user = Repository.find_by_email(attributes[:email])

      if user&.email_verified?
        user.rotate_magic_login_version
        Repository.save(user)
        Mailer.magic_login_email(context, user).deliver_later
      end

      context.flash[:notice] = "If that email can sign in, we sent a login link."
      redirect "/login"
    end

    def confirm_magic_link(_context, params)
      attributes = params.permit(:token)
      unless TokenVerifier.magic_login(attributes[:token])
        return render(:magic_login_confirm, token: "", errors: ["Login link is invalid or expired."], status: 422)
      end

      render :magic_login_confirm, token: attributes[:token].to_s, errors: []
    end

    def complete_magic_login(context, params)
      attributes = params.permit(:token)
      user = TokenVerifier.magic_login(attributes[:token])
      unless user
        return render(:magic_login_confirm, token: "", errors: ["Login link is invalid or expired."], status: 422)
      end

      user.rotate_magic_login_version
      Repository.save(user)
      Session.login(context, user)
      context.flash[:notice] = "Logged in."
      redirect "/"
    end

    def signup(_context, _params)
      {email: "", errors: []}
    end

    def create_account(context, params)
      attributes = params.permit(:email, :password)
      password = attributes[:password].to_s
      user = User.new(email: attributes[:email].to_s)
      user.valid?(password:)
      user.password = password if user.errors.empty?
      return render(:signup, email: user.email, errors: user.errors, status: 422) if user.errors.any?

      existing = Repository.find_by_email(user.email)
      if existing
        Mailer.verification_email(context, existing).deliver_later unless existing.email_verified?
      else
        Repository.save(user)
        Mailer.verification_email(context, user).deliver_later
      end
      context.flash[:notice] = "If that email can be registered, we sent account instructions."
      redirect "/login"
    end

    def verify_email(_context, params)
      attributes = params.permit(:token)
      unless TokenVerifier.email_verification(attributes[:token])
        return render(:verify_email, token: "", errors: ["Verification link is invalid or expired."], status: 422)
      end

      {token: attributes[:token].to_s, errors: []}
    end

    def confirm_email(context, params)
      attributes = params.permit(:token)
      user = TokenVerifier.email_verification(attributes[:token])
      unless user
        return render(:verify_email, token: "", errors: ["Verification link is invalid or expired."], status: 422)
      end

      user.verify_email
      Repository.save(user)
      Session.login(context, user)
      context.flash[:notice] = "Email verified."
      redirect "/"
    end

    def send_verification_email(context, params)
      attributes = params.permit(:email)
      user = Repository.find_by_email(attributes[:email])
      Mailer.verification_email(context, user).deliver_later if user && !user.email_verified?
      context.flash[:notice] = "If that email needs verification, we sent a link."
      redirect "/login"
    end

    def forgot_password(_context, _params)
      {email: ""}
    end

    def send_password_reset(context, params)
      attributes = params.permit(:email)
      user = Repository.find_by_email(attributes[:email])
      Mailer.password_reset_email(context, user).deliver_later if user
      context.flash[:notice] = "If that email exists, we sent a password reset link."
      redirect "/login"
    end

    def reset_password(_context, params)
      attributes = params.permit(:token)
      unless TokenVerifier.password_reset(attributes[:token])
        return render(:reset_password, token: "", errors: ["Password reset link is invalid or expired."], status: 422)
      end

      {token: attributes[:token].to_s, errors: []}
    end

    def update_password(context, params)
      attributes = params.permit(:token, :password)
      user = TokenVerifier.password_reset(attributes[:token])
      unless user
        return render(:reset_password, token: "", errors: ["Password reset link is invalid or expired."], status: 422)
      end

      password = attributes[:password].to_s
      return render(:reset_password, token: attributes[:token].to_s, errors: user.errors, status: 422) if user.invalid?(password:)

      user.password = password
      user.rotate_password_reset_version
      Repository.save(user)
      Session.login(context, user)
      context.flash[:notice] = "Password updated."
      redirect "/"
    end

    def logout(context, _params)
      Session.logout(context)
      context.flash[:notice] = "Logged out."
      redirect "/"
    end
  end
end
