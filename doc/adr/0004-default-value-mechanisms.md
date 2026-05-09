# ADR-0004: Three default-value mechanisms

## Status

Accepted (2026-05-08). Amended by ADR-0011: the unified `default:` keyword is split into `default:` (new rows) and `backfill:` (existing rows). `lazy:` semantics unchanged.

## Context

ADR-0003 forbids in-place type changes; column evolution always proceeds via add-new-column. This makes the population strategy for the new column the central design question. Three patterns recur in practice and have wildly different costs:

1. **Server-evaluable expression** (`username || '@example.com'`, `now()`, a constant). The database can populate every existing row in a single statement — on PostgreSQL ≥11 with non-volatile expressions, it does so without rewriting the table. Cheap and atomic.

2. **Application-language function over the row** (`->(row) { compute_score(row) }`). The database cannot evaluate this. The library must iterate every existing row through the application, in chunks, with resumable progress tracking. Powerful but expensive — on a million-row table this is a multi-phase, possibly multi-hour migration.

3. **Application-language function, evaluated lazily.** For columns that will be filled in over time as rows are naturally written, the eager backfill is wasted work. If the application can tolerate "value is computed on read for not-yet-touched rows," the column can be added as nullable in one cheap statement and the cost is amortized across normal traffic.

Collapsing these into one keyword would hide cost differences that matter. The DSL should make the cost of each choice visible at the field declaration.

## Decision

The DSL exposes three distinct keywords:

```crystal
field 5, :email, String,
  default: SQL.expr("username || '@example.com'")     # (1) server-side, queryable

field 6, :score, Int32,
  default: ->(row : User) { compute_score(row) }      # (2) eager Crystal lambda, queryable

field 7, :badge, String?,
  lazy:    ->(row : User) { derive_badge(row) }       # (3) lazy Crystal lambda, NOT queryable
```

Semantics:

- **(1) `default: SQL.expr(...)`** — server-side default. Backfill happens in the database. Both new rows and existing rows get the expression's value.

- **(2) `default: ->(row) { ... }`** — eager Crystal lambda. On column add, the library runs a chunked, resumable backfill: read rows in batches keyed by primary key, evaluate the lambda, write back, commit per chunk. Progress is persisted so a crashed migration resumes. Once complete, new inserts evaluate the lambda before INSERT.

- **(3) `lazy: ->(row) { ... }`** — lazy Crystal lambda. **The field type must be `T?`** — this is enforced at compile time. The column is added as `NULL`-able in one cheap statement; no backfill runs. On read through the ORM, if the value is NULL, the lambda fills it in (and the row converges on save — see write-through below). The field is **not queryable** — the query DSL refuses to bind it in `WHERE`/`ORDER BY`/`GROUP BY`/`JOIN ON`/aggregates. Indexes and foreign keys on lazy fields are also forbidden.

### Lazy semantics, made explicit

- **Save behavior.** Saving a row always materializes the lazy value (runs the lambda if the field is unset, writes the value). This causes rows to converge over time as they are naturally touched.
- **Read behavior.** Reading a row evaluates the lambda for any NULL lazy field; the result is returned to the caller but is not necessarily written back unless the row is also saved.
- **Convergence is asymptotic.** Cold rows that are never read or written stay NULL forever. This is acceptable as long as the field stays optional. Promoting a lazy field to non-null, or dropping a source column it derives from, requires an eager backfill at that moment — `lazy:` defers the cost, it does not eliminate it.
- **External readers see NULL.** Tools other than the ORM (BI, replication consumers, raw SQL) see NULL where the application sees a value. The library emits a `COMMENT ON COLUMN` noting "lazy-materialized via prostore — NULL means not-yet-touched" so an operator inspecting the schema is not misled.

## Consequences

- Each strategy's cost is visible at the field-declaration site. A reviewer can see whether a schema change will rewrite the table (1, sometimes), run a chunked migration (2), or be effectively free (3).
- The lazy mechanism collapses the most expensive case to a zero-phase column add. This is the cheapest path for wide tables that don't query the new column.
- Three keywords are more surface area than one. Users must learn the difference. The naming (`default` vs `lazy`) is intentionally suggestive of the semantics.
- The `lazy:` + `T?` requirement makes the operational gotcha visible in the type system: every access site must acknowledge that the value may not yet exist.
- The choice between eager and lazy for a Crystal-lambda default is not always the user's to make. Per ADR-0006, if a query references the field, the library overrides `lazy:` to eager and emits a diagnostic. The user expresses intent; access patterns determine feasibility.

## Alternatives Considered

- **Single default mechanism (SQL expression only).** Rejected: limits expressivity to whatever SQL can compute server-side. Many real backfills need application-language logic.
- **Single default mechanism (Crystal only, always eager).** Rejected: forces an expensive multi-phase migration even when the access pattern doesn't warrant it.
- **Lazy as a flag on a unified `default:` keyword.** Rejected: the semantics of lazy diverge significantly from eager (must be `T?`, not queryable, indexes and FKs forbidden, asymptotic convergence). Distinct keywords aid both readability and compile-time enforcement.
