# prostore TUI

A terminal UI database browser for SQLite and PostgreSQL databases.
Discovers schema at runtime — no compiled models required.

Invoked as the `browse` subcommand of the main `prostore` binary
(CLI source at `src/prostore_cli.cr`; built to `bin/prostore` via `shards build`).

Built on the [`tui.cr`](../../../../tui.cr) shard (sibling `path:` dependency)
for terminal rendering, input, and navigation — `prostore` supplies only the
database-aware widgets and domain logic layered on top of it.

## Usage

```sh
# Build the unified prostore CLI (includes the TUI)
shards build prostore                       # → bin/prostore

# Run (SQLite)
DATABASE_URL=sqlite3:///path/to/db.sqlite3 bin/prostore browse

# Run (Postgres)
DATABASE_URL=postgresql://user:pass@host/dbname bin/prostore browse
```

## Keyboard reference

### Table list (left pane) / Record grid (right pane)

Both panes live inside one shared `TUI::SplitWindow`, which owns `Tab` for
switching focus between them and renders both panes inside a single bordered
box with the divider merged in.

| Key | Action |
|---|---|
| `Tab` | Switch focus between the table list and the record grid — or, while the table list is hidden, unhide it (see below) |
| `h` | Toggle the table-list pane's visibility (disabled while a record detail or FK picker is open) — collapses it to width 0, giving the grid the full screen |
| `q` | Quit (disabled while a record detail or FK picker is open) |
| `Ctrl-C` / `Ctrl-D` | Hard quit (handled by `TUI::Runtime`, unconditionally) |

Hiding the table list while it's focused moves focus to the grid first (a
0-width pane can't usefully hold it); the previous width is remembered and
restored on `h` or `Tab`. Both restore focus to the table list — `Tab`
doubles as "unhide" specifically because a bare Tab press with the
sidebar gone would otherwise silently do nothing (there's no visible pane
to switch onto). The status bar's own hint reflects which of "hide"/
"show" `h` (and, while hidden, `Tab`) would currently do, and
`SplitWindow`'s own "Tab:switch pane" hint disappears while hidden since
`App` intercepts Tab before `SplitWindow` ever sees it in that state.

#### Table list

Backed by `tui.cr`'s `TUI::ListView` (`TableList` supplies a
`TableListSource` — an in-memory `ListDataSource` over `Browser#tables`).

| Key | Action |
|---|---|
| `↑` / `↓` | Move the highlighted table (does not load it) |
| `Enter` / double-click | Load the highlighted table into the grid |
| `/` | Filter the table list live by substring |
| `s` | Cycle sort key (only one key — `:name` — so this is a no-op today) |

Loading now requires `Enter`/double-click rather than firing on every
cursor move — a deliberate behavior change from the pre-`ListView` version,
which auto-loaded/previewed each table as the cursor passed over it.

#### Record grid

| Key | Action |
|---|---|
| `↑` / `↓` | Move between rows |
| `←` / `→` | Scroll columns (min 8 chars each) |
| `PgUp` / `PgDn` | Previous / next page (50 rows/page) |
| `Enter` | Open record detail |
| `/` | Open search prompt (filters rows live by `LIKE '%term%'` on string columns) |
| `n` | New row |
| `d` | Delete focused row |

#### While the search prompt is open

| Key | Action |
|---|---|
| any char | Append to filter term; reload page 0 immediately |
| `Backspace` | Drop last char of filter |
| `Enter` / `Esc` | Close the prompt, keep the filter active (clear it by reopening `/` and Backspacing to empty) |

The filter compiles to `col1 LIKE '%term%' OR col2 LIKE '%term%' …` across
every text column of the table (portable type `string`, or SQL types
containing `TEXT` / `CHAR` / `CLOB` when the schema isn't prostore-managed).
PostgreSQL uses `ILIKE` for case-insensitive matching; SQLite's `LIKE` is
already case-insensitive for ASCII. If the table has no text columns, `/`
is a silent no-op. This is a DB-backed search (a fresh query per keystroke),
distinct from `tui.cr`'s own in-memory `ListView` filter (used by
`TableList`, see above) — `RecordGrid` implements its own rather than
adopting `TUI::TableView`/`ListView`, since `TableView`'s data-source
contract assumes the whole (filterable, sortable) row set is already
materialized in memory. `RecordGrid` deliberately keeps rows server-side
paginated (`PAGE_SIZE = 50` fetched via `LIMIT`/`OFFSET`, with a
`COUNT(*)`-derived total) so browsing a table doesn't require loading it
in full — a real requirement `TableView` has no way to express, not a gap
left over from an incomplete migration.

### Record detail / new record

Pushed full-screen onto the nav stack (via `TUI::Runtime#push`) when `Enter`
is pressed in the grid, or `n` for a new record. Navigation mode — the
cursor is on a field row, no editor is open.

| Key | Action |
|---|---|
| `↑` / `↓` | Move between fields |
| `e` | Open the editor for the focused field (FK picker, text editor, single-line number field, bool toggle, enum picker, or flags checkbox — selected by field type) |
| `r` | Clear the focused field to NULL (shown only on nullable, non-PK fields) |
| `f` | Follow FK to referenced record (FK fields only) |
| `Tab` | Same as `e` on a single-column FK field: browse the referenced table to pick a value |
| `s` | Save / insert all in-memory changes |
| `d` | Delete the record (existing records only) |
| `Esc` | Back to the grid/table-list split |

The cursor field is shown with a reversed background and prefixed `▸`.
Modified (unsaved) field names are **bold** so pending changes are visible
even when the cursor is elsewhere. Fields with a validation error are
prefixed with a red `!`.

#### Text editor — when `e` opens a string-ish field

Backed by `tui.cr`'s `TUI::TextEdit`, wrapped in `TUI::ScrollableField` —
see "Why not a `tui.cr` form field for everything" below for which field
kinds are and aren't library-backed.

| Key | Action |
|---|---|
| `←` / `→` | Move cursor within line (wraps to adjacent line) |
| `↑` / `↓` | Move cursor between lines (stays within the buffer — does not commit or change field; see below) |
| `Alt+←` / `Alt+→` | Move by word |
| `Ctrl-A` / `Ctrl-E` | Jump to start / end of current line |
| `Enter` | Insert newline |
| `Backspace` / `Delete` | Delete char before / at cursor; merges with adjacent line at a line boundary |
| `Esc` | Commit the edit buffer to the in-memory row (does not persist — press `s`) |

The cursor starts at the end of the field's existing value (matching where
typing/backspace would continue), not the beginning. There is no
boundary-commit gesture — Up/Down never leave the text buffer or change
fields while editing (a deliberate simplification from the pre-`TextEdit`
version, which committed and moved to the adjacent field when Up/Down hit
the first/last line); press `Esc` to commit, then Up/Down to move fields.
The editor reserves up to 8 display rows and scrolls internally (via its
own scrollbar) for longer values, rather than growing to fit the full
wrapped value the way the old bespoke editor did.

Empty commit on a nullable column stores `nil` (SQL `NULL`), not `""`.
Time-typed fields are validated on commit; invalid input sets a field error
visible in the status bar and as the red `!` marker. The text editor is
only used for free-form string fields without a more specific editor —
FK, numeric, bool, enum, and flags fields all skip it.

#### Single-line number field — when `e` opens an `int32`/`int64`/`float32`/`float64`/`decimal` field

Backed by `tui.cr`'s `TUI::InputField` — a plain single-line editor, unlike
the multi-line `TextEdit` above, since a number never wraps or holds a
newline.

| Key | Action |
|---|---|
| `←` / `→` / `Home` / `End` | Move cursor within the field |
| `Backspace` / `Delete` | Delete char before / at cursor |
| `Enter` / `Esc` | Commit the edit buffer to the in-memory row (does not persist — press `s`) |

Same NULL-on-empty rule as the text editor. Validated on commit against the
column's numeric portable type; invalid input sets a field error visible in
the status bar and as the red `!` marker.

#### Bool toggle — when `e` opens a bool field

| Key | Action |
|---|---|
| `←` / `→` / `Space` | Toggle yes / no |
| `Enter` / `Esc` | Commit and close the toggle |
| `↑` / `↓` | Commit and move to the previous / next field |

The toggle only sets `true` / `false`. To set a nullable bool to NULL,
press `r` in nav mode instead. This is the one field kind backed directly
by `tui.cr`'s `TUI::BoolField.new` — its behavior (toggle,
commit-on-Esc-or-Enter) is an exact match with no value-encoding risk.

#### Enum picker — when `e` opens a plain (non-flags) enum field

Backed by `tui.cr`'s `TUI::EnumField`, driven by an `Array(FormEnumOption)`
built from the column's declared members (`wire_value` set to the ADR-0017
wire form — see "Commit semantics" below). Vertical radio list of every
declared member; `◉` / `○` mark the focused/selected option (focus and
selection are the same thing for this field kind, unlike Flags below — so
there's no separate `▸` focus pointer).

| Key | Action |
|---|---|
| `↑` / `↓` | Move the focused/selected option |
| `Enter` / `Space` | Commit and close the picker |
| `Esc` | Cancel without changing the field |

For `enum_string` columns, the selected member's name is stored verbatim
("Active"); for `enum_int` columns, the underlying integer is stored. The
non-editing display always shows the member name — `enum_int` values are
looked up by integer and rendered as the name so the row reads as
"Silver", not "5".

#### Flags picker — when `e` opens a `@[Flags]` enum field

Prostore's own bespoke checkbox picker — see "Why not a `tui.cr` form
field for everything" below for why `tui.cr`'s `FlagsField` isn't used
here. Vertical checkbox list; `▸` marks the focused option and `[x]` /
`[ ]` mark selected / unselected members. The composed value is the
bitwise OR of the checked members' underlying ints — **by the member's
actual declared value, not its position in the list** (a `@[Flags] enum
Perms; Read = 1; Admin = 8; end` composes `9` when both are checked, not
`3`).

| Key | Action |
|---|---|
| `↑` / `↓` | Move the focused option |
| `Space` | Toggle the focused option |
| `Enter` | Commit the composed value and close the picker |
| `Esc` | Cancel without changing the field |

Zero-valued members (e.g. an explicit `None = 0`) are intentionally
omitted from the initial-selection decoder — they would otherwise appear
checked for every mask and obscure the meaningful selection. Non-editing
display decomposes the stored mask as e.g. `Read | Write`.

#### FK picker — when `e` (or `Tab`) opens a single-column FK field

Picking a referenced row is a better way to set an FK than typing its raw
PK, so `e` routes straight here instead of opening the number/text editor
that the underlying column's own type would otherwise get — see
`RecordDetail#start_edit`.

| Key | Action |
|---|---|
| `↑` / `↓` | Move between rows of the referenced table |
| `←` / `→` | Scroll columns |
| `PgUp` / `PgDn` | Previous / next page |
| `Enter` | Write the highlighted row's PK back into the source field |
| `Esc` | Cancel — return to the detail without changing the source field |
| `/` | Search the referenced table (live LIKE filter); `n`/`d` are suppressed |

A fresh `RecordGrid` (wrapped in a `TUI::Window`) is pushed onto the nav
stack for each pick and wrapped in `TUI::Picker`, which filters `n`/`d` and
routes `Enter`/`Esc` to `on_pick`/`on_cancel` — the source `RecordDetail`
stays on the stack underneath, untouched, so unsaved edits on its other
fields survive the round-trip.

### Mouse support

Click-to-select and scroll-wheel are available throughout (via
`tui.cr`'s SGR mouse mode) — this is new behavior prostore never had before
migrating onto `tui.cr`; it wasn't a requested feature, just a side effect
of the shared framework's `Runtime` enabling mouse reporting unconditionally.

## Architecture

```
prostore browse  (src/prostore_cli.cr → Prostore::TUI::App.run)
  └── App                        event loop, KeyMenu, widget wiring
        ├── Browser                    database access layer
        ├── TableList (ListView)       left pane: table list, backed by TableListSource
        ├── RecordGrid (Scrollable)    right pane: paginated grid (reused as FK picker content)
        ├── RecordDetail (Widget)      full-screen record + editor
        └── PickerWindow (Window)      wraps a RecordGrid + Pickable for the FK-picker flow
```

`Screen`, `Term`, `Keys`/`KeyEvent`/`Key`, `Widget`, `Scrollable`,
`SplitWindow`, `Window`, `Runtime`, `NavStack`, `KeyMenu`, `Picker`,
`ListView`, `ListDataSource`, `BoolField`, `EnumField`, `TextEdit`,
`ScrollableField`, `TypeStyle`, and `Validation` all come from `tui.cr` —
none of that plumbing lives in this directory anymore. What's left here is
strictly prostore's own domain layer:

- `Browser` — database access layer (schema introspection, CRUD, filter SQL).
- `Style` — prostore-domain colours and ornaments with no `tui.cr`
  equivalent (FK reference colour, validation-error colour, soft-wrap
  continuation marker, bool badge); delegates to `TUI::TypeStyle` +
  `TUI::CellStyle` for the generic SQL-type colours it does cover, and
  falls back to its own palette for the prostore-only categories
  (`uuid`, `json`, native enums) that `TypeStyle` doesn't know about.
- `ColumnTypes` — pure type detection (`bool?`, `time?`, `enum?`, `int?`,
  `float?`, `decimal?`, `numeric?`, `searchable_text?`, `bool_truthy?`,
  `bool_display`) over portable type + SQL type_text. Broader than
  `TypeStyle`'s coverage and used well beyond coloring (search-column
  selection, edit-mode dispatch) — kept in full.

### App

`App` (`app.cr`) is the composition root: builds `Browser`, the two panes,
one `TUI::SplitWindow` wrapping them, a `TUI::Runtime`/`TUI::NavStack` pair,
and an app-level `TUI::KeyMenu` for the one global binding (`q`, gated off
while a detail/picker is active). There is no parallel navigation-state
struct — `TUI::NavStack(TUI::Widget)` is the single source of truth for
"what screen is active," and pushing a fresh `RecordDetail` (or a
`PickerWindow`) via `Runtime#push` is enough; popping restores whatever was
underneath with its state intact, which is exactly what following an FK
chain and walking back out via `Esc` needs.

`App#handle_key` is a thin dispatcher: an active FK `Picker` gets first
refusal (it owns Esc/Enter itself and filters everything else); otherwise
`Esc` routes through `Runtime#handle_esc` (delegate to the current widget
first, only pop if it didn't consume the key — e.g. a widget mid-edit
consumes Esc as "commit," not "back out"); otherwise the app-level
`KeyMenu` gets a shot before falling through to the current widget's own
`handle_key`.

The global status bar is `tui.cr`'s own doing — `Runtime` calls
`current_widget.status_hint` every frame and reverse-videos it onto the
bottom row. `SplitWindow#status_hint` already composes
`"Tab:switch pane" + active_pane.status_hint` for the table-list/grid
screen; `RecordDetail#status_hint` is context-aware (nav mode vs. each edit
kind) and is the single source of truth for what every reachable key does
in the current state — widgets must not draw their own hint lines.

### Browser

`Browser` wraps `Prostore::Connection` and exposes a clean interface for the widgets.
All row values are returned as `String?` — values are stringified on read, which
sidesteps the `DB::Any` union divergence between the SQLite and Postgres drivers.
`nil` is preserved end-to-end so SQL `NULL` round-trips through the UI unmodified.

```crystal
alias RowVal = String?
alias Row    = Array(RowVal)

record Filter, term : String, columns : Array(String)
```

Key methods:

```crystal
browser.tables                                    # => Array(String)
browser.schema("users")                           # => Adapter::LiveTable
browser.count("users")                            # => Int64
browser.count("users", filter)                    # => Int64 (filtered)
browser.fetch_rows("users", 50, 0)                # => {col_names, rows}
browser.fetch_rows("users", 50, 0, filter)        # => filtered page
browser.fetch_row("users", "id", "1")             # => Hash(String, RowVal)?
browser.pk_col("users")                           # => "id"
browser.portable_types("users")                   # => {"id" => "int64", ...}
browser.enum_columns("users")                     # => {"status" => EnumColumn{members: [...], is_flags: false}, ...}

browser.insert_row("users", {"name" => "Alice", "email" => nil})  # nil → NULL
browser.update_cell("users", "id", "1", "name", "Bob")
browser.update_cell("users", "id", "1", "email", nil)             # → NULL
browser.delete_row("users", "id", "1")

filter = Prostore::TUI::Filter.new("alice", ["name", "email"])
```

`insert_row` and `update_cell` accept `String?` so the UI can write explicit
NULLs. For inserts, omitting a key from the data hash leaves the database
default in place; passing `nil` writes explicit NULL.

`Filter` produces a `WHERE col1 LIKE ? OR col2 LIKE ? OR …` fragment with
the term wrapped as `%term%`. The operator comes from
`Adapter#like_operator` (`LIKE` on SQLite — case-insensitive for ASCII,
`ILIKE` on PostgreSQL).

`portable_types` reads from the `prostore_schema` bookkeeping table (written by
prostore migrations). It returns an empty hash for databases not managed by prostore;
callers fall back to SQL `type_text` inference in that case.

`enum_columns` reads the typed `enum_members` / `enum_is_flags` columns from
the same bookkeeping table (ADR-0016). Only columns whose portable type is
`enum_string` or `enum_int` appear in the result. Empty hash for unmanaged
databases — `RecordDetail` falls back to text editing for those columns.

### Colour palette

Data-type colours (foreground, applied to cell values):

| Portable type | SQL type match (fallback) | Colour | Source |
|---|---|---|---|
| `int32`, `int64` | `INT`, `SERIAL` | cyan | `TUI::TypeStyle` |
| `float32`, `float64`, `decimal` | `REAL`, `FLOAT`, `NUMERIC` | yellow | `TUI::TypeStyle` |
| `bool` (detail view fallback) | `BOOL` | green | `TUI::TypeStyle` |
| `time` | `DATE`, `TIME`, `STAMP` | blue | `TUI::TypeStyle` |
| `bytes` | `BLOB`, `BINARY` | magenta | `TUI::TypeStyle` |
| `uuid`, `json` | — (prostore-only) | bright cyan / bright yellow | `Style` (not covered by `TypeStyle`) |
| `enum_string`, `enum_int` | — (prostore-only) | bright magenta | `Style` (not covered by `TypeStyle`) |
| `string`, `array_*` | `TEXT`, `VARCHAR` | no colour | — |
| `NULL` | — | dim `(null)` | `TUI::Term.dim` |

Portable types (from `prostore_schema`) take precedence over SQL type
inference. This matters for SQLite, where `bool` is stored as `INTEGER` —
using the portable type keeps it green rather than cyan.

Domain colours (mix of foreground / background / ornament — all prostore's
own, no `tui.cr` equivalent):

| Element | Treatment |
|---|---|
| FK reference value (grid + detail) | regular cyan |
| FK header annotation `→table` | regular cyan |
| Validation error value / hint | bright red |
| Pending-error pointer | red `!` |
| Cursor pointer | `▸` |
| Soft-wrap continuation marker (read-only display) | dim magenta `\` (`Style.wrap_cont`) |
| Soft-wrap continuation marker (open text editor) | dim `→` (`TUI::TextEdit::WRAP_MARKER` — a different glyph from the display-mode marker; the editor's own marker isn't overridable per-instance) |
| Bool badge in the grid — true | green background + black text |
| Bool badge in the grid — false | red background + black text |
| Dirty (unsaved) field name | bold |
| Status bar | reversed video (`TUI::Screen#status_bar`) |
| Selected row | reversed video (ANSI stripped first for full-row highlight) |

`Style.value(portable_type?, type_text, s)` is the unified entry point used
by both `RecordGrid` and `RecordDetail` for type-based colouring —
internally it tries `TUI::TypeStyle.for(...)` + `TUI::CellStyle.apply(...)`
first, falling back to `Style`'s own palette only for the categories
`TypeStyle` doesn't cover. `Style.fk_ref`, `Style.error`, `Style.wrap_cont`,
and `Style.bool_badge` cover the domain elements that have no generic
equivalent at all.

### Field display, editing, and validation

`RecordDetail` renders one logical field per row. Multi-line values (split by
`\n`) become multiple rows; the first row carries the label, continuation
rows have an empty label column. A value wider than the available pane is
**soft-wrapped** at `val_w − 1` characters and each non-final wrap line
ends with a dim magenta `\` so the wrap is visually distinct from a real
newline. This describes the **read-only display** path
(`Style.wrap_cont`/`#display_lines`) — the open text editor wraps via its
own `TUI::TextEdit` layout and marker glyph instead (see the Text editor
section and the Colour palette's soft-wrap row above).

A `@field_scroll` counter (in display rows, not field indices) keeps the
cursor field visible when the total content exceeds the available height.

#### Editor state

```crystal
@text_editor   : TUI::ScrollableField(TUI::TextEdit)?  # non-nil while the text editor is open
@bool_editor   : TUI::BoolField?                        # non-nil while the bool toggle is open
@enum_editor   : TUI::EnumField?                        # non-nil while the plain-enum radio picker is open
@enum_focus    : Int32                                  # focused member index (flags picker only)
@flags_editing : Bool                                   # @[Flags] checkbox picker is open
@flags_pending : Set(Int32)                             # selected member indices for the checkbox picker
@dirty         : Set(String)                            # column names mutated since last reload (public getter)
@field_errors  : Hash(String, String)                   # column → validation error message (public getter)
```

At most one of `@text_editor`/`@bool_editor`/`@enum_editor`/
`@flags_editing` is active at a time — `#handle_key` dispatches on
whichever is non-nil/true, falling through to nav-mode key handling when
none are.

`dirty`, `field_errors`, and `row` are exposed as public `getter`s — useful
to an embedding app deciding whether to prompt before discarding an
in-progress edit, and to `spec/unit/tui/record_detail_spec.cr`, which is
the only spec coverage this widget has (added when it was migrated onto
`tui.cr` — it previously had none at all).

#### Why not a `tui.cr` form field for everything

Bool, Text, Number, and Enum are all `tui.cr`-backed (`TUI::BoolField`,
`TUI::ScrollableField(TUI::TextEdit)`, `TUI::InputField`, `TUI::EnumField`
respectively).
Flags is the one field kind that stays bespoke, and deliberately so:
`tui.cr`'s `TUI::FlagsField` (`lib/tui/src/tui/form/flags_field.cr`)
composes its wire value as `composed |= (1_i64 << i)`, where `i` is the
option's **position in the options array**, not the enum member's actual
declared value — confirmed by reading the source directly, not inferred.
Prostore's flags are routinely non-contiguous (e.g. `Read = 1; Admin = 8;
Owner = 32`), so adopting `FlagsField` here would silently write the wrong
bitmask for any such enum. `spec/unit/tui/record_detail_spec.cr`'s
"composes the bitmask from the members' ACTUAL declared values, not their
array index" test exists specifically to catch a regression to this
by-index scheme, so re-checking this decision in the future should start
by re-reading `flags_field.cr` for whether that composition has changed,
not by re-deriving the problem from scratch.

Flags therefore keeps its original bespoke state machine
(`@flags_editing`/`@flags_pending`/`@enum_focus` + `handle_flags_edit_key`/
`commit_flags_edit`/`flags_picker_lines`), reimplemented against `tui.cr`'s
`Buffer`/`KeyEvent` but otherwise unchanged in behavior.

`RecordGrid` (the table-browsing pane, not a `RecordDetail` field kind)
similarly stays off `tui.cr`'s `TableView`/`TableDataSource` — see the
"Record grid" search section above for why (server-side pagination is a
real requirement `TableDataSource`'s in-memory-array contract can't
express, not a migration gap).

#### Commit semantics

- Text editor `Esc` commits the buffer to `@row` in memory (`↑`/`↓` only
  move the cursor within the buffer, per `TUI::TextEdit`'s own semantics —
  see the Text editor section above). `s` persists `@row` to the database.
- Bool toggle `Esc` **or** `Enter` both commit (matching `TUI::BoolField`'s
  semantics) — there's no discard-in-place gesture for it.
- Enum/Flags pickers **cancel** on `Esc` instead — a picker with nothing
  chosen yet has no sensible "commit" value, unlike Bool/Text which always
  have a well-defined pending value to fall back to.
- Empty commit on a nullable column stores `nil` (SQL `NULL`), preserving
  the `(null)` display.
- `r` in nav mode is a one-keystroke shortcut for the same outcome on
  nullable, non-PK columns.
- Primary key columns cannot be edited on existing records.
- Time, integer, float, and decimal commits run their respective
  `TUI::Validation` helpers; failure populates `@field_errors[col]` and
  surfaces in the status bar and as a red `!`. Re-editing a field clears
  its existing error so the indicator reflects the latest commit only.
- Enum / flags pickers do not need validation — the picker is constrained
  to declared members. Committing always clears any prior error on that
  field.
- `commit_edit`, `commit_bool_edit`, `commit_enum_edit`, `commit_flags_edit`,
  `remove_value`, and the FK picker's `set_row_value` all mark `@dirty`,
  which renders the column name bold.
- `reload` (after `s` or when reopening the record) clears `@dirty` and
  `@field_errors`.

#### Foreign-key interactions

- `f` (follow) pushes a new `RecordDetail` (via `Runtime#push`) for the
  referenced record; `Esc` walks back through the FK trail since popping
  never destroys the covered widget.
- `Tab` (pick) pushes a `PickerWindow`-wrapped `RecordGrid` over the
  referenced table and wraps it in `TUI::Picker`; `Enter` writes the
  highlighted row's PK back into the source field (marking it dirty) via
  `on_pick`, `Esc` cancels via `on_cancel`. Either way the original detail
  widget stays on the nav stack underneath, untouched — no DB round-trip,
  no lost in-memory edits.

### Adding a new widget

1. Decide whether the widget needs its own position/border/`Buffer`
   (subclass `TUI::Widget`, like `RecordDetail`) or is meant to be hosted
   inside a `TUI::Window`/`TUI::SplitWindow` (a `Scrollable`, like
   `RecordGrid`, which implements it directly, or `TableList`, which gets
   it for free by subclassing `TUI::ListView` — either way, no x/y, no
   `Buffer` of your own; `Window` supplies the border/scrollbar/scroll
   position).
2. Implement the contract:
   - `Widget`: `render : Nil` (draw into `@buffer` using local coords),
     `handle_key(ev : TUI::KeyEvent) : Bool`, `status_hint : String`.
   - `Scrollable`: `content_size : Int32`, `render_content(buffer, scroll) :
     Nil`, `handle_key(ev, scroll) : Bool`, `handle_click(row, col, scroll)
     : Bool`, `title : String`, `status_hint : String`.
   - **Do not draw your own hint line inside the widget's box** — the App's
     global status bar is the single place hints are shown.
3. Wire it into `App` — build it in `#initialize`, push/pop via
   `@runtime.push`/`@runtime.pop` (not `@nav.push`/`@nav.pop` directly,
   so the widget gets resized to the current screen first), and route any
   callbacks (`on_activate`, `on_open_detail`, etc.) the same way
   `wire_table_list`/`wire_record_grid`/`wire_detail` do today.
