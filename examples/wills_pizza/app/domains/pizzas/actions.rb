# frozen_string_literal: true

module Pizzas
  class Actions < Hacienda::Actions
    def index(_context, _params)
      {pizzas: Repository.available}
    end

    def show(_context, params)
      {pizza: Repository.find(params[:id])}
    end
  end
end
