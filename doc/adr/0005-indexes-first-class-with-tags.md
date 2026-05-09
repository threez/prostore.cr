# ADR-0005: Indexes as first-class objects with stable tags

## Status

Accepted (2026-05-08)

## Context

Indexes evolve alongside columns. Adding a column to a composite index, changing a partial index's predicate, renaming an index, or removing one are all routine operations. The same identity problem that drove ADR-0002 for columns applies to indexes: if identity is the index name, a rename is indistinguishable from a drop+add, and a definition change is ambiguous.

Indexes also reference columns, which adds a cross-constraint: removing a column whose index still exists silently leaves a dangling index, or worse, blocks the column drop with a database-level error far from the source.

## Decision

Indexes are declared in the model with stable numeric tags, drawn from a separate tag space from fields. They follow the same evolution rules as columns:

```crystal
class User < Prostore::Model
  field 1, :id,        Int64, primary: true
  field 2, :email,     String
  field 3, :tenant_id, Int64
  field 4, :score,     Int32

  index 1, [:email], unique: true
  index 2, [:tenant_id, :score], where: SQL.expr("score > 0")
  reserved_index 3                                    # previously [:created_at]
end
```

Rules:

- Each index has a stable numeric tag. Renames keep the tag and change the label.
- Removed indexes use `reserved_index` and the tag may never be reused.
- An index that references a `reserved` field (per ADR-0002) is a compile-time error. A field cannot be reserved while a non-reserved index references it; the user must reserve the index first.
- Index definition changes (column set, uniqueness, partial predicate) require a new tag. The old index is reserved. This mirrors ADR-0003 for columns: there are no in-place definition changes.
- Backend-specific creation strategy (`CREATE INDEX CONCURRENTLY` on Postgres for non-trivial sizes) is chosen by the library, not by the user. The DSL stays portable.

## Consequences

- Index renames are free.
- Removing a column cannot accidentally orphan an index — the compile-time check forces explicit ordering.
- Replacing an index (e.g., adding a column to a composite for a new query pattern) is a two-step, reviewable change: introduce the new index, let traffic move, reserve the old.
- Composite, partial, and expression indexes all fit the same surface — the index DSL is structurally rich, not derived from per-field annotations.
- Adds another tag space to manage alongside fields. Tooling can suggest the next available tag.
- The library has a single place where it decides per-backend index strategy (concurrent vs blocking creation, for instance). The DSL itself does not need backend conditionals.

## Alternatives Considered

- **Anonymous indexes derived from per-field annotations** (`field 1, :email, indexed: true`). Rejected: cannot express composite, partial, or expression indexes without ad-hoc syntactic extensions, and the identity-by-column-set approach collides for `(a, b)` vs `(b, a)`.
- **Indexes named by their column set with no separate identity.** Rejected: the same column set with a different predicate is a different index but would collide; renames break references; partial-predicate indexes have no canonical name.
- **Index identity by the column tags they reference.** Rejected: a composite index over the same columns with different ordering is semantically distinct, and a partial index over the same columns with different predicates is also distinct.
