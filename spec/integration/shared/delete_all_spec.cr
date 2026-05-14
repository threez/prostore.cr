require "./spec_helper"

private class DAParent < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
end

private class DAChild < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :parent_id, Int64

  foreign_key 1, [:parent_id], references: DAParent, on_delete: :cascade
end

DA_MODELS = [DAParent, DAChild] of Prostore::Model.class

BACKENDS.each do |backend|
  describe "#{backend.name}: Prostore.delete_all / test_reset" do
    it "deletes all rows in FK-safe order (child before parent)" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, DA_MODELS)

        backend.exec(conn, "INSERT INTO da_parent (id, name) VALUES (?, ?)", 1_i64, "p1")
        backend.exec(conn, "INSERT INTO da_child (parent_id) VALUES (?)", 1_i64)

        Prostore.delete_all(DA_MODELS, conn)

        backend.query_one(conn, "SELECT count(*) FROM da_child", as: Int64).should eq(0_i64)
        backend.query_one(conn, "SELECT count(*) FROM da_parent", as: Int64).should eq(0_i64)
      end
    end

    it "test_reset is an alias for delete_all" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, DA_MODELS)

        backend.exec(conn, "INSERT INTO da_parent (id, name) VALUES (?, ?)", 2_i64, "p2")
        backend.exec(conn, "INSERT INTO da_child (parent_id) VALUES (?)", 2_i64)

        Prostore.test_reset(DA_MODELS, conn)

        backend.query_one(conn, "SELECT count(*) FROM da_child", as: Int64).should eq(0_i64)
        backend.query_one(conn, "SELECT count(*) FROM da_parent", as: Int64).should eq(0_i64)
      end
    end
  end
end
