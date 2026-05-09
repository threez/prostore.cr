require "./spec_helper"

private class SSmBefore < Prostore::Model
  table_name "s_sm"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
end

private class SSmAfter < Prostore::Model
  table_name "s_sm"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
  field 3, :nickname, String?
end

BACKENDS.each do |backend|
  describe "#{backend.name}: migration state machine" do
    it "persists migration + step rows for a real migration" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SSmBefore] of Prostore::Model.class)
        Prostore::Migration::Runner.migrate(conn, [SSmAfter] of Prostore::Model.class)

        mig_count = backend.query_one(conn,
          "SELECT COUNT(*) FROM prostore_migration WHERE status = ?", "complete", as: Int64)
        mig_count.should be >= 1_i64

        step_count = backend.query_one(conn,
          "SELECT COUNT(*) FROM prostore_migration_step WHERE status = ?", "complete", as: Int64)
        step_count.should be >= 1_i64
      end
    end

    it "is idempotent — re-running with the same model is a no-op" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SSmBefore] of Prostore::Model.class)
        before = backend.query_one(conn, "SELECT COUNT(*) FROM prostore_migration", as: Int64)

        Prostore::Migration::Runner.migrate(conn, [SSmBefore] of Prostore::Model.class)
        after = backend.query_one(conn, "SELECT COUNT(*) FROM prostore_migration", as: Int64)

        after.should eq(before)
      end
    end

    it "lease cannot be claimed by a second runner while held" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SSmBefore] of Prostore::Model.class)
        mig_id = backend.query_one(conn, "SELECT id FROM prostore_migration ORDER BY id LIMIT 1", as: Int64)

        Prostore::Migration::Lease.claim(conn.adapter, conn.db, mig_id, "runner-a").should be_true
        Prostore::Migration::Lease.claim(conn.adapter, conn.db, mig_id, "runner-b").should be_false
      end
    end

    it "lease becomes stealable after expiry" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SSmBefore] of Prostore::Model.class)
        mig_id = backend.query_one(conn, "SELECT id FROM prostore_migration ORDER BY id LIMIT 1", as: Int64)

        Prostore::Migration::Lease.claim(conn.adapter, conn.db, mig_id, "runner-a").should be_true

        backend.exec(conn,
          "UPDATE prostore_migration SET claimed_until = ? WHERE id = ?",
          "2000-01-01T00:00:00Z", mig_id,
        )

        Prostore::Migration::Lease.claim(conn.adapter, conn.db, mig_id, "runner-b").should be_true
      end
    end
  end
end
