# ADR-0009: Online resumable migration state machine

## Status

Accepted (2026-05-08)

## Context

Migrations computed from a model diff (ADR-0001) are not single DDL statements. They decompose into operations with very different cost profiles:

- Pure DDL on small tables (add/drop/rename column, drop index) — fast and atomic.
- Eager Crystal-lambda backfill (ADR-0004, mechanism 2) — multi-phase: add nullable column → chunked backfill → optional `NOT NULL`. Long-running.
- `CREATE INDEX CONCURRENTLY` on Postgres — long-running, cannot run in a transaction, leaves an `INVALID` index on failure.
- Table-rebuild dance on SQLite (rare under ADR-0003 but still possible for certain metadata operations) — long if the table is large.

A version that only handles the fast atomic case is fine for embedded SQLite use cases but unfit for production Postgres against any non-trivial dataset. Since the declarative-migration value proposition is highest in production, the state machine must be online and resumable from day one — not retrofitted later, because resumability is much harder to add to an existing non-resumable engine than to design in from the start.

State must live in the database. Process restarts and host failures break any in-memory or filesystem-local approach. The state must also be inspectable by operators without bespoke tooling — SQL-queryable is the bar.

## Decision

Migrations are executed by a state machine whose durable state lives in two dedicated bookkeeping tables in the same database as the user data. The machine is online (DDL operations use the lowest-blocking variant the backend supports) and resumable (a crashed runner's work is picked up by the next process to claim the lease).

### Bookkeeping schema

```sql
CREATE TABLE prostore_migration (
  id             BIGINT PRIMARY KEY,
  source_hash    TEXT NOT NULL,    -- hash of the schema we migrate FROM
  target_hash    TEXT NOT NULL,    -- hash of the schema we migrate TO
  status         TEXT NOT NULL,    -- pending|running|complete|failed|aborted
  claimed_by     TEXT,             -- runner identity holding the lease
  claimed_until  TIMESTAMP,        -- lease expiry; another runner can steal after
  started_at     TIMESTAMP,
  completed_at   TIMESTAMP,
  error          TEXT
);

CREATE TABLE prostore_migration_step (
  migration_id   BIGINT NOT NULL,
  ordinal        INT    NOT NULL,
  kind           TEXT   NOT NULL,  -- add_column_nullable | backfill | create_index_concurrently | ...
  params         TEXT   NOT NULL,  -- JSON
  status         TEXT   NOT NULL,  -- pending|running|complete|failed
  progress       TEXT,             -- JSON: cursor pk, rows_done, total, ...
  started_at     TIMESTAMP,
  completed_at   TIMESTAMP,
  PRIMARY KEY (migration_id, ordinal)
);
```

The library reserves the `prostore_` table-name prefix; user models declaring such a table fail at compile time. The diff engine ignores tables matching the prefix.

### Invariants

1. **Atomic step decomposition.** A user-level operation maps to one or more atomic steps.
   - `add column` with `SQL.expr` default → 1 step.
   - `add column` with `lazy:` default → 1 step.
   - `add column` with eager Crystal default → 3 steps: `add_column_nullable`, `backfill`, optional `apply_not_null`.
   - `add index` on Postgres → 1 step (`create_index_concurrently`); recovery first checks for `INVALID` index and drops it before retrying.

   The DSL talks in user-level operations; the state machine plans and tracks at the step level.

2. **Plan persisted at start, never recomputed on resume.** When a migration begins, the full ordered step list is written to `prostore_migration_step` before any DDL runs. Resume reads the steps and continues from the first non-complete one. The model is *not* consulted to recompute a plan against a partially-migrated database — that recomputation is unreliable, since some target tags will exist and some won't, and the diff engine cannot distinguish "step not yet run" from "user intent was always to omit this column."

3. **Backfill idempotency via NULL filter, not cursor.** Chunked backfill executes:
   ```
   UPDATE t SET col = compute(...) WHERE col IS NULL AND pk > cursor LIMIT chunk_size
   ```
   Correctness comes from the `IS NULL` predicate. The cursor is a performance hint to avoid re-scanning known-done rows. Concurrent application writes that materialize the column via the ORM-evaluated lambda remove rows from the backfill's working set naturally; the backfill skips them.

4. **Schema fingerprinting prevents version skew.** Each booting application computes a hash of its target schema. To resume an in-progress migration, the application's `target_hash` must match the migration's `target_hash`. Mismatch → refuse to start. Two app versions targeting the same schema cooperate; targeting different schemas is an operator error and fails loudly rather than producing undefined behavior.

5. **Lease-based mutual exclusion.** Long-running operations cannot live inside a transaction, so transactional row locks are wrong. A runner claims `prostore_migration` by writing `claimed_by` + `claimed_until = now() + lease_duration` and heartbeats the lease while working. Crashed runners' leases expire and are stealable. This works identically on Postgres and SQLite without backend-specific lock primitives.

6. **State tables are the operator API.** Progress is queryable as ordinary SQL. A CLI formats it (`prostore migrate status`). `prostore migrate abort <id>` reverses in-flight and pending steps (drop columns just added, drop indexes just built); completed steps are not unwound. Full reversal of a fully-applied migration is the user's job via the removal lifecycle (ADR-0008).

### Backend asymmetry

- **PostgreSQL.** Full online story. Non-volatile-default column adds don't rewrite the table; index builds run `CONCURRENTLY`; `NOT NULL` is applied via add-constraint-not-valid + `VALIDATE CONSTRAINT` to avoid blocking validation.
- **SQLite.** "Online" means "doesn't hold the writer lock for extended periods." Backfill chunking is the primary online mechanism. The same state machine and bookkeeping tables apply; the operations are simply less concurrent.

## Consequences

- v1 ships with online/resumable as a hard requirement. The implementation cost is higher up front but the library is production-fit on day one.
- Resumability and idempotency are built into the step contract: each step is a function from current state to next state, idempotent under repeated execution. New operation kinds added later inherit this contract.
- Operators get a SQL-queryable, inspectable view of migration progress without bespoke logging or sidecar processes.
- Two extra tables exist in every prostore-managed database. The `prostore_` prefix is reserved.
- Aborts unwind only in-flight and pending steps; completed steps stand. "Abort" means "stop where you are," not "rewind." This keeps the state machine simple and matches operator intuition.
- The plan-at-start invariant means a model edit landed during a running migration is ignored by that migration. The next run picks it up. An operator who wants to incorporate a fresh model edit must wait for the current migration or abort it.
- Schema-fingerprint enforcement causes an app booting against an in-progress migration with a different `target_hash` to refuse to start. This is intentional and surfaces version-skew errors at deploy time.

## Alternatives Considered

- **Per-user-table state (sidecar tables or extra columns).** Rejected: leaks library bookkeeping into user schemas, complicates the diff engine, and provides no benefit over a central state table.
- **In-memory or filesystem-local state on the migrating host.** Rejected: process restarts lose the state, hosts can't coordinate, operators can't inspect with SQL.
- **Recompute plan on resume from current model + DB state.** Rejected: unreliable when the DB is partially migrated; the diff engine cannot disambiguate "step pending" from "intentionally absent."
- **Transactional locking instead of leases.** Rejected: long-running operations cannot be wrapped in a transaction, so a transaction-scoped lock is held wrong. Leases survive process death, which is the failure mode that actually matters.
- **Ship blocking/non-resumable in v1; add online support later.** Rejected per the stated goal: production fitness is the value proposition, and retrofitting resumability into a non-resumable engine is harder than designing for it.

## Open follow-ups (not architecture)

- Default lease duration and heartbeat cadence (operational tuning).
- Richer per-table progress reporting beyond the JSON `progress` blob (the blob is forward-compatible).
- Parallelizing independent steps within one migration. Out of scope for v1 — one runner per migration is sufficient.
