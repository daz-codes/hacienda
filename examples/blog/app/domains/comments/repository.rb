# frozen_string_literal: true

module Comments
  module Repository
    STORE = Hacienda::Store.new(database: APP.database, table: :comments, record: Comment)

    module_function

    def for_post(post)
      STORE.all(dataset.where(post_id: post.id).order(:created_at))
    end

    def save(comment)
      STORE.save(comment)
    end

    def delete_for_post(post)
      dataset.where(post_id: post.id).delete
    end

    def dataset
      STORE.dataset
    end
  end
end
