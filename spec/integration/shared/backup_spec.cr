require "./spec_helper"

private class SBackupModel < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
end

BACKENDS.each do |backend|
  describe "#{backend.name}: Prostore::Backup" do
    it "backs up the database and the destination is readable" do
      if backend.name == "postgres" && !Process.find_executable("pg_dump")
        pending "pg_dump not in PATH"
        next
      end

      pid = Process.pid
      src_path  = "/tmp/prostore_backup_src_#{pid}.db"
      dest_path = "/tmp/prostore_backup_dst_#{pid}.db"
      src_url   = backend.name == "sqlite" ? "sqlite3://#{src_path}" : backend.url
      dest      = backend.name == "sqlite" ? dest_path : "/tmp/prostore_backup_pg_#{pid}.sql"

      conn = Prostore::Connection.open(src_url)
      begin
        tbl = SBackupModel.prostore_table_name
        Prostore.migrate(conn, [SBackupModel] of Prostore::Model.class)
        backend.exec(conn, "INSERT INTO #{tbl} (name) VALUES (?)", "hello")

        actual = Prostore::Backup.run(conn, dest)
        actual.should eq(dest)

        if backend.name == "sqlite"
          verify = Prostore::Connection.open("sqlite3://#{dest_path}?max_pool_size=1")
          begin
            count = verify.scalar("SELECT COUNT(*) FROM #{tbl}").as(Int64)
            count.should eq(1)
          ensure
            verify.close
          end
        else
          File.exists?(dest).should be_true
          File.size(dest).should be > 0
        end
      ensure
        conn.close
        File.delete(src_path) if backend.name == "sqlite" && File.exists?(src_path)
        File.delete(dest_path) if backend.name == "sqlite" && File.exists?(dest_path)
        File.delete(dest) if backend.name == "postgres" && File.exists?(dest)
      end
    end

    it "expands strftime tokens in the destination path" do
      if backend.name == "postgres" && !Process.find_executable("pg_dump")
        pending "pg_dump not in PATH"
        next
      end

      pid      = Process.pid
      src_path = "/tmp/prostore_ts_src_#{pid}.db"
      src_url  = backend.name == "sqlite" ? "sqlite3://#{src_path}" : backend.url
      template = backend.name == "sqlite" \
        ? "/tmp/prostore_ts_dst_#{pid}_%Y%m%d_%H%M%S.db" \
        : "/tmp/prostore_ts_pg_#{pid}_%Y%m%d_%H%M%S.sql"

      conn = Prostore::Connection.open(src_url)
      actual = ""
      begin
        Prostore.migrate(conn, [SBackupModel] of Prostore::Model.class)
        actual = Prostore::Backup.run(conn, template)

        actual.should_not contain("%Y")
        actual.should_not contain("%m")
        actual.should_not contain("%d")
        actual.should contain(Time.utc.year.to_s)
        File.exists?(actual).should be_true
      ensure
        conn.close
        File.delete(src_path) if backend.name == "sqlite" && File.exists?(src_path)
        File.delete(actual) if !actual.empty? && File.exists?(actual)
      end
    end
  end
end
