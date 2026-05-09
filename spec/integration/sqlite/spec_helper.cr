require "../shared/spec_helper"

# Helper for the small set of SQLite-only specs that exercise SQLite-
# specific behaviors (PRAGMA, AUTOINCREMENT-in-DDL string, sqlite_master
# inspection). The shared spec helper supplies `INTEGRATION_SQLITE_URL`
# and the cross-backend `BACKENDS` array; we just add an SQLite-only
# convenience wrapper.

def with_sqlite_connection(&)
  conn = Prostore::Connection.open(INTEGRATION_SQLITE_URL)
  begin
    Prostore.default_connection = conn
    yield conn
  ensure
    Prostore.default_connection = nil
    begin
      conn.close
    rescue ex : SQLite3::Exception
      raise ex unless ex.message.try(&.includes?("constraint"))
    end
  end
end
