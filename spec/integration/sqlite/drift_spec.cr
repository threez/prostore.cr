require "./spec_helper"

# Drift detection (ADR-0010).

private class DriftThing < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String

  index 1, [:email], unique: true
end

describe "drift detection" do
  it "auto-fixes a managed column renamed externally" do
    with_sqlite_connection do |conn|
      Prostore::Migration::Runner.migrate(conn, [DriftThing] of Prostore::Model.class)

      # External rename — bypasses the library.
      conn.db.exec "ALTER TABLE drift_thing RENAME COLUMN email TO email_lol"

      # Re-running migrate should detect the drift and rename back.
      Prostore::Migration::Runner.migrate(conn, [DriftThing] of Prostore::Model.class)

      cols = conn.adapter.introspect_table("drift_thing").columns.map(&.name).sort!
      cols.should contain("email")
      cols.should_not contain("email_lol")
    end
  end

  it "auto-recreates a managed index that was externally dropped" do
    with_sqlite_connection do |conn|
      Prostore::Migration::Runner.migrate(conn, [DriftThing] of Prostore::Model.class)
      conn.db.exec "DROP INDEX drift_thing_email_idx"

      Prostore::Migration::Runner.migrate(conn, [DriftThing] of Prostore::Model.class)

      idx_names = conn.adapter.introspect_table("drift_thing").indexes.map(&.name).sort!
      idx_names.should contain("drift_thing_email_idx")
    end
  end

  it "errors when a managed column is dropped externally (data lost)" do
    with_sqlite_connection do |conn|
      Prostore::Migration::Runner.migrate(conn, [DriftThing] of Prostore::Model.class)
      conn.db.exec "INSERT INTO drift_thing (email) VALUES ('x@y.test')"

      # Drop the index first (SQLite won't drop an indexed column), then the
      # column. Simulates an operator who manually destroys managed state.
      conn.db.exec "DROP INDEX drift_thing_email_idx"
      conn.db.exec "ALTER TABLE drift_thing DROP COLUMN email"

      expect_raises(Prostore::DriftError, /missing from the live database/) do
        Prostore::Migration::Runner.migrate(conn, [DriftThing] of Prostore::Model.class)
      end
    end
  end

  it "tolerates unmanaged columns and tables" do
    with_sqlite_connection do |conn|
      Prostore::Migration::Runner.migrate(conn, [DriftThing] of Prostore::Model.class)

      # Add an unmanaged table — should be ignored.
      conn.db.exec "CREATE TABLE unmanaged_thing (id INTEGER PRIMARY KEY, payload TEXT)"

      # Re-running with the same model is still a no-op for managed state.
      Prostore::Migration::Runner.migrate(conn, [DriftThing] of Prostore::Model.class)

      tables = conn.adapter.introspect_table_names.sort
      tables.should contain("unmanaged_thing")
      tables.should contain("drift_thing")
    end
  end
end
