require "./spec_helper"

describe "Prostore::Connection (SQLite)" do
  it "opens an in-memory database" do
    with_sqlite_connection do |conn|
      conn.adapter.should be_a(Prostore::Adapter::SQLite::Adapter)
    end
  end

  it "enables PRAGMA foreign_keys = ON on every connection" do
    with_sqlite_connection do |conn|
      result = conn.db.query_one("PRAGMA foreign_keys", as: Int32)
      result.should eq(1)
    end
  end

  it "delegates exec directly on Connection" do
    with_sqlite_connection do |conn|
      conn.exec("CREATE TABLE IF NOT EXISTS _delegate_test (x INTEGER)")
      conn.exec("INSERT INTO _delegate_test VALUES (?)", 42)
      result = conn.db.query_one("SELECT x FROM _delegate_test", as: Int32)
      result.should eq(42)
    end
  end

  it "delegates scalar directly on Connection" do
    with_sqlite_connection do |conn|
      conn.scalar("SELECT 1 + 1").should eq(2)
    end
  end

  it "applies journal_mode pragma from URL query string" do
    db_path = "/tmp/prostore_wal_test_#{Process.pid}.db"
    url = "sqlite3://#{db_path}?journal_mode=wal"
    conn = Prostore::Connection.open(url)
    begin
      result = conn.db.query_one("PRAGMA journal_mode", as: String)
      result.should eq("wal")
    ensure
      conn.close
      File.delete(db_path) if File.exists?(db_path)
      File.delete("#{db_path}-wal") if File.exists?("#{db_path}-wal")
      File.delete("#{db_path}-shm") if File.exists?("#{db_path}-shm")
    end
  end
end
