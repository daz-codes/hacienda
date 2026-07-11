# frozen_string_literal: true

module Products
  module NotifySubscribers
    module_function

    def call(event)
      product = Repository.find(event.product_id)
      Subscribers.for_product(product).each do |subscriber|
        Mailer.in_stock(product:, subscriber:).deliver_later
      end
    end
  end
end
