require "../diff/operation"
require "./step"

module Prostore
  module Steps
    # Operation → ordered Step list (ADR-0009 invariant 1).
    #
    # Most operations map 1:1 to atomic steps. `AddField` is the exception:
    # when the field is non-nullable AND has a `backfill:` distinct from the
    # column-level `default:`, it decomposes into:
    #
    #   AddColumnNullable + Backfill(SqlExpr | CrystalLambda) + ApplyNotNull
    #
    # The ordering reflects ADR-0009 invariant 3: the backfill loop's
    # WHERE col IS NULL predicate requires the column to exist as nullable
    # first; ApplyNotNull only tightens after the backfill has populated
    # every row.
    #
    # The single-step `AddColumn` path stays for:
    #   - Nullable fields (no backfill needed; existing rows keep NULL).
    #   - Non-null fields whose `default: SQL.expr(...)` doubles as the
    #     existing-row populator (SQLite ADD COLUMN ... NOT NULL DEFAULT
    #     applies the default to existing rows in one statement).
    module Planner
      extend self

      def plan(operations : Array(Diff::Operation::Any)) : Array(Kind::Any)
        steps = [] of Kind::Any
        operations.each { |op| append_steps_for(op, steps) }
        steps
      end

      private def append_steps_for(op : Diff::Operation::Any, steps : Array(Kind::Any)) : Nil
        case op
        when Diff::Operation::CreateTable
          steps << Kind::CreateTable.new(op.definition)
        when Diff::Operation::DropTable
          steps << Kind::DropTable.new(op.table_name)
        when Diff::Operation::AddField
          plan_add_field(op, steps)
        when Diff::Operation::DropField
          steps << Kind::DropColumn.new(op.table_name, op.tag, op.current_name)
        when Diff::Operation::RenameField
          steps << Kind::RenameColumn.new(op.table_name, op.tag, op.from_name, op.to_name)
        when Diff::Operation::AddIndex
          steps << Kind::AddIndex.new(op.table_name, op.index)
        when Diff::Operation::DropIndex
          steps << Kind::DropIndex.new(op.table_name, op.tag, op.current_name)
        when Diff::Operation::RenameIndex
          steps << Kind::RenameIndex.new(op.table_name, op.tag, op.from_name, op.to_name)
        when Diff::Operation::AddForeignKey
          steps << Kind::AddForeignKey.new(op.table_name, op.foreign_key)
        when Diff::Operation::DropForeignKey
          steps << Kind::DropForeignKey.new(op.table_name, op.tag, op.current_name)
        end
      end

      private def plan_add_field(op : Diff::Operation::AddField,
                                 steps : Array(Kind::Any)) : Nil
        field = op.field
        table = op.table_name

        # Single-step paths:
        # 1. Nullable fields — column added as-is (DEFAULT applied if any).
        # 2. Non-null fields whose default doubles as the backfill (either
        #    no backfill annotation, or backfill SQL identical to default).
        if field.nullable
          steps << Kind::AddColumn.new(table, field)
          return
        end

        if field.has_default && field.default_sql && (
             !field.has_backfill || field.backfill_sql == field.default_sql
           )
          steps << Kind::AddColumn.new(table, field)
          return
        end

        # Multi-phase path. Field is non-null and either has a distinct
        # SQL.expr backfill or a Crystal-lambda backfill.
        steps << Kind::AddColumnNullable.new(table, field)

        if field.has_backfill && field.backfill_sql
          steps << Kind::BackfillSqlExpr.new(table, field.name.to_s, field.backfill_sql || raise(Prostore::SchemaError.new("backfill_sql missing on field #{field.name}")))
        elsif field.has_lambda_backfill?
          steps << Kind::BackfillCrystalLambda.new(table, field.name.to_s, field.tag)
        else
          # Validator should have caught this. Belt-and-suspenders.
          raise Prostore::SchemaError.new(
            "Cannot plan multi-phase AddField for non-nullable field #{field.name} " \
            "without a backfill (ADR-0011)."
          )
        end

        steps << Kind::ApplyNotNull.new(table, field.name.to_s, field.default_sql)
      end
    end
  end
end
