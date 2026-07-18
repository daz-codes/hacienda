# Changelog

All notable Lunula changes are recorded here. The project follows semantic
versioning for the documented public API after 1.0; see
[`docs/upgrading.md`](docs/upgrading.md).

## [Unreleased]

### Added

- The publishable `@lunula/morpheus` HTML navigation and intent-prefetch package,
  with checked vendored copies for Lunula applications.
- Reproducible gem packaging with bundled browser runtime assets.
- A clean-checkout CI matrix for Ruby, examples, JavaScript, browsers,
  PostgreSQL portability, and dependency audits.
- A machine-checked public API inventory, support window, generated-file diff
  tooling, and previous-release-candidate upgrade harness.
- Domain-aware `luna routes` filtering and concrete-request lookup with route
  source locations.
- Mirrored `test/domains/<domain>` generator output with executable action,
  object, repository, and authentication contracts.
- A compact `Lunula::Repository` facade with explicit nil-versus-not-found
  finder semantics and ordinary Sequel-backed custom queries.

### Changed

- Renamed the pre-release framework to Lunula, consolidated its command-line
  interface as `luna`, and renamed framework-owned public strings.
- Moved browser navigation headers, events, attributes, and state into the
  framework-independent Morpheus namespace.
- Generated and example tests use isolated temporary databases.
- Actions are public instance methods on fresh `Lunula::Actions` subclasses.
  Domains may add named multi-method action sets under `actions/` and select
  them with the route `actions:` option.
- Removed the pre-release module `.respond(context, params)` action convention
  and split-action generator flags before they became a supported public API.
- Business routes are owned by domain-local route files. Boot and reload reject
  duplicate, structurally equivalent, and equal-specificity ambiguous routes.
- Removed the pre-release public `STORE` and `module_function` repository
  convention. Domain generation no longer creates an empty repository.

## [0.1.0] - Unreleased

Initial development version. This version has not been declared a stable public
release.

[Unreleased]: https://github.com/daz-codes/lunula/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/daz-codes/lunula/releases/tag/v0.1.0
