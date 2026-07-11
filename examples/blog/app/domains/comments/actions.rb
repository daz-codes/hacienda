# frozen_string_literal: true

module Comments
  module Create
    def self.respond(context, params)
      post = Posts::Repository.find_with_comments(params[:id])
      can_manage = Posts::Policy.manage?(context.current_user, post)
      raise Hacienda::NotFound unless (post.published? && !post.archived?) || can_manage

      attributes = params.permit(:author_name, :body).transform_values { |value| value.to_s.strip }
      comment = Comment.new(
        post_id: post.id,
        author_name: attributes[:author_name],
        body: attributes[:body]
      )

      if comment.invalid?
        context.flash[:alert] = comment.errors.full_messages.join(", ")
        return redirect "/posts/#{post.id}"
      end

      Repository.save(comment)
      context.flash[:notice] = "Comment posted."
      redirect "/posts/#{post.id}"
    end
  end
end
