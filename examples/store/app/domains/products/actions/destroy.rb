# frozen_string_literal: true

module Products
  module Destroy
    def self.respond(context, params)
      product = Repository.find(params[:id])
      context.transaction do
        Subscribers.delete_for_product(product)
        Repository.delete(product)
      end
      context.storage.delete(product.featured_image_key) if product.featured_image?
      context.flash[:notice] = "Product deleted."
      redirect "/products"
    end
  end
end
