# ADR-0017: Customisable enum wire format

## Status

Accepted (2026-05-15). Supersedes the wire-format aspect of
[ADR-0016](0016-native-enums.md), which hard-coded the storage form to
the Crystal source-level member name.

## Context

ADR-0016 introduced native Crystal enum support with two storage modes —
`enum_string` (member name as TEXT) and `enum_int` (underlying integer).
For `enum_string`, the stored value was hard-coded to `member.to_s`, which
in Crystal is the source-level identifier in PascalCase (`BounceHard`,
`Active`, `ComplaintAbuse`).

In practice, applications already expose lots of "status-shaped" columns
through external surfaces — JSON APIs, Prometheus labels, HTML
`<option value="…">` markup, log lines — using the snake_case or
lower-case conventions of those ecosystems (`bounce_hard`, `active`,
`complaint_abuse`). Migrating those columns to native enums under
ADR-0016 would force a breaking rename of every external value because:

- `BounceHard.to_s` is `"BounceHard"`, not `"bounce_hard"`.
- `Enum.parse?` is case-insensitive but does **not** bridge `bounce_hard`
  ↔ `BounceHard` — the underscore makes them distinct strings.
- The CHECK constraint emitted by the migration uses the PascalCase
  names, so writing the snake_case form via raw SQL fails.

A downstream user verified this against the v0.3.0 release: of ~15
status-shaped fields in their app, **one** was a candidate for native
enums (a field with zero external surface). The rest stayed on plain
`String` columns purely to preserve the wire format.

This ADR adds a per-field `naming:` option that controls the wire form
for `enum_string` columns. The Crystal source-level name remains the
canonical identifier (used in display, error messages, and as the lookup
key when comparing schemas across migrations); the wire form is a
separate concept stored alongside.

## Decision

### Field option

```crystal
field 7, :status, Reason, naming: :snake_case
```

`naming:` is valid only on enum fields and only when the storage form is
`enum_string`. The macro rejects `naming:` on:

- Non-enum fields (`naming:` is only meaningful for member-name → wire
  translation).
- Int-backed enums (`as: :int` or `@[Flags]`) — those store integers, so
  there is no name to translate.

Default: `:as_declared` (preserves the v0.3.x behaviour — no breakage for
existing models).

### Supported algorithms

| Symbol | Conversion | Example (`BounceHard`) |
|---|---|---|
| `:as_declared` (default) | none | `BounceHard` |
| `:snake_case` | Crystal `underscore` rule | `bounce_hard` |
| `:kebab_case` | same rule, hyphen separator | `bounce-hard` |
| `:lower_case` | `.downcase` | `bouncehard` |

The conversions live in `Prostore::Schema::NameConversion.apply` as pure
functions of the source-level name and the algorithm symbol. They are
deliberately conservative — no acronym smoothing, no locale handling,
no Unicode normalisation. Users with irregular needs (numbers,
punctuation, colon-separated namespaces like `complaint:abuse`) should
either pick the closest algorithm and ensure the source-level names
already match, or wait for the per-member annotation escape hatch
(deferred to a future ADR).

### Storage representation

Each `Schema::EnumMember` carries:

```crystal
record EnumMember,
  name : String,        # source-level Crystal identifier (canonical key)
  value : Int64,        # underlying integer
  wire_name : String    # what hits storage; defaults to `name`
```

- **Write path** — `Records.coerce_for_write` for `enum_string` calls
  `NameConversion.apply(value.to_s, naming)` to produce the stored string.
- **Read path** — the macro-emitted `___assign_from_rs` keeps
  `EnumClass.parse(s)` as the fast path for `:as_declared`. For non-
  default namings, it uses `EnumClass.values.find { |m| apply(m.to_s,
  naming) == s }` and raises a clear `Prostore::Error` if the stored
  string matches no declared member.
- **CHECK constraint** — both SQLite and PostgreSQL emit
  `CHECK (col IN ('wire1', 'wire2', …))` using `wire_name`.
- **Bookkeeping JSON** — the `enum_members` array compactly encodes each
  member as `[name, value]` (when `wire_name == name`) or `[name, value,
  wire_name]` (when they differ). Reader handles both forms, so
  bookkeeping rows written by v0.3.x deserialise correctly.
- **Fingerprint** — includes `wire_name` so a `naming:` change registers
  as drift and fails the version-skew check.

### Evolution discipline

Changing the `naming:` algorithm on an existing enum column is a
**rewriting** change: the bytes already on disk encode the old wire form.
The validator detects this — a member whose `wire_name` differs between
the stored bookkeeping row and the desired schema raises:

```
Field tag N on TABLE: enum member NAME wire_name changed (OLD → NEW).
Forbidden in-place — existing rows still carry the old wire value and
would fail the CHECK constraint or be silently unreadable (ADR-0017).
Write an explicit data migration first (UPDATE the column to the new
wire values), then change the `naming:` declaration.
```

Users who need to flip `naming:` must:

1. Write a data migration (raw SQL or a one-off rake-style task) that
   `UPDATE TABLE SET col = new_value WHERE col = old_value` for every
   member.
2. **Then** change the field declaration to the new `naming:`.
3. Run the prostore migration, which rebuilds the CHECK constraint with
   the new wire values.

This mirrors the discipline ADR-0016 established for adding/removing
members: any change that touches existing rows is the user's
responsibility to author explicitly, because prostore cannot infer the
right semantics from a declarative diff alone.

### TUI

The TUI picker shows the wire form (`bounce_hard`) for `enum_string`
columns so what the user picks matches what's stored. For `enum_int` and
`@[Flags]` columns the wire form is an integer; the picker falls back
to the source-level member name there. The non-editing display always
shows the raw stored value (already the wire form for `enum_string`).

## Alternatives considered

### Per-member `@[Prostore::EnumMember(wire: "…")]` annotation

The plan included this as an escape hatch for irregular cases (numbers,
punctuation, codes that don't fit any name-conversion rule). Deferred
to a follow-up because (a) it requires macro-level annotation reading
on enum members, which complicates the macro substantially; (b) the
four built-in algorithms cover the documented use case (snake_case
external APIs). When a downstream user actually needs the override, the
annotation can be added without breaking existing declarations.

### Per-field literal map (`mapping: {Active => "active"}`)

Verbose at the call site (`field 7, :status, Reason, mapping: {Reason::Active => "active", Reason::Pending => "pending", ...}`)
and forces the user to enumerate every member. Algorithmic conversion
covers the common case in one symbol.

### PG-native `CREATE TYPE … AS ENUM`

Out of scope: a different decision axis (storage backing, not wire
format). Would change the column type, not the string conversion.
Future ADR; orthogonal to this one.

## Consequences

- **Additive**: existing models without `naming:` keep their PascalCase
  storage. No migration required.
- The fingerprint changes shape (now includes `wire_name`), so models
  using enums will compute a different hash on first run after upgrade.
  The version-skew check accommodates this — it compares fingerprints
  computed by the same prostore version, not across versions.
- Downstream apps can incrementally migrate plain `String` status
  columns to `Status, naming: :snake_case` without breaking the wire
  format their external consumers depend on.
