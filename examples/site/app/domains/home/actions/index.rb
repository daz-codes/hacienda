# frozen_string_literal: true

module Home
  module Index
    def self.respond(_context, _params)
      {
        request_example: <<~'RUBY',
          module Posts
            module Publish
              def self.respond(context, params)
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
          │   └── publish.rb
          └── views/
              ├── index.erb
              └── show.erb
        TEXT
      }
    end
  end
end
