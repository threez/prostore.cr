require "./spec_helper"

private class SFkParent < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
end

private class SFkChildNoFk < Prostore::Model
  table_name "s_fk_child"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :parent_id, Int64
end

private class SFkChildWithFk < Prostore::Model
  table_name "s_fk_child"

  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :parent_id, Int64

  foreign_key 1, [:parent_id], references: SFkParent, on_delete: :cascade
end

private class SFkChildFkDropped < Prostore::Model
  table_name "s_fk_child"

  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :parent_id, Int64

  reserved_foreign_key 1
end

BACKENDS.each do |backend|
  describe "#{backend.name}: FK evolution" do
    it "adds a foreign key to an existing table" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SFkParent, SFkChildNoFk] of Prostore::Model.class)

        backend.exec(conn, "INSERT INTO s_fk_parent (id, name) VALUES (?, ?)", 1_i64, "p1")
        backend.exec(conn, "INSERT INTO s_fk_child (parent_id) VALUES (?)", 1_i64)

        Prostore::Migration::Runner.migrate(conn, [SFkParent, SFkChildWithFk] of Prostore::Model.class)

        fks = conn.adapter.introspect_table("s_fk_child").foreign_keys
        fks.size.should eq(1)
        fks.first.references_table.should eq("s_fk_parent")

        # FK enforced now: orphan insert fails.
        expect_raises(Exception, /[Ff][Oo][Rr][Ee][Ii][Gg][Nn] [Kk][Ee][Yy]/) do
          backend.exec(conn, "INSERT INTO s_fk_child (parent_id) VALUES (?)", 999_i64)
        end
      end
    end

    it "drops a foreign key when its tag is reserved" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SFkParent, SFkChildWithFk] of Prostore::Model.class)
        Prostore::Migration::Runner.migrate(conn, [SFkParent, SFkChildFkDropped] of Prostore::Model.class)

        fks = conn.adapter.introspect_table("s_fk_child").foreign_keys
        fks.size.should eq(0)

        # Orphan insert no longer blocked.
        backend.exec(conn, "INSERT INTO s_fk_child (parent_id) VALUES (?)", 999_i64)
      end
    end
  end
end
