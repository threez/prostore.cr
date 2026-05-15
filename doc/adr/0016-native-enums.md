# ADR-0016: Native Crystal enum support

## Status

Accepted (2026-05-15). Supersedes the enum-related decisions in
[ADR-0015](0015-custom-types.md) (which deferred enum support, citing the
need for a dedicated evolution discipline).

## Context

Crystal enums are the idiomatic way to restrict a value's domain to a
closed set, with compile-time guarantees at the call site. Without
first-class support, prostore users have to either:

- Declare a plain `String` / `Int32` column and re-validate variants in
  application code on every read/write, or
- Manually call `EnumClass.parse` / `EnumClass.from_value` everywhere.

Neither approach captures the value set in the schema, so the database
doesn't enforce it, and changes to the variant list aren't visible to
diff or fingerprinting.

ADR-0015 explicitly deferred enums:

> "Enums would need their own evolution discipline (variant renames,
> removals) that doesn't fit ADR-0003's no-in-place-changes rule cleanly."

That discipline is what this ADR provides. The high-bit insight: the *type*
of the column (string or integer) follows ADR-0003 (no in-place changes),
but the *member set* of an enum is a separate axis that can grow safely
without violating ADR-0003 — only shrinking or value-changes are risky.

## Decision

### Storage discipline (two portable tags)

| Storage | Portable tag | Default? | SQLite | PostgreSQL |
| --- | --- | --- | --- | --- |
| Member name (`Status::Active` → `'Active'`) | `enum_string` | yes | `TEXT` | `TEXT` |
| Underlying integer (`Status::Active` → `0`) | `enum_int` | `as: :int` | `INTEGER` | `BIGINT` |

`enum_string` is the default for two reasons: (a) raw DB queries are
self-explaining, and (b) adding members at arbitrary positions doesn't
shift existing rows' stored values (since the wire form is the name, not
the position).

`@[Flags]` enums are **implicitly int-backed** — combinations (`Read | Write`)
only round-trip through the integer wire form. Passing `as: :string` for a
flags enum is a compile error.

```crystal
enum Status
  Active
  Pending
  Archived
end

@[Flags]
enum Perms
  Read
  Write
  Execute
end

class User < Prostore::Model
  field 5, :status, Status              # TEXT, name-backed
  field 6, :rank, Tier, as: :int        # INTEGER, value-backed
  field 7, :perms, Perms                # @[Flags] → INTEGER, value-backed
end
```

Toggling `enum_string` ↔ `enum_int` for the same field tag changes
`portable_type` and is forbidden by ADR-0003. Switch storage by adding a
new field tag and reserving the old one.

### CHECK constraint

Every enum column carries a named CHECK constraint enforcing the declared
member set at the storage layer. The constraint name is stable
(`<table>_<column>_enum_chk`), so the migration runner can DROP/ADD it
when the member set widens.

- **String-backed:** `CHECK (col IN ('Active', 'Pending', 'Archived'))`
- **Int-backed (non-flags):** `CHECK (col IN (0, 1, 2))`
- **Flags:** `CHECK (col >= 0 AND col <= MAX)` where `MAX` is the bitwise
  OR of all declared flag values. Any combination of declared flags is
  valid; obviously out-of-range writes (negative, or above the max) are
  rejected.

### Evolution discipline

| Change | Allowed | Mechanism |
| --- | --- | --- |
| **Add a member** | Yes (additive) | Diff emits `AlterEnumMembers`; PG drops + re-adds the CHECK constraint, SQLite uses the table-rebuild dance. Existing rows survive. |
| **Remove a member** | **No** | Validator raises with guidance. Existing rows may already carry the value; library cannot guarantee correctness. Keep the member declared, or `reserved` the field tag and add a new field with the trimmed set. |
| **Rename a member** | **No** | Surfaces as remove+add; rejected as above. To rename, add the new name, migrate data in app code, then reserve the old declaration on the next release. |
| **Change a member's int value** | **No** | `enum_int`-stored rows would be silently misread. Validator raises. Forbidden in-place. |
| **Toggle `enum_string` ↔ `enum_int`** | **No** | `portable_type` change; forbidden by ADR-0003. |
| **Toggle `@[Flags]` on/off** | **No** | Reinterprets stored integer values; forbidden by this ADR. |

Member additions flow naturally through the existing migration runner
infrastructure: the new step is restartable, transaction-wrapped on
backends that allow it, and updates the bookkeeping row in the same
transaction as the DDL.

### Schema record and fingerprint

`Schema::Field` carries two new optional fields:

- `enum_members : Array(Schema::EnumMember)?` — list of `{name, value}`
  pairs, populated at compile time when the field's type resolves to an
  Enum subclass.
- `enum_is_flags : Bool` — true for `@[Flags]` enums.

The fingerprint (ADR-0009) hashes the member list (as `name=value,…`) and
the flags flag on each enum-bearing field's hash line. Adding or removing
a member changes the fingerprint, which triggers ADR-0009's version-skew
guard for in-progress migrations.

The `prostore_schema` bookkeeping table grows two columns (`enum_members`
JSON, `enum_is_flags`) via an internal-schema v3 migration. Pre-existing
v2 installs that lack a `schema_version` row are detected by column
shape (`portable_type` present, `enum_members` absent) and migrated.

### Compile-time validation

- `field :col, MyEnum, as: :int` — int-backed.
- `field :col, MyEnum, as: :string` — explicit string (the default).
- `field :col, MyEnum, as: :bool` — compile error (only `:string` /
  `:int` accepted).
- `field :col, String, as: :int` — compile error (`as:` is only valid
  on enum field types).
- `field :col, FlagsEnum, as: :string` — compile error (flags must be
  int-backed; either omit `as:` or pass `as: :int`).
- `field :col, MyEnum, primary: true, auto_increment: true` — compile
  error (auto_increment is restricted to `Int32`/`Int64`, ADR-0013).

## Consequences

- Users get type-safe column declarations whose value space is captured
  in the schema, the bookkeeping table, and the live DB constraint.
- Diff and migration handle the "widen the allowed values" use case
  natively without escape hatches. The forbidden cases (remove, rename,
  reorder integer values) surface as clear errors at validation time,
  before any DDL runs.
- A misbehaving non-prostore client that writes garbage into an enum
  column is rejected by the CHECK constraint at write time, rather than
  silently corrupting the data set.
- Adding a portable type to the taxonomy follows a now-established
  pattern: extend `Types`, extend the macro detection, add the adapter
  mapping, add coercion paths in `records.cr`, hash into the
  fingerprint, surface in the bookkeeping schema.
- The wire format stays uniform — String or Int64, the same shapes
  already handled by the UUID/Decimal/JSON paths.
- The two-release lifecycle that ADR-0008 already documents for *fields*
  is the answer for enum *members* too: keep the variant declared in
  release N while removing all uses, reserve the field tag and reshape
  in release N+1.

## Alternatives Considered

- **Status quo (plain `String` column + Crystal-side validation).**
  Rejected: the value set isn't visible to the schema layer, no DB-side
  enforcement, no fingerprint sensitivity to changes. The exact pain
  point ADR-0015 chose to live with.
- **Native PostgreSQL `CREATE TYPE name AS ENUM (…)`.** Rejected for
  v1: SQLite has no analog, so portability requires fallback handling;
  PG enum types have their own ALTER lifecycle (`ALTER TYPE ADD
  VALUE`) that adds a second axis of state to track in the bookkeeping
  table. A future ADR can opt PG into native enums if the use case
  warrants it; the schema-level metadata stays the same.
- **Always int-backed (smaller storage).** Rejected: brittle against
  member reordering, cryptic in raw queries, contradicts ADR-0014's
  preference for predictable defaults. The integer form is one
  keyword away (`as: :int`) for callers who want the storage savings.
- **Always string-backed (no `as:` opt-in).** Rejected: forces
  workarounds for cases where the integer form is the natural choice
  (sortable rank values, bitfields, interop with non-prostore writers
  that expect integers).
- **`enum_flags` as a separate portable tag.** Rejected: would force
  the bookkeeping table and the type taxonomy to grow without
  meaningful benefit. The `@[Flags]` distinction is one bool on the
  Field record; the storage type is still `enum_int`.
- **Allow member removal with an explicit `unsafe: true` flag at the
  field site.** Rejected: optional escape hatches dilute the discipline
  (ADR-0003 alternatives discussion). If the rule is right, it's the
  only rule. Users who *must* remove a member do so via reserve-and-readd,
  which forces them to think about the existing rows.
- **Implicit CHECK omission (only Crystal-side enforcement).** Rejected:
  the schema record holds the truth, and the database should reflect
  that truth at the storage layer. A misbehaving non-prostore writer is
  exactly the scenario CHECK constraints exist for.

## Future work (deferred)

- **`Array(MyEnum)`** — useful but adds another axis (Array of enum
  values, all from the same enum class, JSON-encoded). Wait for a
  concrete user need before designing the inner-type handling.
- **JSON::Serializable-detection custom types** — already deferred by
  ADR-0015; a future ADR can extend the macro to detect classes
  including `JSON::Serializable` and route them through JSON
  serialization automatically.
- **PG-native `CREATE TYPE … AS ENUM` opt-in** — a future ADR can let
  users choose native PG enums per column for the storage / index
  ergonomics, while SQLite continues with TEXT + CHECK. The schema
  metadata in this ADR is forward-compatible with that choice.
