require "../../spec_helper"
require "../../../src/prostore/tui/browser"
require "../../../src/prostore/tui/widgets/record_detail"

# RecordDetail had zero prior coverage — everything here is new safety net
# for the widget's editing/dirty/validation logic, not a regression suite
# for pre-existing behavior. A plain in-memory SQLite connection is enough
# since none of this is backend-specific (unlike spec/integration/shared,
# which cross-checks SQLite vs Postgres SQL rendering).

enum RDStatus
  Active
  Archived
end

enum RDTier
  Bronze
  Silver =  5
  Gold   = 10
end

# Deliberately non-contiguous / gapped values — none of these equal
# `1 << index` for their position in the enum, so a regression to a
# by-array-index bitmask composition (rather than by actual declared
# member value) would be caught here. TBEPerms in
# tui_browser_enum_spec.cr (Read=1, Write=2, Execute=4) would NOT catch
# this, since those values happen to equal 1<<index for every member.
@[Flags]
enum RDPerms
  Read  =  1
  Admin =  8
  Owner = 32
end

private class RDRecord < Prostore::Model
  table_name "rd_record"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
  field 3, :active, Bool
  field 4, :status, RDStatus       # enum_string
  field 5, :tier, RDTier, as: :int # enum_int
  field 6, :perms, RDPerms         # enum_int + flags
  field 7, :age, Int32?
end

private def build_detail(conn : Prostore::Connection, pk_val : String) : Prostore::TUI::RecordDetail
  browser = Prostore::TUI::Browser.new(conn)
  Prostore::TUI::RecordDetail.new(1, 1, 80, 24, browser, "rd_record", "id", pk_val)
end

private def seed_row(conn : Prostore::Connection) : Int64
  # perms=0 (no flags pre-selected) so a Space toggle in the flags picker
  # is always additive — starting from an already-set member would mean
  # the "same" toggle actually clears it.
  conn.exec(
    "INSERT INTO rd_record (name, active, status, tier, perms, age) VALUES (?, ?, ?, ?, ?, ?)",
    args: ["Alice", "false", "Active", 0_i64, 0_i64, 30_i64] of ::DB::Any
  )
  conn.scalar("SELECT id FROM rd_record WHERE name = 'Alice'").as(Int64)
end

describe Prostore::TUI::RecordDetail do
  describe "bool field editing (BoolField-backed)" do
    it "commits a toggled value via Enter" do
      conn = Prostore::Connection.open("sqlite3::memory:")
      Prostore::Migration::Runner.migrate(conn, [RDRecord] of Prostore::Model.class)
      id = seed_row(conn)
      detail = build_detail(conn, id.to_s)

      2.times { detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down)) } # id -> name -> active
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, 'e'))
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, ' ')) # toggle to true
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Enter))     # commit

      detail.row["active"].should eq("true")
      detail.dirty.includes?("active").should be_true
    ensure
      conn.try &.close
    end

    it "also commits (not cancels) via Esc, matching BoolField's semantics" do
      conn = Prostore::Connection.open("sqlite3::memory:")
      Prostore::Migration::Runner.migrate(conn, [RDRecord] of Prostore::Model.class)
      id = seed_row(conn)
      detail = build_detail(conn, id.to_s)

      2.times { detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down)) }
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, 'e'))
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Left)) # toggle to true
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Esc))  # commit, not cancel

      detail.row["active"].should eq("true")
    ensure
      conn.try &.close
    end
  end

  describe "enum field editing" do
    it "writes the wire_name for an enum_string column" do
      conn = Prostore::Connection.open("sqlite3::memory:")
      Prostore::Migration::Runner.migrate(conn, [RDRecord] of Prostore::Model.class)
      id = seed_row(conn)
      detail = build_detail(conn, id.to_s)

      3.times { detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down)) } # -> status
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, 'e'))
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down)) # Active -> Archived
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Enter))

      detail.row["status"].should eq("Archived")
    ensure
      conn.try &.close
    end

    it "writes the underlying integer for an enum_int column" do
      conn = Prostore::Connection.open("sqlite3::memory:")
      Prostore::Migration::Runner.migrate(conn, [RDRecord] of Prostore::Model.class)
      id = seed_row(conn)
      detail = build_detail(conn, id.to_s)

      4.times { detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down)) } # -> tier
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, 'e'))
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down)) # Bronze(0) -> Silver(5)
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Enter))

      detail.row["tier"].should eq("5")
    ensure
      conn.try &.close
    end

    it "cancels without writing back on Esc" do
      conn = Prostore::Connection.open("sqlite3::memory:")
      Prostore::Migration::Runner.migrate(conn, [RDRecord] of Prostore::Model.class)
      id = seed_row(conn)
      detail = build_detail(conn, id.to_s)

      3.times { detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down)) } # -> status
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, 'e'))
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down))
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Esc)) # cancel

      detail.row["status"].should eq("Active") # unchanged from the seed
      detail.dirty.includes?("status").should be_false
    ensure
      conn.try &.close
    end
  end

  describe "@[Flags] field editing" do
    it "composes the bitmask from the members' ACTUAL declared values, not their array index" do
      conn = Prostore::Connection.open("sqlite3::memory:")
      Prostore::Migration::Runner.migrate(conn, [RDRecord] of Prostore::Model.class)
      id = seed_row(conn)
      detail = build_detail(conn, id.to_s)

      5.times { detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down)) } # -> perms
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, 'e'))

      # Members render in declaration order: Read(1), Admin(8), Owner(32).
      # Toggle Read (focus starts on it) and Admin on, leave Owner off.
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, ' ')) # select Read
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down))      # focus -> Admin
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, ' ')) # select Admin
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Enter))     # commit

      # Correct (by-value): Read | Admin = 1 | 8 = 9.
      # A regression to a `1 << array_index` bitmask composition
      # would instead produce (1 << 0) | (1 << 1) = 1 | 2 = 3.
      detail.row["perms"].should eq("9")
    ensure
      conn.try &.close
    end

    it "cancels without writing back on Esc" do
      conn = Prostore::Connection.open("sqlite3::memory:")
      Prostore::Migration::Runner.migrate(conn, [RDRecord] of Prostore::Model.class)
      id = seed_row(conn)
      detail = build_detail(conn, id.to_s)

      5.times { detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down)) }
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, 'e'))
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, ' '))
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Esc))

      detail.row["perms"].should eq("0") # unchanged from the seed
    ensure
      conn.try &.close
    end
  end

  describe "dirty tracking" do
    it "marks a column dirty only after its edit is committed" do
      conn = Prostore::Connection.open("sqlite3::memory:")
      Prostore::Migration::Runner.migrate(conn, [RDRecord] of Prostore::Model.class)
      id = seed_row(conn)
      detail = build_detail(conn, id.to_s)

      detail.dirty.should be_empty

      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down)) # -> name
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, 'e'))
      detail.dirty.includes?("name").should be_false # not yet committed

      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, '!'))
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Esc)) # commit

      detail.dirty.includes?("name").should be_true
      detail.row["name"].should eq("Alice!")
    ensure
      conn.try &.close
    end
  end

  describe "multi-line text editing (TextEdit-backed)" do
    it "commits a multi-line value via Esc" do
      conn = Prostore::Connection.open("sqlite3::memory:")
      Prostore::Migration::Runner.migrate(conn, [RDRecord] of Prostore::Model.class)
      id = seed_row(conn)
      detail = build_detail(conn, id.to_s)

      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down)) # -> name
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, 'e'))
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Enter)) # newline
      "line2".each_char { |ch| detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, ch)) }
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Esc)) # commit

      detail.row["name"].should eq("Alice\nline2")
      detail.dirty.includes?("name").should be_true
    ensure
      conn.try &.close
    end

    it "starts editing with the cursor after the existing value, not before it" do
      conn = Prostore::Connection.open("sqlite3::memory:")
      Prostore::Migration::Runner.migrate(conn, [RDRecord] of Prostore::Model.class)
      id = seed_row(conn)
      detail = build_detail(conn, id.to_s)

      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down)) # -> name
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, 'e'))
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, '!'))
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Esc))

      detail.row["name"].should eq("Alice!")
    ensure
      conn.try &.close
    end

    it "Backspace deletes from the end of the existing value" do
      conn = Prostore::Connection.open("sqlite3::memory:")
      Prostore::Migration::Runner.migrate(conn, [RDRecord] of Prostore::Model.class)
      id = seed_row(conn)
      detail = build_detail(conn, id.to_s)

      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down)) # -> name
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, 'e'))
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Backspace))
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Esc))

      detail.row["name"].should eq("Alic")
    ensure
      conn.try &.close
    end
  end

  describe "inline validation errors" do
    it "flags an invalid integer and clears the error once corrected" do
      conn = Prostore::Connection.open("sqlite3::memory:")
      Prostore::Migration::Runner.migrate(conn, [RDRecord] of Prostore::Model.class)
      id = seed_row(conn)
      detail = build_detail(conn, id.to_s)

      6.times { detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down)) } # -> age
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, 'e'))
      # age was "30" — clear it and type a non-numeric value.
      "30".size.times { detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Backspace)) }
      "abc".each_char { |char| detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, char)) }
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Esc)) # commit (invalid)

      detail.field_errors["age"]?.should_not be_nil

      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, 'e'))
      "abc".size.times { detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Backspace)) }
      "42".each_char { |char| detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, char)) }
      detail.handle_key(::TUI::KeyEvent.new(::TUI::Key::Esc)) # commit (valid)

      detail.field_errors.has_key?("age").should be_false
      detail.row["age"].should eq("42")
    ensure
      conn.try &.close
    end
  end
end
