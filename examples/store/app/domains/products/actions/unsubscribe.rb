# frozen_string_literal: true

module Products
  module Unsubscribe
    def self.respond(_context, params)
      subscriber = subscriber_from(params[:token])
      render :unsubscribe,
        token: params[:token].to_s,
        subscriber:,
        errors: subscriber ? [] : ["This unsubscribe link is invalid or expired."],
        status: subscriber ? 200 : 422
    end

    def self.subscriber_from(token)
      payload = Hacienda.signed_token.verify(token, purpose: "product_unsubscribe")
      subscriber = payload && Subscribers.find(payload["subscriber_id"])
      subscriber if subscriber && subscriber.email == payload["email"]
    end
    private_class_method :subscriber_from
  end
end
