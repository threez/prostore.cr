# ADR-0001: Declarative schema as source of truth

## Status

Accepted (2026-05-08)

## Context

Traditional ORMs split the schema across three artifacts: the current model class, an ordered list of migration files, and the actual database state. They drift. A migration applied out of order, a hand-edited database, or a half-merged branch can leave any one of the three out of sync with the others.

prostore's purpose is to remove this split. The model definition should be the only place where the schema is described.

## Decision

The model defined in Crystal is the single source of truth for the desired schema state. The library inspects the actual database, computes a diff against the desired state, and produces a migration plan. There are no hand-written migration files in the repository.

## Consequences

- The schema is read in one place — code review of a schema change is the same as code review of the model file.
- Drift is detectable: if the database has structure not present in the model, the library can flag it.
- Refactoring the schema is a code change, not a sequence of forward and reverse migration files.
- The migration plan is computed by the library. Wrong plans are library bugs, not user mistakes; the correctness bar for the diff engine is high.
- Pure auto-apply at process startup is dangerous in production. The library will need a "generate plan, apply later" mode for production deploys, similar to Prisma or Atlas. v1 may ship dev-mode auto-apply only and explicitly punt on the production deploy story.
- Hand-written database modifications outside the library must be either prohibited (refuse to operate against unrecognized state) or detected as drift and surfaced to the user. This decision is deferred to a later ADR.

## Alternatives Considered

- **Hand-written migration files** (Rails, Django, Granite). Rejected: this is the model we are explicitly trying to replace. Truth is scattered, manual labor is required for every change, and forward/reverse migrations rot.
- **Auto-generated migration files from a schema diff** (Prisma, Django `makemigrations`). Rejected: still produces files that must be reviewed and ordered. The goal is to remove the files entirely; if a plan is needed for production deploys, it can be generated on demand from the model and the live DB rather than checked in.
