# Deploying Hacienda applications

`hac new` generates a production `Dockerfile`, `.dockerignore`,
`config/deploy.yml`, `.kamal/secrets`, a `/up` health endpoint, and an
application-specific `DEPLOYMENT.md`.

The default template targets one Linux server with SQLite stored in a named
Docker volume. It is deliberately a starting point rather than an abstraction
over the deployment platform.

## Production requirements

Before deploying, provide:

- a committed `Gemfile.lock`;
- `HACIENDA_MASTER_KEY`, or `HACIENDA_SECRET_KEY_BASE` if encrypted credentials
  are not used;
- a long random `HACIENDA_SESSION_SECRET`;
- `DATABASE_URL` pointing to persistent storage;
- SMTP configuration if the application sends mail.

Generate a session secret locally:

```sh
ruby -rsecurerandom -e 'puts SecureRandom.hex(64)'
```

Never bake `config/master.key`, session secrets, SMTP passwords, or database
passwords into the image. The generated `.dockerignore` excludes the master key
and local data.

Set `HACIENDA_APP_URL` to the public canonical origin, for example
`https://app.example.com`. Hacienda uses this value for generated email
verification, password reset, magic-link-style flows, and other signed URLs
instead of trusting the incoming request `Host` header. Generated production
apps also use the host from `HACIENDA_APP_URL` as the default allowed host.
Set `HACIENDA_ALLOWED_HOSTS` to a comma-separated list only when the app must
accept additional hostnames.

Your reverse proxy should overwrite, not append to, untrusted `Host` and
`X-Forwarded-*` headers. Kamal Proxy does this in the generated deployment
shape; custom proxies should be configured with the same assumption.

## Rotating secrets

Rotate the credentials master key with `hac credentials:rotate`. It re-encrypts
`config/credentials.yml.enc` with a fresh key and rewrites `config/master.key`;
update any `HACIENDA_MASTER_KEY` copies in your deploy secrets afterwards.

To rotate `HACIENDA_SECRET_KEY_BASE` without invalidating outstanding signed
tokens (email verification and password reset links), keep the previous value
in `HACIENDA_SECRET_KEY_BASE_OLD` (comma-separated for more than one) or in an
`old_secret_key_bases` array under `hacienda:` in the encrypted credentials.
New tokens are always signed with the current secret; old secrets are only
used to verify. Drop them once outstanding tokens have expired.

To rotate `HACIENDA_SESSION_SECRET`, deploy the new value as
`HACIENDA_SESSION_SECRET` and keep the previous value in
`HACIENDA_SESSION_SECRET_OLD` until existing cookies expire. Generated apps
accept a comma-separated list of old session secrets. Cookie sessions expire
after 30 days by default; set `HACIENDA_SESSION_EXPIRE_AFTER` to a positive
number of seconds to shorten or lengthen that window.

The default session store is an encrypted client-side cookie. It has no
server-side revocation list: logout removes the browser's current cookie, but a
stolen copy can still be replayed until it expires or the signing/encryption
secret is rotated. Prefer shorter expiries for higher-risk applications. Use a
future database-backed session store when per-session revocation is required.

If a development checkout references Hacienda with `gem "hacienda", path: ...`,
replace it with a released gem version before building an image whose context
does not include the framework checkout.

## Docker

The generated image:

- uses a multi-stage Ruby build;
- installs only runtime SQLite libraries in the final stage;
- runs as an unprivileged `hacienda` user;
- excludes development dependencies;
- starts Rack/Puma on port 5151;
- writes production logs to stdout.

Build and exercise it before deployment:

```sh
bundle install
docker build -t my-app .
docker volume create my-app_db
export HACIENDA_SESSION_SECRET=$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')

docker run --rm \
  -e HACIENDA_MASTER_KEY="$(cat config/master.key)" \
  -e HACIENDA_SESSION_SECRET \
  -e DATABASE_URL=sqlite:///app/db/production.sqlite3 \
  -v my-app_db:/app/db \
  my-app bundle exec hac db:migrate

docker run --rm -p 5151:5151 \
  -e HACIENDA_MASTER_KEY="$(cat config/master.key)" \
  -e HACIENDA_SESSION_SECRET \
  -e DATABASE_URL=sqlite:///app/db/production.sqlite3 \
  -v my-app_db:/app/db \
  my-app
```

Check <http://localhost:5151/up>. The endpoint is a liveness check and does not
query the database or external services.

## Kamal

The generated template follows Kamal 2 conventions. Kamal requires a Linux
server reachable over SSH and a container registry. For automatic HTTPS, point
the configured hostname at the server and allow inbound traffic on ports 80 and
443.

Edit these placeholders in `config/deploy.yml`:

- `192.0.2.1`: server address;
- `app.example.com`: public hostname;
- `your-registry-user`: registry username and image namespace;
- `builder.arch`: deployment server architecture, if it is not AMD64.

Export secrets referenced by `.kamal/secrets`:

```sh
export KAMAL_REGISTRY_PASSWORD="registry-access-token"
export HACIENDA_SESSION_SECRET=$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')
# During rotation only:
# export HACIENDA_SESSION_SECRET_OLD="previous-secret"
```

The master key is read from `config/master.key` by the generated secrets file.
It can instead be fetched from a password manager using Kamal's secrets helpers.

Deploy to a new server and run the first migration:

```sh
bundle exec kamal setup
bundle exec kamal migrate
```

Subsequent deployments and common operational commands are:

```sh
bundle exec kamal deploy
bundle exec kamal migrate
bundle exec kamal console
bundle exec kamal logs
bundle exec kamal rollback VERSION
```

Kamal Proxy terminates TLS, forwards the original request headers, connects to
port 5151, and waits for `/up` to return successfully before routing traffic to
the new container. See the official documentation for
[installation](https://kamal-deploy.org/docs/installation/),
[proxy configuration](https://kamal-deploy.org/docs/configuration/proxy/), and
[secrets](https://kamal-deploy.org/docs/configuration/environment-variables/).

## SQLite and multiple servers

The generated `SERVICE_db:/app/db` volume survives image and container
replacement. It exists on one Docker host, so the default SQLite template must
not be expanded to multiple web servers.

Generated apps configure SQLite with WAL mode, foreign-key enforcement,
`synchronous = NORMAL`, and a 5 second busy-timeout outside test. Keep the web,
worker, scheduler, SQLite database, and any local upload volume on the same
host. Do not place the SQLite database on synced folders or network
filesystems; file locking semantics are part of SQLite's correctness model.

After deployment, verify the runtime database settings:

```sh
bundle exec hac db:check
```

The command reports the SQLite version, database path, WAL mode, busy-timeout,
foreign-key enforcement, and obvious unsafe storage paths. It exits non-zero
only for critical failures; warnings are still operational signals.

If a write-heavy burst leaves a large WAL file after traffic settles, run an
explicit checkpoint during a maintenance window:

```sh
bundle exec hac db:checkpoint --mode TRUNCATE
```

Use this as maintenance, not as a request-path operation.

Before adding hosts:

1. choose an external database supported through Sequel;
2. add its adapter gem, such as `pg`;
3. change `DATABASE_URL` to the external connection string;
4. remove the SQLite volume from `config/deploy.yml`;
5. arrange database backups independently of Kamal.

## Migrations and rollbacks

Container rollbacks do not reverse schema migrations. Prefer additive,
backwards-compatible migrations and use an expand/migrate/contract sequence for
destructive changes:

1. deploy code that works with both schemas;
2. apply and backfill the expanded schema;
3. deploy code using the new schema;
4. remove old columns in a later deployment.

Use maintenance mode when a migration cannot remain compatible:

```sh
bundle exec kamal app maintenance
bundle exec kamal deploy
bundle exec kamal migrate
bundle exec kamal app live
```

Back up SQLite or the external database before significant migrations. For
SQLite, a safe backup must include the database's WAL state. Use a
SQLite-aware backup mechanism such as Litestream or the SQLite online backup
API; copying only `production.sqlite3` while the app is running can produce an
incomplete backup. Generated apps include `config/litestream.yml.example` as a
starting point; copy it to `config/litestream.yml`, fill in the replica
destination, restore before boot, and run `litestream replicate` beside the app
through your host supervisor. Back up local uploads separately from the
database volume.

The generated single-host shape is intended for small-to-medium applications
with modest write contention. Treat repeated `SQLITE_BUSY` errors, sustained
WAL growth, queue latency caused by database contention, or an availability
requirement that cannot tolerate one host as signs that the application has
outgrown this default and should move to an external database through Sequel.

## Operational limits

- The built-in async job adapter is in-process and non-durable. Critical jobs
  need a durable external adapter.
- Domain events dispatch in-process after commit. Critical eventual delivery
  needs an outbox or durable queue.
- Run production background work as explicit processes: web handles requests,
  `hac jobs:work` performs jobs and relays durable hand-offs/events, and
  `hac jobs:schedule` enqueues recurring tasks. `hac jobs:health` and the
  read-only `/hac/jobs/health` endpoint are intended for supervisor checks.
- Qualify the queue on the deployed host with
  `hac jobs:benchmark --jobs 1000 --retry-jobs 25 --threads 2 --batch-size 10`
  after `hac db:check`. The benchmark uses the real database job adapter,
  worker claim/complete path, failed-job retry path, and simple database
  latency samples, then deletes only its own benchmark rows unless `--keep` is
  passed.
- For the generated single-host SQLite shape, start with one worker process,
  `--threads 2`, `--batch-size 5..10`, `--poll 0.25..1.0`, WAL mode, and the
  generated 5 second busy-timeout. Lower worker concurrency if web requests or
  benchmark p95 database latency degrade under load.
- Treat sustained `SQLITE_BUSY` errors, oldest pending job age above the app's
  user-visible SLA, frequent manual WAL checkpoints, or benchmark p95 database
  latency above roughly 100-250ms as signs that the application should reduce
  worker concurrency or move jobs to an external database through Sequel.
- The `/hac/jobs` dashboard is local-only in development and requires
  `HACIENDA_DASHBOARD_PASSWORD` for Basic auth in production.
- The default rate-limit store is process-local. Use a shared store when an
  application runs in multiple processes or containers.
- Production file storage defaults to `NullService`. Configure a remote
  object-storage service, or deliberately mount `HACIENDA_STORAGE_ROOT` as a
  persistent volume for a single-server disk deployment. Local disk storage is
  not shared across hosts.
- The generated blog's cover uploads therefore fail closed with `storage is not
  configured` in production until `config/storage.rb` is changed. Public
  `/uploads` URLs have no authorization; private files need guarded routes or
  signed remote URLs.
- Database and object storage do not share a transaction. Run a periodic
  reconciliation/sweep job if crash-created orphan files matter operationally.
