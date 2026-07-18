# Public API

This document defines the Lunula API that applications may rely on. The
machine-readable inventory in [`public-api.yml`](public-api.yml) is normative
and is checked in CI. An API omitted from that inventory is internal even when
Ruby visibility currently makes it callable.

Lunula is pre-1.0. Until 1.0, a minor release may contain a documented
breaking change. Release candidates follow the 1.0 compatibility policy below.

## Application and request API

- `Lunula::Application.new`, Rack `call`, `reload!`, and `transaction`
- `Lunula.env`, `root`, `credentials`, `signed_token`, `logger`, `cache`, and
  `storage`, plus their documented configuration methods
- `Lunula::Context` request, session, cookie, flash, CSRF, cache, storage,
  navigation, current-user, and transaction accessors
- `Lunula::Params` lookup, `slice`, `permit`, `require`, and conversion
- action response helpers: `render`, `redirect`, `json`, `text`, and `response`
- route declarations: `get`, `post`, `put`, `patch`, `delete`, and `guard`

Actions are public instance methods on a fresh subclass of `Lunula::Actions`
and receive `(context, params)`. A domain's default class is `Domain::Actions`;
routes can select another `Domain::*Actions` class with `actions: :name`.
Guards remain objects or modules with `check(context, params)`. Context loaders
use `load(context)`. These call signatures are public application integration
contracts.

Business routes are owned by `app/domains/<domain>/routes.rb`; the directory
name selects the domain action namespace. Lunula does not load a global
business-route file. Rack middleware and infrastructure mounts remain in
`config.ru`. Exact normalized duplicates, structurally equivalent dynamic
routes, and equal-specificity overlapping patterns raise
`Lunula::Routes::CollisionError` during boot or reload. Different verbs and
static-over-dynamic precedence remain supported.

`luna routes` exposes domain and source ownership. It accepts `--domain DOMAIN`
for table filtering, `METHOD PATH` for dispatch lookup, and `PATH` to show the
selected route for every matching verb.

## Domain and persistence API

- `Lunula::Attributes` declarations, assignment, dirty tracking, and
  persistence state
- `Lunula::Validations` and `Lunula::ValidationErrors`
- `Lunula::Store` CRUD, custom datasets, coercions, timestamps, refresh
  behavior, and optional optimistic locking
- `Lunula::Repository`, extended by an application repository module, with
  explicit `all`, `first`, `find`, `find_by`, `find_by!`, `save`, `delete`,
  `load`, `refresh`, and `dataset` operations
- `Lunula::Application#transaction` and `Lunula::Transaction` event and job
  methods
- `Lunula::Events`, recorder, and database outbox

Repository modules, their named domain queries, domain classes, database
schemas outside the Lunula runtime tables, and validation wording belong to
the application. `find` and `find_by!` raise `Lunula::NotFound`; `first` and
`find_by` return `nil` when no row matches. Lunula does not generate dynamic
finder methods.

## Jobs, mail, cache, and storage

The root `Lunula.enqueue`, `enqueue_in`, `enqueue_at`, and `enqueue_all`
methods are public. Module jobs use `perform`, with optional documented hooks
such as `queue`, `priority`, `max_attempts`, `timeout`, `unique_key`, and
`concurrency_key`.

The adapter capability contract, built-in adapters, worker, scheduler, job
outbox, recurring schedule, operational database-adapter methods, and lifecycle
notifications are public. Database rows and serialized payloads remain readable
under the compatibility policy in [Upgrading](upgrading.md).

`Lunula.mail`, the development-only `Lunula::Mailer::Inbox`, cache stores
and HTTP helpers, storage services and upload objects, signed tokens, encrypted
credentials, and session storage are public at the methods listed in the
manifest. The generated inbox path is `/luna/mail` and remains unavailable in
production.

`Lunula::Assets` compilation, clobbering, manifest lookup, path resolution,
and Rack static-file options are public. Applications should keep logical asset
names in views and let `asset_path` resolve production fingerprints.

## Middleware and browser protocol

The generated Rack middleware classes are public Rack components. Constructor
keywords shown in generated `config.ru` and the deployment documentation are
supported.

This includes `Lunula::Middleware::RequestLimits`,
`Lunula::Middleware::PendingMigrations`, and their generated configuration.
`Lunula::Migrations` exposes the migration-state queries used by the CLI and
middleware. `Lunula::Storage::ContentTypeInspector` and the
`content_inspector:` storage hook are public upload-validation APIs.

The `X-Morpheus-*` headers, `morpheus:*` browser events, `data-morpheus-*`
attributes, generated asset filenames, and the `/luna/jobs` and `/luna/mail`
dashboard paths are public integration strings. They cannot be renamed or
removed as an internal refactor.

The browser implementation is maintained as the independently publishable
`@lunula/morpheus` package under `packages/morpheus`. Lunula vendors that
package's source and Idiomorph dependency so generated applications retain a
no-Node production runtime. `ruby script/vendor_morpheus --check` enforces that
the framework and example copies match the package source.

## CLI and generators

The `luna` executable and commands listed in the manifest are public.
Generated paths are also public. Generator output is
application-owned after creation: Lunula does not overwrite it during a gem
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

- `Lunula::CLI` and command parsing implementation
- generator template and file-writing methods
- renderer/compiler internals and Zeitwerk loader coordination
- durable queue claiming implementation and SQL construction
- job serializer helper methods and execution-context internals
- private normalization, coercion, and instrumentation helpers
- constants described as implementation details in source comments

Internal APIs may change in any release. Applications should open an issue when
an internal hook appears necessary rather than depending on it silently.
