require "db"
require "../base"
require "./ddl"

module Prostore
  module Adapter
    module SQLite
      # Generic table-rebuild helper for SQLite operations that have no
      # native ALTER counterpart: tightening a column to NOT NULL,
      # adding/removing/changing FK semantics on a non-empty table, etc.
      #
      # The dance:
      #   1. CREATE TABLE <table>__prostore_rebuild (... new schema ...)
      #   2. INSERT INTO __prostore_rebuild SELECT ... FROM <table>
      #   3. DROP TABLE <table>
      #   4. ALTER TABLE __prostore_rebuild RENAME TO <table>
      #   5. Re-create every index that existed on the old table.
      #
      # SQLite can rename a table in place (RENAME TO), and indexes on the
      # rebuilt table are dropped along with the original table. We capture
      # them before the drop and re-issue CREATE INDEX statements on the new
      # table afterward.
      #
      # Used by ApplyNotNull and by foreign-key changes against non-empty
      # tables.
      module Rebuild
        extend self

        REBUILD_SUFFIX = "__prostore_rebuild"

        # Rebuild `table` so that its column DDL matches `new_columns_sql`
        # (an array of pre-rendered column-def fragments). Foreign-key and
        # other table-level constraints are passed via `new_constraints_sql`.
        # Indexes are re-created from the captured `existing_indexes`.
        #
        # `column_mapping` maps OLD column names to expressions used in the
        # SELECT that copies data: typically `OLD.col` for unchanged columns
        # and a literal/expression for transformed ones. If a column's value
        # need not change between old and new, just pass its name.
        def rebuild(adapter : Prostore::Adapter::SQLite::Adapter,
                    executor : Prostore::Adapter::Base::Executor,
                    table : String,
                    new_columns_sql : Array(String),
                    new_constraints_sql : Array(String),
                    column_mapping : Array({old_expr: String, new_name: String}),
                    existing_indexes_sql : Array(String)) : Nil
          rebuild_table = "#{table}#{REBUILD_SUFFIX}"

          # 1. Create the rebuild table with new shape.
          io = IO::Memory.new
          io << "CREATE TABLE " << adapter.quote_ident(rebuild_table) << " (\n"
          parts = (new_columns_sql + new_constraints_sql).map { |part| "  #{part}" }
          io << parts.join(",\n") << "\n)"
          executor.exec(io.to_s)

          # 2. Copy data.
          new_cols = column_mapping.map { |mapping| adapter.quote_ident(mapping[:new_name]) }.join(", ")
          old_exprs = column_mapping.map { |mapping| mapping[:old_expr] }.join(", ")
          executor.exec(
            "INSERT INTO #{adapter.quote_ident(rebuild_table)} (#{new_cols}) " \
            "SELECT #{old_exprs} FROM #{adapter.quote_ident(table)}"
          )

          # 3. Drop the old table. Indexes on it are dropped automatically.
          executor.exec("DROP TABLE #{adapter.quote_ident(table)}")

          # 4. Rename the rebuild table.
          executor.exec(
            "ALTER TABLE #{adapter.quote_ident(rebuild_table)} RENAME TO #{adapter.quote_ident(table)}"
          )

          # 5. Re-create indexes.
          existing_indexes_sql.each do |sql|
            executor.exec(sql)
          end
        end

        # Capture each non-PK index's CREATE INDEX statement from
        # sqlite_master so we can re-issue after rebuild. PK indexes are
        # implicit and don't appear here.
        def capture_index_statements(executor : Prostore::Adapter::Base::Executor,
                                     table : String) : Array(String)
          stmts = [] of String
          executor.query_each(
            "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ? " \
            "AND sql IS NOT NULL",
            table
          ) do |rs|
            stmts << rs.read(String)
          end
          stmts
        end
      end
    end
  end
end
