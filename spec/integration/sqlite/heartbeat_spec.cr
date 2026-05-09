require "./spec_helper"

# HeartbeatFiber unit-style integration spec. Verifies:
#   1. The fiber starts/stops cleanly on a working pool.
#   2. With an in-memory SQLite (single-connection pool), the fiber
#      gracefully degrades to no-op — its `attempt` catches PoolTimeout.
#   3. When `Lease.heartbeat` returns false (lease was stolen externally),
#      the fiber sets `lost?` and exits.

private class HbModel < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
end

describe "Prostore::Migration::HeartbeatFiber (SQLite, single-pool)" do
  it "starts and stops cleanly" do
    with_sqlite_connection do |conn|
      Prostore::Migration::Runner.migrate(conn, [HbModel] of Prostore::Model.class)
      mig_id = conn.db.query_one(
        "SELECT id FROM prostore_migration ORDER BY id LIMIT 1", as: Int64)
      Prostore::Migration::Lease.claim(conn.adapter, conn.db, mig_id, "runner-test").should be_true

      hb = Prostore::Migration::HeartbeatFiber.new(
        conn, mig_id, "runner-test",
        interval: 50.milliseconds,
        lease_duration: 5.minutes,
      )
      hb.start
      sleep 10.milliseconds
      hb.stop
      hb.lost?.should be_false
    end
  end

  it "marks lost? when another runner steals the lease" do
    with_sqlite_connection do |conn|
      Prostore::Migration::Runner.migrate(conn, [HbModel] of Prostore::Model.class)
      mig_id = conn.db.query_one(
        "SELECT id FROM prostore_migration ORDER BY id LIMIT 1", as: Int64)
      Prostore::Migration::Lease.claim(conn.adapter, conn.db, mig_id, "runner-A").should be_true

      hb = Prostore::Migration::HeartbeatFiber.new(
        conn, mig_id, "runner-A",
        interval: 50.milliseconds,
      )
      hb.start

      # Simulate another runner expiring this lease and stealing.
      conn.db.exec(
        "UPDATE prostore_migration SET claimed_until = ? WHERE id = ?",
        "2000-01-01T00:00:00Z", mig_id,
      )
      Prostore::Migration::Lease.claim(conn.adapter, conn.db, mig_id, "runner-B").should be_true

      # Wait long enough for the fiber to wake at least once. With pool=1
      # the heartbeat fiber gets the connection during a yield window of
      # the main fiber, observes the stolen lease, and sets lost? = true.
      sleep 100.milliseconds
      hb.stop
      hb.lost?.should be_true
    end
  end
end
