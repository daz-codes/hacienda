admin = Auth::Repository.find_by_email("will@example.com")
unless admin
  admin = Auth::User.new(email: "will@example.com")
  admin.password = "wood-fired-pizza"
  admin.verify_email
  Auth::Repository.save(admin)
end

[
  {
    name: "Margherita",
    description: "Tomato, fior di latte, basil and extra virgin olive oil.",
    price_cents: 1_050,
    vegetarian: true
  },
  {
    name: "Pepperoni Hot Honey",
    description: "Pepperoni, mozzarella, chilli and Will's hot honey.",
    price_cents: 1_350,
    vegetarian: false
  },
  {
    name: "Mushroom & Taleggio",
    description: "Roasted mushrooms, taleggio, thyme and garlic.",
    price_cents: 1_250,
    vegetarian: true
  }
].each do |attributes|
  next if Pizzas::Repository.dataset.where(name: attributes[:name]).any?

  Pizzas::Repository.save(Pizzas::Pizza.new(**attributes, available: true))
end

[
  {
    name: "Will's Pizza Soho",
    slug: "soho",
    address: "12 Ruby Street, London"
  },
  {
    name: "Will's Pizza Camden",
    slug: "camden",
    address: "24 Gem Road, London"
  }
].each do |attributes|
  next if Franchises::Repository.dataset.where(slug: attributes[:slug]).any?

  Franchises::Repository.save(Franchises::Venue.new(**attributes, published: true))
end
