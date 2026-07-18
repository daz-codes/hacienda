# frozen_string_literal: true

module Products
  class Actions < Lunula::Actions
    def index(_context, _params)
      {products: Repository.all}
    end

    def show(context, params)
      product_page(context, Repository.find(params[:id]))
    end

    private

    def product_page(context, product, subscriber: Subscriber.new, errors: [])
      {product:, can_manage: !!context.current_user, subscriber:, errors:}
    end

  end
end
