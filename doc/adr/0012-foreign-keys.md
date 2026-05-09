# ADR-0012: Foreign keys as first-class tagged objects

## Status

Accepted (2026-05-08)

## Context

Foreign keys are structural relationships that evolve with the schema. They have the same identity problems as indexes (rename vs. drop+add), they encode semantics (ON DELETE / ON UPDATE actions) that change application-visible behavior when modified, and they are expensive to add online to a non-empty table.

Both backends support FKs but with significantly different DDL profiles:

- **PostgreSQL** supports `ALTER TABLE ... ADD CONSTRAINT ... NOT VALID` (cheap, no row scan) followed by `ALTER TABLE ... VALIDATE CONSTRAINT` (online, no exclusive lock). Drop is single-statement.
- **SQLite** has limited DDL: in older versions, adding or removing a FK requires a table rebuild. Modern SQLite (>= 3.26) handles `ALTER TABLE ... DROP COLUMN` and similar more gracefully but FK changes still often imply rebuilds. SQLite also requires `PRAGMA foreign_keys = ON` per connection for FK enforcement to be active at all.

FKs also interact with several existing ADRs:

- **ADR-0002 / ADR-0008** (reservation lifecycle): a column that is the source or target of a non-reserved FK cannot be reserved without first reserving the FK.
- **ADR-0003** (no in-place type changes): the FK's contract — column set, target, ON DELETE/UPDATE actions — is application-visible. Changing it in place would silently alter behavior.
- **ADR-0006** (named queries): joins through a FK are an access pattern. The library uses query introspection to determine that the source-side column needs an index — it does not auto-create indexes on FK columns simply because the FK exists.

## Decision

Foreign keys are first-class objects with stable numeric tags, drawn from a separate tag space from fields and indexes. They follow the same evolution rules as columns and indexes: renames keep the tag, definition changes require a new tag, removals go through `reserved_foreign_key`.

```crystal
class Order < Prostore::Model
  field 1, :id,        Int64, primary: true, auto_increment: true
  field 2, :user_id,   Int64
  field 3, :tenant_id, Int64

  foreign_key 1, [:user_id],
    references: User,
    on_delete:  :cascade,
    on_update:  :no_action

  foreign_key 2, [:tenant_id, :user_id],
    references:        TenantMember,
    references_fields: [:tenant_id, :user_id],   # explicit when target isn't PK
    on_delete:         :restrict
end
```

### Rules

1. **Default reference is the target's primary key.** If the target is something other than the PK, the user names target columns explicitly via `references_fields:`. Both single-column and composite FKs are supported.

2. **Allowed actions:** `:no_action | :restrict | :cascade | :set_null | :set_default`. `:set_default` requires a `default:` to exist on the source field (compile-time check). Deferred constraints (Postgres-only) are out of scope for v1; the DSL leaves room (`deferrable:`) for a later ADR.

3. **Definition changes require a new tag.** Changing the column set, the target, or any action requires reserving the old FK and introducing a new one. The two-step removal lifecycle (ADR-0008) applies. Both FKs may briefly coexist during the transition; this is harmless when semantics are compatible (both `:cascade`, for example) and is the operator's responsibility to evaluate when they are not (transitioning `:restrict` → `:cascade` means deletes are still blocked by the old FK during the window).

4. **Reservation interlocks.** Compile error if a `reserved` column tag is still referenced by a non-reserved FK on either side. Operator must reserve the FK first, then the column.

5. **Online add via two steps on Postgres.** The planner emits `add_foreign_key_not_valid` (cheap, no scan) and `validate_foreign_key` (online, no exclusive lock) as separate steps in the migration plan (ADR-0009). Either step is independently resumable. SQLite has no equivalent; FK changes against non-empty tables become long-running rebuild steps in the state machine.

6. **Indexes on FK source columns are not auto-created.** Per ADR-0006, named queries drive index creation. A query that joins through or filters by the FK column declares the access; the planner sees an index is required and emits the migration. FKs without queries against them get no index — and that is correct, because nobody is querying them.

7. **`PRAGMA foreign_keys = ON` is set automatically per SQLite connection.** Off by default in SQLite; the runtime enables it on every connection without operator action.

8. **Drift extends to FK objects.** `prostore_schema.kind` (ADR-0010) gains `'foreign_key'`. External addition of an FK is reported as unmanaged. External removal of a managed FK is auto-fixed (re-create — no data loss). External change to the action (`CASCADE` ↔ `NO ACTION` etc.) is unfixable per ADR-0003 spirit and surfaces as a hard error.

9. **Topological ordering at table creation.** The planner sorts tables by FK dependency. Cycles (rare) are resolved by creating tables without FKs first, then adding the FKs as separate steps in a second pass. v1 does not attempt to be cleverer than this.

## Consequences

- FK evolution is on the same disciplined footing as columns and indexes. Renames are free; semantically meaningful changes (action, target) require a new tag and are visible in code review.
- Postgres gets non-blocking online FK additions out of the box via the two-step `NOT VALID` + `VALIDATE` pattern.
- SQLite's weaker FK story is honest about the cost — the state machine treats rebuild-driven FK changes as long steps with the same resumability contract as backfills.
- Adding a FK does not silently add an index. Apps that need the index declare a named query that uses the column, and the index falls out of ADR-0006's analysis. This is consistent with the rest of the design (no implicit indexes anywhere).
- The compile-time interlock prevents a class of bugs where a column is reserved but a FK still points at it, leaving an inconsistent migration plan.
- Cycles between tables are handled but inelegantly. Most schemas don't have them; users who do pay a small cost in the form of two-pass table creation. Acceptable for v1.

## Alternatives Considered

- **Inline FK declaration as a field property** (`field 2, :user_id, Int64, references: User`). Rejected: doesn't extend cleanly to composite FKs or explicit ON DELETE/UPDATE configuration. Inline form would have to grow into something approaching the standalone form for any non-trivial case.
- **Auto-create an index on every FK source column.** Rejected: produces dead indexes for FKs that no query uses. ADR-0006's named-query analysis already covers the case where indexes are needed.
- **Forbid non-PK references entirely in v1.** Rejected (confirmed during design): non-PK FKs are uncommon but real (referencing a unique business key), and supporting them is a small marginal cost in DSL surface.
- **Allow in-place ON DELETE / ON UPDATE changes** ("they're just metadata"). Rejected: action changes are application-visible — `:cascade` and `:no_action` produce different runtime behavior. Requiring a new tag forces explicit thinking about the transition window and matches ADR-0003's broader rule.
- **First-class deferred constraints in v1.** Rejected: Postgres-only feature, niche use case (mostly for circular FKs and bulk loads). DSL slot is reserved (`deferrable:`) for a later ADR.
