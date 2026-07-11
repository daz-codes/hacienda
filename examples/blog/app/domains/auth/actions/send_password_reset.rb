module Auth
  module SendPasswordReset
    def self.respond(context, params)
      attributes = params.permit(:email)
      user = Repository.find_by_email(attributes[:email])
      Mailer.password_reset_email(context, user).deliver_later if user
      context.flash[:notice] = "If that email exists, we sent a password reset link."
      redirect "/login"
    end
  end
end
