require "db"
require "../schema"
require "./live_state"

module Prostore
  module Adapter
    # Abstract backend adapter (ADR-0007).
    #
    # Implementations: SQLite (`Prostore::Adapter::SQLite::Adapter`) and
    # PostgreSQL (`Prostore::Adapter::Postgres::Adapter`). The adapter
    # exposes a uniform surface that the planner, runner, and drift detector
    # consume; backend-specific operational behaviors (e.g., Postgres
    # `CREATE INDEX CONCURRENTLY`) are hidden behind capability flags and
    # per-step planner branching.
    #
    # Methods that issue SQL accept an `Executor` — anything that responds
    # to `exec` and `query_*`. In practice this is `DB::Database`,
    # `DB::Connection`, or `DB::Transaction`. The runner pins all DDL to a
    # single checked-out connection (see `Prostore::Connection#with_connection`)
    # to avoid pool deadlock when multi-step operations call back into the
    # adapter from inside a transaction.
    abstract class Base
      # An "executor" is anything that responds to `exec` and `query_*`.
      # `DB::Transaction` is intentionally excluded — its `connection` should
      # be unwrapped at the call site (`tx.connection`) and passed in here.
      alias Executor = DB::Database | DB::Connection

      getter db : DB::Database

      def initialize(@db : DB::Database)
      end

      # ----------------------------------------------------------- Quoting

      abstract def quote_ident(name : String) : String
      abstract def quote_string(s : String) : String

      # ----------------------------------------------------------- DDL emission

      abstract def render_create_table(definition : Schema::Definition) : String
      abstract def render_create_index(table : String, index : Schema::Index) : String

      # ----------------------------------------------------------- Introspection

      abstract def introspect_table_names(executor : Executor = @db) : Array(String)
      abstract def introspect_table(name : String, executor : Executor = @db) : LiveTable

      def introspect_all(executor : Executor = @db) : Array(LiveTable)
        introspect_table_names(executor).map { |name| introspect_table(name, executor) }
      end

      # ----------------------------------------------------------- Capability flags

      def supports_concurrent_index? : Bool
        false
      end

      def supports_alter_drop_column? : Bool
        true
      end

      def supports_alter_set_not_null? : Bool
        true
      end

      def supports_add_constraint_not_valid? : Bool
        false
      end

      # Connection-establishment hook. Adapters override to set per-connection
      # session state (SQLite's `PRAGMA foreign_keys = ON`).
      def session_setup(conn : DB::Connection) : Nil
      end

      # ----------------------------------------------------------- Backend-specific bookkeeping

      # Column DDL fragment for an auto-incrementing BIGINT primary key on
      # the bookkeeping tables. SQLite emits `INTEGER PRIMARY KEY AUTOINCREMENT`
      # while Postgres emits `BIGSERIAL PRIMARY KEY` (or identity). Each
      # adapter overrides.
      abstract def bookkeeping_id_column_def : String

      # INSERT a row and return its newly-assigned ID. SQLite uses
      # `last_insert_rowid()`; Postgres uses `RETURNING id`. The adapter
      # encapsulates the difference.
      abstract def insert_returning_id(executor : Executor, sql : String, *args) : Int64

      # Array-args overload for callers that build their argument list
      # dynamically (e.g., the record-layer INSERT helper).
      abstract def insert_returning_id(executor : Executor, sql : String, args : Array) : Int64

      # The n-th positional parameter placeholder in the adapter's SQL
      # syntax. SQLite uses `?` (position-implicit). PostgreSQL uses
      # `$1, $2, …` (position-explicit). crystal-db does NOT translate
      # between them, so SQL strings shared by both adapters must build
      # placeholders via this method.
      abstract def placeholder(n : Int32) : String

      # Convenience: comma-joined sequence of `count` placeholders, e.g.
      # "?, ?, ?" on SQLite or "$1, $2, $3" on Postgres.
      def placeholders(count : Int32) : String
        (1..count).map { |name| placeholder(name) }.join(", ")
      end

      # The operator for a case-insensitive substring match in a WHERE
      # clause.  SQLite's `LIKE` is case-insensitive for ASCII by default;
      # PostgreSQL exposes `ILIKE` for the same purpose.
      abstract def like_operator : String

      # Write a point-in-time backup to `dest` (an absolute file path).
      # SQLite uses `VACUUM INTO`; PostgreSQL shells out to `pg_dump`.
      abstract def backup(dest : String) : Nil
    end
  end
end
