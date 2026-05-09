require "./spec_helper"

private class AiThing < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
end

describe "auto_increment on Int64 PK (ADR-0013)" do
  it "produces INTEGER PRIMARY KEY AUTOINCREMENT in the live DDL" do
    with_sqlite_connection do |conn|
      Prostore::Migration::Runner.migrate(conn, [AiThing] of Prostore::Model.class)

      sql = conn.db.query_one(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
        "ai_thing", as: String
      )
      sql.upcase.should contain("AUTOINCREMENT")
    end
  end

  it "auto-assigns IDs on insert without an explicit value" do
    with_sqlite_connection do |conn|
      Prostore::Migration::Runner.migrate(conn, [AiThing] of Prostore::Model.class)

      conn.db.exec "INSERT INTO ai_thing (name) VALUES (?)", "first"
      conn.db.exec "INSERT INTO ai_thing (name) VALUES (?)", "second"

      ids = [] of Int64
      conn.db.query_each("SELECT id FROM ai_thing ORDER BY id") { |rs| ids << rs.read(Int64) }
      ids.should eq([1_i64, 2_i64])
    end
  end

  it "honors explicit ID inserts (BY DEFAULT semantics, ADR-0013)" do
    with_sqlite_connection do |conn|
      Prostore::Migration::Runner.migrate(conn, [AiThing] of Prostore::Model.class)

      conn.db.exec "INSERT INTO ai_thing (id, name) VALUES (?, ?)", 1000, "explicit"
      ids = [] of Int64
      conn.db.query_each("SELECT id FROM ai_thing") { |rs| ids << rs.read(Int64) }
      ids.should eq([1000_i64])
    end
  end
end
