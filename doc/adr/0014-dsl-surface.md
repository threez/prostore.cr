# ADR-0014: DSL surface

## Status

Accepted (2026-05-08)

## Context

Prior ADRs (0002, 0004, 0005, 0006, 0008, 0011, 0012, 0013) introduced individual DSL primitives — `field`, `reserved`, `index`, `query`, `foreign_key`, `default:`, `backfill:`, `lazy:`, `auto_increment:` — but no single ADR captures the DSL as a coherent whole. As implementation begins, the macro structure, the introspection surface the planner consumes, the query DSL extent, type mapping, and the compile-time vs runtime validation split need to be locked in.

This ADR is the consolidated specification of the v1 DSL surface. It does not introduce new evolution semantics — those live in the prior ADRs — but it specifies how those rules are expressed in Crystal source and how the rest of the library introspects them.

## Decision

### Class structure

A model is a Crystal class extending `Prostore::Model`. The body uses macros to declare schema and queries; macros run at compile time and produce per-class introspection structures plus a global registry the planner iterates.

```crystal
class User < Prostore::Model
  field 1, :id,        Int64,  primary: true, auto_increment: true
  field 2, :email,     String
  field 3, :tenant_id, Int64

  index 1, [:email], unique: true
  foreign_key 1, [:tenant_id], references: Tenant, on_delete: :restrict

  query :by_email, ->(e : String) { where(email: e) }
end
```

### Table name derivation

Default table name is the class name lower-snake-cased with **no pluralization**: `User → user`, `OrderItem → order_item`. Predictable and locale-independent. Override with `table_name "users"` at the top of the class body for projects that prefer pluralization or different naming.

### Macro keywords (model body)

| Macro                              | Purpose                                                     |
| ---------------------------------- | ----------------------------------------------------------- |
| `table_name "..."`                 | Override default table name                                 |
| `field N, :name, T, **opts`        | Column declaration with stable tag (ADR-0002)               |
| `reserved N`                       | Permanently retire a field tag                              |
| `index N, [:cols], **opts`         | Index declaration with stable tag (ADR-0005)                |
| `reserved_index N`                 | Permanently retire an index tag                             |
| `foreign_key N, [:cols], **opts`   | FK declaration with stable tag (ADR-0012)                   |
| `reserved_foreign_key N`           | Permanently retire an FK tag                                |
| `query :name, ->(*args) { ... }`   | Named access pattern (ADR-0006)                             |

Reserved-but-not-implemented (compile error in v1, claimed for future ADRs): `sequence`.

### Tag spaces

Three independent tag spaces per model: fields, indexes, foreign keys. `field 1, ...` and `index 1, ...` do not conflict. Each space requires unique tags within the model, with no reuse after `reserved` (per ADR-0002).

### Field options

```crystal
field N, :name, T,
  primary:        false,
  auto_increment: false,    # ADR-0013; only on Int32/Int64 + primary
  default:        ...,      # SQL.expr or Crystal lambda (ADR-0011)
  backfill:       ...,      # SQL.expr or Crystal lambda (ADR-0011)
  lazy:           ...       # Crystal lambda; T? required; mutex with default/backfill (ADR-0004/0011)
```

Nullability is expressed via Crystal's `T?` syntax. `String` ⇒ `NOT NULL TEXT`; `String?` ⇒ `NULL TEXT`. The library does not introduce a separate `nullable:` flag.

### Type mapping (v1 portable set)

| Crystal type | SQLite           | PostgreSQL                 |
| ------------ | ---------------- | -------------------------- |
| `Int32`      | INTEGER          | INTEGER                    |
| `Int64`      | INTEGER          | BIGINT                     |
| `Float32`    | REAL             | REAL                       |
| `Float64`    | REAL             | DOUBLE PRECISION           |
| `String`     | TEXT             | TEXT                       |
| `Bool`       | INTEGER (0/1)    | BOOLEAN                    |
| `Time`       | TEXT (ISO 8601)  | TIMESTAMP WITH TIME ZONE   |
| `Bytes`      | BLOB             | BYTEA                      |
| `T?`         | NULLABLE column  | NULLABLE column            |

Out of scope for v1, requiring future ADRs: `UUID`, `Array(T)`, `JSON::Any`, decimal/numeric, enums, application-defined custom types. Custom mappings are not exposed in v1 — the type set is what ships.

### Index options

```crystal
index N, [:col1, :col2],
  unique: false,
  where:  SQL.expr("status = 'active'"),   # partial index (PG; SQLite ≥ 3.8.0)
  name:   "users_email_idx"                # optional; default derived from table+columns
```

### Foreign key options

```crystal
foreign_key N, [:cols],
  references:        OtherModel,
  references_fields: [:cols],     # optional; defaults to OtherModel's PK
  on_delete:         :no_action,  # :no_action | :restrict | :cascade | :set_null | :set_default
  on_update:         :no_action,
  name:              "..."        # optional
```

### Query DSL

The lambda passed to `query` may use these methods, all macro-introspectable at compile time:

- `where(field: value)` — equality
- `where(field: range)` — range over `Range(T)`
- `where(field: array)` — IN binding
- `order_by(field, desc: false)` — ordering; calls compose
- `limit(n)` / `offset(n)` — paging
- `joins(Model)` — join via the FK between the current model and `Model`; ambiguity (multiple FKs between the two models) is a compile error and must be disambiguated by tag (`joins(Model, fk: 2)`)
- `select(field, ...)` — projection; default is all fields

Explicitly **not** supported inside named queries:

- Raw SQL fragments (`where("col > ?", x)`) — opaque to the macro analyzer and would defeat ADR-0006's index planning. Use Crystal-typed bindings or step outside named queries.
- `group_by`, `having`, window functions — out of scope for v1.
- Subqueries — out of scope for v1.

Ad-hoc queries — using the same DSL outside a `query :name, ...` declaration — are permitted at runtime, are not factored into index planning, and may not bind lazy fields (ADR-0006).

### `SQL.expr`

A literal SQL fragment passed verbatim to the backend, intended for static expressions:

- May reference column names: `SQL.expr("legacy_email")`.
- May call portable SQL functions: `SQL.expr("now()")`.
- May not interpolate Crystal values — doing so is a compile error. For parameterized population, use a Crystal lambda.

The library does not parse `SQL.expr` content. The user is responsible for portability across both backends when targeting both.

### Schema introspection

Each model class exposes at compile time:

- `Class.prostore_schema` — a `Prostore::Schema` value containing fields, indexes, foreign keys, queries, and the resolved table name.
- `Class.prostore_table_name` — the resolved table name.

A module-level registry:

- `Prostore.models` — all registered model classes, populated by the `Prostore::Model` `inherited` hook.

These are the surfaces the planner reads. Application code does not normally call them directly; they exist for migration planning, drift detection, and tooling.

### Compile-time vs runtime validation

**Compile time** (macro errors, block compilation):

- Tag uniqueness within each space.
- No reuse of a `reserved` tag.
- `auto_increment` only on `Int32`/`Int64` + `primary: true`.
- `lazy:` requires `T?`; mutually exclusive with `default:`/`backfill:`.
- `on_delete: :set_default` / `on_update: :set_default` requires `default:` on the source field.
- `references:` resolves to a `Prostore::Model` subclass.
- Named-query lambda body uses only introspectable DSL methods.
- Field, index, FK, and table names do not start with the reserved `prostore_` prefix.
- Column names within a table are unique.
- A `reserved` field is not still referenced by a non-reserved index or FK.

**Runtime** (planner errors, surfaced before any DDL runs):

- Adding a non-nullable field to a non-empty table without `backfill:`.
- Schema-fingerprint mismatch with an in-progress migration (ADR-0009).
- Unfixable drift (ADR-0010).
- FK target column missing in the live DB.
- Step-parameter validation (chunk sizes, lease bounds).

## Consequences

- Implementation has a single specification to build against. New surface changes go through this ADR or a successor.
- The planner's input shape is well-defined: iterate `Prostore.models`, read each `prostore_schema`, diff against the live DB and `prostore_schema` bookkeeping table.
- Compile-time checks catch the bulk of programmer error before the program runs. Runtime checks are reserved for state-dependent conditions.
- The query DSL is intentionally narrow. Users with needs beyond it (subqueries, windows, GROUP BY) escape via runtime ad-hoc queries, accepting that those patterns are not factored into index planning.
- Type mapping is portable but small. v1 covers most real-world apps; advanced types are gated behind future ADRs.
- Non-pluralized table-name default surprises users coming from Rails/AR. The override is one line; the default trades a one-off convenience for predictability.
- Reserving the `prostore_` prefix prevents accidental collision with bookkeeping tables (ADR-0009/0010).

## Alternatives Considered

- **Pluralized default table names.** Rejected: locale-dependent, irregular plurals are a known source of ORM bugs, override is trivial, project-level mixin can pluralize uniformly if desired.
- **Open query DSL allowing raw SQL fragments inside named queries.** Rejected: defeats ADR-0006's index-planning analysis. Raw SQL has its place — at the call site, not in named queries.
- **Single unified tag space across fields/indexes/FKs.** Rejected: forces coordination across three unrelated concerns. Independent spaces let `field 1` and `index 1` coexist intuitively.
- **Type registry letting users define new Crystal-to-SQL mappings.** Rejected for v1: scope creep. Portable types are what ships; new types arrive via ADRs that may scope to one backend.
- **Inline `nullable: true` flag instead of using Crystal's `T?` syntax.** Rejected: redundant with Crystal's type system. Using `T?` puts nullability in one place — the type — and lets the type system carry it.
- **Class-level `inherited` registry vs. explicit registration.** Rejected explicit: idiomatic Crystal/Ruby uses `inherited`, and explicit registration is forgettable. The hook also lets the planner enumerate models without configuration.
- **Allow `query` to take a block instead of a lambda.** Rejected: lambdas have explicit parameter types, which the macro analyzer can introspect for query parameter binding. A bare block would require type inference the macros aren't equipped for.
