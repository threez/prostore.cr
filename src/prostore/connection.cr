require "db"
require "uri"
require "http/params"
require "./adapter/sqlite/adapter"
require "./adapter/postgres/adapter"

module Prostore
  # High-level handle bundling a `DB::Database` pool with a chosen `Adapter`.
  #
  # Per-connection session setup (e.g. `PRAGMA foreign_keys = ON` for
  # SQLite, ADR-0012) is installed via `DB::Database#setup_connection` so
  # every connection acquired from the pool is initialized.
  #
  # `Connection` delegates `exec`, `scalar`, `query_one`, `query_one?`,
  # `query_each`, and `transaction` directly to the underlying pool, so
  # callers can use `conn.exec(...)` rather than `conn.db.exec(...)`.
  class Connection
    getter db : DB::Database
    getter adapter : Adapter::Base

    def self.open(url : String) : Connection
      db = DB.open(url)
      adapter = create_adapter(db, url)
      db.setup_connection { |conn| adapter.session_setup(conn) }
      new(db, adapter)
    end

    def initialize(@db : DB::Database, @adapter : Adapter::Base)
    end

    def close : Nil
      @db.close
    end

    # Acquire a single connection and yield it. The runner uses this to keep
    # all bootstrap / migration DDL on one connection so that nested
    # operations don't deadlock the pool.
    def with_connection(&)
      @db.using_connection do |conn|
        yield conn
      end
    end

    # Convenience delegates so callers can use conn.exec / conn.scalar etc.
    # without reaching into conn.db directly.

    def exec(query : String, *args_, args : Array? = nil) : DB::ExecResult
      @db.exec(query, *args_, args: args)
    end

    def scalar(query : String, *args_, args : Array? = nil)
      @db.scalar(query, *args_, args: args)
    end

    def query_one(query : String, *args_, args : Array? = nil, & : DB::ResultSet -> T) forall T
      @db.query_one(query, *args_, args: args) { |rs| yield rs }
    end

    def query_one?(query : String, *args_, args : Array? = nil, & : DB::ResultSet -> T) forall T
      @db.query_one?(query, *args_, args: args) { |rs| yield rs }
    end

    def query_each(query : String, *args_, args : Array? = nil, & : DB::ResultSet -> Nil) : Nil
      @db.query_each(query, *args_, args: args) { |rs| yield rs }
    end

    def transaction(& : DB::Transaction -> T) forall T
      @db.transaction { |tx| yield tx }
    end

    private def self.create_adapter(db : DB::Database, url : String) : Adapter::Base
      case url
      when .starts_with?("sqlite3:")
        Adapter::SQLite::Adapter.new(db, extract_sqlite_pragmas(url))
      when .starts_with?("postgres:"), .starts_with?("postgresql:")
        Adapter::Postgres::Adapter.new(db)
      else
        raise Prostore::Error.new("Unsupported database URL: #{url} (supported schemes: sqlite3:, postgres:)")
      end
    end

    private def self.extract_sqlite_pragmas(url : String) : Hash(String, String)
      pragmas = {} of String => String
      query = URI.parse(url).query
      return pragmas unless query
      HTTP::Params.parse(query).each do |key, value|
        pragmas[key] = value if Adapter::SQLite::Adapter::PRAGMA_KEYS.includes?(key)
      end
      pragmas
    end
  end
end
