# frozen_string_literal: true

module Comments
  module Repository
    extend Lunula::Repository

    store database: APP.database, table: :comments, record: Comment

    def for_post(post)
      all(dataset.where(post_id: post.id).order(:created_at))
    end

    def delete_for_post(post)
      dataset.where(post_id: post.id).delete
    end
  end
end
