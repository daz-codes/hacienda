# frozen_string_literal: true

module Posts
  module Archive
    def self.respond(context, params)
      post = Repository.find(params[:id])
      return response("Forbidden", status: 403) unless Policy.manage?(context.current_user, post)

      occurred_at = Time.now
      context.transaction do |transaction|
        post.archive(at: occurred_at)
        Repository.save(post)
        transaction.emit Events::Archived.new(
          post_id: post.id,
          author_id: post.author_id,
          occurred_at:
        )
      end

      context.flash[:notice] = "Post archived."
      redirect "/posts"
    end
  end
end
