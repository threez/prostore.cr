require "./spec_helper"

private class DropFieldBefore < Prostore::Model
  table_name "drop_field"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
  field 3, :legacy_phone, String?
end

private class DropFieldAfter < Prostore::Model
  table_name "drop_field"

  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
  reserved 3 # legacy_phone — to be dropped
end

describe "DropField via reserved" do
  it "drops a column whose tag is reserved in the new model" do
    with_sqlite_connection do |conn|
      Prostore::Migration::Runner.migrate(conn, [DropFieldBefore] of Prostore::Model.class)
      conn.db.exec "INSERT INTO drop_field (email, legacy_phone) VALUES (?, ?)", "a@x.test", "555"

      Prostore::Migration::Runner.migrate(conn, [DropFieldAfter] of Prostore::Model.class)

      cols = conn.adapter.introspect_table("drop_field").columns.map(&.name).sort!
      cols.should eq(["email", "id"])

      # Existing data preserved (only the column is gone).
      email = conn.db.query_one("SELECT email FROM drop_field", as: String)
      email.should eq("a@x.test")
    end
  end

  it "removes the prostore_schema row for the dropped column" do
    with_sqlite_connection do |conn|
      Prostore::Migration::Runner.migrate(conn, [DropFieldBefore] of Prostore::Model.class)
      Prostore::Migration::Runner.migrate(conn, [DropFieldAfter] of Prostore::Model.class)

      rows = Prostore::Drift::SchemaTable.for_table(conn.adapter, conn.db, "drop_field")
      column_tags = rows.select { |row| row.kind == "column" }.map(&.tag).sort!
      column_tags.should eq([1, 2])
    end
  end

  it "rejects dropping a column without an explicit reservation" do
    with_sqlite_connection do |conn|
      Prostore::Migration::Runner.migrate(conn, [DropFieldBefore] of Prostore::Model.class)

      expect_raises(Prostore::SchemaError, /neither declared nor reserved/) do
        Prostore::Migration::Runner.migrate(conn, [ModelMissingTag2] of Prostore::Model.class)
      end
    end
  end
end

private class ModelMissingTag2 < Prostore::Model
  table_name "drop_field"

  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
  # tag 3 not declared, not reserved — should raise during diff
end
