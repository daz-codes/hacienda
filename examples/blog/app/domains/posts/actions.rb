# frozen_string_literal: true

module Posts
  module Index
    def self.respond(_context, _params)
      {posts: Repository.published}
    end
  end

  module Show
    def self.respond(context, params)
      post = Repository.find_with_comments(params[:id])
      can_manage = Policy.manage?(context.current_user, post)
      raise Hacienda::NotFound unless (post.published? && !post.archived?) || can_manage

      unless context.flash.any?
        public_response = context.current_user.nil?
        stale = context.stale?(
          etag: ["post", post.id, post.updated_at.to_f],
          last_modified: post.updated_at,
          public: public_response,
          max_age: public_response ? 60 : 0
        )
        return response("", status: 304) unless stale
      end

      {post:, comment: Comments::Comment.new, comment_errors: [], can_manage:}
    end
  end

  module New
    def self.respond(_context, _params)
      {post: Post.new, errors: []}
    end
  end

  module Create
    def self.respond(context, params)
      attributes = params.permit(:title, :body).transform_values { |value| value.to_s.strip }
      post = Post.new(
        title: attributes[:title],
        body: attributes[:body],
        author_id: context.current_user.id
      )
      post.valid?
      blob = attach_cover(context, params, post) if post.errors.empty?
      return render(:new, post:, errors: post.errors, status: 422) if post.errors.any?

      begin
        Repository.save(post)
      rescue StandardError
        context.storage.delete(blob.key) if blob
        raise
      end
      context.flash[:notice] = "Post created."
      redirect "/posts/#{post.id}"
    end

    def self.attach_cover(context, params, post)
      return unless Hacienda::Storage::Upload.present?(params[:cover])

      blob = context.storage.store(
        params[:cover],
        prefix: "post-covers",
        max_bytes: 5 * 1024 * 1024,
        content_types: ["image/jpeg", "image/png", "image/webp", "image/avif"]
      )
      post.attach_cover(blob)
      blob
    rescue Hacienda::Storage::InvalidUpload => error
      post.errors.add(:cover, error.message)
      nil
    end
    private_class_method :attach_cover
  end

  module Edit
    def self.respond(context, params)
      post = Repository.find(params[:id])
      return response("Forbidden", status: 403) unless Policy.manage?(context.current_user, post)

      {post:, errors: []}
    end
  end

  module Update
    def self.respond(context, params)
      post = Repository.find(params[:id])
      return response("Forbidden", status: 403) unless Policy.manage?(context.current_user, post)

      attributes = params.permit(:title, :body).transform_values { |value| value.to_s.strip }
      post.title = attributes[:title]
      post.body = attributes[:body]
      post.valid?
      previous_cover_key = post.cover_key
      blob = attach_cover(context, params, post) if post.errors.empty?
      return render(:edit, post:, errors: post.errors, status: 422) if post.errors.any?

      begin
        Repository.save(post)
      rescue StandardError
        context.storage.delete(blob.key) if blob
        raise
      end
      context.storage.delete(previous_cover_key) if blob && previous_cover_key
      context.flash[:notice] = "Post updated."
      redirect "/posts/#{post.id}"
    end

    def self.attach_cover(context, params, post)
      return unless Hacienda::Storage::Upload.present?(params[:cover])

      blob = context.storage.store(
        params[:cover],
        prefix: "post-covers",
        max_bytes: 5 * 1024 * 1024,
        content_types: ["image/jpeg", "image/png", "image/webp", "image/avif"]
      )
      post.attach_cover(blob)
      blob
    rescue Hacienda::Storage::InvalidUpload => error
      post.errors.add(:cover, error.message)
      nil
    end
    private_class_method :attach_cover
  end

  module Destroy
    def self.respond(context, params)
      post = Repository.find(params[:id])
      return response("Forbidden", status: 403) unless Policy.manage?(context.current_user, post)

      Comments::Repository.delete_for_post(post)
      Repository.delete(post)
      context.storage.delete(post.cover_key) if post.cover?
      context.flash[:notice] = "Post deleted."
      redirect "/posts"
    end
  end
end
