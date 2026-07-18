# frozen_string_literal: true

module Home
  module Samples
    module_function

    def locals
      {
        request_example: <<~'RUBY',
          module Posts
            class PublishingActions < Hacienda::Actions
              def publish(context, params)
                post = Repository.find(params[:id])
                Posts.publish(post)
                Repository.save(post)

                context.flash[:notice] = "Post published."
                redirect "/posts/#{post.id}"
              end
            end
          end
        RUBY
        structure_example: <<~TEXT
          app/domains/posts/
          ├── routes.rb
          ├── actions.rb
          ├── post.rb
          ├── repository.rb
          ├── publishable.rb
          ├── actions/
          │   └── publishing_actions.rb
          └── views/
              ├── index.erb
              └── show.erb
        TEXT
      }
    end
  end
end
