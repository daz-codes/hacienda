# frozen_string_literal: true

module Products
  module Subscribers
    extend Lunula::Repository

    store(
      database: APP.database,
      table: :subscribers,
      record: Subscriber
    )

    def for_product(product)
      all(dataset.where(product_id: product.id).order(:created_at))
    end

    def find_by_email(product, email)
      find_by(product_id: product.id, email: normalize(email))
    end

    def save(subscriber)
      subscriber.email = normalize(subscriber.email)
      super
    end

    def delete_for_product(product)
      dataset.where(product_id: product.id).delete
    end

    private

    def normalize(email)
      email.to_s.strip.downcase
    end
  end
end
