# frozen_string_literal: true

admin = Auth::Repository.find_by_email("admin@example.com")
unless admin
  admin = Auth::User.new(email: "admin@example.com")
  admin.password = "change-this-password"
  admin.verify_email
  Auth::Repository.save(admin)
end

unless Products::Repository.dataset.any?
  Products::Repository.save Products::Product.new(
    name: "Lunula T-Shirt",
    description: "Heavyweight organic cotton shirt with a small LUNA 01 mark.",
    inventory_count: 12
  )

  sold_out = Products::Product.new(
    name: "Factory Records Tote",
    description: "A sturdy canvas tote. Subscribe to hear when it returns.",
    inventory_count: 0
  )
  Products::Repository.save(sold_out)
  Products::Subscribers.save Products::Subscriber.new(
    product_id: sold_out.id,
    email: "listener@example.com"
  )
end
