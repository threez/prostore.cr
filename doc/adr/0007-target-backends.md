# ADR-0007: Target backends — SQLite and PostgreSQL

## Status

Accepted (2026-05-08)

## Context

The value of prostore is in declarative schema evolution, not in being a universal SQL adapter. Different SQL backends differ enough in DDL surface, transactional semantics, and type systems that supporting many of them dilutes the discipline. Each additional backend multiplies the test matrix and pulls the DSL toward the lowest common denominator of features.

SQLite and PostgreSQL together cover most Crystal use cases:

- **SQLite** for embedded use, CLI tools, single-node web apps, tests.
- **PostgreSQL** for multi-user web apps, OLTP, anything needing concurrent writers and rich types.

They also have very different DDL profiles — SQLite cannot `ALTER COLUMN` at all in older versions, PostgreSQL has `CREATE INDEX CONCURRENTLY` and online schema changes — which forces the design to be honest. If a feature works on both, it works.

## Decision

prostore supports **SQLite** and **PostgreSQL** as first-class backends. The DSL surface is the intersection of what both can express portably. Backend-specific operational behaviors (e.g., Postgres `CREATE INDEX CONCURRENTLY` for non-trivial table sizes, SQLite table-rebuild dance for the rare case it is unavoidable) are chosen by the library transparently, not by the user.

No third backend will be added without a strong case and demonstrated parity with the existing portability rules.

Backend-specific features that genuinely cannot be expressed portably (Postgres-only enums, JSONB operators, exclusion constraints) are either:
- Left out of v1.
- Exposed via a clearly-marked, backend-specific escape hatch in a later version, with the explicit understanding that using it forfeits portability for that model.

## Consequences

- ADR-0003's "no in-place type changes" rule is feasible with two backends. Adding a backend with even more limited DDL (or one that pushes back on the discipline) would force a re-evaluation.
- The test matrix is small enough to run against real databases on every commit.
- Design decisions are pressure-tested through a useful constraint: "does this work on both?" If it requires conditionals, that's a signal to step back.
- Users who need MySQL, MS SQL, or others are not served. This is acknowledged scope.
- Some Postgres features that Crystal users will reasonably want (enums, JSONB indexing, full-text search) are out of scope for v1. The escape-hatch path is left open for later.

## Alternatives Considered

- **Multi-backend via plugin architecture.** Rejected for v1: too much surface area before the core design is proven. May be revisited once SQLite + Postgres are solid and someone has a real third-backend use case to drive the abstraction.
- **PostgreSQL only.** Rejected: SQLite is a strong fit for Crystal's strengths in embedded and CLI use cases, and the dual-backend constraint sharpens design.
- **SQLite only.** Rejected: leaves out the multi-user OLTP use case where declarative migrations matter most.
