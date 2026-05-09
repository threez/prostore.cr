# ADR-0011: Separate `default:` and `backfill:` annotations

## Status

Accepted (2026-05-08). Refines ADR-0004 in the area of new-row vs existing-row population. The `lazy:` keyword and its semantics are unchanged.

## Context

ADR-0004 unified new-row defaults and existing-row backfill under a single `default:` keyword — the same expression was used for both INSERT-time population and column-add-time backfill. This works when the two values coincide but breaks down in two recurring cases:

1. **v1→v2 replacement (ADR-0008).** The existing-row backfill needs to read from the legacy column. The new-row default has no business referencing it — new rows live entirely in the new tag's space. Forcing one expression to serve both produces something awkward like "if legacy_email is set, use it, else use the new default" — logic that doesn't belong in either role.

2. **Different mechanisms for different timings.** A column may naturally use `SQL.expr` for new rows (cheap, server-side) but require a Crystal lambda for the backfill (richer logic over legacy data). Forcing one mechanism for both is a worse fit than letting each timing pick what it needs.

Both cases motivate splitting the keyword.

## Decision

`default:` and `backfill:` are independent annotations. Each accepts `SQL.expr(...)` or a Crystal lambda independently. `lazy:` remains a separate keyword for the on-demand-materialization case.

```crystal
class User < Prostore::Model
  field 1, :id, Int64, primary: true

  # Same value for both — written twice; explicit beats implicit
  field 2, :status, String,
    default:  SQL.expr("'active'"),
    backfill: SQL.expr("'active'")

  # Different: backfill from a related column, default is a constant
  field 3, :region, String,
    default:  SQL.expr("'unknown'"),
    backfill: SQL.expr("country_code")

  # Different mechanisms: server-side default, eager Crystal backfill
  field 4, :score, Int32,
    default:  SQL.expr("0"),
    backfill: ->(row : User) { migrate_old_score(row) }

  # v1→v2 replacement: new rows provided by caller, existing rows from legacy column
  field 5, :email, String,
    default:  ->(row : User) { row.email },
    backfill: SQL.expr("legacy_email")

  # Lazy: one lambda for both timings — unchanged from ADR-0004
  field 6, :badge, String?,
    lazy: ->(row : User) { derive_badge(row) }
end
```

### Rules

1. **`default:` is the new-row strategy**, evaluated at INSERT. `SQL.expr` renders as a column DEFAULT clause; a Crystal lambda is evaluated by the ORM before issuing INSERT.

2. **`backfill:` is the existing-row strategy**, evaluated at column-add time. `SQL.expr` is applied as a server-side update (folded into `ADD COLUMN ... DEFAULT (expr)` on Postgres when the expression is non-volatile). A Crystal lambda runs as the chunked, resumable backfill defined in ADR-0009 (mechanism 2 of ADR-0004).

3. **`lazy:` is mutually exclusive with `default:` and `backfill:`**. It is the only form where one lambda genuinely serves both timings, because the laziness is the point — computing differently per timing would defeat it. Field type must be `T?`; column is not queryable (per ADR-0004).

4. **Compile-time validation:**
   - A non-nullable field added to a non-empty table requires `backfill:`. Without it, the column cannot be added without violating NOT NULL on existing rows.
   - A non-nullable field requires `default:` *or* the model's named queries / INSERT call sites must bind the field explicitly. ADR-0006's query introspection makes this checkable.
   - A nullable field with no `backfill:` is valid; existing rows are NULL.
   - `default:` without `backfill:` is valid for nullable fields and for first-time table creation (no existing rows to backfill).
   - `lazy:` combined with `default:` or `backfill:` is a compile error.

## Consequences

- The cost of each population strategy is visible at the field declaration. A reviewer sees that one column's existing-row backfill is a cheap server-side update while another's is a chunked Crystal lambda with attendant migration state.
- The v1→v2 replacement pattern (ADR-0008) is expressible without contortion: `default:` describes the new-state shape; `backfill:` describes the migration from legacy data.
- Coinciding values must be written twice. Explicit at the cost of brevity. A `default_and_backfill:` sugar can be added later if duplication proves common — out of scope for v1.
- The compile-time validation catches missing `backfill:` on non-nullable fields before any DDL runs. The unified-keyword form silently used the same expression for both timings, which masked this class of error.
- `lazy:` is preserved unchanged. It remains the only annotation where one lambda intentionally serves both new-row and existing-row paths.

## Alternatives Considered

- **Keep the unified `default:` keyword (ADR-0004 as originally written).** Rejected: cannot express the v1→v2 case where the two diverge, and forces a single mechanism for both timings even when different ones are appropriate.
- **`default:` falls back to `backfill:` when `backfill:` is absent.** Rejected: implicit behavior. Writing the same expression twice makes the choice visible. Implicit fallback also misbehaves for Crystal lambdas, which the library cannot cheaply apply to all existing rows the way a `SQL.expr` can — silent fallback would hide a multi-phase migration the user didn't ask for.
- **Three keywords by mechanism (`sql_default:`, `eager_default:`, `lazy:`).** Rejected: orthogonal to the new-row vs existing-row split. The current shape (`default:`/`backfill:`/`lazy:` as timing keywords; `SQL.expr` vs Crystal lambda as strategy values) keeps timing and strategy on separate axes.
