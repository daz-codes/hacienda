module Auth
  module CompleteMagicLogin
    def self.respond(context, params)
      attributes = params.permit(:token)
      payload = Hacienda.signed_token.verify(attributes[:token], purpose: "magic_login")
      user = payload && Repository.find(payload["user_id"])

      unless user&.email_verified? && user.magic_login_version.to_i == payload["magic_login_version"].to_i
        return render(:magic_login_confirm, token: "", errors: ["Login link is invalid or expired."], status: 422)
      end

      user.rotate_magic_login_version
      Repository.save(user)
      Session.login(context, user)
      context.flash[:notice] = "Logged in."
      redirect "/"
    end
  end
end
