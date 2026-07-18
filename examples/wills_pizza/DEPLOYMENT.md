# Deploying wills-pizza

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
docker build -t wills-pizza .
docker volume create wills-pizza_db
export LUNULA_SESSION_SECRET=$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')
docker run --rm \
  -e LUNULA_MASTER_KEY="$(cat config/master.key)" \
  -e LUNULA_SESSION_SECRET \
  -e DATABASE_URL=sqlite:///app/db/production.sqlite3 \
  -v wills-pizza_db:/app/db \
  wills-pizza bundle exec luna db:migrate
docker run --rm -p 5151:5151 \
  -e LUNULA_MASTER_KEY="$(cat config/master.key)" \
  -e LUNULA_SESSION_SECRET \
  -e DATABASE_URL=sqlite:///app/db/production.sqlite3 \
  -v wills-pizza_db:/app/db \
  wills-pizza
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

The named `wills-pizza_db` volume persists SQLite data across deployments.
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
