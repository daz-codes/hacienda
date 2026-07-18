# frozen_string_literal: true

module Products
  class ManagementActions < Actions
    def new(_context, _params)
      {product: Product.new, errors: []}
    end

    def create(context, params)
      product = Product.new(**product_attributes(params))
      product.valid?
      image = image_upload(context, params, product)
      image.attach if product.errors.empty?
      return render(:new, product:, errors: product.errors, status: 422) if product.errors.any?

      image.persist { Repository.save(product) }
      context.flash[:notice] = "Product created."
      redirect "/products/#{product.id}"
    end

    def edit(_context, params)
      {product: Repository.find(params[:id]), errors: []}
    end

    def update(context, params)
      product = Repository.find(params[:id])
      previous_image_key = product.featured_image_key
      product.assign(product_attributes(params))
      product.valid?
      image = image_upload(context, params, product)
      image.attach if product.errors.empty?
      return render(:edit, product:, errors: product.errors, status: 422) if product.errors.any?

      restocked = product.back_in_stock?
      image.persist { save_product(context, product, restocked:) }
      image.delete_replaced(previous_image_key)
      context.flash[:notice] = "Product updated."
      redirect "/products/#{product.id}"
    end

    def destroy(context, params)
      product = Repository.find(params[:id])
      context.transaction do
        Subscribers.delete_for_product(product)
        Repository.delete(product)
      end
      context.storage.delete(product.featured_image_key) if product.featured_image?
      context.flash[:notice] = "Product deleted."
      redirect "/products"
    end

    private

    def product_attributes(params)
      attributes = params.permit(:name, :description, :inventory_count)
      attributes[:name] = attributes[:name].to_s.strip
      attributes[:description] = attributes[:description].to_s.strip
      attributes
    end

    def image_upload(context, params, product)
      FeaturedImageUpload.new(storage: context.storage, upload: params[:featured_image], product:)
    end

    def save_product(context, product, restocked:)
      context.transaction do |transaction|
        Repository.save(product)
        if restocked
          transaction.emit Events::Restocked.new(product_id: product.id, occurred_at: Time.now.utc)
        end
      end
    end
  end
end
