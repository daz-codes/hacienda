# Upgrading Hacienda

## Versioning policy

Hacienda uses semantic versioning for the public contract in
[`public-api.md`](public-api.md).

- Patch releases fix defects without intentionally changing public behavior.
- Minor releases add compatible APIs and may deprecate existing APIs.
- Major releases may remove deprecated APIs or otherwise break the public
  contract.
- Before 1.0, minor releases may break APIs, but every break must appear in the
  changelog and upgrade notes. Release candidates follow the 1.0 rules.

Dropping an upstream runtime or database version is normally a minor release
when that version is no longer maintained upstream. An early removal from the
documented support window requires a major release.

## Deprecations

A public Ruby API, CLI command, configuration key, environment variable,
browser integration string, or generated convention is deprecated before
removal. Deprecations must:

1. identify the replacement in runtime or CLI output where practical;
2. appear under `Deprecated` in `CHANGELOG.md`;
3. remain functional for at least two minor releases and six months after 1.0;
4. include a test for both the deprecated path and its replacement.

Security fixes may shorten this window. The release notes must explain why.

## Application upgrade procedure

1. Pin the target Hacienda version and read every intervening changelog entry.
2. Back up the database, uploaded files, credentials, and deployment secrets.
3. Run the generated-file diff for the previous release tag:

   ```sh
   bundle exec rake "release:generated_diff[v0.9.0.rc1]"
   ```

4. Review the diff and merge applicable changes into application-owned files.
   Do not replace the application with a newly generated copy.
5. Add new framework migrations as new migration files. Never edit a migration
   that has already run in another environment.
6. Run `bundle exec hac db:migrate`, the application test suite, `db:check`, and
   the job health checks in a staging copy before production deployment.
7. Deploy application processes and migrations using the ordering stated in
   that release's notes. Keep the database backup until rollback is no longer
   required.

Hacienda does not currently provide `hac update`. Generated files are explicit
and application-owned, so upgrades are reviewable source changes rather than an
automatic rewrite.

## Generated files

The generator snapshot tests are the canonical before/after input for release
diffs. `script/generated_diff BASE_REF` emits Markdown covering the new app,
REST resource, and authentication generator snapshots. Each release candidate
stores that output under `docs/generated-diffs/` and links it from the
changelog.

Changing a generated default does not mutate an existing application. A change
that existing applications must adopt is called out as `Required` in the
upgrade notes and includes exact manual steps.

## Migrations and persisted data

Published Hacienda runtime migrations are append-only. A release may add a new
migration, but must not silently alter an already published migration. Schema
changes support rolling deployment when practical; otherwise release notes must
state the required shutdown ordering and rollback boundary.

Durable job and event rows are public persisted contracts:

- existing payloads must remain readable across compatible releases;
- new serialized types use an explicit tag while old tags remain readable;
- renaming a job or event class requires a temporary constant alias or an
  application migration until old rows are drained;
- arguments should be treated as a versioned message schema and changed
  additively;
- table or state changes require migrations and upgrade tests.

Credentials and signed-token formats remain readable during their documented
rotation window. Session-secret rotation uses the old-secret configuration
rather than invalidating every active session without notice.

## Previous release-candidate test

`script/upgrade_test BASE_REF` builds the previous ref, generates an application
with that version, points the unchanged application at the current checkout,
migrates it, and runs its tests. A sentinel application-owned file verifies that
the process did not regenerate the app.

There is no predecessor for the first release candidate. From the second
release candidate onward, CI discovers the most recent reachable RC tag and
runs this test automatically.
