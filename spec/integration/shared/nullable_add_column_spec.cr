require "./spec_helper"

# Adding a nullable column to a populated existing table — no explicit
# default: or backfill: required (an implicit NULL covers both). Existing
# rows surface NULL on read; new inserts without an explicit value also
# default to NULL.

private class NullableAddBefore < Prostore::Model
  table_name "nullable_add"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :label, String
end

private class NullableAddAfter < Prostore::Model
  table_name "nullable_add"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :label, String
  field 3, :note, String? # no default:, no backfill:
end

BACKENDS.each do |backend|
  describe "#{backend.name}: nullable AddColumn implicit NULL" do
    it "adds a nullable column without explicit default/backfill; existing rows surface NULL" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [NullableAddBefore] of Prostore::Model.class)

        backend.exec(conn, "INSERT INTO nullable_add (label) VALUES (?)", "row-1")
        backend.exec(conn, "INSERT INTO nullable_add (label) VALUES (?)", "row-2")

        Prostore::Migration::Runner.migrate(conn, [NullableAddAfter] of Prostore::Model.class)

        live = conn.adapter.introspect_table("nullable_add")
        live.columns.map(&.name).should contain("note")
        live.columns.find { |col| col.name == "note" }.try(&.nullable).should be_true

        # Existing rows are NULL.
        null_count = backend.query_one(conn,
          "SELECT COUNT(*) FROM nullable_add WHERE note IS NULL", as: Int64)
        null_count.should eq(2)

        # New insert without a value also lands NULL.
        backend.exec(conn, "INSERT INTO nullable_add (label) VALUES (?)", "row-3")
        backend.query_one(conn,
          "SELECT COUNT(*) FROM nullable_add WHERE note IS NULL", as: Int64).should eq(3)
      end
    end
  end
end
