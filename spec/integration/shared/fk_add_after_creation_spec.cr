require "./spec_helper"

# Covers FK additions after a table's initial creation. The diff engine
# topologically orders new-table creates and emits a separate AddForeignKey
# step for FKs declared on already-managed tables (ADR-0012); both Postgres
# (ALTER TABLE ADD CONSTRAINT) and SQLite (table rebuild) paths apply.

# --- scenario 1: new table later, FK to existing table ----------------------

private class FkLaterA < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
end

private class FkLaterB < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :a_id, Int64

  foreign_key 1, [:a_id], references: FkLaterA, on_delete: :cascade
end

private class FkLaterC < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :a_id, Int64

  foreign_key 1, [:a_id], references: FkLaterA, on_delete: :cascade
end

# --- scenario 2: existing table gains a FK to a new table in same migration -

private class FkCrossA < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
end

private class FkCrossBNoFk < Prostore::Model
  table_name "fk_cross_b"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :child_id, Int64
end

private class FkCrossChild < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :label, String
end

private class FkCrossBWithFk < Prostore::Model
  table_name "fk_cross_b"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :child_id, Int64

  foreign_key 1, [:child_id], references: FkCrossChild, on_delete: :cascade
end

BACKENDS.each do |backend|
  describe "#{backend.name}: FK add-after-creation" do
    it "creates a new table with a FK to an existing table in a later migration" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [FkLaterA, FkLaterB] of Prostore::Model.class)

        backend.exec(conn, "INSERT INTO fk_later_a (id, name) VALUES (?, ?)", 1_i64, "a1")

        Prostore::Migration::Runner.migrate(conn,
          [FkLaterA, FkLaterB, FkLaterC] of Prostore::Model.class)

        tables = conn.adapter.introspect_table_names
        tables.should contain("fk_later_c")

        fks = conn.adapter.introspect_table("fk_later_c").foreign_keys
        fks.size.should eq(1)
        fks.first.references_table.should eq("fk_later_a")

        expect_raises(Exception, /[Ff][Oo][Rr][Ee][Ii][Gg][Nn] [Kk][Ee][Yy]/) do
          backend.exec(conn, "INSERT INTO fk_later_c (a_id) VALUES (?)", 999_i64)
        end
      end
    end

    it "adds a FK on an existing table that references a NEW table created in the same migration" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn,
          [FkCrossA, FkCrossBNoFk] of Prostore::Model.class)

        backend.exec(conn, "INSERT INTO fk_cross_a (id, name) VALUES (?, ?)", 1_i64, "a1")

        # One migration creates fk_cross_child AND adds the FK on fk_cross_b.
        Prostore::Migration::Runner.migrate(conn,
          [FkCrossA, FkCrossBWithFk, FkCrossChild] of Prostore::Model.class)

        tables = conn.adapter.introspect_table_names
        tables.should contain("fk_cross_child")

        fks = conn.adapter.introspect_table("fk_cross_b").foreign_keys
        fks.size.should eq(1)
        fks.first.references_table.should eq("fk_cross_child")

        # Orphan rows in fk_cross_b are rejected.
        expect_raises(Exception, /[Ff][Oo][Rr][Ee][Ii][Gg][Nn] [Kk][Ee][Yy]/) do
          backend.exec(conn, "INSERT INTO fk_cross_b (child_id) VALUES (?)", 999_i64)
        end
      end
    end
  end
end
