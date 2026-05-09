require "./spec_helper"

private class EvAddBefore < Prostore::Model
  table_name "ev_add"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
end

private class EvAddAfter < Prostore::Model
  table_name "ev_add"

  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
  field 3, :nickname, String?
  field 4, :status, String,
    default: Prostore::SQL.expr("'active'"),
    backfill: Prostore::SQL.expr("'active'")
end

private class EvDropBefore < Prostore::Model
  table_name "ev_drop"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
  field 3, :legacy_phone, String?
end

private class EvDropAfter < Prostore::Model
  table_name "ev_drop"

  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
  reserved 3
end

private class EvRenameBefore < Prostore::Model
  table_name "ev_rename"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
end

private class EvRenameAfter < Prostore::Model
  table_name "ev_rename"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :handle, String
end

private class EvIdxBefore < Prostore::Model
  table_name "ev_idx"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
  field 3, :tenant_id, Int64

  index 1, [:email], unique: true
end

private class EvIdxAfter < Prostore::Model
  table_name "ev_idx"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
  field 3, :tenant_id, Int64

  index 1, [:email], unique: true
  index 2, [:tenant_id]
end

BACKENDS.each do |backend|
  describe "#{backend.name}: AddField" do
    it "adds a nullable column to an existing table" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [EvAddBefore] of Prostore::Model.class)
        backend.exec(conn, "INSERT INTO ev_add (email) VALUES (?)", "a@x.test")

        Prostore::Migration::Runner.migrate(conn, [EvAddAfter] of Prostore::Model.class)

        cols = conn.adapter.introspect_table("ev_add").columns.map(&.name).sort!
        cols.should contain("nickname")
        cols.should contain("status")

        status = backend.query_one(conn, "SELECT status FROM ev_add WHERE email = ?", "a@x.test", as: String)
        status.should eq("active")

        nickname = backend.query_one?(conn, "SELECT nickname FROM ev_add WHERE email = ?", "a@x.test", as: String?)
        nickname.should be_nil
      end
    end
  end

  describe "#{backend.name}: DropField via reserved" do
    it "drops a column whose tag is reserved" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [EvDropBefore] of Prostore::Model.class)
        backend.exec(conn, "INSERT INTO ev_drop (email, legacy_phone) VALUES (?, ?)", "a@x.test", "555")

        Prostore::Migration::Runner.migrate(conn, [EvDropAfter] of Prostore::Model.class)

        cols = conn.adapter.introspect_table("ev_drop").columns.map(&.name).sort!
        cols.should eq(["email", "id"])

        email = backend.query_one(conn, "SELECT email FROM ev_drop", as: String)
        email.should eq("a@x.test")
      end
    end
  end

  describe "#{backend.name}: RenameField" do
    it "renames a column when the same tag has a new name" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [EvRenameBefore] of Prostore::Model.class)
        backend.exec(conn, "INSERT INTO ev_rename (email) VALUES (?)", "a@x.test")

        Prostore::Migration::Runner.migrate(conn, [EvRenameAfter] of Prostore::Model.class)

        cols = conn.adapter.introspect_table("ev_rename").columns.map(&.name).sort!
        cols.should eq(["handle", "id"])

        v = backend.query_one(conn, "SELECT handle FROM ev_rename", as: String)
        v.should eq("a@x.test")
      end
    end
  end

  describe "#{backend.name}: AddIndex / DropIndex" do
    it "adds a new index" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [EvIdxBefore] of Prostore::Model.class)
        Prostore::Migration::Runner.migrate(conn, [EvIdxAfter] of Prostore::Model.class)

        idx_names = conn.adapter.introspect_table("ev_idx").indexes.map(&.name).sort!
        idx_names.should contain("ev_idx_email_idx")
        idx_names.should contain("ev_idx_tenant_id_idx")
      end
    end
  end
end
