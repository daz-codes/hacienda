# frozen_string_literal: true

module Home
  class Actions < Hacienda::Actions
    def index(_context, _params)
      Samples.locals
    end

    def up(_context, _params)
      text "OK"
    end
  end
end
