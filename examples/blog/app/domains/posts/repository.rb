# frozen_string_literal: true

module Posts
  module Repository
    extend Lunula::Repository

    store database: APP.database, table: :posts, record: Post

    def all(scope = dataset.reverse_order(:created_at))
      super(scope)
    end

    def published
      scope = dataset
        .exclude(published_at: nil)
        .where(archived_at: nil)
        .reverse_order(:published_at)

      all(scope)
    end

    def find_with_comments(id)
      find(id).tap do |post|
        post.comments = Comments::Repository.for_post(post)
      end
    end
  end
end
