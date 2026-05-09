# ADR-0003: No in-place type changes

## Status

Accepted (2026-05-08)

## Context

Two pressures push toward forbidding in-place column type changes:

1. **Backend asymmetry.** SQLite cannot alter most column types in place — it requires a table-rebuild dance (create new, copy, drop old, rename). PostgreSQL can `ALTER COLUMN TYPE` but may rewrite the whole table for non-trivial conversions, taking long locks. A library that promises portability across both must either hide vastly different mechanics or refuse the operation.

2. **Data conversion is intractable in general.** Going from `Int32` to `Int64` is safe; from `String` to `Int32` requires a function the library cannot infer. A library that emits `USING` clauses takes on a correctness obligation it cannot meet.

Protocol Buffers, which inspires the schema-evolution model (ADR-0002), forbids type changes for the same kinds of reasons. To "change" a field's type, you add a new field with a new tag and deprecate the old one. The same discipline applies cleanly to SQL.

## Decision

prostore forbids in-place type changes. Specifically:

- A column's declared type cannot be altered. Changing it is a model-level error.
- A nullable column cannot be tightened to non-nullable. Same constraint.
- A unique constraint cannot be added to an existing column. Same constraint.

To "change" any of these, the user adds a new field with a new tag and reserves the old one. Eventually, after the application has migrated reads and writes, the old tag is removed entirely.

## Consequences

- The diff engine never emits `ALTER COLUMN TYPE`, never needs `USING` clauses, and never has to run a row-by-row data conversion.
- SQLite's lack of `ALTER COLUMN` becomes irrelevant for most evolution paths.
- Schema evolution is forced to be explicit about compatibility. The model file *is* the migration plan.
- Zero-downtime migrations are the default path: add new column → backfill (mechanism depending on ADR-0004) → switch reads, then writes → eventually drop old.
- Both the old and new column exist during the transition window. Storage cost is real for wide tables and high-frequency types. This is the price of safety; users who can't pay it have to manage their own migration outside the library.
- Even widenings that are objectively safe (`varchar(50) → varchar(100)`, `int32 → int64`) require a new tag. Some users will find this excessive.
- The model file accumulates reservations over time, preserving the evolution history.

## Alternatives Considered

- **Allow widening only.** Rejected: what's safe on Postgres is not always safe on SQLite, the rules differ by type, and the library would have to track a per-backend matrix of permitted widenings. The portability story erodes immediately.
- **Allow arbitrary type changes with library-emitted `USING` clauses.** Rejected: the library cannot guarantee correctness of arbitrary conversions. This pushes correctness onto the user via a hook they may not know exists.
- **Allow type changes in a "permissive" mode flag.** Rejected: optional escape hatches encourage divergence between projects and dilute the discipline. If the rule is correct, it should be the only rule.
