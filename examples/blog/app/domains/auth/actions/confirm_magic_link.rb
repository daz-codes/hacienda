module Auth
  module ConfirmMagicLink
    def self.respond(_context, params)
      attributes = params.permit(:token)
      payload = Hacienda.signed_token.verify(attributes[:token], purpose: "magic_login")
      user = payload && Repository.find(payload["user_id"])

      unless user&.email_verified? && user.magic_login_version.to_i == payload["magic_login_version"].to_i
        return render(:magic_login_confirm, token: "", errors: ["Login link is invalid or expired."], status: 422)
      end

      {token: attributes[:token].to_s, errors: []}
    end
  end
end
