# frozen_string_literal: true

module Products
  module Update
    def self.respond(context, params)
      product = Repository.find(params[:id])
      attributes = params.permit(:name, :description, :inventory_count)
      product.name = attributes[:name].to_s.strip
      product.description = attributes[:description].to_s.strip
      product.inventory_count = attributes[:inventory_count]
      product.valid?
      previous_image_key = product.featured_image_key
      blob = attach_image(context, params, product) if product.errors.empty?
      return render(:edit, product:, errors: product.errors, status: 422) if product.errors.any?

      restocked = product.back_in_stock?
      begin
        context.transaction do |transaction|
          Repository.save(product)
          if restocked
            transaction.emit Events::Restocked.new(product_id: product.id, occurred_at: Time.now.utc)
          end
        end
      rescue StandardError
        context.storage.delete(blob.key) if blob
        raise
      end
      context.storage.delete(previous_image_key) if blob && previous_image_key
      context.flash[:notice] = "Product updated."
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
