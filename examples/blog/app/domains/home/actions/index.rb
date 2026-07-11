# frozen_string_literal: true

module Home
  module Index
    def self.respond(_context, _params)
      {posts: Posts::Repository.published.first(5)}
    end
  end
end
