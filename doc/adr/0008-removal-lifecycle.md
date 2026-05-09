# ADR-0008: Removal lifecycle — two steps, no separate deprecation state

## Status

Accepted (2026-05-08)

## Context

Once stable tags (ADR-0002) are in place, removing a column is a model-file edit: replace `field N, ...` with `reserved N`, and the diff engine plans a `DROP COLUMN`. The question is whether this should happen in **one** model edit or **two**.

In a rolling-deploy environment, two app versions run simultaneously while the new one rolls out. If the model edit that reserves the tag and the migration that drops the column both ship in the same release, instances of the previous release are still reading and writing that column when it disappears — they crash. The same problem applies when replacing a column (introducing a new tag and removing the old): if both happen in one release, the older instances don't know about the new tag and the newer instances don't keep the old column in sync.

The standard fix is to split the change into two releases. The open question was whether this discipline needs a dedicated lifecycle state in the DSL — a `deprecated` keyword — or whether the existing primitives (`field`, `reserved`, named queries from ADR-0006) already express it.

## Decision

Removal is a **two-release** discipline using only the existing primitives. No `deprecated` keyword is added.

**Pure removal** — field is no longer needed, no replacement:

- *Release N:* remove all named-query references to the field. The `field` declaration stays; the column stays in the database. No migration runs.
- *Release N+1:* replace the `field` declaration with `reserved <tag>`. The diff engine plans `DROP COLUMN`.

**Replacement** — field is superseded by a new tag:

- *Release N:* add the new `field` with a `default:` (typically `SQL.expr` or a Crystal lambda) that reads from the old column to populate existing rows; switch named queries to bind the new tag. Old `field` declaration stays. Migration adds the new column and runs the backfill per ADR-0004.
- *Release N+1:* replace the old `field` declaration with `reserved <tag>`. Diff engine plans `DROP COLUMN` of the old column.

The "deprecated" state — *the field is declared but no named query references it* — is observable directly from the named-query analysis (ADR-0006). The library emits a lint diagnostic ("field N is declared but no query references it; consider `reserved` in a future release") but does not enforce. The two-release split is an external discipline appropriate to the deployment model, not something the library can validate from a single model snapshot.

## Consequences

- The DSL surface stays minimal. The lifecycle is `field → reserved`, with the "between" state implicit.
- The lint diagnostic surfaces unused fields without requiring users to mark them.
- Users in environments without rolling deploys (single-binary CLIs, batch jobs, dev) can collapse the two releases into one. The library has no way to detect this is happening and does not need to.
- The library can warn when a single migration plan both reserves a tag and drops a column that was queried in the immediately-previous schema — a heuristic for "this might be unsafe under rolling deploys." This is a hint, not an error, and depends on the library having access to the prior schema state, which it does via the live DB and the migration history table.
- Stricter rolling-deploy contracts (zero-downtime with mixed running versions during the deploy itself) may need to fan out *Release N* of a replacement into multiple sub-steps — add column with dual-write, switch reads, stop dual-writing — before *Release N+1* reserves. This staging is expressed through ordinary `field` and `query` edits in successive releases; no library lifecycle state is required to support it.
- The library does not track or enforce release boundaries. Discipline lives with the user and the deploy pipeline, not in the schema language.

## Alternatives Considered

- **Add a `deprecated <tag>` keyword as a third lifecycle state.** Rejected: it adds DSL surface area for state that is already observable. Anything `deprecated` could express (intent, lint behavior, refusing writes) is either a comment, derivable from named-query analysis, or a separate orthogonal feature ("read-only field"). The two-release pattern works without it.
- **Library-enforced two-release discipline** (refuse to plan a migration that reserves and drops a column not previously declared as deprecated). Rejected: the library sees only the current model and the live DB. It has no robust notion of "the previous release's model" — only "the schema currently applied to this database," which may itself be N or N+1 depending on the deploy stage. A heuristic warning is the strongest correct enforcement.
- **One-step removal as the only mode** (collapse `field` directly to `reserved` in a single edit). Rejected as universal advice: works for non-rolling environments but is unsafe for production rolling deploys, which is a primary use case.
