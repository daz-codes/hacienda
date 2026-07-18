# frozen_string_literal: true

module Posts
  class ManagementActions < Actions
    def new(_context, _params)
      {post: Post.new, errors: []}
    end

    def create(context, params)
      post = Post.new(**post_attributes(params), author_id: context.current_user.id)
      post.valid?
      cover = cover_upload(context, params, post)
      cover.attach if post.errors.empty?
      return render(:new, post:, errors: post.errors, status: 422) if post.errors.any?

      cover.persist { Repository.save(post) }
      context.flash[:notice] = "Post created."
      redirect "/posts/#{post.id}"
    end

    def edit(context, params)
      post = authorized_post(context, params[:id])
      return response("Forbidden", status: 403) unless post

      {post:, errors: []}
    end

    def update(context, params)
      post = authorized_post(context, params[:id])
      return response("Forbidden", status: 403) unless post

      previous_cover_key = post.cover_key
      post.assign(post_attributes(params))
      post.valid?
      cover = cover_upload(context, params, post)
      cover.attach if post.errors.empty?
      return render(:edit, post:, errors: post.errors, status: 422) if post.errors.any?

      cover.persist { Repository.save(post) }
      cover.delete_replaced(previous_cover_key)
      context.flash[:notice] = "Post updated."
      redirect "/posts/#{post.id}"
    end

    def destroy(context, params)
      post = authorized_post(context, params[:id])
      return response("Forbidden", status: 403) unless post

      Comments::Repository.delete_for_post(post)
      Repository.delete(post)
      context.storage.delete(post.cover_key) if post.cover?
      context.flash[:notice] = "Post deleted."
      redirect "/posts"
    end

    private

    def authorized_post(context, id)
      post = Repository.find(id)
      post if Policy.manage?(context.current_user, post)
    end

    def post_attributes(params)
      params.permit(:title, :body).transform_values { |value| value.to_s.strip }
    end

    def cover_upload(context, params, post)
      CoverUpload.new(storage: context.storage, upload: params[:cover], post:)
    end
  end
end
