require "./spec_helper"

# Nullable (optional) FK columns — the FK constraint is enforced only on
# non-NULL values per SQL. Exercises:
#   - NULL inserts succeed
#   - non-NULL valid references succeed
#   - non-NULL invalid references are rejected
#   - on_delete: :set_null nulls the column when the parent is deleted
#   - adding a new table with a nullable FK to an existing table
#   - adding a nullable FK column to an existing table

# ---- scenario 1: new table with a nullable FK column ----------------------

private class FkNullParent < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
end

private class FkNullChild < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :parent_id, Int64?

  foreign_key 1, [:parent_id], references: FkNullParent, on_delete: :set_null
end

# ---- scenario 2: existing table gains a new nullable FK column + FK -------

private class FkNullAddParent < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
end

private class FkNullAddChildBefore < Prostore::Model
  table_name "fk_null_add_child"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :note, String
end

private class FkNullAddChildAfter < Prostore::Model
  table_name "fk_null_add_child"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :note, String
  field 3, :parent_id, Int64?

  foreign_key 1, [:parent_id], references: FkNullAddParent, on_delete: :set_null
end

# ---- scenario 3: add FK to an existing nullable column with NULL rows -----

private class FkNullExistingParent < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
end

private class FkNullExistingChildNoFk < Prostore::Model
  table_name "fk_null_existing_child"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :parent_id, Int64?
end

private class FkNullExistingChildWithFk < Prostore::Model
  table_name "fk_null_existing_child"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :parent_id, Int64?

  foreign_key 1, [:parent_id], references: FkNullExistingParent, on_delete: :set_null
end

BACKENDS.each do |backend|
  describe "#{backend.name}: nullable FK columns" do
    it "permits NULL inserts on an optional FK column" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [FkNullParent, FkNullChild] of Prostore::Model.class)

        backend.exec(conn, "INSERT INTO fk_null_child (parent_id) VALUES (?)", nil)

        count = backend.query_one(conn,
          "SELECT COUNT(*) FROM fk_null_child WHERE parent_id IS NULL",
          as: Int64)
        count.should eq(1)
      end
    end

    it "enforces the FK on non-NULL references" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [FkNullParent, FkNullChild] of Prostore::Model.class)

        backend.exec(conn, "INSERT INTO fk_null_parent (id, name) VALUES (?, ?)", 1_i64, "p1")
        backend.exec(conn, "INSERT INTO fk_null_child (parent_id) VALUES (?)", 1_i64)

        expect_raises(Exception, /[Ff][Oo][Rr][Ee][Ii][Gg][Nn] [Kk][Ee][Yy]/) do
          backend.exec(conn, "INSERT INTO fk_null_child (parent_id) VALUES (?)", 999_i64)
        end
      end
    end

    it "nulls the FK column when the parent is deleted (on_delete: :set_null)" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [FkNullParent, FkNullChild] of Prostore::Model.class)

        backend.exec(conn, "INSERT INTO fk_null_parent (id, name) VALUES (?, ?)", 1_i64, "p1")
        backend.exec(conn, "INSERT INTO fk_null_child (parent_id) VALUES (?)", 1_i64)

        backend.exec(conn, "DELETE FROM fk_null_parent WHERE id = ?", 1_i64)

        remaining = backend.query_one(conn,
          "SELECT COUNT(*) FROM fk_null_child WHERE parent_id IS NULL",
          as: Int64)
        remaining.should eq(1)
      end
    end

    it "adds a new nullable FK column to a populated existing table" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn,
          [FkNullAddParent, FkNullAddChildBefore] of Prostore::Model.class)

        backend.exec(conn, "INSERT INTO fk_null_add_child (note) VALUES (?)", "row-1")
        backend.exec(conn, "INSERT INTO fk_null_add_child (note) VALUES (?)", "row-2")

        Prostore::Migration::Runner.migrate(conn,
          [FkNullAddParent, FkNullAddChildAfter] of Prostore::Model.class)

        live = conn.adapter.introspect_table("fk_null_add_child")
        live.columns.map(&.name).should contain("parent_id")
        live.foreign_keys.size.should eq(1)
        live.foreign_keys.first.references_table.should eq("fk_null_add_parent")

        # Existing rows keep NULL parent_id (the new column is nullable).
        null_rows = backend.query_one(conn,
          "SELECT COUNT(*) FROM fk_null_add_child WHERE parent_id IS NULL",
          as: Int64)
        null_rows.should eq(2)

        # FK is enforced on non-NULL values for new rows.
        expect_raises(Exception, /[Ff][Oo][Rr][Ee][Ii][Gg][Nn] [Kk][Ee][Yy]/) do
          backend.exec(conn,
            "INSERT INTO fk_null_add_child (note, parent_id) VALUES (?, ?)", "row-3", 999_i64)
        end
      end
    end

    it "adds a FK to an existing nullable column with pre-existing NULL rows" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn,
          [FkNullExistingParent, FkNullExistingChildNoFk] of Prostore::Model.class)

        backend.exec(conn, "INSERT INTO fk_null_existing_parent (id, name) VALUES (?, ?)", 1_i64, "p1")
        backend.exec(conn, "INSERT INTO fk_null_existing_child (parent_id) VALUES (?)", nil)
        backend.exec(conn, "INSERT INTO fk_null_existing_child (parent_id) VALUES (?)", 1_i64)

        Prostore::Migration::Runner.migrate(conn,
          [FkNullExistingParent, FkNullExistingChildWithFk] of Prostore::Model.class)

        fks = conn.adapter.introspect_table("fk_null_existing_child").foreign_keys
        fks.size.should eq(1)
        fks.first.references_table.should eq("fk_null_existing_parent")

        # Pre-existing NULL row survives — FK does not require non-NULL.
        backend.query_one(conn,
          "SELECT COUNT(*) FROM fk_null_existing_child WHERE parent_id IS NULL",
          as: Int64).should eq(1)

        # Orphan inserts are now rejected.
        expect_raises(Exception, /[Ff][Oo][Rr][Ee][Ii][Gg][Nn] [Kk][Ee][Yy]/) do
          backend.exec(conn, "INSERT INTO fk_null_existing_child (parent_id) VALUES (?)", 999_i64)
        end
      end
    end
  end
end
