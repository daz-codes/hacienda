# frozen_string_literal: true

module Products
  module ConfirmUnsubscribe
    def self.respond(context, params)
      payload = Hacienda.signed_token.verify(params[:token], purpose: "product_unsubscribe")
      subscriber = payload && Subscribers.find(payload["subscriber_id"])
      unless subscriber && subscriber.email == payload["email"]
        return render(:unsubscribe,
          token: "",
          subscriber: nil,
          errors: ["This unsubscribe link is invalid or expired."],
          status: 422)
      end

      Subscribers.delete(subscriber)
      context.flash[:notice] = "Unsubscribed successfully."
      redirect "/"
    end
  end
end
