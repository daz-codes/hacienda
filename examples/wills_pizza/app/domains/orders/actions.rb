# frozen_string_literal: true

module Orders
  class Actions < Lunula::Actions
    def new(_context, _params)
      checkout_page
    end

    def create(context, params)
      menu = Pizzas::Repository.available
      checkout = Checkout.new(
        menu:,
        attributes: params.permit(:customer_name, :email, :delivery_address),
        quantities: params[:quantities]
      )
      return render(:new, **checkout_page(menu:, order: checkout.order), status: 422) unless checkout.valid?

      context.transaction { Repository.save(checkout.order) }
      redirect "/orders/#{checkout.order.public_token}"
    end

    def show(_context, params)
      {order: Repository.find_by_token(params[:token])}
    end

    private

    def checkout_page(menu: Pizzas::Repository.available, order: Order.new)
      {menu:, order:, errors: order.errors}
    end
  end
end
