# frozen_string_literal: true

module Products
  class SubscriptionActions < Actions
    def subscribe(context, params)
      product = Repository.find(params[:id])
      if product.in_stock?
        context.flash[:notice] = "This product is already in stock."
        return redirect "/products/#{product.id}"
      end

      email = params.permit(:email)[:email].to_s
      subscriber = Subscriber.new(product_id: product.id, email:)
      subscriber.valid?
      subscriber.errors.add(:email, "is already subscribed") if Subscribers.find_by_email(product, email)
      if subscriber.errors.any?
        return render(:show, **product_page(context, product, subscriber:, errors: subscriber.errors), status: 422)
      end

      Subscribers.save(subscriber)
      context.flash[:notice] = "We will email you when #{product.name} is back in stock."
      redirect "/products/#{product.id}"
    end

    def unsubscribe(_context, params)
      subscriber = subscriber_from(params[:token])
      render :unsubscribe,
        token: params[:token].to_s,
        subscriber:,
        errors: subscriber ? [] : ["This unsubscribe link is invalid or expired."],
        status: subscriber ? 200 : 422
    end

    def confirm_unsubscribe(context, params)
      subscriber = subscriber_from(params[:token])
      unless subscriber
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

    private

    def subscriber_from(token)
      payload = Lunula.signed_token.verify(token, purpose: "product_unsubscribe")
      subscriber = payload && Subscribers.find_by(id: payload["subscriber_id"])
      subscriber if subscriber && subscriber.email == payload["email"]
    end
  end
end
