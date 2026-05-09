require "./spec_helper"

private class SDriftThing < Prostore::Model
  table_name "s_drift"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String

  index 1, [:email], unique: true
end

BACKENDS.each do |backend|
  describe "#{backend.name}: drift detection" do
    it "auto-fixes a managed column renamed externally" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SDriftThing] of Prostore::Model.class)

        # External rename — bypasses the library.
        conn.db.exec %(ALTER TABLE s_drift RENAME COLUMN "email" TO "email_lol")

        Prostore::Migration::Runner.migrate(conn, [SDriftThing] of Prostore::Model.class)

        cols = conn.adapter.introspect_table("s_drift").columns.map(&.name).sort!
        cols.should contain("email")
        cols.should_not contain("email_lol")
      end
    end

    it "auto-recreates a managed index that was externally dropped" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SDriftThing] of Prostore::Model.class)
        conn.db.exec "DROP INDEX s_drift_email_idx"

        Prostore::Migration::Runner.migrate(conn, [SDriftThing] of Prostore::Model.class)

        idx_names = conn.adapter.introspect_table("s_drift").indexes.map(&.name).sort!
        idx_names.should contain("s_drift_email_idx")
      end
    end

    it "tolerates unmanaged tables" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SDriftThing] of Prostore::Model.class)

        conn.db.exec "CREATE TABLE unmanaged_thing_drift (id INTEGER PRIMARY KEY, payload TEXT)"

        Prostore::Migration::Runner.migrate(conn, [SDriftThing] of Prostore::Model.class)

        tables = conn.adapter.introspect_table_names.sort
        tables.should contain("unmanaged_thing_drift")
        tables.should contain("s_drift")
      end
    end
  end
end
