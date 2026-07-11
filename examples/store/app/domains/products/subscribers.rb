# frozen_string_literal: true

module Products
  module Subscribers
    STORE = Hacienda::Store.new(
      database: APP.database,
      table: :subscribers,
      record: Subscriber
    )

    module_function

    def for_product(product)
      STORE.all(dataset.where(product_id: product.id).order(:created_at))
    end

    def find(id)
      STORE.first(dataset.where(id: id))
    end

    def find_by_email(product, email)
      STORE.first(dataset.where(product_id: product.id, email: normalize(email)))
    end

    def save(subscriber)
      subscriber.email = normalize(subscriber.email)
      STORE.save(subscriber)
    end

    def delete(subscriber)
      STORE.delete(subscriber)
    end

    def delete_for_product(product)
      dataset.where(product_id: product.id).delete
    end

    def dataset
      STORE.dataset
    end

    def normalize(email)
      email.to_s.strip.downcase
    end
  end
end
