# frozen_string_literal: true

module Auth
  class RegistrationActions < Actions
    INVALID_LINK = "Verification link is invalid or expired."

    def signup(_context, _params)
      {email: "", errors: []}
    end

    def create_account(context, params)
      attributes = params.permit(:email, :password)
      user = new_user(attributes)
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
      token = params.permit(:token)[:token].to_s
      return invalid_link unless TokenVerifier.email_verification(token)

      {token:, errors: []}
    end

    def confirm_email(context, params)
      user = TokenVerifier.email_verification(params.permit(:token)[:token])
      return invalid_link unless user

      user.verify_email
      Repository.save(user)
      sign_in(context, user, "Email verified.")
    end

    def send_verification_email(context, params)
      user = Repository.find_by_email(params.permit(:email)[:email])
      Mailer.verification_email(context, user).deliver_later if user && !user.email_verified?
      context.flash[:notice] = "If that email needs verification, we sent a link."
      redirect "/login"
    end

    private

    def new_user(attributes)
      password = attributes[:password].to_s
      user = User.new(email: attributes[:email].to_s)
      user.valid?(password:)
      user.password = password if user.errors.empty?
      user
    end

    def invalid_link
      render :verify_email, token: "", errors: [INVALID_LINK], status: 422
    end
  end
end
