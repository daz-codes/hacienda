# frozen_string_literal: true

module Pizzas
  class ManagementActions < Actions
    def new(_context, _params)
      {pizza: Pizza.new, errors: []}
    end

    def create(context, params)
      pizza = Pizza.new(**pizza_attributes(params))
      return invalid(:new, pizza) if pizza.invalid?

      Repository.save(pizza)
      context.flash[:notice] = "#{pizza.name} was added to the menu."
      redirect "/pizzas/#{pizza.id}"
    end

    def edit(_context, params)
      {pizza: Repository.find(params[:id]), errors: []}
    end

    def update(context, params)
      pizza = Repository.find(params[:id])
      pizza.assign(pizza_attributes(params))
      return invalid(:edit, pizza) if pizza.invalid?

      Repository.save(pizza)
      context.flash[:notice] = "#{pizza.name} was updated."
      redirect "/pizzas/#{pizza.id}"
    end

    private

    def pizza_attributes(params)
      attributes = params.permit(:name, :description, :price, :vegetarian, :available)
      {
        name: attributes[:name].to_s.strip,
        description: attributes[:description].to_s.strip,
        price_cents: decimal_to_cents(attributes[:price]),
        vegetarian: attributes[:vegetarian],
        available: attributes[:available]
      }
    end

    def decimal_to_cents(value)
      amount = Float(value, exception: false)
      amount && (amount * 100).round
    end

    def invalid(view, pizza)
      render view, pizza:, errors: pizza.errors, status: 422
    end
  end
end
