# ADR-0015: Custom column types — UUID, BigDecimal, JSON::Any, Array(T)

## Status

Accepted (2026-05-09). Extends ADR-0014 (DSL surface) with an additional set
of portable types that ADR-0014 explicitly listed as out of scope for v1.

## Context

ADR-0014 froze the v1 portable type set at `Int32`, `Int64`, `Float32`,
`Float64`, `String`, `Bool`, `Time`, `Bytes` — and explicitly listed UUID,
JSON, Array(T), decimal, and enums as out of scope, gated behind future
ADRs. Real-world prostore use needs at least UUIDs (external IDs),
`BigDecimal` (money), `JSON::Any` (semi-structured payloads), and arrays of
primitives (tag lists, score arrays). Without these, users either work
around with `String` columns and serialize manually, or pick a different
ORM. This ADR opens the door for them while keeping the type system
disciplined.

Enums are deliberately left out: they would require a separate evolution
discipline (renaming a variant ≠ in-place change; dropping a variant in
production data is dangerous), which doesn't fit ADR-0003's "no in-place
type changes" rule cleanly. Users wanting enum-like semantics declare a
plain `String` or `Int32` column and handle the variant set in
application code.

Custom user-defined types are also deferred — `JSON::Any` covers the
structured-data case for v1; a future ADR can add a `JSON::Serializable`
detection path that auto-routes user classes through JSON serialization.

## Decision

The portable type set extends with four new tags:

| Crystal type | Portable tag | SQLite column type | PostgreSQL column type |
| ------------ | ------------ | ------------------ | ---------------------- |
| `UUID`       | `uuid`       | TEXT               | UUID                   |
| `BigDecimal` | `decimal`    | TEXT               | NUMERIC                |
| `JSON::Any`  | `json`       | TEXT               | JSONB                  |
| `Array(T)`   | `array_<inner>` | TEXT (JSON)     | JSONB                  |

Where `T` for `Array(T)` must itself be a v1 portable type
(`Array(Int32)`, `Array(String)`, `Array(UUID)`, etc.). Nested arrays and
arrays of unrecognized types are a compile-time error.

### Wire format

All four types travel through `crystal-db` as `String` regardless of
backend. The model boundary converts:

- **Write** — `save` calls `Records.coerce_for_write(value, portable_type)`
  which dispatches on the value's Crystal type:
  - `UUID#to_s` → 36-char string
  - `BigDecimal#to_s` → arbitrary-precision text
  - `JSON::Any#to_json` → JSON text
  - `Array(T)#to_json` → JSON-encoded array
- **Read** — `__prostore_load_from_rs` switches on the field's portable tag
  and parses the column's `String?` value with `UUID.new`,
  `BigDecimal.new`, `JSON.parse`, or `Array(T).from_json` respectively.

The column DDL is still backend-native (UUID/NUMERIC/JSONB on Postgres;
TEXT on SQLite), so storage and indexing benefit from the right type
class. PG accepts strings into UUID/NUMERIC/JSONB columns and returns
them as strings on read, which keeps the IO path uniform.

### Native PostgreSQL arrays — explicitly deferred

PG can store primitive arrays as `INTEGER[]`, `TEXT[]`, etc., with native
indexing and operators. Routing `Array(Int32)` to `INTEGER[]` instead of
`JSONB` requires:

1. Backend-aware DDL emission for the column type (already easy).
2. Backend-aware materialization — `rs.read(Array(Int32)?)` works for PG
   but not SQLite, which has no array type.
3. Backend-aware coercion at write time — pass the array as-is to PG,
   JSON-encode for SQLite.

The split adds complexity for a single-digit-percent storage/indexing
gain in v1's typical workload. JSONB on PG and TEXT (JSON) on SQLite give
us a uniform path with zero special-case code, at the cost of native
array operators (`@>`, `&&`, `unnest`). If a future user demands PG-native
arrays, a follow-up ADR adds the per-backend dispatch.

### Auto-increment, defaults, indexes — orthogonal

`auto_increment` rejects all coerced types (only `Int32`/`Int64` allowed
per ADR-0013). `SQL.expr` defaults work as-is for any type — the user is
responsible for backend-portable expressions (`gen_random_uuid()` is PG
only, for instance). Indexes on coerced types behave normally; PG's UUID
and NUMERIC indexes work natively, SQLite's TEXT indexes work for the
string representation.

## Consequences

- The portable type set covers more real-world domain modeling needs
  without yet supporting fully open-ended custom types.
- Type-system discipline holds: every field's type is still drawn from a
  closed enumeration; the diff and validation rules from ADR-0003 carry
  over unchanged (a column declared `UUID` cannot become `Int32` in place
  any more than `String` could).
- The wire format is uniform — the runtime path doesn't case on adapter
  for any of these types. Per-backend variation lives only in the column
  DDL.
- `BigDecimal` round-trips losslessly via decimal-string serialization on
  both backends. PG's NUMERIC handles it natively; SQLite's TEXT preserves
  the source string. No floating-point conversion happens anywhere.
- Adding a new portable type in a future ADR is a known-shape change:
  extend `Types::PORTABLE`, add SQLite affinity, add PG mapping, add a
  branch to the macro-emitted load/save coercion. The pattern is
  established.

## Alternatives Considered

- **Native PG arrays for primitive `Array(T)`.** Rejected for v1 (see
  above). Adds backend-specific paths in materialization and write
  coercion for marginal benefit; JSONB covers the use case.
- **Custom user types via JSON::Serializable detection.** Considered but
  rejected for v1 — it requires the macro to detect whether a user's
  class includes the `JSON::Serializable` module, which Crystal's macro
  type-introspection supports but adds complexity. Users wanting custom
  structured data wrap in `JSON::Any` for now.
- **Dedicated enum support.** Rejected per the discussion — enums would
  need their own evolution discipline (variant renames, removals) that
  doesn't fit ADR-0003's no-in-place-changes rule. Users declare
  `field :status, String` and validate variants in application code.
- **Keep types passing through crystal-db natively where possible
  (UUID on PG, etc.).** Rejected: the case-on-adapter logic at every IO
  boundary for marginal gain isn't worth it. String wire format is fine.
- **Auto-detect any unknown user type and route through JSON.** Rejected
  for v1 — silently widening the accepted type set would erase the
  portable-type discipline that ADR-0014 was carefully closed about. Each
  added type should be an explicit ADR.
