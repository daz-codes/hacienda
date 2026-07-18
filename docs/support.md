# Supported Versions

This is the support window intended for the Lunula 1.0 line. CI is the source
of truth for tested combinations; dependency constraints in `lunula.gemspec`
remain authoritative for installation.

| Component | Supported contract | CI coverage |
| --- | --- | --- |
| Ruby | `>= 3.2`; use a patch release still maintained by the Ruby project in production | Lowest 3.2 and current stable 4.0 on Linux |
| Rack | `>= 3.1`, `< 4` | Locked Rack 3.x through framework and browser tests |
| Sequel | `>= 5.80`, `< 6` | Locked Sequel 5.x through all persistence tests |
| sqlite3 gem | Application dependency `~> 2.0` | Locked 2.x gem and its bundled SQLite library |
| SQLite | The SQLite version shipped by the supported `sqlite3` 2.x gem | Full framework, examples, generator, jobs, sessions, and storage integration |
| PostgreSQL | PostgreSQL 17 for explicitly portable contracts | Migrations, Store, transactions, and durable queue |

The minimum Ruby job is a compatibility floor, not a promise of security fixes
from the Ruby project. Production users must run an upstream- or vendor-supported
Ruby patch release.

Lunula supports the current dependency constraints, not arbitrary older
patch releases inside those ranges. A reported bug must reproduce on the latest
compatible patch before it is treated as a framework defect.

PostgreSQL coverage is deliberately narrower than SQLite coverage. Features
described as SQLite-only, including WAL diagnostics and checkpoint commands,
are not PostgreSQL contracts. Additional PostgreSQL majors become supported
only when added to CI.

Support for an upstream version normally ends in the first Lunula minor
release after upstream maintenance ends. Security requirements may force an
earlier change, documented in the changelog and upgrade notes.
