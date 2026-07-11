module Auth
  module ResetPassword
    def self.respond(_context, params)
      attributes = params.permit(:token)
      payload = Hacienda.signed_token.verify(attributes[:token], purpose: "password_reset")
      user = payload && Repository.find(payload["user_id"])

      unless user && user.password_reset_version.to_i == payload["password_reset_version"].to_i
        return render(:reset_password, token: "", errors: ["Password reset link is invalid or expired."], status: 422)
      end

      {token: attributes[:token].to_s, errors: []}
    end
  end
end
