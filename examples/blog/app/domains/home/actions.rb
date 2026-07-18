# frozen_string_literal: true

module Home
  class Actions < Lunula::Actions
    def index(_context, _params)
      {posts: Posts::Repository.published.first(5)}
    end
  end
end
