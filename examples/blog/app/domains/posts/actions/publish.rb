# frozen_string_literal: true

module Posts
  module Publish
    def self.respond(context, params)
      post = Repository.find(params[:id])
      return response("Forbidden", status: 403) unless Policy.manage?(context.current_user, post)

      occurred_at = Time.now
      context.transaction do |transaction|
        post.publish(at: occurred_at)
        Repository.save(post)
        transaction.emit Events::Published.new(
          post_id: post.id,
          author_id: post.author_id,
          occurred_at:
        )
      end

      context.flash[:notice] = "Post published."
      redirect "/posts/#{post.id}"
    end
  end
end
