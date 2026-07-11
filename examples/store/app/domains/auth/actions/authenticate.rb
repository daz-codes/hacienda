module Auth
  module Authenticate
    def self.respond(context, params)
      credentials = params.permit(:email, :password)
      user = Repository.find_by_email(credentials[:email])

      if user&.authenticate(credentials[:password].to_s) && user.email_verified?
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
  end
end
