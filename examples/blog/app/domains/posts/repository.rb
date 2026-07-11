# frozen_string_literal: true

module Posts
  module Repository
    STORE = Hacienda::Store.new(database: APP.database, table: :posts, record: Post)

    module_function

    def all
      STORE.all(dataset.reverse_order(:created_at))
    end

    def published
      scope = dataset
        .exclude(published_at: nil)
        .where(archived_at: nil)
        .reverse_order(:published_at)

      STORE.all(scope)
    end

    def find(id)
      STORE.find(id)
    end

    def find_with_comments(id)
      find(id).tap do |post|
        post.comments = Comments::Repository.for_post(post)
      end
    end

    def save(record)
      STORE.save(record)
    end

    def delete(record)
      STORE.delete(record)
    end

    def dataset
      STORE.dataset
    end
  end
end
