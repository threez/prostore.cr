# ADR-0006: Access patterns declared as named queries in the model

## Status

Accepted (2026-05-08)

## Context

The library needs to know how data will be read in order to:

1. Decide whether a Crystal-lambda-defaulted field (ADR-0004) should be **eager** or **lazy**. A lambda-defaulted field that is filtered, sorted, grouped, joined, or aggregated cannot be lazy — those operations require the value to exist in the database, queryable.
2. Derive the indexes required to support the application's queries, and surface missing ones in the migration plan.
3. Detect indexes that no query covers, which are dead weight and should be dropped.
4. Prevent ad-hoc queries from accidentally relying on lazy fields, which would silently miss not-yet-materialized rows.

There is no reliable way to derive this from arbitrary application code. Every observed access pattern would have to be discovered via macro introspection of every call site, and refactoring caller code would silently change the migration plan.

## Decision

Read access patterns are declared in the model file as **named queries**:

```crystal
class User < Prostore::Model
  field 1, :id,        Int64, primary: true
  field 2, :email,     String
  field 3, :tenant_id, Int64
  field 4, :score,     Int32?, default: ->(r : User) { compute_score(r) }

  query :by_email,      ->(e : String) { where(email: e) }
  query :top_in_tenant, ->(t : Int64)  { where(tenant_id: t).order_by(:score).limit(10) }
  query :find_by_id,    ->(id : Int64) { find(id) }
end
```

The library introspects each named query at compile time and classifies field usage as: **filtered** (`WHERE`), **sorted** (`ORDER BY`), **grouped** (`GROUP BY`), **joined** (`JOIN ON`), **aggregated**, or **projected only** (appears only in the SELECT list).

From this, the library:

- Picks **eager** for a Crystal-lambda-defaulted field that any query references in any non-projected role. A user-declared `lazy:` is overridden to eager; a diagnostic surfaces the override and identifies the offending query. A field referenced only in projection (or never referenced) stays lazy if declared so.
- Plans the index set required to cover the named queries, intersects it with the indexes declared in the model, and emits the missing ones into the migration plan. (Or, at the user's preference, refuses to migrate until the user adds the missing index declarations — to be decided in v1 implementation.)
- Marks indexes not covered by any named query as dead and surfaces them for removal.
- Forbids ad-hoc queries that touch lazy fields. The query DSL does not generate methods that bind lazy fields to filter/sort/group/join positions; attempting to use them is a compile error.

## Consequences

- Adding a query is a reviewable change that includes any required schema and index migrations atomically. Code review of "we now query users by status" is the same diff as "we now have an index on status."
- The migration plan is correctness-driven by construction: every declared query is index-covered.
- The model file is the source of truth for both shape and access patterns. This is closer to DynamoDB single-table design or Cassandra "design for queries" than to the SQL "general-purpose table" tradition.
- Dead-index detection is free.
- More ceremony than ad-hoc query writing. Users coming from arbitrary-SQL traditions will find it constraining; users who have been bitten by missing-index incidents will find it correctness-by-construction.
- Ad-hoc queries are real and necessary in some workflows (one-off investigations, admin tools). They are permitted but: (a) cannot reference lazy fields, (b) are not factored into index planning, (c) are the user's responsibility for performance.
- The scoping question — "should the library *require* every query to be declared, or just the ones that drive schema/index decisions?" — is currently answered as "declare what should drive planning." Ad-hoc paths exist alongside.

## Alternatives Considered

- **(b) Per-field access annotation** (e.g., `field 4, :score, Int32?, lazy: ..., access: :sortable`). Rejected as the canonical surface: it lets the library pick eager-vs-lazy but does not provide enough information for index validation, dead-index detection, or compile-time refusal of unsafe ad-hoc queries. May still be useful as a light-weight escape hatch.
- **(c) Macro-discovered access patterns from application call sites.** Rejected: refactoring caller code would silently change the migration plan. Action-at-a-distance during a migration is a recipe for incidents. The migration plan should depend only on the model file and the live database state.
- **No access patterns; library plans purely from declared indexes.** Rejected: if the user must already declare every index, the library is just a schema applier with extra ceremony. Declaring queries gives the library enough information to *check* the index set against actual access.
