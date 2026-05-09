# ADR-0002: Stable numeric field tags for schema identity

## Status

Accepted (2026-05-08)

## Context

Once the model is the source of truth (ADR-0001), the diff engine must compare desired and actual schemas and decide what changed. The hard case is distinguishing a *rename* from a *drop + add*. If column identity is the column name, a rename is indistinguishable from removing one column and adding another with different content.

Existing declarative-schema tools (Atlas, Prisma, Django auto-makemigrations) all stumble here. They prompt the user, apply name-similarity heuristics, or refuse. None solve it cleanly. prostore intends to.

Protocol Buffers solved the analogous problem decades ago by separating identity (a numeric tag) from label (the field name). The same idea applies to SQL columns.

## Decision

Each column carries a numeric tag declared in the model. The tag is the column's identity for diff and migration purposes. Names are labels and may change freely. Removed tags are recorded as `reserved` and may never be reused.

```crystal
class User < Prostore::Model
  field 1, :id, Int64, primary: true
  field 2, :username, String       # was previously :name — same tag, no migration cost
  reserved 3                        # was :legacy_email; tag retired forever
  field 4, :email, String?
end
```

The same identity model applies to indexes (see ADR-0005).

## Consequences

- Renames are unambiguous — same tag, new name → `RENAME COLUMN`. No prompting, no heuristics.
- Reservations prevent accidental tag reuse, which would conflate a removed column with a new one of the same number.
- The diff engine is deterministic and runs without user interaction.
- Users must assign tags manually. This is unfamiliar to those coming from Rails-style ORMs. The DSL can suggest the next available tag, but assignment remains explicit.
- Tags are permanent. A typo committed to a release cannot be silently corrected — it can only be reserved and superseded by a new tag.
- The model file grows monotonically as reservations accumulate. This mirrors `.proto` files and is a feature, not a bug: it preserves the deprecation history at the code-review level.

## Alternatives Considered

- **Name-based identity with rename heuristics.** Rejected: every existing implementation of this approach either prompts the user or makes wrong guesses on edge cases.
- **Library-managed tags hidden in a metadata table.** Rejected: source of truth would split between the model file and the database, defeating ADR-0001. A developer reading only the model file could not reason about renames.
- **Identity by composite (name, type, position).** Rejected: position is too brittle, and a type change still loses identity (and ADR-0003 forbids type changes anyway).
