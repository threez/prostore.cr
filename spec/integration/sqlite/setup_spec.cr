require "./spec_helper"

private class SetupModel < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :value, String
end

describe "Prostore.setup (sqlite3::memory:)" do
  it "migrates and connects over the same in-memory database" do
    conn = Prostore.setup(INTEGRATION_SQLITE_URL, [SetupModel] of Prostore::Model.class)
    begin
      # If setup shared the connection, the schema exists on the live connection.
      m = SetupModel.allocate
      m.value = "hello"
      m.save
      SetupModel.find(m.id).value.should eq("hello")
    ensure
      Prostore.default_connection = nil
      conn.close
    end
  end

  it "Prostore.migrate(conn) overload migrates on a pre-opened connection" do
    conn = Prostore::Connection.open(INTEGRATION_SQLITE_URL)
    begin
      Prostore.migrate(conn, [SetupModel] of Prostore::Model.class)
      Prostore.default_connection = conn
      m = SetupModel.allocate
      m.value = "via migrate(conn)"
      m.save
      SetupModel.find(m.id).value.should eq("via migrate(conn)")
    ensure
      Prostore.default_connection = nil
      conn.close
    end
  end
end
