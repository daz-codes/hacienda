# Hacienda

Hacienda is a lightweight, domain-oriented Ruby web framework. Its command-line
tool is `hac`, with `fac` provided as an equivalent alias.

The first-stage implementation provides:

- explicit Rack routing in each domain;
- module actions with a single `respond(context, params)` entry point;
- automatically escaped ERB rendering when an action returns a Hash;
- layouts and partial-based components;
- HTML helpers for links, buttons, forms, assets, flash, and errors;
- explicit response helpers for redirects, JSON, text, and custom responses;
- explicit route guards and request-scoped context;
- separate `respond(context, params)` action arguments;
- nested params helpers with `slice`, `permit`, and `require`;
- form, query, route, and JSON request parameters through one `Params` object;
- a small validation/errors convention for domain objects;
- optional attributes and Store primitives for thin Sequel repositories;
- flash messages through request context and session storage;
- encrypted credentials for secrets;
- explicit mail delivery with file, SMTP, and test adapters;
- background jobs with inline, async, test, and durable database adapters;
- validated multipart uploads with pluggable file storage services;
- explicit Sequel transactions with typed domain events and an optional database outbox;
- first-class development, test, and production environments;
- request logging with sensitive parameter filtering;
- development and production error pages;
- app-owned `app/errors/404.erb` and `app/errors/500.erb` templates;
- CSRF-protected session middleware in generated applications;
- security headers, configurable CSP, and Rack rate limiting middleware;
- `hac`/`fac` new, domain, REST, action, migration, auth, start, console, and routes commands;
- default-on, Idiomorph-powered GET navigation with intent prefetching;
- local Helium assets in every generated app, using its CSP-safe runtime by
  default with no Node.js runtime.

## Try it

From this repository:

```sh
bundle install
bundle exec ruby -Ilib exe/hac new blog
cd blog
bundle install
bundle exec hac db:migrate
bundle exec hac start
```

Open a console with the application environment loaded:

```sh
bundle exec hac console
```

Inspect the application’s explicit routes, action modules, and guards:

```sh
bundle exec hac routes
```

Manage migrations and seeds without going through Rake:

```sh
bundle exec hac db:migrate
bundle exec hac db:rollback       # rolls back one migration
bundle exec hac db:rollback 3     # rolls back three migrations
bundle exec hac db:seed
bundle exec hac db:check
bundle exec hac db:checkpoint --mode TRUNCATE
```

`db:seed` only loads `db/seeds.rb`; run migrations explicitly first. The
generated Rake tasks remain available for developers who prefer them.
`db:check` reports SQLite production settings such as WAL mode, busy-timeout,
foreign keys, and unsafe synced-storage paths. `db:checkpoint` runs an explicit
SQLite WAL checkpoint for maintenance windows.

New applications include a working Rack::Test integration setup:

```sh
bundle exec rake test
```

Tests subclass `ApplicationTest`, exercise the complete `config.ru` middleware
stack, and use a separate test database. Pending test migrations are applied
when `test/test_helper.rb` boots. The base helper exposes `database` and
`csrf_token` for explicit persistence setup and CSRF-protected requests.

```text
VERB    PATH            ACTION          GUARDS
GET     /posts          Posts::Index    -
POST    /posts          Posts::Create   Auth::Required
DELETE  /posts/:id      Posts::Destroy  Auth::Required
```

Generated applications include Docker and Kamal 2 templates. See the
[deployment guide](docs/deployment.md) for secrets, health checks, migrations,
SQLite persistence, HTTPS, and multi-server constraints.

Useful objects like `DB`, domain constants, repositories, `Hacienda.env`, and
`Hacienda.credentials` are available because the command boots
`config/application.rb`.

A generated route:

```ruby
get "/posts/:id", :show
```

maps to:

```ruby
module Posts
  module Show
    def self.respond(_context, params)
      {post: Repository.find(params[:id])}
    end
  end
end
```

and renders `app/domains/posts/views/show.erb`.

Generate a standalone migration with:

```sh
bundle exec hac generate migration add_excerpt_to_posts
```

Set cross-request feedback before redirecting:

```ruby
context.flash[:notice] = "Post published."
redirect "/posts/#{post.id}"
```

Validate domain objects without adding a model framework:

```ruby
module Posts
  class Post
    include Hacienda::Validations

    def validate
      errors.add :title, "is required" if title.to_s.strip.empty?
    end
  end
end

return render(:new, post:, errors: post.errors, status: 422) if post.invalid?
```

Use the optional attributes and Store primitives to remove repetitive row
mapping while keeping repositories explicit:

```ruby
module Posts
  class Post
    include Hacienda::Attributes
    include Hacienda::Validations

    attributes :id, :published_at, :created_at, :updated_at
    attribute :title, default: ""
  end

  module Repository
    STORE = Hacienda::Store.new(
      database: APP.database,
      table: :posts,
      record: Post
    )

    module_function

    def published
      STORE.all(
        STORE.dataset.exclude(published_at: nil).reverse_order(:published_at)
      )
    end

    def find(id) = STORE.find(id)
    def save(post) = STORE.save(post)
  end
end
```

`STORE.dataset` is the underlying Sequel dataset. Pass any custom dataset to
`STORE.all` or `STORE.first`, or map a row directly with `STORE.load`. This
keeps custom queries on Sequel without reintroducing `Post.new(**row)` in every
finder.

Persistence coercion is explicit and belongs to the Store, not the domain
object. For example, a JSON text column can opt into separate load and dump
functions:

```ruby
STORE = Hacienda::Store.new(
  database: APP.database,
  table: :workouts,
  record: Workout,
  coercions: {
    program_variants: {
      load: ->(value) { value.to_s.empty? ? {} : JSON.parse(value) },
      dump: ->(value) { JSON.generate(value || {}) }
    }
  }
)
```

Store performs partial updates using `record.changed_attributes`; unchanged
persisted records are a no-op. It owns `created_at` and `updated_at` when those
attributes are declared. Inserts are refreshed by default so database defaults
are available in memory; updates trust the in-memory values unless Store is
configured with `refresh: :always`. Call `STORE.refresh(record)` explicitly
when database triggers or defaults need to be reloaded.

The default `refresh: :insert` performs one `SELECT` after every insert. For an
insert-heavy path that does not use database defaults or triggers, configure
`refresh: false` to avoid that round trip:

```ruby
STORE = Hacienda::Store.new(
  database: APP.database,
  table: :events,
  record: Event,
  refresh: false
)
```

Optimistic locking is opt-in:

```ruby
attribute :lock_version, default: 0
STORE = Hacienda::Store.new(
  database: APP.database,
  table: :posts,
  record: Post,
  lock: :lock_version
)
```

A conflicting update raises `Hacienda::Store::StaleObject`; it never returns a
false success. Dirty state is cleared only after the database transaction
commits, so a rollback preserves the record's changes. Store deliberately has
no identity map: two finds return independent instances.

Finish mutating a record before calling `save`. Store takes its clean snapshot
when the surrounding transaction commits; mutations made after `save` but
before commit would otherwise become part of the clean baseline without being
written.

Attributes deep-copies mutable values when taking dirty-tracking snapshots.
That allows in-place changes such as `record.metadata["tags"] << "ruby"` to be
detected, but large JSON hashes and arrays cost an additional copy on load and
snapshot. For hot list endpoints, select smaller columns or keep large payloads
in a separate record when that cost matters.

Render errors in ERB:

```erb
<%= error_messages errors %>
```

Customize application error pages with plain ERB:

```text
app/errors/404.erb
app/errors/500.erb
```

Both templates render through the application layout and receive `status`,
`title`, `message`, `context`, and `error` locals. Development 500s keep the
framework debug page so exception details remain visible while building.

Whitelist request parameters before assigning attributes:

```ruby
attributes = params.permit(:title, :body)

post = Post.new(
  title: attributes[:title].to_s.strip,
  body: attributes[:body].to_s.strip
)
```

Nested form data is normalized to symbol keys:

```ruby
attributes = params.require(:post).permit(:title, :body)
```

If a required param is missing or empty, Hacienda returns `400 Bad Request`.

JSON request bodies use the same nested normalization and whitelisting:

```ruby
module Posts
  module Create
    def self.respond(_context, params)
      attributes = params.require(:post).permit(:title, :body)
      json Repository.create(attributes), status: 201
    end
  end
end
```

Requests with `Content-Type: application/json` or a vendor `+json` media type
must contain a top-level object. Malformed JSON and top-level arrays/scalars
return `400 Bad Request`. JSON values override query values with the same key;
route parameters override both. An empty body contributes no parameters, and
the input stream is rewound after parsing so an action can still read it.

For a session-authenticated JSON write, send the CSRF token in the
`X-CSRF-Token` header. Form submissions can continue using the generated
`_csrf` field.

ERB output is HTML-escaped by default:

```erb
<h1><%= post.title %></h1>
```

Framework helpers, layouts, partials, and components return safe HTML. Use
`raw` only for HTML that the application has already sanitised or constructed
itself:

```erb
<%= raw trusted_html %>
```

The `h` helper remains available for compatibility and explicit escaping.

Use small HTML helpers when they reduce boilerplate:

```erb
<%= link "Edit", path("/posts/:id/edit", id: post.id) %>
<%= button_to "Delete", path("/posts/:id", id: post.id), method: "delete", context: %>

<%= form_start "/posts", context: %>
  <input name="title">
  <button type="submit">Save</button>
<%= form_end %>
```

Read encrypted credentials:

```ruby
Hacienda.credentials.dig(:mail, :smtp_password)
```

Generated apps store encrypted secrets in `config/credentials.yml.enc`. The
local `config/master.key` is ignored by git; production can use
`HACIENDA_MASTER_KEY`. Hacienda writes `config/master.key` with `0600`
permissions; keep deployment secret files such as `.kamal/secrets` owner-readable
only as well.

```sh
bundle exec hac credentials:show
bundle exec hac credentials:edit
```

Send mail without mailer classes:

```ruby
Hacienda.mail(
  to: "reader@example.com",
  subject: "Welcome",
  text: "Hello from Hacienda"
).deliver_later
```

Generated apps write mail to `tmp/mail` in development. Production can use SMTP
with environment variables or encrypted credentials configured in `config/mail.rb`.
Mail can be sent synchronously with `deliver`, or queued with `deliver_later`.

Enqueue explicit jobs:

```ruby
module Posts
  module PublishWebhookJob
    def self.priority = 10

    def self.perform(post_id)
      post = Repository.find(post_id)
      # slow external work
    end
  end
end

Hacienda.enqueue Posts::PublishWebhookJob, post.id
Hacienda.enqueue_in 30, Posts::PublishWebhookJob, post.id
Hacienda.enqueue_at Time.now + 3600, Posts::PublishWebhookJob, post.id
```

Lower priority numbers run first. Jobs with the same priority are ordered by
their scheduled time and then insertion ID. Declare a default on the job module
with `def self.priority = 10`; the default is `0`.

Use `Hacienda.enqueue` when the work is independent of an open database
transaction. When a job depends on data being committed, enqueue it through the
transaction:

```ruby
context.transaction do |transaction|
  post.publish
  Posts::Repository.save(post)
  transaction.enqueue Posts::PublishWebhookJob, post.id
end
```

The database adapter inserts that job in the same Sequel transaction. A durable
external adapter declares its capabilities and uses `hacienda_job_outbox` for a
crash-safe hand-off after commit. Inline, async, and test adapters run through a
Sequel `after_commit` callback and are discarded on rollback. Nested savepoint
rollbacks are respected in every case.

Generated apps configure jobs in `config/jobs.rb`. Tests use `inline`,
development uses the lightweight in-process `async` adapter, and production
uses the durable `database` adapter. Durable jobs accept JSON values, symbols,
dates, and times; pass record IDs rather than live domain objects.

The built-in async adapter is intentionally small and in-process. It avoids
blocking responses, but queued jobs can be lost on restart. The database
adapter persists jobs, leases work atomically, retries failures with backoff,
reclaims expired leases after worker crashes, and moves a crashed final attempt
to the failed list. Running jobs renew their leases automatically. A replacement
worker also recovers jobs owned by a worker whose registry heartbeat has
expired, without waiting for the longer lease deadline.

Timeouts are deliberately cooperative, avoiding unsafe forced termination of a
Ruby thread. Set a default with `HACIENDA_JOB_TIMEOUT`, or declare one per job:

```ruby
def self.timeout = 30

def self.perform(record_ids)
  record_ids.each do |id|
    Hacienda::Jobs.checkpoint!
    process(id)
  end
end
```

Long loops should call `checkpoint!`; network and database operations should
also configure their own native timeouts. A job that never reaches a checkpoint
continues until it returns, then records the timeout instead of being reported
as successful.

Run a worker and inspect or retry terminal failures:

```sh
bundle exec hac jobs:work
bundle exec hac jobs:work --queue critical,default --threads 4 --batch-size 20
bundle exec hac jobs:work --all-queues --threads 4 --batch-size 20
bundle exec hac jobs:status
bundle exec hac jobs:health
bundle exec hac jobs:benchmark --jobs 1000 --threads 2 --batch-size 10
bundle exec hac jobs:list pending
bundle exec hac jobs:list completed --limit 20
bundle exec hac jobs:failed
bundle exec hac jobs:scheduled
bundle exec hac jobs:prune --completed 604800 --discarded 2592000 --failed 2592000
bundle exec hac jobs:pause mailers
bundle exec hac jobs:resume mailers
bundle exec hac jobs:recurring
bundle exec hac jobs:schedule
bundle exec hac jobs:cancel 42
bundle exec hac jobs:discard 42 "no longer needed"
bundle exec hac jobs:reschedule 42 300
bundle exec hac jobs:retry job 42
bundle exec hac jobs:retry handoff 9
bundle exec hac jobs:retry event 17
```

`hac jobs:work --once` performs one polling cycle. Repeat `--queue`, or pass a
comma-separated ordered list; `--all-queues` selects every queue. `--threads`,
`--batch-size`, and `--poll` control execution concurrency, claiming, and idle
latency. Selected queues are served in a fair round-robin cycle so a permanently
busy queue cannot starve the others. All-queue workers use global priority,
scheduled-time, and ID ordering.

Delivery is at least once, not exactly once: jobs must be safe to retry. Multiple
worker processes atomically claim distinct leases. Active worker identity,
process, host, queues, concurrency, heartbeat, and workload are recorded in
`hacienda_job_workers`; graceful shutdown finishes the currently claimed batch
without claiming more work.

`HACIENDA_JOB_LEASE_SECONDS`, `HACIENDA_JOB_HEARTBEAT_INTERVAL`,
`HACIENDA_JOB_TIMEOUT`, and `HACIENDA_JOB_WORKER_TIMEOUT` configure the safety
intervals. `HACIENDA_JOB_COMPLETED_RETENTION`,
`HACIENDA_JOB_DISCARDED_RETENTION`, and `HACIENDA_JOB_FAILED_RETENTION`
configure the default age used by `jobs:prune`; pass explicit `--completed`,
`--discarded`, or `--failed` seconds to override those defaults for one run.

Completed database jobs are retained with `completed_at`. Terminal failures and
cancellations are retained with `discarded_at` and still appear in
`jobs:failed` through their existing `failed_at` state. `jobs:status` reports
queue depth, scheduled and running work, active worker count, oldest pending
age, completed/discarded/failed totals, and simple completed-job throughput.
`jobs:health` reports supervisor-friendly checks for failed jobs, stale
workers, oldest pending age, paused queues, and running jobs; it exits non-zero
only when health is critical.
`jobs:list` inspects pending, running, scheduled, completed, discarded, or
failed jobs.

`jobs:benchmark` runs a repeatable qualification pass against the configured
database job adapter. It enqueues benchmark jobs, processes them through the
real worker claim/complete path, exercises an explicit failed-job retry cycle,
can drive concurrent GET requests against a chosen application path, can relay
job and event outbox rows, samples simple database latency while work is active,
runs a WAL checkpoint, and deletes only its own benchmark job rows unless
`--keep` is passed. Run it in staging, or during a production maintenance
window, after `db:check`:

```sh
bundle exec hac db:check
bundle exec hac jobs:benchmark --jobs 1000 --retry-jobs 25 --web-requests 250 --web-path /up --outbox-items 100 --threads 2 --batch-size 10 --latency-samples 100
```

For the generated single-host SQLite deployment, start with one web process,
one worker process, WAL mode, a 5 second busy-timeout, `--threads 2`,
`--batch-size 5..10`, and `--poll 0.25..1.0`. Keep
`HACIENDA_JOB_LEASE_SECONDS` comfortably above the longest normal job,
`HACIENDA_JOB_HEARTBEAT_INTERVAL` below one third of the lease, and set
explicit per-job or default `HACIENDA_JOB_TIMEOUT` values for slow external
I/O.

Treat sustained `SQLITE_BUSY` errors, `jobs:health` warnings that do not clear,
oldest pending age above your user-visible SLA, benchmark p95 database latency
above roughly 100-250ms under normal load, or WAL growth that needs frequent
manual checkpoints as signals to reduce worker concurrency or move the queue to
a client/server database through Sequel.

When SQLite busy/locked errors repeat in a short window, Hacienda logs a
throttled warning beginning with `sqlite_busy_contention`. Those warnings include
the source (`request`, `jobs`, `job_outbox`, `event_outbox`, or
`durable_queue`) and route or table metadata so you can distinguish ordinary
single write collisions from sustained write contention.

Generated apps mount a read-only queue dashboard at `/hac/jobs`, with JSON
health at `/hac/jobs/health`. Development access is local-only. Production
access requires `HACIENDA_DASHBOARD_PASSWORD` and uses HTTP Basic auth, with
username `hacienda` unless `HACIENDA_DASHBOARD_USERNAME` is set. The dashboard
checks local development access with the direct `REMOTE_ADDR` socket address,
not spoofable forwarding headers. It is an operational view over the existing
queue tables, not a required runtime dependency.

Bulk enqueue accepts explicit job entries and uses the database adapter’s bulk
insert path when available:

```ruby
ids = Hacienda.enqueue_all([
  {job: Reports::GenerateJob, args: [user.id], kwargs: {}},
  {job: Reports::GenerateJob, args: [other_user.id], kwargs: {}}
]) do |inserted_ids|
  Hacienda.logger.info("enqueued #{inserted_ids.length} report jobs")
end
```

Inside a request transaction, `transaction.enqueue_all([...])` participates in
the same Sequel transaction for the built-in database adapter, so a rollback
removes both the domain write and the queued jobs.

Jobs can opt into enqueue uniqueness and execution concurrency limits with
plain module methods:

```ruby
module Reports::GenerateJob
  module_function

  def unique_key(user_id)
    "reports:generate:#{user_id}"
  end

  def unique_for = 10 * 60
  def unique_conflict = :keep # or :raise

  def concurrency_key(user_id)
    "reports:user:#{user_id}"
  end

  def concurrency_limit = 1

  def perform(user_id)
    # expensive report generation
  end
end
```

Uniqueness is enforced at enqueue time until `unique_for` expires. The default
conflict behavior is `:keep`, which returns the existing job ID; `:raise`
raises `Hacienda::Jobs::Error`. Concurrency limits are enforced when workers
claim jobs. Jobs blocked by a concurrency limit remain visible through
`hac jobs:list blocked`, and `jobs:status` includes a blocked count. A worker
crash releases concurrency naturally when abandoned leases are recovered.

Queues can be paused and resumed operationally. Pausing a queue records it in
`hacienda_job_queues`, blocks pending work with a visible reason, and prevents
future claims until `hac jobs:resume QUEUE` is run. Lifecycle operations are
explicit: `jobs:cancel` requests cooperative cancellation for running work or
cancels pending work; `jobs:discard` only discards unlocked active jobs;
`jobs:reschedule` only moves unlocked active jobs to a future time; and
`jobs:retry` only revives terminal failed jobs.

`jobs:failed` distinguishes ordinary terminal errors, timeouts, cancellations,
abandoned workers, and expired leases. Retryable failures, terminal failures,
timeouts, cancellations, and uncertain lease loss are also reported separately
by the worker.

Each worker loop claims up to its configured job batch, plus one
external-adapter hand-off and one event outbox entry. It does not sleep while
any backlog has work, but an idle item can wait for up to the configured poll
interval. `SIGTERM` and `SIGINT` stop the worker after its current batch or
outbox item finishes.

Custom adapters implement:

```ruby
def capabilities = %i[durable external idempotent_handoff scheduled priorities]

def enqueue(job, args:, kwargs:, queue:, priority:, scheduled_at:, idempotency_key:)
  # Publish to the external queue. The hand-off ID is stable across retries.
end
```

The built-in adapters declare their capabilities explicitly. External and
cross-database durable adapters require `Hacienda::Jobs::Outbox`; Hacienda will
raise instead of silently weakening transaction safety when it is absent.
The database and async adapters honor delayed execution and priorities. The
test adapter records that metadata; the inline adapter intentionally performs
immediately.

Subscribe to job lifecycle notifications when you want application logging or
metrics without a monitoring dependency:

```ruby
Hacienda::Jobs.subscribe do |event, payload|
  Hacienda.logger.info("job.#{event} #{payload.inspect}")
end
```

The built-in database adapter emits `:enqueue`, `:start`, `:finish`, `:retry`,
`:timeout`, `:discard`, and `:lease_loss`.

### Queue capability matrix

| Capability | Hacienda database queue | Solid Queue comparison |
| --- | --- | --- |
| Durable database-backed jobs | Supported through Sequel tables | Comparable goal |
| Transactional enqueue with app writes | Supported when using the same Sequel database | Comparable goal |
| External adapter hand-off after commit | Supported through `hacienda_job_outbox` | Hacienda-specific |
| Delayed jobs and priorities | Supported | Comparable goal |
| Multiple queues and worker selection | Supported with ordered queues or all-queue priority mode | Comparable goal |
| Atomic batch claiming | Supported | Comparable goal |
| Retries and failed-job visibility | Supported | Comparable goal |
| Lease renewal and crash recovery | Supported | Comparable goal |
| Worker registry and health checks | Supported | Comparable goal |
| Recurring jobs | Supported with Hacienda's narrow interval syntax | Intentional narrower design |
| Uniqueness and concurrency limits | Supported opt-in per job | Comparable operational feature |
| Pause/resume/cancel/discard/reschedule | Supported through explicit CLI commands | Comparable operational feature |
| Dashboard | Read-only built-in dashboard | Narrower than Rails ecosystem dashboards |
| Active Job API compatibility | Not provided | Intentional omission |
| Active Record/Railties dependency | Not required | Intentional omission |
| First-party Redis/Sidekiq adapter | Planned as optional separate package | Not core |
| PostgreSQL production qualification | Pending through Sequel | Roadmap item |

Recurring jobs live in `config/recurring.yml`:

```yaml
tasks:
  cleanup:
    job: "Maintenance::CleanupJob"
    every: "1 hour"
    queue: "default"
    priority: 0
    enabled: true
    args: []
    kwargs: {}
```

The schedule syntax is deliberately narrow and dependency-free: use integer
seconds or interval strings such as `5 minutes`, `1 hour`, or `1 day`. The
scheduler aligns each task to interval slots and records `(task_name,
scheduled_at)` in `hacienda_recurring_runs`, protected by a unique index, so
multiple scheduler processes do not enqueue the same slot twice.

Run the scheduler with `hac jobs:schedule`; use `--once` for a single tick.
Inspect and validate tasks with `hac jobs:recurring`, manually trigger one with
`hac jobs:recurring run cleanup`, and toggle YAML `enabled` state with
`hac jobs:recurring disable cleanup` or `hac jobs:recurring enable cleanup`.

Durable arguments use JSON-style hash semantics. Top-level keyword argument
keys are restored as symbols so Ruby keyword calls work; keys in nested hashes
are restored as strings. Domain events follow the same rule when rebuilt from
their `to_h` payload.

Coordinate database changes and domain events explicitly:

```ruby
context.transaction do |transaction|
  post.publish
  Posts::Repository.save(post)

  transaction.emit Posts::Events::Published.new(
    post_id: post.id,
    occurred_at: Time.now
  )
end
```

Pass the Sequel database and optional outbox when constructing the application:

```ruby
APP = Hacienda::Application.new(
  root: APP_ROOT,
  database: DB,
  outbox: Hacienda::Events::Outbox.new(database: DB)
)
```

Register plain Ruby callables after the application has been created:

```ruby
APP.events.configure do |events|
  events.subscribe(
    Posts::Events::Published,
    Notifications.method(:post_published)
  )
end
```

Without an outbox, events are delivered synchronously in declaration order
after commit. With an outbox, `transaction.emit` inserts the serialized event
inside the same database transaction and the worker delivers it later. A
rollback therefore removes both the business write and its pending event.

Outbox delivery is also at least once. If one subscriber fails, successful
subscribers may receive the event again on retry, so subscriber side effects
must be idempotent. Events must be named classes that respond to `to_h`; they
are rebuilt with keyword arguments, or with a custom class-level `from_h`.
Use direct calls inside the transaction for invariants that must succeed before
commit. This is reliable domain-event delivery, not event sourcing or a
distributed pub/sub system.

Use a recorder in tests:

```ruby
recorder = Hacienda::Events::Recorder.new
subscription = APP.events.subscribe(Posts::Events::Published, recorder)

# perform the command

assert_equal post.id, recorder.events.last.post_id
APP.events.unsubscribe(subscription)
```

See [`examples/blog/config/events.rb`](examples/blog/config/events.rb) for a
complete reload-safe registration setup.

Generate and verify signed tokens:

```ruby
token = Hacienda.signed_token.generate(
  { user_id: user.id },
  purpose: "email_verification",
  expires_in: 24 * 60 * 60
)

payload = Hacienda.signed_token.verify(token, purpose: "email_verification")
```

Generated auth includes email verification, magic-link login, and password reset
flows backed by signed expiring tokens and mail delivery. Email verification and
magic-link login use a GET confirmation page followed by a CSRF-protected POST,
so link scanners cannot complete the flow by fetching the URL. Password reset
links use a reset-version token rather than exposing password hashes.

Generated apps require `HACIENDA_SESSION_SECRET` or `SESSION_SECRET` in
production. Development keeps a visible fallback secret so local apps boot
without setup. Cookie sessions expire after 30 days by default; override that
with `HACIENDA_SESSION_EXPIRE_AFTER` in seconds. To rotate the session secret
without immediately logging everyone out, deploy the new value as
`HACIENDA_SESSION_SECRET` and keep the previous value in
`HACIENDA_SESSION_SECRET_OLD` until old cookies have expired. Multiple old
secrets may be comma-separated.

Hacienda's default sessions are encrypted client-side cookies. That keeps the
stack small and fast, but it also means logout cannot revoke a stolen cookie
that was copied before logout; it remains usable until expiry or secret
rotation. Use short expiries for sensitive applications. Set
`HACIENDA_SESSION_STORE=database` to store session payloads in Sequel instead;
that keeps only an opaque id in the browser, uses the generated
`hacienda_sessions` table, and allows server-side revocation by deleting rows.
Expired database sessions can be pruned with
`Hacienda::SessionStore#prune_expired`.

Generated auth emails use `Hacienda.app_url`, not the request `Host` header, so
password reset and verification links come from one canonical origin. Configure
that origin with `HACIENDA_APP_URL`, legacy `APP_URL`, or
`credentials.hacienda.app_url`; production requires one of them. Generated
production apps also derive their default host allowlist from that canonical
URL. Set `HACIENDA_ALLOWED_HOSTS` to a comma-separated list when a deployment
needs additional accepted hosts.

Generated apps also include security headers, a default Content Security Policy,
and rate limits for auth-sensitive POST routes. Configure those in `config.ru`:

```ruby
use Hacienda::Middleware::HostAuthorization,
  hosts: ["example.com"]

use Hacienda::Middleware::SecurityHeaders,
  hsts: Hacienda.env.production?,
  csp: {
    "default-src" => ["'self'"],
    "script-src" => ["'self'", :nonce],
    "style-src" => ["'self'", :nonce]
  }

use Hacienda::Middleware::RateLimiter,
  rules: [
    {method: "POST", path: "/login", limit: 10, period: 60}
  ]
```

The default rate limiter store is in-process. It is thread-safe and expired
buckets are swept. It also caps the number of live buckets to avoid unbounded
growth from many distinct identities. It is not shared across Puma workers or
multiple servers. By default it keys on `request.ip`, so deployments behind a
proxy must ensure the proxy overwrites untrusted forwarding headers rather than
passing client-supplied `X-Forwarded-For` through unchanged. Pass a custom
`store:` or `key:` if the app needs shared limits or different identity rules.

HSTS is disabled by default at the middleware level and enabled by generated
apps only in production. That assumes HTTPS is terminated correctly by your
proxy or load balancer before traffic reaches the Rack app.

Use `:nonce` in CSP directives to include the per-request nonce. Views can read
the same value with `csp_nonce context`, or ask asset helpers to add it:

```erb
<script nonce="<%= csp_nonce context %>">
  window.appBooted = true
</script>

<%= javascript_include "admin.js", nonce: true, context: %>
```

CSRF tokens are intentionally simple signed-session tokens rather than masked
per-render tokens. Do not enable HTTP compression for pages that reflect secrets
into the response if BREACH-style attacks are in scope for your deployment.

## Caching

Every application owns an explicit cache, available as `APP.cache` or
`context.cache`. The API is deliberately small:

```ruby
context.cache.write(["posts", post.id], post, expires_in: 60)
post = context.cache.read(["posts", post.id])
context.cache.delete(["posts", post.id])

post = context.cache.fetch(["posts", post.id], expires_in: 60) do
  Posts::Repository.find(post.id)
end
```

`fetch` caches `false`, but does not cache `nil`. Array keys are expanded into
readable namespaced strings, and objects can define `cache_key`. Prefer
versioned keys containing `updated_at` for fragments so writes naturally move
to a new entry.

`fetch` deliberately provides no stampede or dogpile lock. Concurrent misses
can all execute the block, including across Puma threads, workers, and hosts.
Likewise, nil-returning work repeats because nil is not negatively cached. Use
an application-specific per-key/distributed lock or an explicit cached sentinel
when either behavior matters; Hacienda does not impose those semantics on every
cache.

The built-in `MemoryStore` is thread-safe, TTL-aware, and bounded with
least-recently-used eviction:

```ruby
store = Hacienda::Cache::MemoryStore.new(max_size: 1_000)
Hacienda.configure_cache(store:, namespace: "blog")
```

At capacity, the memory store finds the least-recently-used entry with an O(n)
scan on each new write. That cost is negligible at the generated 1,000-entry
default. Use a purpose-built external cache instead of raising the bound to a
very large value.

Generated apps use it in development and test. Production defaults to
`NullStore`, making caching an explicit deployment decision rather than
silently creating inconsistent per-worker caches. A production adapter only
needs `read(key)`, `write(key, value, expires_in:)`, and `delete(key)`:

```ruby
Hacienda.configure_cache(store: RedisCacheStore.new(redis), namespace: "blog")
```

Cache partial or component output in ERB with a block that returns safe HTML:

```erb
<%= cache_fragment(["post-card", post.id, post.updated_at.to_f],
      context:, expires_in: 300) { component(:post_card, post:) } %>
```

For conditional HTTP caching, `context.stale?` sets `ETag`, `Last-Modified`,
and optional `Cache-Control` headers. Return `304` when the request is fresh:

```ruby
stale = context.stale?(
  etag: ["post", post.id, post.updated_at.to_f],
  last_modified: post.updated_at,
  public: true,
  max_age: 60
)
return response("", status: 304) unless stale
```

Only mark a full HTML response public when it has no user-specific layout,
authorization state, session data, or flash messages. `stale?` only treats GET
and HEAD requests as conditionally fresh.

## File uploads and storage

Rack parses multipart forms; Hacienda turns the resulting upload into explicit
storage metadata. Forms opt into multipart encoding normally:

```erb
<%= form_start "/posts", context:, enctype: "multipart/form-data" %>
  <input type="file" name="cover" accept="image/jpeg,image/png,image/webp">
<%= form_end %>
```

An action validates and stores the raw upload separately from permitted scalar
attributes:

```ruby
attributes = params.permit(:title, :body)

blob = context.storage.store(
  params[:cover],
  prefix: "post-covers",
  max_bytes: 5 * 1024 * 1024,
  content_types: ["image/jpeg", "image/png", "image/webp"]
)

post.attach_cover(blob)
```

`Storage#store` returns a `Hacienda::Storage::Blob` containing `key`, sanitized
original `filename`, declared `content_type`, `byte_size`, SHA-256 `checksum`,
and `url`. Hacienda does not create a blobs table: persist the fields the domain
needs in its own repository. Generated keys use a date, random UUID, and safe
extension; explicit keys reject absolute paths, traversal, empty segments, and
backslashes.

The service API is small:

```ruby
APP.storage.read(key)
APP.storage.open(key) { |io| process(io) }
APP.storage.exist?(key)
APP.storage.delete(key)
APP.storage.url(key)
```

Generated apps use `DiskService` in development, `MemoryService` in tests, and
`NullService` in production. Production therefore fails loudly on a write until
`config/storage.rb` is connected to object storage. A custom service implements
`write(key, io, overwrite:)`, `open(key)`, `delete(key)`, `exist?(key)`, and
`url(key)`. Services must make `overwrite: false` an atomic create-if-absent
operation; the built-in disk and memory services guarantee this.

`Hacienda::Middleware::StorageFiles` serves local disk/memory files at
`/uploads`. It streams bodies, blocks traversal, adds `nosniff` and a sandboxed
CSP, and only renders a conservative image allowlist inline; HTML, SVG, and
other types are forced to download. Remote object-storage adapters set
`local?` to false and return their own public or signed URLs.

`StorageFiles` performs no authentication. Its random URLs are public
capability URLs: anyone who obtains one can fetch the file. Do not mount private,
owner-only, medical, financial, or otherwise sensitive files through this
middleware. Serve those from an authenticated application route or use
short-lived signed URLs from a remote adapter.

Security boundaries remain explicit:

- browser filenames and content types are untrusted metadata;
- `content_types:` checks the declared media type, not file signatures;
- `max_bytes:` validates the parsed file, so also enforce request-body limits at
  the proxy/server for denial-of-service protection;
- store a replacement before deleting the old object, and clean up a new object
  when a database write fails;
- `overwrite: false` is atomic, but `overwrite: true` intentionally replaces the
  named object;
- a process crash after storage succeeds but before the database commits can
  still leave an orphan; reconcile persisted keys with storage periodically or
  schedule a sweep job;
- disk storage is process-local and needs a persistent shared volume only for a
  deliberate single-server deployment.

See the blog's `Posts::Coverable` behavior and create/update actions for a full
multipart-to-domain example.

## Navigation

Generated applications enable Hacienda Navigation by default. Same-origin GET
links fetch and morph the single `#hacienda-page` target using the vendored
Idiomorph library. The layout remains in place while the URL, title, focus,
scroll position, active navigation links, and browser history are updated.
Likely destinations are prefetched after hover, focus, or touch intent and held
in a small, time-limited cache.

The generated layout shows the complete integration:

```erb
<title><%= document_title %></title>
<%= hacienda_navigation context %>
<body>
  <%= navigation_page content, context: context %>
  <script type="module" src="/assets/helium-csp.js"></script>
</body>
```

Set a response title in a view with `page_title "Posts"`. Configure or disable
navigation at application construction:

```ruby
APP = Hacienda::Application.new(
  root: APP_ROOT,
  navigation: {prefetch: :intent, cache_size: 20, cache_ttl: 15}
)

# navigation: false
```

Helium remains independent. Its `MutationObserver` is the official integration
mechanism: newly inserted nodes are bound, removed nodes are cleaned up, and
unchanged nodes retain their state. If a preserved node's Helium directive
attributes (`@...`, `:...`, or `data-he...`) change, Hacienda replaces that node
so Helium can bind the new directives safely. Hacienda does not perform a
Turbo-style global teardown and reinitialization.

Helium's Server-Sent Events support is available as an optional add-on. New
applications vendor `helium-sse.js` and `helium-csp-sse.js` beside the default
assets. If a page uses Helium requests that expect `text/event-stream`, load
`/assets/helium-csp-sse.js` instead of `/assets/helium-csp.js` in that layout.
Hacienda Navigation still handles page-to-page GET morphing; Helium SSE is the
lighter live-update path for individual moving parts on a page.

The app-facing lifecycle events are:

- `hacienda:before-navigate` (cancelable)
- `hacienda:navigation-start`
- `hacienda:before-morph` (cancelable)
- `hacienda:load`
- `hacienda:navigation-error`
- `hacienda:navigation-end`
- `hacienda:invalidate` (dispatch to clear the prefetch cache)

`hacienda:load` fires on the animation frame after the morph. MutationObserver
callbacks, including Helium's normal synchronous binding pass, have therefore
run before application listeners receive it. Code loaded asynchronously by a
Helium `@import` directive can finish later and should expose its own readiness
signal when ordering matters.

Use `data-hacienda-navigation="off"` on a link or ancestor for a native page
load, `data-hacienda-prefetch="off"` to disable prefetching for a link, and
`data-hacienda-permanent` to preserve an element across morphs. An action can
force a full reload with `context.navigation_reload!`. Non-2xx, non-HTML,
cross-origin, incompatible, and explicitly opted-out responses fall back to
normal browser navigation.

Normal POST, PATCH, and DELETE forms intentionally remain native in this first
version. A successful write followed by a redirect performs one full page load,
then GET navigation resumes. Helium can progressively enhance individual forms
without requiring a framework-wide form protocol.

Client tests are development-only and do not add Node.js to generated apps:

```sh
npm run test:client
npm run test:browser
```

Environment-specific config lives in:

```text
config/environments/
  development.rb
  test.rb
  production.rb
```

Use the current environment in app code:

```ruby
Hacienda.env.production?
Hacienda.logger.info "Published post"
```

Generated apps enable code reloading in development. Action modules and route
files are reloaded on each request, so adding or removing routes does not require
a server restart while developing. Development requests are serialized around
reload so a threaded server cannot reload constants while another request is
using them.

Actions can live together in `app/domains/posts/actions.rb` or be split into
`app/domains/posts/actions/show.rb`-style files. Hacienda loads `actions.rb`
first, so an inline `Posts::Show` wins if both layouts define the same action.
Split action files are managed by Zeitwerk: each domain's `actions/` directory
is collapsed so `app/domains/posts/actions/show.rb` maps directly to
`Posts::Show`. On reload, Hacienda reloads inline action manifests, Zeitwerk
unloads the managed domain generation, and Hacienda redraws the explicit route
files. This keeps repositories, behavior modules, nested constants, actions,
guards, and cross-domain references on the same generation.

Route files are intentionally ignored by Zeitwerk because they declare route
data rather than a `Routes` constant. The ignore and action-collapse rules use
glob patterns that are recomputed on reload, so newly added domains work without
a restart.

Keep references to reloadable application code inside `app/domains`, and use
constant names such as `"Auth::LoadCurrentUser"` for application-level context
loaders. Do not cache a domain class or module in non-reloadable configuration;
doing so deliberately holds the previous generation, just as it would in other
Zeitwerk-based applications.

See [`examples/blog`](examples/blog) for a complete application with domain
objects, composable behavior modules, policies, authentication, guarded routes,
Sequel repositories, migrations, ERB components, and Helium.

See [`examples/todomvc`](examples/todomvc) for a smaller TodoMVC-style app that
keeps writes HTML-first while using a lot of Helium for filtering, counters,
editing affordances, keyboard shortcuts, optimistic UI updates, and previews.

See [`examples/workouts`](examples/workouts) for a larger AI-backed application
with structured OpenAI responses, explicit Sequel JSON persistence, composable
domain behaviour, and Helium-powered partial updates without Turbo.

See [`docs/getting-started.md`](docs/getting-started.md) and
[`examples/store`](examples/store) for a Rails Guides-style walkthrough and its
complete store application, including an explicit feature-gap comparison.

See [`examples/site`](examples/site) for Hacienda’s own database-free website,
including the product homepage, ten-minute blog quick start, and web-rendered
store guide.
