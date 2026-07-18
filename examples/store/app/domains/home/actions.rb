# frozen_string_literal: true

module Home
  class Actions < Lunula::Actions
    def index(_context, _params)
      {framework: "Lunula", command: "luna"}
    end

    def up(_context, _params)
      text "OK"
    end
  end
end
