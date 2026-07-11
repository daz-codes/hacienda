module Auth
  module VerifyEmail
    def self.respond(context, params)
      attributes = params.permit(:token)
      payload = Hacienda.signed_token.verify(attributes[:token], purpose: "email_verification")
      user = payload && Repository.find(payload["user_id"])

      unless user && user.email == payload["email"]
        return render(:verify_email, token: "", errors: ["Verification link is invalid or expired."], status: 422)
      end

      {token: attributes[:token].to_s, errors: []}
    end
  end
end
