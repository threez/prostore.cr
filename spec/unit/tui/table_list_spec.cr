require "../../spec_helper"
require "../../../src/prostore/tui/browser"
require "../../../src/prostore/tui/widgets/table_list"

private class TLOne < Prostore::Model
  table_name "tl_one"
  field 1, :id, Int64, primary: true, auto_increment: true
end

private class TLTwo < Prostore::Model
  table_name "tl_two"
  field 1, :id, Int64, primary: true, auto_increment: true
end

private def build_list(conn : Prostore::Connection) : Prostore::TUI::TableList
  Prostore::Migration::Runner.migrate(conn, [TLOne, TLTwo] of Prostore::Model.class)
  browser = Prostore::TUI::Browser.new(conn)
  list = Prostore::TUI::TableList.new(browser)
  list.reload
  list
end

private def no_scroll : ::TUI::ScrollControl
  ::TUI::ScrollControl.new(::TUI::Scroller.new, 10)
end

describe Prostore::TUI::TableListSource do
  it "filters table names by substring on reload" do
    conn = Prostore::Connection.open("sqlite3::memory:")
    Prostore::Migration::Runner.migrate(conn, [TLOne, TLTwo] of Prostore::Model.class)
    browser = Prostore::TUI::Browser.new(conn)
    source = Prostore::TUI::TableListSource.new(browser)

    source.reload("", :name)
    source.table_at.should contain("tl_one")
    source.table_at.should contain("tl_two")

    source.reload("tl_one", :name)
    source.table_at.should eq(["tl_one"])
  ensure
    conn.try &.close
  end
end

describe Prostore::TUI::TableList do
  it "moves the cursor on Up/Down without firing on_activate" do
    conn = Prostore::Connection.open("sqlite3::memory:")
    list = build_list(conn)
    activated = false
    list.on_activate = ->(_i : Int32) { activated = true; nil }

    list.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down), no_scroll)

    activated.should be_false
  ensure
    conn.try &.close
  end

  it "fires on_activate (and exposes selected_table) only on Enter" do
    conn = Prostore::Connection.open("sqlite3::memory:")
    list = build_list(conn)
    # Filter down to a single, deterministic match so the assertion below
    # doesn't depend on where the migration bookkeeping table happens to
    # sort relative to the app's own tables.
    list.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, '/'), no_scroll)
    "tl_one".each_char { |ch| list.handle_key(::TUI::KeyEvent.new(::TUI::Key::Char, ch), no_scroll) }

    activated_index = nil.as(Int32?)
    list.on_activate = ->(i : Int32) { activated_index = i; nil }
    list.handle_key(::TUI::KeyEvent.new(::TUI::Key::Enter), no_scroll)

    activated_index.should eq(0)
    list.selected_table.should eq("tl_one")
  ensure
    conn.try &.close
  end
end
