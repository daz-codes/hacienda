# Security Policy

## Supported versions

Lunula is pre-1.0. Only the latest release and the current `main` branch receive security fixes. Upgrade to the newest release before reporting a problem that only affects an older pre-release.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use the repository's [private vulnerability reporting form](https://github.com/daz-codes/lunula/security/advisories/new). Include the affected version, a minimal reproduction, likely impact, and any suggested mitigation. Remove real credentials and personal data from reports.

Maintainers aim to acknowledge a report within three business days, provide an initial assessment within seven business days, and coordinate a fix and disclosure date with the reporter. These are targets rather than a service-level agreement. Please allow a reasonable remediation period before publishing details.

If private vulnerability reporting is unavailable, open a public issue containing no exploit details and ask a maintainer to establish a private channel.

## Security scope and review status

The framework test suite covers request limits, CSRF, host authorization, redirects, session rotation, token replay, record authorization, upload validation, dependency audits, secret scanning, and deterministic security properties. Deployments must still configure TLS, proxy body/time limits, secrets, database access, storage authorization, backups, and application-specific authorization correctly.

Lunula has **not received an independent professional security audit**. The current assurance work is maintainer review and automated testing only. Do not represent the 1.0 release as independently audited unless this section is updated with the reviewer, scope, date, and published findings.
