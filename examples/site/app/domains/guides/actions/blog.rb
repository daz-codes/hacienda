# frozen_string_literal: true

module Guides
  module Blog
    def self.respond(_context, _params)
      {
        samples: {
          install: <<~SHELL,
            gem install hacienda
            hac new journal
            cd journal
            bundle install
          SHELL
          generate: <<~SHELL,
            bundle exec hac generate rest posts
            bundle exec hac db:migrate
          SHELL
          routes: <<~RUBY,
            get "/posts", :index
            get "/posts/new", :new
            post "/posts", :create
            get "/posts/:id", :show
            get "/posts/:id/edit", :edit
            patch "/posts/:id", :update
            delete "/posts/:id", :destroy
          RUBY
          action: <<~RUBY,
            module Posts
              module Index
                def self.respond(_context, _params)
                  {posts: Repository.all}
                end
              end
            end
          RUBY
          post: <<~RUBY,
            module Posts
              class Post
                include Hacienda::Attributes
                include Hacienda::Validations

                attributes :id, :created_at, :updated_at
                attribute :title, default: ""
                attribute :body, default: ""

                def validate
                  errors.add :title, "is required" if title.strip.empty?
                  errors.add :body, "is required" if body.strip.empty?
                end
              end
            end
          RUBY
          view: <<~ERB,
            <% page_title "Posts" %>

            <header>
              <h1>Posts</h1>
              <%= link "New post", "/posts/new" %>
            </header>

            <% posts.each do |post| %>
              <%= component :post_card, post: post %>
            <% end %>
          ERB
          run: <<~SHELL
            bundle exec hac start
            # Open http://localhost:5151/posts
          SHELL
        }
      }
    end
  end
end
