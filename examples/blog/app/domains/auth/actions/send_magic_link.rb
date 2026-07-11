module Auth
  module SendMagicLink
    def self.respond(context, params)
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
  end
end
