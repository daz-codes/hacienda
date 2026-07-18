# frozen_string_literal: true

module Franchises
  class Actions < Lunula::Actions
    def index(_context, _params)
      {venues: Repository.available}
    end
  end
end
