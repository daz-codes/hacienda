# Changelog

All notable Hacienda changes are recorded here. The project follows semantic
versioning for the documented public API after 1.0; see
[`docs/upgrading.md`](docs/upgrading.md).

## [Unreleased]

### Added

- Reproducible gem packaging with bundled browser runtime assets.
- A clean-checkout CI matrix for Ruby, examples, JavaScript, browsers,
  PostgreSQL portability, and dependency audits.
- A machine-checked public API inventory, support window, generated-file diff
  tooling, and previous-release-candidate upgrade harness.
- Domain-aware `hac routes` filtering and concrete-request lookup with route
  source locations.
- Mirrored `test/domains/<domain>` generator output with executable action,
  object, repository, and authentication contracts.

### Changed

- Generated and example tests use isolated temporary databases.
- Actions are public instance methods on fresh `Hacienda::Actions` subclasses.
  Domains may add named multi-method action sets under `actions/` and select
  them with the route `actions:` option.
- Removed the pre-release module `.respond(context, params)` action convention
  and split-action generator flags before they became a supported public API.
- Business routes are owned by domain-local route files. Boot and reload reject
  duplicate, structurally equivalent, and equal-specificity ambiguous routes.

## [0.1.0] - Unreleased

Initial development version. This version has not been declared a stable public
release.

[Unreleased]: https://github.com/hacienda-rb/hacienda/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/hacienda-rb/hacienda/releases/tag/v0.1.0
