require "./spec_helper"

private class SCliModel < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
end

BACKENDS.each do |backend|
  describe "#{backend.name}: CLI helpers" do
    it "status writes a migration summary" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SCliModel] of Prostore::Model.class)

        io = IO::Memory.new
        Prostore::Migration::CLI.status(conn, io)

        out = io.to_s
        out.should contain("Migrations")
        out.should contain("complete")
      end
    end

    it "drift_check reports no drift on a freshly-migrated database" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SCliModel] of Prostore::Model.class)

        io = IO::Memory.new
        Prostore::Migration::CLI.drift_check(conn, io)
        io.to_s.should contain("No drift detected")
      end
    end

    it "abort marks a migration aborted" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SCliModel] of Prostore::Model.class)
        mig_id = backend.query_one(conn,
          "SELECT id FROM prostore_migration ORDER BY id LIMIT 1", as: Int64)

        io = IO::Memory.new
        Prostore::Migration::CLI.abort(conn, mig_id, io)

        status = backend.query_one(conn,
          "SELECT status FROM prostore_migration WHERE id = ?", mig_id, as: String)
        status.should eq("aborted")
      end
    end
  end
end
