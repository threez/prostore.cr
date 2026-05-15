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

          if row.portable_type && row.portable_type != field.portable_type.to_s
            raise Prostore::SchemaError.new(
              "Field tag #{tag} on #{definition.table_name}: type changed from " \
              "#{row.portable_type} to #{field.portable_type} — in-place type changes are " \
              "forbidden (ADR-0003). Reserve the old tag and add a new field instead."
            )
          end

          stored_nullable = row.nullable
          if !stored_nullable.nil? && stored_nullable != field.nullable
            raise Prostore::SchemaError.new(
              "Field tag #{tag} on #{definition.table_name}: nullability changed " \
              "(#{stored_nullable ? "T?" : "T"} → #{field.nullable ? "T?" : "T"}) — " \
              "in-place tightening or widening is forbidden (ADR-0003). Reserve and re-add."
            )
          end

          stored_primary = row.primary
          if !stored_primary.nil? && stored_primary != field.primary
            raise Prostore::SchemaError.new(
              "Field tag #{tag} on #{definition.table_name}: primary-key flag changed — " \
              "primary key reassignment is forbidden in-place (ADR-0003)."
            )
          end

          stored_ai = row.auto_increment
          if !stored_ai.nil? && stored_ai != field.auto_increment
            raise Prostore::SchemaError.new(
              "Field tag #{tag} on #{definition.table_name}: auto_increment changed — " \
              "auto_increment cannot be added or removed in place (ADR-0013)."
            )
          end

          # ADR-0016: enum member set may grow (additive) but never shrink, and
          # the integer value of an existing member is fixed. Adds are silent
          # here; the engine emits an AlterEnumMembers op to widen the CHECK.
          validate_enum_members(definition, tag, field, row)
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

      private def validate_enum_members(definition : Schema::Definition,
                                        tag : Int32,
                                        field : Schema::Field,
                                        row : Drift::SchemaTable::Row) : Nil
        stored = row.enum_members
        return if stored.nil? || stored.empty?

        desired = field.enum_members || [] of Schema::EnumMember

        removed = stored.reject do |stored_member|
          desired.any? { |desired_member| desired_member.name == stored_member.name }
        end
        unless removed.empty?
          raise Prostore::SchemaError.new(
            "Field tag #{tag} on #{definition.table_name}: enum member(s) " \
            "#{removed.map(&.name).join(", ")} removed. Removing an enum member is " \
            "forbidden because existing rows may still carry that value (ADR-0016). " \
            "Keep the member declared, or reserve this field tag (ADR-0002) and add a " \
            "new field with the trimmed set."
          )
        end

        desired.each do |desired_member|
          if existing = stored.find { |stored_member| stored_member.name == desired_member.name }
            if existing.value != desired_member.value
              raise Prostore::SchemaError.new(
                "Field tag #{tag} on #{definition.table_name}: enum member " \
                "#{desired_member.name} value changed (#{existing.value} → #{desired_member.value}). Forbidden " \
                "in-place — `enum_int`-stored rows would be silently misread (ADR-0016). " \
                "Reserve the tag and add a new field if the value space must change."
              )
            end
            if existing.wire_name != desired_member.wire_name
              raise Prostore::SchemaError.new(
                "Field tag #{tag} on #{definition.table_name}: enum member " \
                "#{desired_member.name} wire_name changed (#{existing.wire_name.inspect} → " \
                "#{desired_member.wire_name.inspect}). Forbidden in-place — existing rows still " \
                "carry the old wire value and would fail the CHECK constraint or be silently " \
                "unreadable (ADR-0017). Write an explicit data migration first (UPDATE the " \
                "column to the new wire values), then change the `naming:` declaration."
              )
            end
          end
        end

        if !row.enum_is_flags.nil? && row.enum_is_flags != field.enum_is_flags
          raise Prostore::SchemaError.new(
            "Field tag #{tag} on #{definition.table_name}: @[Flags] annotation " \
            "toggled (#{row.enum_is_flags} → #{field.enum_is_flags}). The flags / " \
            "non-flags distinction changes how integer values are interpreted; " \
            "forbidden in-place (ADR-0016)."
          )
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

          stored_cols = row.index_columns || [] of String
          desired_cols = idx.columns.map(&.to_s)
          if stored_cols != desired_cols
            raise Prostore::SchemaError.new(
              "Index tag #{tag} on #{definition.table_name}: column set changed " \
              "(#{stored_cols} → #{desired_cols}) — in-place definition changes are " \
              "forbidden (ADR-0005). Reserve the old tag and add a new index."
            )
          end

          stored_unique = row.index_unique
          if !stored_unique.nil? && stored_unique != idx.unique
            raise Prostore::SchemaError.new(
              "Index tag #{tag} on #{definition.table_name}: unique flag changed — " \
              "definition change requires a new tag (ADR-0005)."
            )
          end

          stored_where = row.index_where_sql
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
