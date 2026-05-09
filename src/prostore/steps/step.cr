require "../schema"

module Prostore
  module Steps
    # The atomic-step layer (ADR-0009).
    #
    # A `Step` is the smallest unit the migration runner executes. Each step:
    #   - Is independently restartable (idempotent under retry).
    #   - Declares whether it `requires_transaction?` (used for Postgres
    #     `CREATE INDEX CONCURRENTLY`, which cannot be wrapped in a tx).
    #   - Knows how to record progress.
    #
    # Steps carry the data they need to execute (table names, column names,
    # SQL fragments, full Schema::Field/Index/ForeignKey records). The
    # adapter does the actual DDL emission via the executor.

    module Kind
      # Atomic kinds:
      record CreateTable, definition : Schema::Definition
      record DropTable, table_name : String
      record AddColumn, table_name : String, field : Schema::Field
      record DropColumn, table_name : String, tag : Int32, column_name : String
      record RenameColumn, table_name : String, tag : Int32, from_name : String, to_name : String
      record AddIndex, table_name : String, index : Schema::Index
      record DropIndex, table_name : String, tag : Int32, index_name : String
      record RenameIndex, table_name : String, tag : Int32, from_name : String, to_name : String

      # Multi-phase kinds (ADR-0009 invariant 1: user-level operations
      # decompose into atomic steps).
      #
      # AddColumnNullable adds the column as nullable regardless of the
      # field's final nullability. Used as the first step of a non-null
      # add-with-backfill so existing rows can hold NULL until the backfill
      # populates them, and ApplyNotNull tightens afterward.
      record AddColumnNullable, table_name : String, field : Schema::Field

      # BackfillSqlExpr issues a single server-side UPDATE for existing rows
      # whose value is still NULL. Crystal-lambda backfills use the chunked
      # form below.
      record BackfillSqlExpr,
        table_name : String,
        column_name : String,
        sql_expr : String

      # BackfillCrystalLambda is the chunked, NULL-filter loop described in
      # ADR-0009 invariant 3. The executor delegates to the model's
      # `__prostore_run_backfill` method to invoke the user lambda per row.
      record BackfillCrystalLambda,
        table_name : String,
        column_name : String,
        field_tag : Int32

      # ApplyNotNull tightens a nullable column to NOT NULL. SQLite has no
      # native ALTER COLUMN SET NOT NULL — the executor uses the
      # table-rebuild helper. Postgres uses the native form.
      record ApplyNotNull,
        table_name : String,
        column_name : String,
        default_sql : String?

      # Foreign-key kinds. SQLite has no ALTER TABLE ADD/DROP CONSTRAINT
      # FOREIGN KEY for non-empty tables; both go through the table-rebuild
      # helper. Postgres uses ADD CONSTRAINT NOT VALID + VALIDATE CONSTRAINT.
      record AddForeignKey, table_name : String, foreign_key : Schema::ForeignKey
      record DropForeignKey, table_name : String, tag : Int32, constraint_name : String

      # Reset an auto-increment sequence to MAX(column) (ADR-0013). SQLite
      # rewrites `sqlite_sequence`; Postgres calls `setval` on the column's
      # serial sequence. Idempotent — safe to run after any migration that
      # may have written explicit values to an auto_increment column.
      record ResetSequence, table_name : String, column_name : String

      alias Any = CreateTable | DropTable |
                  AddColumn | DropColumn | RenameColumn |
                  AddIndex | DropIndex | RenameIndex |
                  AddColumnNullable | BackfillSqlExpr | BackfillCrystalLambda | ApplyNotNull |
                  AddForeignKey | DropForeignKey |
                  ResetSequence
    end

    # Whether this step kind must run inside a transaction.
    #
    # `AddIndex` against an adapter that supports `CREATE INDEX CONCURRENTLY`
    # returns `false` — Postgres requires that variant to run outside a
    # transaction. Every other step is `true` because they're single DDL
    # statements that benefit from atomic application.
    def self.requires_transaction?(step : Kind::Any, adapter : Adapter::Base? = nil) : Bool
      case step
      when Kind::AddIndex
        return false if adapter && adapter.supports_concurrent_index?
        true
      else
        true
      end
    end
  end
end
