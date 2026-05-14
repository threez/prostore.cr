# prostore TUI

A terminal UI database browser for SQLite and PostgreSQL databases.
Discovers schema at runtime — no compiled models required.

Invoked as the `browse` subcommand of the main `prostore` binary
(CLI source at `src/prostore_cli.cr`; built to `bin/prostore` via `shards build`).

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

### Table list (left pane)

| Key | Action |
|---|---|
| `↑` / `↓` | Move between tables |
| `Enter` | Open table in grid |
| `q` | Quit |

### Record grid (right pane)

| Key | Action |
|---|---|
| `↑` / `↓` | Move between rows |
| `←` / `→` | Scroll columns (min 8 chars each) |
| `PgUp` / `PgDn` | Previous / next page (50 rows/page) |
| `Enter` | Open record detail |
| `/` | Open search prompt (filters rows live by `LIKE '%term%'` on string columns) |
| `n` | New row |
| `d` | Delete focused row |
| `Esc` | Back to table list |

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
is a silent no-op.

### Record detail / new record

Navigation mode — the cursor is on a field row, no editor is open.

| Key | Action |
|---|---|
| `↑` / `↓` | Move between fields |
| `e` | Open the editor for the focused field (text editor or bool toggle) |
| `r` | Clear the focused field to NULL (shown only on nullable, non-PK fields) |
| `f` | Follow FK to referenced record (FK fields only) |
| `Tab` | Browse the referenced table to pick a value (single-column FK fields only) |
| `s` | Save / insert all in-memory changes |
| `d` | Delete the record (existing records only) |
| `Esc` | Back to grid |

The cursor field is shown with a reversed background and prefixed `▸`.
Modified (unsaved) field names are **bold** so pending changes are visible
even when the cursor is elsewhere. Fields with a validation error are
prefixed with a red `!`.

#### Text editor — when `e` opens a string-ish field

| Key | Action |
|---|---|
| `←` / `→` | Move cursor within line (wraps to adjacent line) |
| `↑` / `↓` | Move cursor between lines; at boundary commits and moves field |
| `Enter` | Insert newline |
| `Backspace` | Delete char before cursor; at line start merges with previous line |
| `Delete` | Delete char at cursor; at line end merges with next line |
| `Home` / `End` | Jump to start / end of current line |
| `Tab` | Hand off to the FK picker (on FK fields) — discards the typed buffer |
| `Esc` | Commit the edit buffer to the in-memory row (does not persist — press `s`) |

Empty commit on a nullable column stores `nil` (SQL `NULL`), not `""`.
Time-typed fields are validated on commit; invalid input sets a field error
visible in the status bar and as the red `!` marker.

#### Bool toggle — when `e` opens a bool field

| Key | Action |
|---|---|
| `←` / `→` / `Space` | Toggle yes / no |
| `Enter` / `Esc` | Commit and close the toggle |
| `↑` / `↓` | Commit and move to the previous / next field |

The toggle only sets `true` / `false`. To set a nullable bool to NULL,
press `r` in nav mode instead.

#### FK picker — when `Tab` is pressed on a single-column FK field

| Key | Action |
|---|---|
| `↑` / `↓` | Move between rows of the referenced table |
| `←` / `→` | Scroll columns |
| `PgUp` / `PgDn` | Previous / next page |
| `Enter` | Write the highlighted row's PK back into the source field |
| `Esc` | Cancel — return to the detail without changing the source field |
| `/` | Search the referenced table (live LIKE filter) |

The picker pushes onto the navigation stack while keeping the source
detail widget alive, so unsaved edits on other fields survive the
round-trip.

## Architecture

```
prostore browse  (src/prostore_cli.cr → Prostore::TUI::App.run)
  └── App                  event loop, navigation stack, global status bar
        ├── Browser              database access layer
        ├── Screen               buffered ANSI renderer
        ├── TableList (Widget)   left sidebar
        ├── RecordGrid (Widget)  paginated row grid (reused as FK picker)
        └── RecordDetail (Widget) full-screen record + editor
```

Cross-cutting modules:

- `Style` — prostore-domain colours and ornaments (FK, error, wrap_cont, bool badge, type colours).
- `ColumnTypes` — pure type detection (`bool?`, `time?`, `searchable_text?`) over portable type + SQL type_text.
- `Validation` — input validators (time formats).
- `Term` — generic terminal infrastructure (raw mode, ANSI, fit/trunc/strip_ansi); no prostore knowledge.

### Navigation stack

`App` holds a typed stack `Array(NavEntry)`:

```
NavTableList | NavRecordGrid | NavRecordDetail | NavNewRecord | NavFKPicker
```

`Enter` always pushes a new entry; `Esc` pops (delegated to the widget first
so a widget in a sub-mode — search prompt, editor, bool toggle — can
consume it). Following a foreign key (`f`) pushes a new `NavRecordDetail`
without closing the current one, so `Esc` traces back through the full FK
chain. `Tab` on a FK field pushes a `NavFKPicker` that holds a reference to
the source `RecordDetail` so unsaved edits aren't lost — `pop_fk_picker`
restores the same widget instance rather than rebuilding it from the DB.
Inserts and deletes call `on_close`, which pops and reloads the grid.

The global status bar at the bottom of the screen is the single source of
key-binding documentation: every widget exposes a `status_hint : String`
method and the App renders the active widget's hint in reverse video.
Widgets must NOT draw their own hint lines.

### Files

| File | Class / Module | Responsibility |
|---|---|---|
| `app.cr` | `App` | Event loop, navigation stack, layout, widget orchestration |
| `browser.cr` | `Browser` | All database I/O: schema, rows, CRUD, portable type lookup |
| `term.cr` | `Term` | Terminal infrastructure: raw mode, ANSI, cursor, box chars, generic `fit`/`trunc`/`strip_ansi` |
| `style.cr` | `Style` | App-level theme: FK colour, error colour, soft-wrap marker, bool badge, type-aware value colouring |
| `column_types.cr` | `ColumnTypes` | Pure type detection: `bool?` / `time?` over portable type + SQL type_text; bool truthiness and display |
| `validation.cr` | `Validation` | Input validators (time formats, `valid_time?`) |
| `screen.cr` | `Screen` | Buffered output, cursor positioning, box drawing |
| `keys.cr` | `Keys`, `Key`, `KeyEvent` | Raw byte → key-event parsing, escape sequence decoding |
| `widget.cr` | `Widget` | Abstract base: position, focus, `render`/`handle_key` contract |
| `widgets/table_list.cr` | `TableList` | Left pane: scrollable table list, `on_select` callback |
| `widgets/record_grid.cr` | `RecordGrid` | Right pane: paginated rows, column scroll, `on_open_detail` / `on_new_row` callbacks |
| `widgets/record_detail.cr` | `RecordDetail` | Full-screen overlay: multi-line field editor, FK navigation, `on_close` / `on_follow_fk` / `on_pick_fk` callbacks |

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

### Colour palette

Data-type colours (foreground, applied to cell values):

| Portable type | SQL type match (fallback) | Colour |
|---|---|---|
| `int32`, `int64`, `uuid` | `INT`, `SERIAL` | bright cyan |
| `float32`, `float64`, `decimal`, `json` | `REAL`, `FLOAT`, `NUMERIC` | bright yellow |
| `bool` (detail view fallback) | `BOOL` | bright green |
| `time` | `DATE`, `TIME`, `STAMP` | bright blue |
| `bytes` | `BLOB`, `BINARY` | bright magenta |
| `string`, `array_*` | `TEXT`, `VARCHAR` | no colour |
| `NULL` | — | dim `(null)` |

Portable types (from `prostore_schema`) take precedence over SQL type
inference. This matters for SQLite, where `bool` is stored as `INTEGER` —
using the portable type keeps it green rather than cyan.

Domain colours (mix of foreground / background / ornament):

| Element | Treatment |
|---|---|
| FK reference value (grid + detail) | regular cyan |
| FK header annotation `→table` | regular cyan |
| Validation error value / hint | bright red |
| Pending-error pointer | red `!` |
| Cursor pointer | `▸` |
| Soft-wrap continuation marker | dim magenta `\` |
| Bool badge in the grid — true | green background + black text |
| Bool badge in the grid — false | red background + black text |
| Dirty (unsaved) field name | bold |
| Status bar | reversed video |
| Selected row | reversed video (ANSI stripped first for full-row highlight) |

`Style.value(portable_type?, type_text, s)` is the unified entry point used
by both `RecordGrid` and `RecordDetail` for type-based colouring;
`Style.fk_ref`, `Style.error`, `Style.wrap_cont`, and `Style.bool_badge`
cover the domain elements.

### Field display, editing, and validation

`RecordDetail` renders one logical field per row. Multi-line values (split by
`\n`) become multiple rows; the first row carries the label, continuation
rows have an empty label column. A value wider than the available pane is
**soft-wrapped** at `val_w − 1` characters and each non-final wrap line
ends with a dim magenta `\` so the wrap is visually distinct from a real
newline.

A `@field_scroll` counter (in display rows, not field indices) keeps the
cursor field visible when the total content exceeds the available height.

#### Editor state

```crystal
@edit_lines    : Array(String)         # lines of the field being edited
@edit_row      : Int32                 # cursor line within @edit_lines
@edit_col      : Int32                 # cursor column within current line
@bool_editing  : Bool                  # bool-toggle is open instead of the text editor
@bool_pending  : Bool                  # pending toggle value
@dirty         : Set(String)           # column names mutated since last reload
@field_errors  : Hash(String, String)  # column → validation error message
```

#### Commit semantics

- Text editor `Esc` (or `↑`/`↓` past the buffer edge) commits the buffer to
  `@row` in memory. `s` persists `@row` to the database.
- Empty commit on a nullable column stores `nil` (SQL `NULL`), preserving
  the `(null)` display.
- `r` in nav mode is a one-keystroke shortcut for the same outcome on
  nullable, non-PK columns.
- Primary key columns cannot be edited on existing records.
- Time-typed commits run `Validation.valid_time?`; a failure populates
  `@field_errors[col]` and surfaces in the status bar and as a red `!`.
  Re-editing a field clears its existing error so the indicator reflects
  the latest commit only.
- `commit_edit`, `commit_bool_edit`, `remove_value`, and the FK picker's
  `set_row_value` all mark `@dirty`, which renders the column name bold.
- `reload` (after `s` or when reopening the record) clears `@dirty` and
  `@field_errors`.

#### Foreign-key interactions

- `f` (follow) pushes a new `NavRecordDetail` for the referenced record;
  `Esc` walks back through the FK trail.
- `Tab` (pick) pushes `NavFKPicker` holding a reference to the source
  `RecordDetail`. The picker is a `RecordGrid` over the referenced table;
  `Enter` writes the highlighted row's PK back into the source field
  (marking it dirty), `Esc` cancels. Either way the original detail widget
  is restored intact — no DB round-trip, no lost in-memory edits.

### Adding a new widget

1. Create `src/prostore/tui/widgets/my_widget.cr` extending `Widget`.
2. Implement the three abstract methods:
   - `render(screen : Screen) : Nil`
   - `handle_key(ev : KeyEvent) : Bool` (return `true` if the key was consumed)
   - `status_hint : String` — context-aware key hint rendered by the App's
     global status bar. **Do not draw your own hint line inside the
     widget's box.**
3. Add a nav-entry record to `app.cr` and extend the `NavEntry` union if the
   widget represents a new navigation level.
4. Push / pop in `App#handle_key`, render in `App#render`. The
   `render_status_bar` dispatcher in `App` delegates to the focused widget's
   `status_hint`; only override the case for widgets used in multiple
   modes from the App's perspective (e.g. the FK picker, which is the same
   `RecordGrid` class playing a read-only role).
