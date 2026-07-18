# Field Notes

A working blog that demonstrates Lunula’s intended application architecture.

## Run it

Use Ruby 3.2 or newer:

```sh
bundle install
bundle exec luna db:migrate
bundle exec luna db:seed
bundle exec luna start
```

Visit `http://localhost:5151`, sign up, write a post, and publish it.
The optional seed uses `writer@example.com` / `change-this-password`.
Auth emails are queued with Lunula jobs and delivered through the configured
mail adapter.

Development defaults to the in-process job adapter and immediate after-commit
events. To exercise the durable jobs and transactional outbox, run both the web
process and worker with the database options:

```sh
LUNULA_JOB_ADAPTER=database LUNULA_EVENT_OUTBOX=database bundle exec luna start
LUNULA_JOB_ADAPTER=database LUNULA_EVENT_OUTBOX=database bundle exec luna jobs:work
```

Publishing or archiving a post then writes its activity event to the outbox in
the same transaction. The worker dispatches it to the subscribers registered in
`config/events.rb`.

Same-origin GET links use Morpheus: the posts content is prefetched
on intent and morphed with Idiomorph while the layout stays in place. Normal
forms remain native, and Helium continues to bind changed content through its
MutationObserver.

The posts index caches versioned post-card components in the bounded memory
store. Post pages demonstrate conditional HTTP caching with ETags and
`Last-Modified`; production leaves the application cache disabled until a
shared store is configured.

Authors can attach a cover image. The multipart action validates and stores it,
`Posts::Coverable` owns the persisted metadata, and local files are streamed by
Lunula's protected `/uploads` middleware. Production storage remains disabled
until `config/storage.rb` is connected to an object-store adapter; cover uploads
fail closed with `storage is not configured` until then. `/uploads` is public
capability-URL serving and must not be used for private documents.

Posts have comments through an explicit cross-domain query. The show action
uses `Posts::Repository.find_with_comments(id)`, which loads comments from
`Comments::Repository.for_post(post)` and assigns them to `post.comments`.
Calling `post.comments` in the view therefore reads preloaded state; it does not
perform a hidden database query.

The direct Rack command remains available:

```sh
bundle exec rackup -p 5151
```

Open a console with the app loaded:

```sh
bundle exec luna console
```

## Structure

```text
app/domains/posts/
├── routes.rb
├── actions.rb
├── post.rb
├── publishable.rb
├── archivable.rb
├── coverable.rb
├── events.rb
├── activity.rb
├── policy.rb
├── repository.rb
├── actions/
│   ├── management_actions.rb
│   └── publishing_actions.rb
└── views/

app/domains/comments/
├── routes.rb
├── actions.rb
├── comment.rb
└── repository.rb
```

`posts/actions.rb` keeps the common HTTP actions together.
`management_actions.rb` contains the guarded editing workflow, while
`publishing_actions.rb` groups publish and archive in a separate action set.

Current-user loading is configured once:

```ruby
APP = Lunula::Application.new(
  root: APP_ROOT,
  context_loaders: ["Auth::LoadCurrentUser"],
  database: DB
)
```

Public routes need no authentication annotation. Protected routes share a
visible guard scope:

```ruby
get "/posts", :index
get "/posts/:id", :show

guard Auth::Required do
  get "/posts/new", :new
  post "/posts", :create
  post "/posts/:id/publish", :publish, actions: :publishing
end
```

Actions receive request context separately from parameters:

```ruby
module Posts
  class PublishingActions < Lunula::Actions
    def publish(context, params)
      post = Repository.find(params[:id])
      return response("Forbidden", status: 403) unless
        Policy.manage?(context.current_user, post)

      context.transaction do |transaction|
        post.publish
        Repository.save(post)
        transaction.emit Events::Published.new(
          post_id: post.id,
          author_id: post.author_id,
          occurred_at: Time.now
        )
      end

      context.flash[:notice] = "Post published."
      redirect "/posts/#{post.id}"
    end
  end
end
```

Assignable request attributes are whitelisted before use:

```ruby
attributes = params.permit(:title, :body).transform_values { |value| value.to_s.strip }
post.title = attributes[:title]
post.body = attributes[:body]
```

Domain behavior is composed into ordinary Ruby objects:

```ruby
module Posts
  class Post
    include Lunula::Attributes
    include Lunula::Validations
    include Publishable
    include Archivable
  end
end
```

```ruby
module Posts
  module Publishable
    def publish(at: Time.now)
      raise "Archived posts cannot be published" if archived?

      self.published_at = at
      self
    end
  end
end
```

Persistence and transaction boundaries remain explicit:

```ruby
context.transaction do |transaction|
  post.publish
  Posts::Repository.save(post)
  transaction.emit Posts::Events::Published.new(
    post_id: post.id,
    author_id: post.author_id,
    occurred_at: Time.now
  )
end
```

Custom queries stay as Sequel datasets while `Lunula::Repository` provides
the common row mapping over Store:

```ruby
def published
  scope = dataset
    .exclude(published_at: nil)
    .where(archived_at: nil)
    .reverse_order(:published_at)

  all(scope)
end
```

Subscribers are plain Ruby callables registered in `config/events.rb`. Events
are delivered only after commit; the activity subscriber therefore never sees
a post publication that was rolled back.

Authentication is implemented with generated domain code and visible route
guards. CSRF protection and sessions are Rack middleware. There are no
controller base classes, inherited callbacks, or global `Current.user`.

The current example verifies email addresses before login and supports password
resets. Both flows use Lunula signed tokens and the mail delivery adapter.
Verification is confirmed by POST, and reset links use a reset-version token
rather than exposing password hashes.

Views are ERB with locals, partials, and components:

```erb
<%= component :post_card, post: post %>
<%= partial :form, post:, errors:, action: "/posts", method: "post" %>
<%= form_start "/posts", context: %>
<%= button_to "Delete", path("/posts/:id", id: post.id), method: "delete", context: %>
<%= flash_messages context %>
```

The layout loads the local `public/assets/helium-csp.js` build and uses Helium
attributes for a progressively enhanced navigation menu without Node.js, a
build step, or an `unsafe-eval` Content Security Policy exception.
