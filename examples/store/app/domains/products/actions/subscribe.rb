# frozen_string_literal: true

module Products
  module Subscribe
    def self.respond(context, params)
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
        return render(:show,
          product:,
          subscriber:,
          can_manage: !!context.current_user,
          errors: subscriber.errors,
          status: 422)
      end

      Subscribers.save(subscriber)
      context.flash[:notice] = "We will email you when #{product.name} is back in stock."
      redirect "/products/#{product.id}"
    end
  end
end
