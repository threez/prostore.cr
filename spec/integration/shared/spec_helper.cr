require "../../spec_helper"
require "uuid"
require "big"
require "json"

# Backend abstraction so the same spec body runs against SQLite (always)
# and PostgreSQL (when `POSTGRES_URL` is set). Each shared spec iterates
# `BACKENDS` and defines a `describe "<backend>:..."` block per backend.
#
# Backend-specific raw SQL in tests goes through `backend.exec` /
# `backend.query_one`, which translates `?` placeholders to the adapter's
# syntax. Avoid hand-writing `$1` / `?` in shared specs.

INTEGRATION_SQLITE_URL = "sqlite3::memory:?max_pool_size=1&initial_pool_size=1&max_idle_pool_size=1"

class TestBackend
  getter name : String
  getter url : String

  def initialize(@name : String, @url : String)
  end

  def with_connection(&)
    conn = Prostore::Connection.open(@url)
    begin
      reset_state(conn)
      Prostore.default_connection = conn
      yield conn
    ensure
      Prostore.default_connection = nil
      begin
        conn.close
      rescue ex
        # Tolerate SQLite's deferred constraint exception at close.
        raise ex unless ex.message.try(&.includes?("constraint"))
      end
    end
  end

  def reset_state(conn : Prostore::Connection) : Nil
    case @name
    when "sqlite"
      # In-memory; fresh per connection. Nothing to do.
    when "postgres"
      tables = [] of String
      conn.db.query_each("SELECT tablename FROM pg_tables WHERE schemaname = 'public'") do |rs|
        tables << rs.read(String)
      end
      tables.each { |table| conn.db.exec %(DROP TABLE IF EXISTS "#{table}" CASCADE) }
    end
  end

  # Execute raw SQL with `?` placeholders translated to the adapter's syntax.
  # The args array is explicitly typed `Array(DB::Any)` because crystal-pg's
  # encoder requires it (Tuple#to_a's inferred element type doesn't match).
  def exec(conn : Prostore::Connection, sql : String, *args) : Nil
    conn.db.exec(translate_qmarks(sql, conn.adapter), args: typed_args(args))
  end

  def query_one(conn : Prostore::Connection, sql : String, *args, as type : T.class) forall T
    conn.db.query_one(translate_qmarks(sql, conn.adapter), args: typed_args(args), as: type)
  end

  def query_one?(conn : Prostore::Connection, sql : String, *args, as type : T.class) forall T
    conn.db.query_one?(translate_qmarks(sql, conn.adapter), args: typed_args(args), as: type)
  end

  def query_each(conn : Prostore::Connection, sql : String, *args, & : DB::ResultSet ->)
    conn.db.query_each(translate_qmarks(sql, conn.adapter), args: typed_args(args)) do |rs|
      yield rs
    end
  end

  private def typed_args(args) : Array(::DB::Any)
    arr = [] of ::DB::Any
    args.each { |arg| arr << arg.as(::DB::Any) }
    arr
  end

  private def translate_qmarks(sql : String, adapter : Prostore::Adapter::Base) : String
    return sql if adapter.placeholder(1) == "?"
    i = 0
    sql.gsub("?") do
      i += 1
      adapter.placeholder(i)
    end
  end
end

BACKENDS = begin
  # `PROSTORE_TEST_PG_ONLY=1` (set by the test-postgres CI job) restricts
  # the matrix to Postgres so the shared specs run only against PG in
  # that job — SQLite is fully covered by the test-sqlite job. Default
  # mode picks up SQLite always and PG when its URL is set.
  if ENV["PROSTORE_TEST_PG_ONLY"]?
    pg_url = ENV["POSTGRES_URL"]? ||
             raise "PROSTORE_TEST_PG_ONLY requires POSTGRES_URL to be set"
    [TestBackend.new("postgres", pg_url)]
  else
    list = [TestBackend.new("sqlite", INTEGRATION_SQLITE_URL)]
    if pg_url = ENV["POSTGRES_URL"]?
      list << TestBackend.new("postgres", pg_url)
    end
    list
  end
end
