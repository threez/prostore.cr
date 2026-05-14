# prostore TUI

A terminal UI database browser for SQLite and PostgreSQL databases.
Discovers schema at runtime — no compiled models required.

## Usage

```sh
# Build
crystal build bin/prostui -o bin/prostui_built

# Run (SQLite)
DATABASE_URL=sqlite3:///path/to/db.sqlite3 bin/prostui_built

# Run (Postgres)
DATABASE_URL=postgresql://user:pass@host/dbname bin/prostui_built
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
| `n` | New row |
| `d` | Delete focused row |
| `Esc` | Back to table list |

### Record detail / edit overlay

| Key | Action |
|---|---|
| `↑` / `↓` | Move between fields |
| `e` | Edit focused field |
| `f` | Follow FK to referenced record (shown only on FK fields) |
| `s` | Save all in-memory changes to the database |
| `d` | Delete record |
| `Esc` | Back to grid |

#### While editing a field

| Key | Action |
|---|---|
| `←` / `→` | Move cursor within line (wraps to adjacent line) |
| `↑` / `↓` | Move cursor between lines; at boundary commits edit and moves field |
| `Enter` | Insert newline |
| `Backspace` | Delete char before cursor; at line start merges with previous line |
| `Delete` | Delete char at cursor; at line end merges with next line |
| `Home` / `End` | Jump to start / end of current line |
| `Esc` | Commit edit buffer to in-memory row (does not persist — press `s` to save) |

## Architecture

```
bin/prostui
  └── App                  event loop + navigation stack
        ├── Browser              database access layer
        ├── Screen               buffered ANSI renderer
        ├── TableList (Widget)   left sidebar
        ├── RecordGrid (Widget)  paginated row grid
        └── RecordDetail (Widget) full-screen record + editor
```

### Navigation stack

`App` holds a typed stack `Array(NavEntry)`:

```
NavTableList | NavRecordGrid | NavRecordDetail | NavNewRecord
```

`Enter` always pushes a new entry; `Esc` always pops. Following a foreign key pushes a new `NavRecordDetail` without closing the current one, so `Esc` traces back through the full FK chain. Inserts and deletes call `on_close`, which pops and reloads the grid.

### Files

| File | Class / Module | Responsibility |
|---|---|---|
| `app.cr` | `App` | Event loop, navigation stack, layout, widget orchestration |
| `browser.cr` | `Browser` | All database I/O: schema, rows, CRUD, portable type lookup |
| `term.cr` | `Term` | ANSI sequences, raw mode, terminal size, color helpers |
| `screen.cr` | `Screen` | Buffered output, cursor positioning, box drawing |
| `keys.cr` | `Keys`, `Key`, `KeyEvent` | Raw byte → key-event parsing, escape sequence decoding |
| `widget.cr` | `Widget` | Abstract base: position, focus, `render`/`handle_key` contract |
| `widgets/table_list.cr` | `TableList` | Left pane: scrollable table list, `on_select` callback |
| `widgets/record_grid.cr` | `RecordGrid` | Right pane: paginated rows, column scroll, `on_open_detail` / `on_new_row` callbacks |
| `widgets/record_detail.cr` | `RecordDetail` | Full-screen overlay: multi-line field editor, FK navigation, `on_close` / `on_follow_fk` callbacks |

### Browser

`Browser` wraps `Prostore::Connection` and exposes a clean interface for the widgets.
All row values are returned as `String?` — values are stringified on read, which
sidesteps the `DB::Any` union divergence between the SQLite and Postgres drivers.

```crystal
alias RowVal = String?
alias Row    = Array(RowVal)
```

Key methods:

```crystal
browser.tables                            # => Array(String)
browser.schema("users")                   # => Adapter::LiveTable
browser.count("users")                    # => Int64
browser.fetch_rows("users", 50, 0)        # => {col_names, rows}
browser.pk_col("users")                   # => "id"
browser.portable_types("users")           # => {"id" => "int64", "active" => "bool", ...}

browser.insert_row("users", {"name" => "Alice"})
browser.update_cell("users", "id", "1", "name", "Bob")
browser.delete_row("users", "id", "1")
```

`portable_types` reads from the `prostore_schema` bookkeeping table (written by
prostore migrations). It returns an empty hash for databases not managed by prostore;
callers fall back to SQL `type_text` inference in that case.

### Type colorization

Values are colored by data type using bright ANSI codes (readable on dark terminals):

| Portable type | SQL type match (fallback) | Color |
|---|---|---|
| `int32`, `int64`, `uuid` | `INT`, `SERIAL` | bright cyan |
| `float32`, `float64`, `decimal`, `json` | `REAL`, `FLOAT`, `NUMERIC` | bright yellow |
| `bool` | `BOOL` | bright green |
| `time` | `DATE`, `TIME`, `STAMP` | bright blue |
| `bytes` | `BLOB`, `BINARY` | bright magenta |
| `string`, `array_*` | `TEXT`, `VARCHAR` | no color |
| `NULL` | — | dim |

Portable types (from `prostore_schema`) take precedence over SQL type inference.
This matters for SQLite, where `bool` is stored as `INTEGER` — using the portable
type keeps it green rather than cyan.

`Term.value_color(portable_type?, type_text, s)` is the unified entry point used by
both `RecordGrid` and `RecordDetail`.

### Multi-line field editing

`RecordDetail` renders each field's value split by `\n`, with continuation lines
indented to align with the first line. A `@field_scroll` counter (in display rows,
not field indices) keeps the cursor field visible when the total field content
exceeds the available height.

Edit state:

```
@edit_lines : Array(String)   # lines of the field being edited
@edit_row   : Int32           # cursor line within @edit_lines
@edit_col   : Int32           # cursor column within current line
```

`Esc` commits the buffer to `@row` (in-memory only); `s` persists to the database.
Primary key fields cannot be edited on existing records.

### Adding a new widget

1. Create `src/prostore/tui/widgets/my_widget.cr` extending `Widget`.
2. Implement `render(screen : Screen) : Nil` and `handle_key(ev : KeyEvent) : Bool`.
3. Add a nav entry type to `app.cr` if the widget represents a new navigation level.
4. Push / pop the entry in `App#handle_key` and render it in `App#render`.
