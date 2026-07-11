# Deploying store

The generated Docker and Kamal files provide a production starting
point for one Linux server using SQLite. Edit `config/deploy.yml`
before using it.

## Prepare the application

Install dependencies and commit `Gemfile.lock`; the Docker build is
intentionally locked and will fail without it:

```sh
bundle install
git add Gemfile.lock
```

If Hacienda is referenced through a local `path:` in `Gemfile`, replace
it with a released gem version before building outside the framework
checkout.

## Test the image locally

```sh
docker build -t store .
docker volume create store_db
docker volume create store_storage
export HACIENDA_SESSION_SECRET=$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')
docker run --rm \
  -e HACIENDA_MASTER_KEY="$(cat config/master.key)" \
  -e HACIENDA_SESSION_SECRET \
  -e DATABASE_URL=sqlite:///app/db/production.sqlite3 \
  -e HACIENDA_STORAGE_SERVICE=disk \
  -e HACIENDA_STORAGE_ROOT=/app/storage \
  -v store_db:/app/db \
  -v store_storage:/app/storage \
  store bundle exec hac db:migrate
docker run --rm -p 5151:5151 \
  -e HACIENDA_MASTER_KEY="$(cat config/master.key)" \
  -e HACIENDA_SESSION_SECRET \
  -e DATABASE_URL=sqlite:///app/db/production.sqlite3 \
  -e HACIENDA_STORAGE_SERVICE=disk \
  -e HACIENDA_STORAGE_ROOT=/app/storage \
  -v store_db:/app/db \
  -v store_storage:/app/storage \
  store
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
   export HACIENDA_SESSION_SECRET=$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')
   # During rotation only:
   # export HACIENDA_SESSION_SECRET_OLD="previous-secret"
   ```

Sessions use encrypted client-side cookies by default. They expire after 30
days; set `HACIENDA_SESSION_EXPIRE_AFTER` to a positive number of seconds to
change that. To rotate `HACIENDA_SESSION_SECRET`, deploy the new value and keep
the previous value in `HACIENDA_SESSION_SECRET_OLD` until old cookies have
expired. Logout removes the browser's current cookie, but a stolen copy remains
replayable until expiry or secret rotation because the default store has no
server-side revocation list.

Set `HACIENDA_SESSION_STORE=database` to store session payloads in Sequel
instead. That keeps only an opaque id in the browser, uses the generated
`hacienda_sessions` table, and allows server-side revocation by deleting rows.
Run migrations before enabling it.

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

The named `store_db` volume persists SQLite data across deployments.
This is deliberately a single-server configuration. Keep the database
on a local filesystem; WAL mode is not suitable for a network filesystem.
Generated apps configure WAL mode, foreign-key enforcement,
`synchronous = NORMAL`, and a 5 second busy-timeout outside test. Run
`bundle exec hac db:check` after deployment to verify these settings.
Run `bundle exec hac db:checkpoint --mode TRUNCATE` during maintenance
if the WAL file grows unexpectedly after a burst of writes.
Move to a client/server database only when measured write contention or
availability requirements justify a multi-host design.

A container rollback does not roll back database migrations. Prefer
additive, backwards-compatible migrations; use separate
expand/migrate/contract deployments for destructive schema changes.
Back up the database volume before significant migrations. A safe SQLite
backup must include WAL state; use Litestream or the SQLite online backup
API rather than copying only `production.sqlite3` while the app is
running. `config/litestream.yml.example` is a starting point; copy it to
`config/litestream.yml`, fill in the replica destination, restore before
boot, and run `litestream replicate` beside the app through your host
supervisor.

## Jobs and event delivery

Production uses Hacienda's durable database job adapter and the
transactional event outbox. The generated `job` server role runs
`hac jobs:work` on the same host and volume. Delivery is at least once,
so jobs and event subscribers must be idempotent.

Qualify the queue on the deployed host after `hac db:check`:

```sh
bundle exec hac jobs:benchmark --jobs 1000 --retry-jobs 25 --threads 2 --batch-size 10
```

The benchmark uses the real database job adapter, worker claim/complete
path, failed-job retry path, and simple database latency samples. It
deletes only its own benchmark rows unless `--keep` is passed. For this
single-host SQLite shape, start with one worker process, `--threads 2`,
`--batch-size 5..10`, and `--poll 0.25..1.0`. Lower worker concurrency
if web requests or benchmark p95 database latency degrade under load.

Inspect terminal failures with
`kamal app exec --role job "bundle exec hac jobs:failed"`.
Configure SMTP secrets in `.kamal/secrets` and `config/deploy.yml` if
the application sends mail.

This example configures disk storage and mounts `store_storage` at
`/app/storage`. Back up that volume separately from SQLite. Do not bake
uploaded files into the image; use an object-store adapter only if the
application later outgrows its single-host deployment.

The local `/uploads` middleware serves public capability URLs without
authorization. Private files need guarded application routes or signed
remote URLs. Database and storage writes are not one transaction, so
applications with strict retention requirements should run a periodic
orphan-file sweep.

See the [Kamal documentation](https://kamal-deploy.org/docs/installation/)
for server, registry, proxy, and command details.
