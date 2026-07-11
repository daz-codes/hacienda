module Auth
  module CreateAccount
    def self.respond(context, params)
      attributes = params.permit(:email, :password)
      password = attributes[:password].to_s
      user = User.new(email: attributes[:email].to_s)
      user.valid?(password:)
      user.errors.add :email, "is already in use" if Repository.find_by_email(user.email)
      return render(:signup, email: user.email, errors: user.errors, status: 422) if user.errors.any?

      user.password = password
      Repository.save(user)
      Mailer.verification_email(context, user).deliver_later
      context.flash[:notice] = "Account created. Check your email to verify your account."
      redirect "/login"
    end
  end
end
