# frozen_string_literal: true

module Lunula
  class Generator
    module DocumentationTemplates
      private

      def deployment_readme
        <<~'MARKDOWN'.gsub("%APP%", deployment_name)
          # Deploying %APP%

          The generated Docker and Kamal files provide a production starting
          point for one Linux server using SQLite. Edit `config/deploy.yml`
          before using it.

          ## Prepare the application

          Install dependencies and commit `Gemfile.lock`; the Docker build is
          intentionally locked and will fail without it. The build also runs
          `luna assets:precompile`, so the final image contains fingerprinted
          assets and the production manifest:

          ```sh
          bundle install
          git add Gemfile.lock
          ```

          If Lunula is referenced through a local `path:` in `Gemfile`, replace
          it with a released gem version before building outside the framework
          checkout.

          ## Test the image locally

          ```sh
          docker build -t %APP% .
          docker volume create %APP%_db
          export LUNULA_SESSION_SECRET=$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')
          docker run --rm \
            -e LUNULA_MASTER_KEY="$(cat config/master.key)" \
            -e LUNULA_SESSION_SECRET \
            -e DATABASE_URL=sqlite:///app/db/production.sqlite3 \
            -v %APP%_db:/app/db \
            %APP% bundle exec luna db:migrate
          docker run --rm -p 5151:5151 \
            -e LUNULA_MASTER_KEY="$(cat config/master.key)" \
            -e LUNULA_SESSION_SECRET \
            -e DATABASE_URL=sqlite:///app/db/production.sqlite3 \
            -v %APP%_db:/app/db \
            %APP%
          ```

          Open <http://localhost:5151/up>; it should return `OK`.

          ## Deploy with Kamal

          You need a Linux server reachable over SSH, a container registry, and
          a domain whose DNS points to the server.

          1. Replace `192.0.2.1`, `app.example.com`, and
             `your-registry-user` in `config/deploy.yml`.
          2. Keep local deployment secret files owner-readable only:

             ```sh
             chmod 600 config/master.key .kamal/secrets
             ```

          3. Export the registry and session secrets:

             ```sh
             export KAMAL_REGISTRY_PASSWORD="registry-access-token"
             export LUNULA_SESSION_SECRET=$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')
             # During rotation only:
             # export LUNULA_SESSION_SECRET_OLD="previous-secret"
             ```

          Sessions use encrypted client-side cookies by default. They expire
          after 30 days; set `LUNULA_SESSION_EXPIRE_AFTER` to a positive number
          of seconds to change that. To rotate `LUNULA_SESSION_SECRET`, deploy
          the new value and keep the previous value in
          `LUNULA_SESSION_SECRET_OLD` until old cookies have expired. Logout
          removes the browser's current cookie, but a stolen copy remains
          replayable until expiry or secret rotation because the default store
          has no server-side revocation list.

          Set `LUNULA_SESSION_STORE=database` to store session payloads in
          Sequel instead. That keeps only an opaque id in the browser, uses the
          generated `lunula_sessions` table, and allows server-side revocation
          by deleting rows. Run migrations before enabling it.

          3. Run the first deployment and migrate the database:

             ```sh
             bundle exec kamal setup
             bundle exec kamal migrate
             ```

          Later deployments use `bundle exec kamal deploy`. Other generated
          aliases include `kamal console`, `kamal seed`, and `kamal logs`.

          Kamal Proxy terminates TLS and checks `/up` before routing traffic to a
          new container. Production logs go to stdout so `kamal logs` can read
          them.

          ## Database and migration constraints

          The named `%APP%_db` volume persists SQLite data across deployments.
          Generated apps configure SQLite with WAL mode, foreign-key enforcement,
          `synchronous = NORMAL`, and a 5 second busy-timeout outside test. This
          is a single-server configuration: keep web, worker, scheduler, SQLite,
          and local uploads on the same host and persistent volumes.

          Run `bundle exec luna db:check` after deployment to verify WAL,
          busy-timeout, foreign keys, and storage-path assumptions. Run
          `bundle exec luna db:checkpoint --mode TRUNCATE` during maintenance if
          the WAL file grows unexpectedly after a burst of writes.

          Use an external PostgreSQL or MySQL database and update `DATABASE_URL`
          before adding another web host.

          A container rollback does not roll back database migrations. Prefer
          additive, backwards-compatible migrations; use separate
          expand/migrate/contract deployments for destructive schema changes.
          Back up the database volume before significant migrations. SQLite
          backups must include WAL state; use a SQLite-aware tool such as
          Litestream or the SQLite online backup API rather than copying only the
          main database file while the app is running. The generated
          `config/litestream.yml.example` is a starting point; copy it to
          `config/litestream.yml`, fill in the replica destination, and run
          Litestream beside the app through your host supervisor. Back up local
          uploads separately from SQLite.

          ## Jobs and event delivery

          Production uses Lunula's durable database job adapter and the
          transactional event outbox. The generated `job` server role runs
          `luna jobs:work` on the same host and volume; that worker also relays
          durable job hand-offs and event outbox deliveries. The generated
          `scheduler` role runs `luna jobs:schedule` for recurring tasks.
          Delivery is at least once, so jobs and event subscribers must be
          idempotent.

          Qualify the queue on the deployed host after `luna db:check`:

          ```sh
          bundle exec luna jobs:benchmark --jobs 1000 --retry-jobs 25 --web-requests 250 --web-path /up --outbox-items 100 --threads 2 --batch-size 10
          ```

          The benchmark uses the real database job adapter, worker
          claim/complete path, failed-job retry path, optional web requests,
          durable outbox relays, a WAL checkpoint, and simple database latency
          samples. It deletes only its own benchmark rows unless `--keep` is
          passed. For the generated single-host SQLite shape, start with one
          worker process, `--threads 2`, `--batch-size 5..10`, and
          `--poll 0.25..1.0`. Lower worker concurrency if web requests or
          benchmark p95 database latency degrade under load.

          Inspect terminal failures with
          `kamal app exec --role job "bundle exec luna jobs:failed"` and check
          worker health with
          `kamal app exec --role job "bundle exec luna jobs:health"`.

          The mounted dashboard at `/luna/jobs` is read-only. In development it is
          local-only. In production it returns forbidden unless
          `LUNULA_DASHBOARD_PASSWORD` is set, in which case it uses HTTP Basic
          auth with username `lunula` unless `LUNULA_DASHBOARD_USERNAME` is
          also set. Development local-only checks use the direct `REMOTE_ADDR`
          socket address, not forwarding headers.

          Configure SMTP secrets in `.kamal/secrets` and `config/deploy.yml` if
          the application sends mail.

          Production storage defaults to `NullService`. Configure an object-store
          adapter in `config/storage.rb`. If disk storage is deliberately used on
          one server, mount `LUNULA_STORAGE_ROOT` as a separate persistent
          volume; do not bake uploaded files into the image.

          The local `/uploads` middleware serves public capability URLs without
          authorization. Private files need guarded application routes or signed
          remote URLs. Database and storage writes are not one transaction, so
          applications with strict retention requirements should run a periodic
          orphan-file sweep.

          See the [Kamal documentation](https://kamal-deploy.org/docs/installation/)
          for server, registry, proxy, and command details.
        MARKDOWN
      end

      def app_readme
        <<~MARKDOWN
          # Lunula application

          Start the application:

          ```sh
          bundle install
          bundle exec luna db:migrate
          # Optional application seed data:
          bundle exec luna db:seed
          bundle exec luna start
          ```

          `luna start` runs Rackup on port 5151. The equivalent direct command is:

          ```sh
          bundle exec rackup -p 5151
          ```

          Both startup paths check for pending migrations. `luna start` refuses
          to boot and prints the pending filenames; direct Rack requests receive
          an actionable development `503` page. Lunula never migrates
          automatically at web-process boot.

          Development serves the readable source files in `public/assets`.
          Production resolves asset helpers through a fingerprint manifest. The
          generated Dockerfile compiles it automatically; for another deployment
          method run:

          ```sh
          bundle exec luna assets:precompile
          ```

          Use `bundle exec luna assets:clobber` to remove compiled copies while
          preserving the source files.

          Open a console with the application environment loaded:

          ```sh
          bundle exec luna console
          ```

          Manage the database through the same application environment:

          ```sh
          bundle exec luna db:migrate
          bundle exec luna db:rollback       # one migration
          bundle exec luna db:rollback 3     # three migrations
          bundle exec luna db:seed
          bundle exec luna db:check
          bundle exec luna db:checkpoint --mode TRUNCATE
          ```

          `db:seed` loads `db/seeds.rb` without implicitly running migrations.
          `db:check` reports SQLite production settings such as WAL mode,
          busy-timeout, foreign keys, and unsafe synced-storage paths.
          `db:checkpoint` runs an explicit SQLite WAL checkpoint.

          Run the generated Minitest and Rack::Test suite:

          ```sh
          bundle exec rake test
          ```

          `test/test_helper.rb` boots the complete `config.ru` middleware stack in
          the test environment, applies pending test-database migrations, and
          provides `ApplicationTest`, `database`, and `csrf_token` helpers.

          Keep focused tests beside their owning domain under
          `test/domains/<domain>`: plain object tests call Ruby directly,
          repository tests use the isolated database, and action tests may use
          `ApplicationTest` for the Rack contract. Keep complete customer journeys
          and cross-domain workflows under `test/integration`. These test paths
          mirror production ownership without entering the `app/domains`
          autoload tree. Domain generators create the mirrored directory; action,
          REST, and authentication generators add executable behavior tests.

          List routes with their action methods and guards:

          ```sh
          bundle exec luna routes
          bundle exec luna routes --domain posts
          bundle exec luna routes GET /posts/42
          ```

          Business routes live only in `app/domains/*/routes.rb`; their file owns
          the route and its action namespace. Rack infrastructure mounts stay in
          `config.ru`. Lunula rejects duplicate, structurally equivalent, and
          equal-specificity ambiguous routes during boot and reload. By default a
          route maps to a method on the domain's `Actions` class and renders its
          matching ERB view when it returns a Hash. Additional multi-method action
          sets can live in `app/domains/posts/actions/publishing_actions.rb` and
          be selected with `actions: :publishing` in the route.

          Branded error pages live in `app/errors/404.erb` and
          `app/errors/500.erb`. They render through the application layout and
          receive `status`, `title`, `message`, `context`, and `error` locals.
          Development 500s keep the framework debug page.

          Generated REST resources use `Lunula::Attributes` and the compact
          `Lunula::Repository` facade over `Lunula::Store`. Repositories receive
          the application database through `APP.database`, while `dataset` remains
          available for custom Sequel queries.

          Actions receive request-scoped context separately from parameters:

          ```ruby
          module Posts
            class Actions < Lunula::Actions
              def create(context, params)
              end
            end
          end
          ```

          Form, query, route, and top-level JSON object parameters all use the
          same nested `Params` API. Whitelist input explicitly:

          ```ruby
          attributes = params.require(:post).permit(:title, :body)
          ```

          Malformed JSON returns `400 Bad Request`. Session-authenticated JSON
          writes send their CSRF token in the `X-CSRF-Token` header.

          `Lunula::Middleware::RequestLimits` bounds request bodies, query
          strings, multipart parts/files, parameter count, and nesting. Override
          the generated `LUNULA_MAX_*` values when needed, and configure matching
          proxy body limits plus slow-client read/header timeouts.

          The application cache is available as `context.cache` in actions and
          `APP.cache` elsewhere. Development and test use a bounded memory store;
          production defaults to the null store until `config/cache.rb` is wired
          to a shared adapter.

          ```ruby
          value = context.cache.fetch(["posts", post.id], expires_in: 60) { expensive_value }
          ```

          Multipart uploads are stored explicitly through `context.storage`.
          Development uses `storage/`, tests use memory, and production defaults
          to a null service until `config/storage.rb` is connected to object
          storage:

          ```ruby
          blob = context.storage.store(
            params[:file],
            max_bytes: 5 * 1024 * 1024,
            content_types: ["image/*"],
            content_inspector: Lunula::Storage::ContentTypeInspector.new
          )
          ```

          Local `/uploads` URLs are public and unguarded. Store private files
          behind an authenticated route or a remote service with signed URLs.
          Filenames and declared media types are client supplied. Signature checks
          do not make polyglots or compressed files safe; decode/scan them with
          explicit resource limits when the application accepts those formats.

          Encrypted credentials live in `config/credentials.yml.enc`. Keep
          `config/master.key` local, or set `LUNULA_MASTER_KEY` in production.
          Keep `config/master.key` and `.kamal/secrets` owner-readable only
          (`chmod 600`).

          ```sh
          bundle exec luna credentials:show
          bundle exec luna credentials:edit
          ```

          Security headers, CSRF protection, host authorization, and auth route
          rate limits are wired in `config.ru`. HSTS is enabled only in
          production, assuming HTTPS terminates at your proxy. The default rate
          limiter keys on `request.ip`, so the proxy must overwrite untrusted
          forwarding headers rather than passing client-supplied
          `X-Forwarded-For` through unchanged. CSRF tokens are unmasked; avoid
          compressing pages that reflect secrets if BREACH-style attacks are in
          scope. CSP directives can use `:nonce`, and views can read the matching
          value with `csp_nonce context` for inline scripts or styles.

          Mail writes to `tmp/mail` in development. Read it at `/luna/mail`, which
          is local-only and unavailable in production. Configure SMTP with env
          vars or encrypted credentials in `config/mail.rb`.

          Background jobs are configured in `config/jobs.rb`. Development uses
          the async in-process adapter, tests run inline, and production persists
          jobs in the database. Run production work with:

          ```sh
          bundle exec luna jobs:work
          bundle exec luna jobs:work --queue critical,default --threads 4 --batch-size 20
          bundle exec luna jobs:health
          bundle exec luna jobs:benchmark --jobs 1000 --web-requests 250 --web-path /up --outbox-items 100 --threads 2 --batch-size 10
          bundle exec luna jobs:failed
          bundle exec luna jobs:scheduled
          bundle exec luna jobs:recurring
          bundle exec luna jobs:schedule
          ```

          For the generated single-host SQLite deployment, start with one worker
          process, two worker threads, a batch size between 5 and 10, and a poll
          interval between 0.25 and 1.0 seconds. Treat sustained `SQLITE_BUSY`
          errors, oldest pending age above your user-visible SLA, frequent manual
          WAL checkpoints, or benchmark p95 database latency above roughly
          100-250ms as signs to reduce worker concurrency or move jobs to an
          external database through Sequel. Repeated SQLite busy/locked errors
          are logged as throttled `sqlite_busy_contention` warnings with request,
          job, outbox, or table metadata.

          For local development with a web process, worker, and recurring
          scheduler, use `Procfile.dev` with a process runner such as Overmind,
          Foreman, or Hivemind. The production shape is the same: web serves
          requests, `luna jobs:work` performs queued jobs and outbox delivery, and
          `luna jobs:schedule` enqueues recurring tasks.

          The read-only jobs dashboard is mounted at `/luna/jobs`; its JSON health
          endpoint is `/luna/jobs/health`. Development access is local-only.
          Production access requires `LUNULA_DASHBOARD_PASSWORD` and uses HTTP
          Basic auth. Development local-only checks use the direct `REMOTE_ADDR`
          socket address, not forwarding headers.

          Use `Lunula.enqueue` for independent work. Enqueue work that depends
          on a database write through the transaction so rollback remains safe:

          ```ruby
          context.transaction do |transaction|
            # persist domain changes
            transaction.enqueue MyDomain::Jobs::Notify, record_id
          end
          ```

          The generated `lunula_job_outbox` provides a crash-safe hand-off when
          a durable external adapter cannot share the Sequel transaction.

          Schedule work with `Lunula.enqueue_in(seconds, Job, ...)` or
          `Lunula.enqueue_at(time, Job, ...)`. Jobs may declare an integer
          `priority`; lower numbers run first, then scheduled time and insertion
          order.

          Workers atomically claim configurable batches. Ordered queue lists are
          served fairly, while `--all-queues` uses global priority ordering.
          Active worker identity, process, host, queues, heartbeat, concurrency,
          and current workload are stored in `lunula_job_workers`; graceful
          shutdown drains the claimed batch without taking more work.

          Running jobs renew their leases, and dead-worker heartbeats allow early
          recovery after a crash or `SIGKILL`. Configure lease, heartbeat, default
          execution timeout, and worker expiry through `LUNULA_JOB_LEASE_SECONDS`,
          `LUNULA_JOB_HEARTBEAT_INTERVAL`, `LUNULA_JOB_TIMEOUT`, and
          `LUNULA_JOB_WORKER_TIMEOUT`.

          Timeouts and cancellation are cooperative: long loops call
          `Lunula::Jobs.checkpoint!`, while external I/O keeps its own native
          timeout. Jobs can override the default with `def self.timeout = 30`.

          Recurring jobs are declared in `config/recurring.yml` with a narrow
          interval syntax such as `every: "5 minutes"` or `every: "1 hour"`.
          `luna jobs:schedule` enqueues due tasks and uses
          `lunula_recurring_runs` to prevent duplicate runs across scheduler
          processes. Use `luna jobs:recurring` to inspect the schedule,
          `luna jobs:recurring run NAME` to trigger a task now, and
          `luna jobs:recurring enable NAME` / `disable NAME` to toggle a task.

          The worker handles `SIGTERM` and `SIGINT` by finishing its current item
          before exiting. Durable arguments use JSON hash semantics: top-level
          keyword keys are symbols when performed, while nested hash keys are
          strings.

          The application is configured with `database: DB`, so actions can use
          explicit transactions and emit events only after commit:

          ```ruby
          context.transaction do |transaction|
            # persist domain changes
            transaction.emit MyDomain::Events::Changed.new(record_id: 1)
          end
          ```

          Register event subscribers explicitly with `APP.events.configure` after
          creating `APP`. Production writes emitted events to a transactional
          database outbox; the same worker delivers them after commit. Delivery
          is at least once, so jobs and subscribers must be idempotent.

          Environment-specific config lives in `config/environments`. Logs are
          written to `log/<environment>.log` in development and stdout in
          production.

          ```ruby
          Lunula.env.development?
          Lunula.logger.info "Application event"
          ```

          See `DEPLOYMENT.md` for the generated Docker and Kamal production
          template.
        MARKDOWN
      end
    end
  end
end
