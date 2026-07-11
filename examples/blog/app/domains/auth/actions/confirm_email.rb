module Auth
  module ConfirmEmail
    def self.respond(context, params)
      attributes = params.permit(:token)
      payload = Hacienda.signed_token.verify(attributes[:token], purpose: "email_verification")
      user = payload && Repository.find(payload["user_id"])

      unless user && user.email == payload["email"]
        return render(:verify_email, token: "", errors: ["Verification link is invalid or expired."], status: 422)
      end

      user.verify_email
      Repository.save(user)
      Session.login(context, user)
      context.flash[:notice] = "Email verified."
      redirect "/"
    end
  end
end
