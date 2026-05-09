require "./spec_helper"

private class SBTenant < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
end

private class SBUser < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
  field 3, :tenant_id, Int64
  field 4, :status, String,
    default: Prostore::SQL.expr("'active'"),
    backfill: Prostore::SQL.expr("'active'")

  index 1, [:email], unique: true
  index 2, [:tenant_id, :status]

  foreign_key 1, [:tenant_id], references: SBTenant, on_delete: :cascade
end

BACKENDS.each do |backend|
  describe "#{backend.name}: first-run bootstrap" do
    it "creates user tables and the prostore_* bookkeeping tables" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SBTenant, SBUser] of Prostore::Model.class)

        tables = conn.adapter.introspect_table_names.sort
        tables.should contain("sb_tenant")
        tables.should contain("sb_user")
        tables.should contain("prostore_migration")
        tables.should contain("prostore_migration_step")
        tables.should contain("prostore_schema")
      end
    end

    it "creates indexes on the user table" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SBTenant, SBUser] of Prostore::Model.class)

        idx_names = conn.adapter.introspect_table("sb_user").indexes.map(&.name).sort!
        idx_names.should contain("sb_user_email_idx")
        idx_names.should contain("sb_user_tenant_id_status_idx")
      end
    end

    it "populates prostore_schema with tag↔name rows" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SBTenant, SBUser] of Prostore::Model.class)

        rows = Prostore::Drift::SchemaTable.for_table(conn.adapter, conn.db, "sb_user")

        column_rows = rows.select { |row| row.kind == "column" }
        column_rows.size.should eq(4)
        column_rows.map(&.tag).sort!.should eq([1, 2, 3, 4])
        column_rows.find { |row| row.tag == 2 }.try(&.current_name).should eq("email")

        index_rows = rows.select { |row| row.kind == "index" }
        index_rows.size.should eq(2)

        fk_rows = rows.select { |row| row.kind == "foreign_key" }
        fk_rows.size.should eq(1)
        fk_rows.first.current_name.should eq("sb_user_tenant_id_fkey")
      end
    end

    it "topologically orders FK-dependent table creation" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SBUser, SBTenant] of Prostore::Model.class)
        conn.adapter.introspect_table_names.should contain("sb_user")
      end
    end
  end

  describe "#{backend.name}: auto_increment (ADR-0013)" do
    it "auto-assigns IDs on insert without an explicit value" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SBTenant] of Prostore::Model.class)

        backend.exec(conn, "INSERT INTO sb_tenant (name) VALUES (?)", "first")
        backend.exec(conn, "INSERT INTO sb_tenant (name) VALUES (?)", "second")

        ids = [] of Int64
        conn.db.query_each("SELECT id FROM sb_tenant ORDER BY id") { |rs| ids << rs.read(Int64) }
        ids.size.should eq(2)
        ids.first.should be > 0_i64
      end
    end

    it "honors explicit IDs (BY DEFAULT semantics, ADR-0013)" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SBTenant] of Prostore::Model.class)

        backend.exec(conn, "INSERT INTO sb_tenant (id, name) VALUES (?, ?)", 1000_i64, "explicit")
        n = backend.query_one(conn, "SELECT COUNT(*) FROM sb_tenant WHERE id = ?", 1000_i64, as: Int64)
        n.should eq(1_i64)
      end
    end
  end

  describe "#{backend.name}: foreign keys" do
    it "FK is enforced (orphan insert blocked)" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SBTenant, SBUser] of Prostore::Model.class)

        expect_raises(Exception, /[Ff][Oo][Rr][Ee][Ii][Gg][Nn] [Kk][Ee][Yy]/) do
          backend.exec(conn, "INSERT INTO sb_user (email, tenant_id) VALUES (?, ?)", "x@y.test", 999_i64)
        end
      end
    end
  end
end
