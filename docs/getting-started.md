# Getting Started with Hacienda

This tutorial builds **Hacienda Supply**, a small product store with inventory,
authentication, image uploads, stock notifications, email, caching, tests, and
deployment configuration.

It deliberately follows the shape of the current
[Rails 8.1 Getting Started guide](https://guides.rubyonrails.org/getting_started.html),
but translates each feature into Hacienda’s domain-oriented architecture. The
completed application is in [`examples/store`](../examples/store).

Callouts marked **Hacienda difference** explain intentional design choices.
Callouts marked **Current gap** identify something the Rails guide can do that
Hacienda cannot currently provide.

## 1. Prerequisites

You need Ruby 3.2 or newer, Bundler, SQLite, and Hacienda’s `hac` executable.
When working from this repository, Ruby 3.3.6 can be selected explicitly:

```sh
mise exec ruby@3.3.6 -- ruby --version
```

Create the application:

```sh
hac new store
cd store
bundle install
```

`hac new` creates a Rack application, SQLite configuration, encrypted
credentials, CSRF/session middleware, ERB layout, static assets, Helium,
Hacienda Navigation, tests, Docker, and Kamal configuration.

Start it with:

```sh
bundle exec hac db:migrate
bundle exec hac start
```

Open <http://localhost:5151>. Hacienda uses port 5151 by default.

> **Hacienda difference:** Rails organizes generated code into models,
> controllers, views, jobs, and mailers. Hacienda puts application behavior
> under `app/domains/<domain>` and keeps infrastructure in `config`.

## 2. Application structure

The finished product domain looks like this:

```text
app/domains/products/
├── routes.rb
├── product.rb
├── subscriber.rb
├── imageable.rb
├── inventory_notifications.rb
├── repository.rb
├── subscribers.rb
├── events.rb
├── notify_subscribers.rb
├── mailer.rb
├── actions.rb
├── actions/
│   ├── management_actions.rb
│   └── subscription_actions.rb
└── views/
    ├── index.erb
    ├── show.erb
    ├── form.erb
    ├── inventory.erb
    └── components/
        └── _product_card.erb
```

The filesystem describes the domain: products own their persistence, inventory
behavior, subscribers, events, mail, HTTP actions, and HTML.

Development code reloading is enabled by the generated
`config/environments/development.rb`, so most Ruby and route changes do not
require a server restart.

## 3. Generate the product skeleton

Generate explicit REST code:

```sh
bundle exec hac generate rest products
```

This writes seven route declarations, seven methods on `Products::Actions`, ERB
templates, a plain Ruby product object, a repository, and a migration. Larger
groups can be generated into a separate action set with
`hac generate action products publish --actions publishing`.

The generated routes are ordinary code:

```ruby
get "/products", :index
get "/products/new", :new
post "/products", :create
get "/products/:id", :show
get "/products/:id/edit", :edit
patch "/products/:id", :update
delete "/products/:id", :destroy
```

> **Hacienda difference:** There is intentionally no `resources :products`
> macro. The generator saves typing once; the resulting routes remain visible.

The REST generator starts with generic `title` and `body` fields. Change its
migration to the store schema:

```ruby
Sequel.migration do
  change do
    create_table(:products) do
      primary_key :id
      String :name, null: false
      String :description, text: true, null: false, default: ""
      Integer :inventory_count, null: false, default: 0
      String :featured_image_key
      String :featured_image_filename
      String :featured_image_content_type
      Integer :featured_image_byte_size
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
  end
end
```

Apply it:

```sh
bundle exec hac db:migrate
```

> **Hacienda difference:** Sequel migrations are explicit Ruby. Hacienda does
> not infer a domain object from the table schema.

## 4. The product domain object

`Products::Product` is a plain Ruby object using two optional Hacienda mixins:

```ruby
module Products
  class Product
    include Hacienda::Attributes
    include Hacienda::Validations
    include Imageable
    include InventoryNotifications

    attributes :id, :created_at, :updated_at
    attributes :featured_image_key, :featured_image_filename,
      :featured_image_content_type, :featured_image_byte_size
    attribute :name, default: ""
    attribute :description, default: ""
    attribute :inventory_count,
      default: 0,
      cast: ->(value) { value.to_s.empty? ? 0 : Integer(value, exception: false) }

    def validate
      errors.add :name, "is required" if name.to_s.strip.empty?
      if !inventory_count.is_a?(Integer)
        errors.add :inventory_count, "must be a whole number"
      elsif inventory_count.negative?
        errors.add :inventory_count, "must be zero or greater"
      end
    end
  end
end
```

The object does not inherit from a framework class. `Attributes` provides
accessors and dirty tracking; `Validations` provides a small errors convention.

Persistence belongs to the repository:

```ruby
module Products
  module Repository
    STORE = Hacienda::Store.new(
      database: APP.database,
      table: :products,
      record: Product
    )

    module_function

    def all
      STORE.all(dataset.order(:name))
    end

    def find(id)
      STORE.find(id)
    end

    def save(product)
      STORE.save(product)
    end

    def delete(product)
      STORE.delete(product)
    end

    def dataset
      STORE.dataset
    end
  end
end
```

> **Hacienda difference:** Rails’ Active Record object combines schema mapping,
> queries, persistence, associations, callbacks, and validation. Hacienda keeps
> the domain object and repository separate. This is more code, but every query
> and write boundary remains explicit.

## 5. Use the console

Open an application console:

```sh
bundle exec hac console
```

Create and query products using domain and repository methods:

```ruby
product = Products::Product.new(
  name: "T-Shirt",
  description: "Heavy cotton",
  inventory_count: 10
)

product.valid?
Products::Repository.save(product)
Products::Repository.all
Products::Repository.find(product.id)

product.inventory_count = 8
Products::Repository.save(product)
Products::Repository.delete(product)
```

For custom queries, use the exposed Sequel dataset and preserve row mapping:

```ruby
scope = Products::Repository.dataset.where(inventory_count: 0)
Products::Repository::STORE.all(scope)
```

> **Current gap:** Hacienda has no association DSL equivalent to `has_many` or
> `belongs_to`. Related queries are named repository methods. This is deliberate
> today, but it is less concise for association-heavy domains.

## 6. Request flow: route, action, view

The root and product pages map directly to methods on `Products::Actions`:

```ruby
get "/", :index
get "/products", :index
get "/products/:id", :show
```

`get "/products", :index` resolves to `Products::Actions#index`:

```ruby
module Products
  class Actions < Hacienda::Actions
    def index(_context, _params)
      {products: Repository.all}
    end
  end
end
```

The declaration belongs in `app/domains/products/routes.rb`. Its location owns
the route, fixes the `Products` action namespace, and keeps the public request
surface beside the behavior it exposes. Hacienda does not load a global
business-route file. Rack middleware and infrastructure mounts belong in
`config.ru`, so there is only one normal home for application routes.

Inspect ownership or trace a concrete request with:

```sh
bundle exec hac routes --domain products
bundle exec hac routes GET /products/42
bundle exec hac routes /products/42
```

The final form reports the selected route for every matching HTTP verb. Boot and
reload fail with both source locations when routes are duplicates,
structurally equivalent, or equally specific and capable of matching the same
request. Static routes such as `/products/new` still take precedence over
`/products/:id`, and different verbs may intentionally share a path.

Returning a Hash renders `app/domains/products/views/index.erb` and exposes its
keys as local variables:

```erb
<h1>Products</h1>

<% products.each do |product| %>
  <%= component :product_card, product: %>
<% end %>
```

ERB output is escaped automatically. Components are partials, not classes.

## 7. Forms, permitted parameters, and CRUD

The shared form uses plain HTML and explicit Hacienda helpers:

```erb
<%= error_messages errors %>

<%= form_start action, method:, context:, enctype: "multipart/form-data" %>
  <label>
    Name
    <input name="name" value="<%= product.name %>" required>
  </label>

  <label>
    Description
    <textarea name="description"><%= product.description %></textarea>
  </label>

  <label>
    Inventory count
    <input type="number" name="inventory_count"
      value="<%= product.inventory_count %>" min="0" required>
  </label>

  <button type="submit">Save</button>
<%= form_end %>
```

`form_start` adds CSRF protection and a hidden method override for PATCH or
DELETE. The create action whitelists input and translates HTTP values into the
domain object:

```ruby
attributes = params.permit(:name, :description, :inventory_count)
product = Products::Product.new(
  name: attributes[:name].to_s.strip,
  description: attributes[:description].to_s.strip,
  inventory_count: attributes[:inventory_count]
)

if product.invalid?
  render :new, product:, errors: product.errors, status: 422
else
  Products::Repository.save(product)
  context.flash[:notice] = "Product created."
  redirect "/products/#{product.id}"
end
```

The update action loads the existing object, assigns permitted values, validates,
and saves it. The destroy action explicitly deletes dependent subscribers before
deleting the product.

> **Hacienda difference:** Hacienda has no model-aware form builder. Form URLs,
> field names, and button labels stay visible. `Params#permit` provides the
> whitelisting boundary without coupling parameters to persistence.

## 8. Authentication and guarded routes

Generate authentication:

```sh
bundle exec hac generate auth
bundle install
bundle exec hac db:migrate
```

This generates sign-up, login, logout, magic-link login, email verification,
password reset, password hashing, session rotation, a current-user context
loader, and a route guard.

Keep product browsing public and group management routes under one guard:

```ruby
get "/products", :index
get "/products/:id", :show

guard Auth::Required do
  get "/products/new", :new
  post "/products", :create
  get "/products/:id/edit", :edit
  patch "/products/:id", :update
  delete "/products/:id", :destroy
end
```

The generated application config loads the user once per request:

```ruby
APP = Hacienda::Application.new(
  root: APP_ROOT,
  database: DB,
  context_loaders: ["Auth::LoadCurrentUser"]
)
```

Views can use `context.current_user` to show management controls.

> **Hacienda difference:** Guards replace controller-wide authentication
> callbacks. Public and protected HTTP boundaries are visible together in the
> domain route file.

Guards answer whether a user may enter a route group; write a domain policy for
record ownership and roles. Load the record first and require an explicit truthy
decision. Missing records, users, roles, and policy failures should return
`403`/`404`, never fall through to the mutation. Integration tests should cover
an owner, a different authenticated user, and an anonymous request.

## 9. Fragment caching

Cache product-card HTML using a versioned product key:

```erb
<%= cache_fragment(
  ["product-card", product.cache_key],
  context:,
  expires_in: 300
) { component(:product_card, product:) } %>
```

The product key includes `updated_at`, so saving the product naturally selects
a new cache entry. Development, test, and this single-host example use the
bounded memory cache.

> **Hacienda difference:** Hacienda does not calculate template digests or use
> Solid Cache. Cache keys and expiry are explicit, and the default memory cache
> is process-local.

## 10. Product descriptions and rich text

The store uses a plain `<textarea>` and renders escaped text with CSS preserving
line breaks:

```css
.product-description { white-space: pre-wrap; }
```

> **Current gap — rich text:** Hacienda has no Action Text equivalent, rich-text
> editor, embedded attachment handling, or rich-text sanitization pipeline.
> Applications currently choose their own Markdown or editor integration. This
> tutorial intentionally stays with safe plain text.

## 11. Featured image uploads

Add a multipart file field:

```erb
<input type="file" name="featured_image"
  accept="image/jpeg,image/png,image/webp,image/avif">
```

The action validates and stores it explicitly:

```ruby
blob = context.storage.store(
  params[:featured_image],
  prefix: "product-images",
  max_bytes: 5 * 1024 * 1024,
  content_types: ["image/jpeg", "image/png", "image/webp", "image/avif"],
  content_inspector: Hacienda::Storage::ContentTypeInspector.new
)
product.attach_featured_image(blob)
```

`Imageable` is a plain module that copies blob metadata onto the product. The
view asks the configured storage service for its URL:

```erb
<img src="<%= context.storage.url(product.featured_image_key) %>" alt="">
```

Development uses local disk, tests use memory, and this example mounts a
persistent disk volume in production.

> **Current gap — attachment ecosystem:** Hacienda Storage covers validated
> upload, local serving, and pluggable services. It does not yet provide image
> variants, metadata analysis jobs, direct browser-to-cloud uploads, or a built-in
> S3 service comparable to the wider Active Storage feature set.

## 12. Internationalization

The Rails guide translates the product heading and selects locale from a query
parameter. The Hacienda example leaves its English labels inline.

> **Current gap — i18n:** Hacienda does not yet integrate the Ruby `i18n` gem or
> provide `t`/`translate` helpers and request-scoped locale handling. This is an
> explicit roadmap item. Applications can wire the gem themselves, but there is
> not yet a framework convention worth teaching as the default.

## 13. Inventory and subscribers

Create a subscribers migration:

```sh
bundle exec hac generate migration create_subscribers
```

```ruby
create_table(:subscribers) do
  primary_key :id
  foreign_key :product_id, :products, null: false, on_delete: :cascade
  String :email, null: false
  DateTime :created_at, null: false
  DateTime :updated_at, null: false
  index [:product_id, :email], unique: true
end
```

The `Subscriber` object declares attributes and validation. The
`Products::Subscribers` repository owns relationship queries:

```ruby
def for_product(product)
  STORE.all(dataset.where(product_id: product.id).order(:created_at))
end

def find_by_email(product, email)
  STORE.first(dataset.where(product_id: product.id, email: normalize(email)))
end
```

The public nested route remains explicit:

```ruby
post "/products/:id/subscribers", :subscribe
```

> **Hacienda difference:** There is no generated association collection such as
> `product.subscribers`. `Subscribers.for_product(product)` states the query and
> ownership directly.

## 14. Notify subscribers after commit

Inventory behavior is a composable module:

```ruby
module Products
  module InventoryNotifications
    def back_in_stock?
      attribute_was(:inventory_count).to_i.zero? && inventory_count.to_i.positive?
    end
  end
end
```

When an update crosses from zero to positive inventory, the action emits a typed
event in the same transaction as the product update:

```ruby
context.transaction do |transaction|
  Products::Repository.save(product)
  if product.back_in_stock?
    transaction.emit Products::Events::Restocked.new(
      product_id: product.id,
      occurred_at: Time.now.utc
    )
  end
end
```

Register the subscriber in `config/events.rb`:

```ruby
APP.events.configure do |events|
  events.subscribe Products::Events::Restocked, Products::NotifySubscribers
end
```

The subscriber loads current records and queues mail:

```ruby
def call(event)
  product = Products::Repository.find(event.product_id)
  Products::Subscribers.for_product(product).each do |subscriber|
    Products::Mailer.in_stock(product:, subscriber:).deliver_later
  end
end
```

Production stores the event in Hacienda’s transactional outbox. `hac jobs:work`
delivers the event and durable mail jobs with at-least-once semantics.

> **Hacienda difference:** Rails demonstrates an `after_update_commit` callback.
> Hacienda makes the transaction and event explicit in the action. Required
> business invariants remain direct calls; eventual side effects become
> idempotent event subscribers.

## 15. Mail and unsubscribe links

Hacienda mail is a function, not an inherited mailer class:

```ruby
product_url = Hacienda.app_url("/products/#{product.id}")
unsubscribe_url = Hacienda.app_url("/unsubscribe?#{Rack::Utils.build_query(token: unsubscribe_token(subscriber))}")

Hacienda.mail(
  to: subscriber.email,
  subject: "#{product.name} is back in stock",
  text: "Good news! #{product_url}\n\nUnsubscribe: #{unsubscribe_url}",
  html: "<h1>Good news!</h1>..."
).deliver_later
```

Development writes `.eml` files to `tmp/mail`; tests collect deliveries in
memory; production uses SMTP and durable database jobs. During development,
open `/hac/mail` to inspect delivered messages and follow verification, reset,
or magic-login links. HTML messages render in a restricted sandbox and remote
resources are disabled.

Generate an expiring signed unsubscribe token:

```ruby
Hacienda.signed_token.generate(
  {subscriber_id: subscriber.id, email: subscriber.email},
  purpose: "product_unsubscribe",
  expires_in: 30 * 24 * 60 * 60
)
```

The Rails guide deletes the subscription from a GET request. This example uses
a safer two-step flow:

```ruby
get "/unsubscribe", :unsubscribe
post "/unsubscribe", :confirm_unsubscribe
```

GET renders a confirmation page. POST verifies the token again, includes CSRF
protection, and deletes the subscription.

> **Hacienda difference:** This is an intentional security divergence, not a
> missing capability. Link scanners and prefetchers can issue GET requests, so
> GET should not consume a token or mutate subscription state.

## 16. CSS, JavaScript, Navigation, and Helium

Static files live in `public/assets` and are included explicitly:

```erb
<%= stylesheet_link "application.css" %>
<%= hacienda_navigation context %>
<%= javascript_include "helium-csp.js", module: true %>
<%= javascript_include "store.js", defer: true %>
```

Hacienda Navigation prefetches and morphs same-origin GET pages with Idiomorph.
Helium progressively enhances local interface behavior. The product form uses
`@bind` and `@text` for live inventory feedback while remaining a normal HTML
form.

`store.js` provides a small delete confirmation behavior:

```javascript
document.addEventListener("submit", (event) => {
  const message = event.target.dataset.confirm;
  if (message && !window.confirm(message)) event.preventDefault();
});
```

> **Hacienda difference:** Hacienda fingerprints static assets, rewrites local
> CSS and JavaScript dependencies, and generates a production manifest without
> Node.js. It deliberately does not bundle, transpile, or compile source tools
> such as Tailwind; those tools write their output into `public/assets` before
> `hac assets:precompile` fingerprints it.

> **Hacienda difference:** Native POST/PATCH/DELETE forms perform full browser
> submissions. Navigation only accelerates GET transitions; Hacienda does not
> reproduce Turbo Frames or Turbo Streams. Helium enhances individual moving
> parts without becoming the navigation system.

## 17. Testing

Generated applications include Minitest, Rack::Test, automatic test migrations,
and the complete middleware stack.

Test paths mirror the domain layout without putting tests under `app/domains`,
which keeps them outside Zeitwerk's production autoload tree:

```text
test/domains/products/product_test.rb
test/domains/products/repository_test.rb
test/domains/products/actions_test.rb
test/domains/auth/user_test.rb
test/domains/auth/actions_test.rb
test/integration/purchase_workflow_test.rb
```

Plain objects are tested directly with `Minitest::Test`. Repository contracts
use the isolated test database and explicit setup. Focused HTTP behavior for one
domain belongs in its `actions_test.rb` and can subclass `ApplicationTest`.
Cross-domain workflows, such as authentication followed by purchasing and mail
delivery, belong in `test/integration`. Name those files after the customer
story rather than after a single implementation class.

`hac generate domain` creates the mirrored directory. Action generation adds a
direct action contract, REST generation adds object, repository, and HTTP action
tests, and authentication generation adds user-policy and signup contracts.
Each generated assertion describes behavior that can be retained and extended.

The store integration test creates explicit records rather than fixtures:

```ruby
product = Products::Product.new(
  name: "Record Bag",
  description: "A guide product",
  inventory_count: 0
)
Products::Repository.save(product)
Products::Subscribers.save Products::Subscriber.new(
  product_id: product.id,
  email: "listener@example.com"
)
```

It logs in, submits a CSRF-protected PATCH, and verifies the resulting mail:

```ruby
patch "/products/#{product.id}", {
  _csrf: fresh_csrf("/products/#{product.id}/edit"),
  name: product.name,
  description: product.description,
  inventory_count: "5"
}

assert_equal 1, Hacienda.mail_deliveries.length
assert_equal ["listener@example.com"], Hacienda.mail_deliveries.first.to
```

Run the suite:

```sh
bundle exec rake test
```

> **Current gap — fixtures:** Hacienda does not generate or load named fixture
> files. Tests use factories, helper methods, or direct domain/repository calls.
> The tradeoff is less implicit test data but more setup code.

## 18. Formatting, security scanning, and CI

The application includes a small GitHub Actions workflow that installs Ruby and
runs `bundle exec rake test`.

> **Current gap — generated tooling:** Hacienda does not currently generate a
> RuboCop configuration, a framework-aware static security scanner equivalent to
> Brakeman, or CI workflow files. Generic RuboCop, dependency auditing, and
> GitHub Actions can be added normally; the completed example includes CI to show
> the shape.

Runtime security is not absent: generated applications include escaped ERB,
CSRF protection, secure session defaults, security headers/CSP, filtered logs,
encrypted credentials, rate-limiting hooks, and signed tokens.

## 19. Deployment and durable jobs

`hac new` generates a production Dockerfile, Kamal configuration, encrypted
credentials support, HTTPS proxy settings, health check, migration aliases, and
a separate durable worker role.

For the single-host SQLite deployment used by this example:

```yaml
servers:
  web:
    - 192.0.2.1
  job:
    hosts:
      - 192.0.2.1
    cmd: bundle exec hac jobs:work

env:
  clear:
    HACIENDA_APP_URL: https://app.example.com

volumes:
  - "store_db:/app/db"
  - "store_storage:/app/storage"
```

Before deployment, edit `config/deploy.yml`, configure DNS and registry
credentials, and set production secrets. Then:

```sh
bundle exec kamal setup
bundle exec kamal migrate
```

The database worker handles SIGTERM gracefully, retries failures with backoff,
reclaims expired leases, and exposes failures through:

```sh
bundle exec hac jobs:failed
bundle exec hac jobs:scheduled
bundle exec hac jobs:cancel 42
bundle exec hac jobs:retry job 42
bundle exec hac jobs:retry handoff 9
bundle exec hac jobs:retry event 17
```

For heavier workloads, configure a worker pool and multiple queues explicitly:

```sh
bundle exec hac jobs:work --queue critical,default --threads 4 --batch-size 20
bundle exec hac jobs:work --all-queues --threads 4 --batch-size 20
bundle exec hac jobs:health
bundle exec hac jobs:benchmark --jobs 1000 --threads 2 --batch-size 10
```

Named queues are served fairly in their declared cycle; `--all-queues` uses
global priority ordering. Workers claim batches atomically, finish their current
batch during graceful shutdown, and publish identity, heartbeat, queue, thread,
batch, and workload information to `hacienda_job_workers`.

Running jobs renew their leases. If a worker is killed, a replacement can use
the expired worker heartbeat to reclaim its jobs before the longer lease expiry.
Configure defaults through `HACIENDA_JOB_LEASE_SECONDS`,
`HACIENDA_JOB_HEARTBEAT_INTERVAL`, `HACIENDA_JOB_TIMEOUT`, and
`HACIENDA_JOB_WORKER_TIMEOUT`.

Use `jobs:benchmark` in staging, or during a production maintenance window, to
exercise sustained enqueue, worker claim/complete, failed-job retry, and simple
database latency sampling against the real queue tables. The command removes
only its own benchmark rows unless `--keep` is passed.

Execution timeouts are cooperative. A job may declare `def self.timeout = 30`;
long-running loops call `Hacienda::Jobs.checkpoint!` so timeout and cancellation
requests can stop them safely. External I/O must still use its own timeout.

Generated applications also mount a read-only queue dashboard at `/hac/jobs`
and JSON health at `/hac/jobs/health`. Development access is local-only;
production access requires `HACIENDA_DASHBOARD_PASSWORD` and uses HTTP Basic
auth.

Use `Hacienda.enqueue` for independent work. If a job relies on a database
change made by the current request, enqueue it through the transaction:

```ruby
context.transaction do |transaction|
  order = Orders.place(params)
  Orders::Repository.save(order)
  transaction.enqueue Orders::Jobs::SendReceipt, order.id
end
```

The built-in database adapter writes the job atomically with the order. Durable
external adapters use the generated `hacienda_job_outbox` table and receive a
stable idempotency key when the worker relays the job. Rollbacks and nested
savepoint rollbacks discard the corresponding work.

Schedule work with `Hacienda.enqueue_in(seconds, Job, ...)` or
`Hacienda.enqueue_at(time, Job, ...)`. A job module can declare
`def self.priority = 10`; lower numbers run first, followed by scheduled time
and insertion order. The database and development async adapters honor both.

See the generated `DEPLOYMENT.md` for backup and rollback constraints.

> **Hacienda difference:** The production opinion is one host, SQLite WAL, one
> web process, one worker process, memory cache, and persistent local uploads.
> PostgreSQL and object storage remain optional escape hatches rather than
> mandatory infrastructure.

## 20. Capability summary

| Rails guide feature | Hacienda equivalent | Status |
| --- | --- | --- |
| `rails new` | `hac new` | Supported |
| Model generator | REST/domain/migration generators | Partial: no standalone model generator |
| Active Record CRUD | Attributes + Store + repository | Supported explicitly |
| Associations | Named repository queries | No association DSL |
| Resource routes | Generated explicit routes | Supported differently |
| Controllers/callbacks | Action modules, guards, context loaders | Supported differently |
| Model form builder | HTML + explicit form helpers | Partial |
| Authentication generator | `hac generate auth` | Supported |
| Fragment caching/Solid Cache | `cache_fragment` + memory/pluggable cache | Supported, process-local default |
| Action Text | None | Missing |
| Active Storage | Hacienda Storage | Core upload support; advanced attachment features missing |
| I18n | None built in | Missing; roadmap item |
| Action Mailer | `Hacienda.mail` | Supported without mailer inheritance |
| Commit callback | Explicit transaction + domain event | Supported differently |
| Signed record tokens | `Hacienda.signed_token` | Supported |
| Propshaft/import maps | Static asset helpers | Partial; no build/fingerprinting pipeline |
| Turbo/Stimulus | Hacienda Navigation + Helium | Supported with a narrower HTML-first model |
| Fixtures | Explicit test setup | Missing fixture convention |
| Mail test helpers | In-memory deliveries | Supported |
| RuboCop/Brakeman generation | Bring generic tools yourself | Missing generator integration |
| GitHub Actions | Ordinary workflow file | Supported manually |
| Docker/Kamal | Generated Docker/Kamal files | Supported |
| Solid Queue | Sequel-native durable jobs/outbox | Supported without Rails dependencies; Active Job compatibility intentionally omitted |

## 21. Run the completed example

From the Hacienda repository:

```sh
cd examples/store
bundle install
bundle exec hac db:migrate
bundle exec hac db:seed
bundle exec hac start
```

Sign in with `admin@example.com` / `change-this-password`. Edit the seeded
out-of-stock product and increase its inventory to generate a stock notification
in `tmp/mail`.

The tutorial intentionally leaves the unsupported sections visible. Those gaps
are useful roadmap input: Hacienda should stay small, but its boundaries should
never be ambiguous.
