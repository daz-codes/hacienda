# frozen_string_literal: true

module Products
  module Create
    def self.respond(context, params)
      attributes = params.permit(:name, :description, :inventory_count)
      product = Product.new(
        name: attributes[:name].to_s.strip,
        description: attributes[:description].to_s.strip,
        inventory_count: attributes[:inventory_count]
      )
      product.valid?
      blob = attach_image(context, params, product) if product.errors.empty?
      return render(:new, product:, errors: product.errors, status: 422) if product.errors.any?

      begin
        Repository.save(product)
      rescue StandardError
        context.storage.delete(blob.key) if blob
        raise
      end
      context.flash[:notice] = "Product created."
      redirect "/products/#{product.id}"
    end

    def self.attach_image(context, params, product)
      return unless Hacienda::Storage::Upload.present?(params[:featured_image])

      blob = context.storage.store(
        params[:featured_image],
        prefix: "product-images",
        max_bytes: 5 * 1024 * 1024,
        content_types: ["image/jpeg", "image/png", "image/webp", "image/avif"]
      )
      product.attach_featured_image(blob)
      blob
    rescue Hacienda::Storage::InvalidUpload => error
      product.errors.add(:featured_image, error.message)
      nil
    end
    private_class_method :attach_image
  end
end
