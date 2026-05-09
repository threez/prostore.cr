# Architecture Decision Records

This directory captures the load-bearing design decisions for prostore. Each ADR is one decision: the context it was made in, what was decided, and the consequences and alternatives considered. ADRs are immutable once accepted — a decision that no longer holds is recorded by adding a new ADR that supersedes the old one, not by editing the old one.

Format follows Michael Nygard's lightweight convention.

## Index

| #    | Title                                                           | Status                |
| ---- | --------------------------------------------------------------- | --------------------- |
| 0001 | [Declarative schema as source of truth](0001-declarative-schema.md) | Accepted (2026-05-08) |
| 0002 | [Stable numeric field tags for schema identity](0002-stable-field-tags.md) | Accepted (2026-05-08) |
| 0003 | [No in-place type changes](0003-no-in-place-type-changes.md)    | Accepted (2026-05-08) |
| 0004 | [Three default-value mechanisms](0004-default-value-mechanisms.md) | Accepted (2026-05-08), amended by 0011 |
| 0005 | [Indexes as first-class objects with stable tags](0005-indexes-first-class-with-tags.md) | Accepted (2026-05-08) |
| 0006 | [Access patterns declared as named queries](0006-access-patterns-as-named-queries.md) | Accepted (2026-05-08) |
| 0007 | [Target backends — SQLite and PostgreSQL](0007-target-backends.md) | Accepted (2026-05-08) |
| 0008 | [Removal lifecycle — two steps, no separate deprecation state](0008-removal-lifecycle.md) | Accepted (2026-05-08) |
| 0009 | [Online resumable migration state machine](0009-migration-state-machine.md) | Accepted (2026-05-08) |
| 0010 | [Drift detection and correction](0010-drift-detection-and-correction.md) | Accepted (2026-05-08) |
| 0011 | [Separate `default:` and `backfill:` annotations](0011-separate-default-and-backfill.md) | Accepted (2026-05-08) |
| 0012 | [Foreign keys as first-class tagged objects](0012-foreign-keys.md) | Accepted (2026-05-08) |
| 0013 | [Auto-increment primary keys (sequence portability scope)](0013-auto-increment-primary-keys.md) | Accepted (2026-05-08) |
| 0014 | [DSL surface](0014-dsl-surface.md) | Accepted (2026-05-08), extended by 0015 |
| 0015 | [Custom column types — UUID, BigDecimal, JSON::Any, Array(T)](0015-custom-types.md) | Accepted (2026-05-09) |
