require "json"
require "../drift/schema_table"
require "../schema"

module Prostore
  module Diff
    # Validates the desired model state against the existing prostore_schema
    # state, enforcing the constraints from ADR-0003 (no in-place type
    # changes), ADR-0008 (reservation interlocks), and ADR-0011 (non-nullable
    # adds against non-empty tables require `backfill:`).
    #
    # The validator runs *before* the planner. If validation fails, no DDL is
    # planned or executed. The errors raised here are the user-facing
    # failures of "your model is incompatible with the existing database
    # state." All cross-checks here are static — they don't query the live
    # DB.
    module Validator
      extend self

      def validate(models : Array(Prostore::Model.class),
                   schema_rows : Array(Drift::SchemaTable::Row)) : Nil
        rows_by_table = schema_rows.group_by(&.table_name)

        models.each do |model_class|
          definition = model_class.prostore_schema
          rows = rows_by_table[definition.table_name]? || [] of Drift::SchemaTable::Row
          next if rows.empty? # New table; nothing to compare against.
          validate_table(definition, rows)
        end
      end

      def validate_table(definition : Schema::Definition,
                         rows : Array(Drift::SchemaTable::Row)) : Nil
        validate_field_changes(definition, rows)
        validate_index_changes(definition, rows)
      end

      # ---- internals --------------------------------------------------------

      private def validate_field_changes(definition : Schema::Definition,
                                         rows : Array(Drift::SchemaTable::Row)) : Nil
        existing = rows.select { |row| row.kind == Drift::SchemaTable::KIND_COLUMN }
          .to_h { |row| {row.tag, row} }
        desired = definition.fields.to_h { |field| {field.tag, field} }

        desired.each do |tag, field|
          row = existing[tag]?
          next unless row

          stored = JSON.parse(row.definition)

          if stored["portable_type"]?.try(&.as_s) != field.portable_type.to_s
            raise Prostore::SchemaError.new(
              "Field tag #{tag} on #{definition.table_name}: type changed from " \
              "#{stored["portable_type"]?} to #{field.portable_type} — in-place type changes are " \
              "forbidden (ADR-0003). Reserve the old tag and add a new field instead."
            )
          end

          stored_nullable = stored["nullable"]?.try(&.as_bool)
          if !stored_nullable.nil? && stored_nullable != field.nullable
            raise Prostore::SchemaError.new(
              "Field tag #{tag} on #{definition.table_name}: nullability changed " \
              "(#{stored_nullable ? "T?" : "T"} → #{field.nullable ? "T?" : "T"}) — " \
              "in-place tightening or widening is forbidden (ADR-0003). Reserve and re-add."
            )
          end

          stored_primary = stored["primary"]?.try(&.as_bool)
          if !stored_primary.nil? && stored_primary != field.primary
            raise Prostore::SchemaError.new(
              "Field tag #{tag} on #{definition.table_name}: primary-key flag changed — " \
              "primary key reassignment is forbidden in-place (ADR-0003)."
            )
          end

          stored_ai = stored["auto_increment"]?.try(&.as_bool)
          if !stored_ai.nil? && stored_ai != field.auto_increment
            raise Prostore::SchemaError.new(
              "Field tag #{tag} on #{definition.table_name}: auto_increment changed — " \
              "auto_increment cannot be added or removed in place (ADR-0013)."
            )
          end
        end

        # ADR-0011: non-nullable add to a non-empty table requires `backfill:`.
        # Surface the error eagerly when a non-empty schema is being extended
        # with a non-nullable column that has no SQL.expr default and no
        # backfill.
        existing_field_tags = existing.keys
        unless existing_field_tags.empty?
          desired.each do |tag, field|
            next if existing.has_key?(tag)
            next if field.nullable
            next if field.has_default && !field.default_sql.nil?
            next if field.has_backfill

            raise Prostore::SchemaError.new(
              "Field tag #{tag} (#{field.name}) on #{definition.table_name}: " \
              "adding a non-nullable column to an existing table requires either " \
              "`default: SQL.expr(...)` (server-side default that populates existing rows) " \
              "or `backfill:` (ADR-0011). Add one, or make the column nullable."
            )
          end
        end
      end

      private def validate_index_changes(definition : Schema::Definition,
                                         rows : Array(Drift::SchemaTable::Row)) : Nil
        existing = rows.select { |row| row.kind == Drift::SchemaTable::KIND_INDEX }
          .to_h { |row| {row.tag, row} }
        desired = definition.indexes.to_h { |idx| {idx.tag, idx} }

        desired.each do |tag, idx|
          row = existing[tag]?
          next unless row
          stored = JSON.parse(row.definition)

          stored_cols = stored["columns"]?.try(&.as_a.map(&.as_s)) || [] of String
          desired_cols = idx.columns.map(&.to_s)
          if stored_cols != desired_cols
            raise Prostore::SchemaError.new(
              "Index tag #{tag} on #{definition.table_name}: column set changed " \
              "(#{stored_cols} → #{desired_cols}) — in-place definition changes are " \
              "forbidden (ADR-0005). Reserve the old tag and add a new index."
            )
          end

          stored_unique = stored["unique"]?.try(&.as_bool)
          if !stored_unique.nil? && stored_unique != idx.unique
            raise Prostore::SchemaError.new(
              "Index tag #{tag} on #{definition.table_name}: unique flag changed — " \
              "definition change requires a new tag (ADR-0005)."
            )
          end

          stored_where = stored["where_sql"]?.try(&.as_s?)
          if stored_where != idx.where_sql
            raise Prostore::SchemaError.new(
              "Index tag #{tag} on #{definition.table_name}: WHERE clause changed " \
              "(#{stored_where.inspect} → #{idx.where_sql.inspect}) — definition change " \
              "requires a new tag (ADR-0005)."
            )
          end
        end
      end
    end
  end
end
