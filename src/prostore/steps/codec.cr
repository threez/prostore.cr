require "json"
require "../schema"
require "./step"

module Prostore
  module Steps
    # Serialize/deserialize `Steps::Kind::*` values to and from JSON for
    # persistence in `prostore_migration_step.params` (ADR-0009 invariant 2:
    # plan-at-start, never recompute on resume).
    #
    # Each step round-trips losslessly: the encoded form contains every
    # primitive needed to re-execute, so the deserialized step yields
    # identical DDL on retry. No Symbols are ever stored — everything is
    # String-keyed JSON, which is why `Schema::Field.name` and the column
    # arrays on indexes/FKs are typed as String at the schema model level.
    module Codec
      extend self

      def encode(step : Kind::Any) : {kind: String, params: String}
        case step
        when Kind::CreateTable
          {kind: "create_table", params: encode_definition(step.definition)}
        when Kind::DropTable
          {kind: "drop_table", params: {table_name: step.table_name}.to_json}
        when Kind::AddColumn
          {kind: "add_column", params: {
            table_name: step.table_name,
            field:      encode_field(step.field),
          }.to_json}
        when Kind::DropColumn
          {kind: "drop_column", params: {
            table_name: step.table_name, tag: step.tag, column_name: step.column_name,
          }.to_json}
        when Kind::RenameColumn
          {kind: "rename_column", params: {
            table_name: step.table_name, tag: step.tag,
            from_name: step.from_name, to_name: step.to_name,
          }.to_json}
        when Kind::AddIndex
          {kind: "add_index", params: {
            table_name: step.table_name, index: encode_index(step.index),
          }.to_json}
        when Kind::DropIndex
          {kind: "drop_index", params: {
            table_name: step.table_name, tag: step.tag, index_name: step.index_name,
          }.to_json}
        when Kind::RenameIndex
          {kind: "rename_index", params: {
            table_name: step.table_name, tag: step.tag,
            from_name: step.from_name, to_name: step.to_name,
          }.to_json}
        when Kind::AddColumnNullable
          {kind: "add_column_nullable", params: {
            table_name: step.table_name, field: encode_field(step.field),
          }.to_json}
        when Kind::BackfillSqlExpr
          {kind: "backfill_sql_expr", params: {
            table_name: step.table_name, column_name: step.column_name, sql_expr: step.sql_expr,
          }.to_json}
        when Kind::BackfillCrystalLambda
          {kind: "backfill_crystal_lambda", params: {
            table_name: step.table_name, column_name: step.column_name, field_tag: step.field_tag,
          }.to_json}
        when Kind::ApplyNotNull
          {kind: "apply_not_null", params: {
            table_name: step.table_name, column_name: step.column_name, default_sql: step.default_sql,
          }.to_json}
        when Kind::AddForeignKey
          {kind: "add_foreign_key", params: {
            table_name: step.table_name, foreign_key: encode_foreign_key(step.foreign_key),
          }.to_json}
        when Kind::DropForeignKey
          {kind: "drop_foreign_key", params: {
            table_name: step.table_name, tag: step.tag, constraint_name: step.constraint_name,
          }.to_json}
        when Kind::ResetSequence
          {kind: "reset_sequence", params: {
            table_name: step.table_name, column_name: step.column_name,
          }.to_json}
        else
          raise Prostore::MigrationError.new("Unknown step kind: #{step.class}")
        end
      end

      def decode(kind : String, params_json : String) : Kind::Any
        params = JSON.parse(params_json)

        case kind
        when "create_table"
          Kind::CreateTable.new(decode_definition(params))
        when "drop_table"
          Kind::DropTable.new(params["table_name"].as_s)
        when "add_column"
          Kind::AddColumn.new(params["table_name"].as_s, decode_field(params["field"]))
        when "drop_column"
          Kind::DropColumn.new(params["table_name"].as_s, params["tag"].as_i, params["column_name"].as_s)
        when "rename_column"
          Kind::RenameColumn.new(params["table_name"].as_s, params["tag"].as_i,
            params["from_name"].as_s, params["to_name"].as_s)
        when "add_index"
          Kind::AddIndex.new(params["table_name"].as_s, decode_index(params["index"]))
        when "drop_index"
          Kind::DropIndex.new(params["table_name"].as_s, params["tag"].as_i, params["index_name"].as_s)
        when "rename_index"
          Kind::RenameIndex.new(params["table_name"].as_s, params["tag"].as_i,
            params["from_name"].as_s, params["to_name"].as_s)
        when "add_column_nullable"
          Kind::AddColumnNullable.new(params["table_name"].as_s, decode_field(params["field"]))
        when "backfill_sql_expr"
          Kind::BackfillSqlExpr.new(params["table_name"].as_s,
            params["column_name"].as_s, params["sql_expr"].as_s)
        when "backfill_crystal_lambda"
          Kind::BackfillCrystalLambda.new(params["table_name"].as_s,
            params["column_name"].as_s, params["field_tag"].as_i)
        when "apply_not_null"
          Kind::ApplyNotNull.new(params["table_name"].as_s, params["column_name"].as_s,
            params["default_sql"]?.try(&.as_s?))
        when "add_foreign_key"
          Kind::AddForeignKey.new(params["table_name"].as_s, decode_foreign_key(params["foreign_key"]))
        when "drop_foreign_key"
          Kind::DropForeignKey.new(params["table_name"].as_s, params["tag"].as_i, params["constraint_name"].as_s)
        when "reset_sequence"
          Kind::ResetSequence.new(params["table_name"].as_s, params["column_name"].as_s)
        else
          raise Prostore::MigrationError.new("Unknown step kind on resume: #{kind}")
        end
      end

      # ---- helpers ---------------------------------------------------------

      def encode_field(f : Schema::Field)
        {
          tag:            f.tag,
          name:           f.name,
          crystal_type:   f.crystal_type,
          portable_type:  f.portable_type,
          nullable:       f.nullable,
          primary:        f.primary,
          auto_increment: f.auto_increment,
          has_default:    f.has_default,
          default_sql:    f.default_sql,
          has_backfill:   f.has_backfill,
          backfill_sql:   f.backfill_sql,
          has_lazy:       f.has_lazy,
        }
      end

      def decode_field(j : JSON::Any) : Schema::Field
        Schema::Field.new(
          tag: j["tag"].as_i,
          name: j["name"].as_s,
          crystal_type: j["crystal_type"].as_s,
          portable_type: j["portable_type"].as_s,
          nullable: j["nullable"].as_bool,
          primary: j["primary"].as_bool,
          auto_increment: j["auto_increment"].as_bool,
          has_default: j["has_default"].as_bool,
          default_sql: j["default_sql"]?.try(&.as_s?),
          has_backfill: j["has_backfill"].as_bool,
          backfill_sql: j["backfill_sql"]?.try(&.as_s?),
          has_lazy: j["has_lazy"].as_bool,
        )
      end

      def encode_index(i : Schema::Index)
        {
          tag:       i.tag,
          name:      i.name,
          columns:   i.columns,
          unique:    i.unique,
          where_sql: i.where_sql,
        }
      end

      def decode_index(j : JSON::Any) : Schema::Index
        Schema::Index.new(
          tag: j["tag"].as_i,
          name: j["name"].as_s,
          columns: j["columns"].as_a.map(&.as_s),
          unique: j["unique"].as_bool,
          where_sql: j["where_sql"]?.try(&.as_s?),
        )
      end

      def encode_foreign_key(fk : Schema::ForeignKey)
        {
          tag:                fk.tag,
          name:               fk.name,
          columns:            fk.columns,
          references_table:   fk.references_table,
          references_columns: fk.references_columns,
          on_delete:          fk.on_delete.to_s,
          on_update:          fk.on_update.to_s,
        }
      end

      def decode_foreign_key(j : JSON::Any) : Schema::ForeignKey
        Schema::ForeignKey.new(
          tag: j["tag"].as_i,
          name: j["name"].as_s,
          columns: j["columns"].as_a.map(&.as_s),
          references_table: j["references_table"].as_s,
          references_columns: j["references_columns"].as_a.map(&.as_s),
          on_delete: parse_action(j["on_delete"].as_s),
          on_update: parse_action(j["on_update"].as_s),
        )
      end

      def encode_definition(d : Schema::Definition) : String
        {
          table_name:                d.table_name,
          fields:                    d.fields.map { |field| encode_field(field) },
          indexes:                   d.indexes.map { |i| encode_index(i) },
          foreign_keys:              d.foreign_keys.map { |fk| encode_foreign_key(fk) },
          reserved_field_tags:       d.reserved_field_tags,
          reserved_index_tags:       d.reserved_index_tags,
          reserved_foreign_key_tags: d.reserved_foreign_key_tags,
        }.to_json
      end

      def decode_definition(j : JSON::Any) : Schema::Definition
        Schema::Definition.new(
          table_name: j["table_name"].as_s,
          fields: j["fields"].as_a.map { |x| decode_field(x) },
          indexes: j["indexes"].as_a.map { |x| decode_index(x) },
          foreign_keys: j["foreign_keys"].as_a.map { |x| decode_foreign_key(x) },
          queries: [] of Schema::Query,
          reserved_field_tags: j["reserved_field_tags"].as_a.map(&.as_i),
          reserved_index_tags: j["reserved_index_tags"].as_a.map(&.as_i),
          reserved_foreign_key_tags: j["reserved_foreign_key_tags"].as_a.map(&.as_i),
        )
      end

      private def parse_action(s : String) : Symbol
        case s
        when "no_action"   then :no_action
        when "restrict"    then :restrict
        when "cascade"     then :cascade
        when "set_null"    then :set_null
        when "set_default" then :set_default
        else                    raise Prostore::MigrationError.new("Unknown FK action: #{s}")
        end
      end
    end
  end
end
