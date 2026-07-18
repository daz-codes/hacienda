get "/guides/blog", :blog
get "/guides/helium", :helium
post "/guides/helium/title-preview", :title_preview, actions: :preview
post "/guides/helium/comment-preview", :comment_preview, actions: :preview
post "/guides/helium/post-preview", :post_preview, actions: :preview
get "/guides/store", :store
