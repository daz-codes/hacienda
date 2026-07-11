module Auth
  module UpdatePassword
    def self.respond(context, params)
      attributes = params.permit(:token, :password)
      payload = Hacienda.signed_token.verify(attributes[:token], purpose: "password_reset")
      user = payload && Repository.find(payload["user_id"])

      unless user && user.password_reset_version.to_i == payload["password_reset_version"].to_i
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
  end
end
