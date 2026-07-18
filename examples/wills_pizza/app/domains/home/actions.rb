# frozen_string_literal: true

module Home
  class Actions < Lunula::Actions
    def index(_context, _params)
      redirect "/pizzas"
    end

    def up(_context, _params)
      text "OK"
    end
  end
end
