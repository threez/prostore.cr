require "./prostore/version"
require "./prostore/error"
require "./prostore/types"
require "./prostore/sql_expr"
require "./prostore/schema"
require "./prostore/schema/fingerprint"
require "./prostore/model"
require "./prostore/macros"

require "./prostore/adapter/base"
require "./prostore/adapter/sqlite/adapter"
require "./prostore/connection"
require "./prostore/migration/bookkeeping"
require "./prostore/migration/internal"
require "./prostore/drift/schema_table"
require "./prostore/drift/detector"
require "./prostore/diff/operation"
require "./prostore/diff/engine"
require "./prostore/diff/validator"
require "./prostore/steps/step"
require "./prostore/steps/codec"
require "./prostore/steps/planner"
require "./prostore/steps/executor"
require "./prostore/migration/state"
require "./prostore/migration/lease"
require "./prostore/migration/heartbeat"
require "./prostore/migration/runner"
require "./prostore/migration/cli"
require "./prostore/backup"
require "./prostore/records"
require "./prostore/query/ast"
require "./prostore/query/predicates"
require "./prostore/query/renderer"
require "./prostore/query/builder"
require "./prostore/query/analyzer"

# prostore — declarative ORM for Crystal targeting SQLite and PostgreSQL.
#
# See doc/adr/ for the architectural decisions.
module Prostore
  # High-level entry: bootstrap or migrate the database referenced by `url`.
  # Opens a temporary connection, migrates, then closes it. For in-memory
  # SQLite use `Prostore.setup(url)` instead, which reuses the connection.
  def self.migrate(url : String, models : Array(Prostore::Model.class) = Prostore.models) : Nil
    conn = Connection.open(url)
    begin
      Migration::Runner.migrate(conn, models)
    ensure
      conn.close
    end
  end

  # Migrate using a pre-opened connection. The caller retains ownership of
  # `conn` and is responsible for closing it. Use this when migrate and the
  # subsequent app queries must share the same underlying database — most
  # importantly for `sqlite3::memory:` where each `DB.open` is a distinct,
  # empty database.
  def self.migrate(conn : Connection, models : Array(Prostore::Model.class) = Prostore.models) : Nil
    Migration::Runner.migrate(conn, models)
  end

  # Open, migrate, and set as the default connection in one call.
  # Returns the connection so the caller can close it on shutdown.
  # Prefer this over separate `migrate(url)` + `connect(url)` for
  # `sqlite3::memory:` databases.
  def self.setup(url : String, models : Array(Prostore::Model.class) = Prostore.models) : Connection
    conn = Connection.open(url)
    Migration::Runner.migrate(conn, models)
    @@default_connection = conn
    conn
  end

  # Delete all rows from `models` in reverse FK dependency order (children
  # before parents). Safe for test teardown when foreign_keys=ON.
  def self.delete_all(models : Array(Prostore::Model.class) = Prostore.models,
                      conn : Connection = Prostore.default_connection) : Nil
    sorted = Diff::Engine.topological_sort(models)
    conn.with_connection do |db_conn|
      sorted.reverse_each do |model|
        db_conn.exec("DELETE FROM #{conn.adapter.quote_ident(model.prostore_table_name)}")
      end
    end
  end

  # Convenience alias for test teardown — identical to `delete_all`.
  def self.test_reset(models : Array(Prostore::Model.class) = Prostore.models,
                      conn : Connection = Prostore.default_connection) : Nil
    delete_all(models, conn)
  end
end
