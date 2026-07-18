# frozen_string_literal: true

module Posts
  class Actions < Hacienda::Actions
    def index(_context, _params)
      {posts: Repository.published}
    end

    def show(context, params)
      post = Repository.find_with_comments(params[:id])
      can_manage = Policy.manage?(context.current_user, post)
      raise Hacienda::NotFound unless (post.published? && !post.archived?) || can_manage

      return response("", status: 304) if fresh_public_post?(context, post)

      {post:, comment: Comments::Comment.new, comment_errors: [], can_manage:}
    end

    private

    def fresh_public_post?(context, post)
      return false if context.flash.any?

      public_response = context.current_user.nil?
      !context.stale?(
        etag: ["post", post.id, post.updated_at.to_f],
        last_modified: post.updated_at,
        public: public_response,
        max_age: public_response ? 60 : 0
      )
    end

  end
end
