# frozen_string_literal: true

module Posts
  module Policy
    module_function

    def manage?(user, post)
      user && post.author_id == user.id
    end
  end
end
