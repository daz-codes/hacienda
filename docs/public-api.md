# Public API

This document defines the Hacienda API that applications may rely on. The
machine-readable inventory in [`public-api.yml`](public-api.yml) is normative
and is checked in CI. An API omitted from that inventory is internal even when
Ruby visibility currently makes it callable.

Hacienda is pre-1.0. Until 1.0, a minor release may contain a documented
breaking change. Release candidates follow the 1.0 compatibility policy below.

## Application and request API

- `Hacienda::Application.new`, Rack `call`, `reload!`, and `transaction`
- `Hacienda.env`, `root`, `credentials`, `signed_token`, `logger`, `cache`, and
  `storage`, plus their documented configuration methods
- `Hacienda::Context` request, session, cookie, flash, CSRF, cache, storage,
  navigation, current-user, and transaction accessors
- `Hacienda::Params` lookup, `slice`, `permit`, `require`, and conversion
- action response helpers: `render`, `redirect`, `json`, `text`, and `response`
- route declarations: `get`, `post`, `put`, `patch`, `delete`, and `guard`

Actions are public instance methods on a fresh subclass of `Hacienda::Actions`
and receive `(context, params)`. A domain's default class is `Domain::Actions`;
routes can select another `Domain::*Actions` class with `actions: :name`.
Guards remain objects or modules with `check(context, params)`. Context loaders
use `load(context)`. These call signatures are public application integration
contracts.

Business routes are owned by `app/domains/<domain>/routes.rb`; the directory
name selects the domain action namespace. Hacienda does not load a global
business-route file. Rack middleware and infrastructure mounts remain in
`config.ru`. Exact normalized duplicates, structurally equivalent dynamic
routes, and equal-specificity overlapping patterns raise
`Hacienda::Routes::CollisionError` during boot or reload. Different verbs and
static-over-dynamic precedence remain supported.

`hac routes` exposes domain and source ownership. It accepts `--domain DOMAIN`
for table filtering, `METHOD PATH` for dispatch lookup, and `PATH` to show the
selected route for every matching verb.

## Domain and persistence API

- `Hacienda::Attributes` declarations, assignment, dirty tracking, and
  persistence state
- `Hacienda::Validations` and `Hacienda::ValidationErrors`
- `Hacienda::Store` CRUD, custom datasets, coercions, timestamps, refresh
  behavior, and optional optimistic locking
- `Hacienda::Application#transaction` and `Hacienda::Transaction` event and job
  methods
- `Hacienda::Events`, recorder, and database outbox

Repository modules, domain classes, database schemas outside the Hacienda
runtime tables, and validation wording belong to the application.

## Jobs, mail, cache, and storage

The root `Hacienda.enqueue`, `enqueue_in`, `enqueue_at`, and `enqueue_all`
methods are public. Module jobs use `perform`, with optional documented hooks
such as `queue`, `priority`, `max_attempts`, `timeout`, `unique_key`, and
`concurrency_key`.

The adapter capability contract, built-in adapters, worker, scheduler, job
outbox, recurring schedule, operational database-adapter methods, and lifecycle
notifications are public. Database rows and serialized payloads remain readable
under the compatibility policy in [Upgrading](upgrading.md).

`Hacienda.mail`, the development-only `Hacienda::Mailer::Inbox`, cache stores
and HTTP helpers, storage services and upload objects, signed tokens, encrypted
credentials, and session storage are public at the methods listed in the
manifest. The generated inbox path is `/hac/mail` and remains unavailable in
production.

`Hacienda::Assets` compilation, clobbering, manifest lookup, path resolution,
and Rack static-file options are public. Applications should keep logical asset
names in views and let `asset_path` resolve production fingerprints.

## Middleware and browser protocol

The generated Rack middleware classes are public Rack components. Constructor
keywords shown in generated `config.ru` and the deployment documentation are
supported.

This includes `Hacienda::Middleware::RequestLimits`,
`Hacienda::Middleware::PendingMigrations`, and their generated configuration.
`Hacienda::Migrations` exposes the migration-state queries used by the CLI and
middleware. `Hacienda::Storage::ContentTypeInspector` and the
`content_inspector:` storage hook are public upload-validation APIs.

The `X-Hacienda-*` headers, `hacienda:*` browser events, `data-hacienda-*`
attributes, generated asset filenames, and the `/hac/jobs` and `/hac/mail`
dashboard paths are public integration strings. They cannot be renamed or removed as an internal
refactor.

## CLI and generators

Both `hac` and `fac` are supported equivalent executables. Commands and
generated paths listed in the manifest are public. Generator output is
application-owned after creation: Hacienda does not overwrite it during a gem
upgrade.

Generated tests mirror domain ownership under `test/domains/<domain>` while
cross-domain and complete customer workflows belong in `test/integration`.
Tests remain outside `app/domains`, so production Zeitwerk loading never owns
test code. Domain generation creates the mirrored location; action, REST, and
authentication generation add executable behavior contracts rather than
placeholder assertions.

The exact contents of generated files may evolve. Each release candidate must
publish a snapshot diff so applications can manually review relevant changes.
Generators must refuse unsafe overwrites and report partial failures.

## Internal API

The following are deliberately internal unless added to the manifest:

- `Hacienda::CLI` and command parsing implementation
- generator template and file-writing methods
- renderer/compiler internals and Zeitwerk loader coordination
- durable queue claiming implementation and SQL construction
- job serializer helper methods and execution-context internals
- private normalization, coercion, and instrumentation helpers
- constants described as implementation details in source comments

Internal APIs may change in any release. Applications should open an issue when
an internal hook appears necessary rather than depending on it silently.
