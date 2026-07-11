module Auth
  module Logout
    def self.respond(context, _params)
      Session.logout(context)
      context.flash[:notice] = "Logged out."
      redirect "/"
    end
  end
end
