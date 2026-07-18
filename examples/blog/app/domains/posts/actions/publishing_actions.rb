# frozen_string_literal: true

module Posts
  class PublishingActions < Lunula::Actions
    def publish(context, params)
      transition(context, params[:id], :publish, Events::Published)
    end

    def archive(context, params)
      transition(context, params[:id], :archive, Events::Archived)
    end

    private

    def transition(context, id, operation, event_class)
      post = Repository.find(id)
      return response("Forbidden", status: 403) unless Policy.manage?(context.current_user, post)

      occurred_at = Time.now
      context.transaction do |transaction|
        post.public_send(operation, at: occurred_at)
        Repository.save(post)
        transaction.emit event_class.new(
          post_id: post.id,
          author_id: post.author_id,
          occurred_at:
        )
      end

      context.flash[:notice] = "Post #{operation == :publish ? "published" : "archived"}."
      redirect operation == :publish ? "/posts/#{post.id}" : "/posts"
    end
  end
end
