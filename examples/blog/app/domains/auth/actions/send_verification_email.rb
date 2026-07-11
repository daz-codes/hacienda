module Auth
  module SendVerificationEmail
    def self.respond(context, params)
      attributes = params.permit(:email)
      user = Repository.find_by_email(attributes[:email])
      Mailer.verification_email(context, user).deliver_later if user && !user.email_verified?
      context.flash[:notice] = "If that email needs verification, we sent a link."
      redirect "/login"
    end
  end
end
