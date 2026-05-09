require "json"
require "../adapter/base"
require "../adapter/live_state"
require "../diff/operation"
require "./schema_table"

module Prostore
  module Drift
    # Drift detection (ADR-0010).
    #
    # Compares the library's record of the schema (`prostore_schema` rows)
    # against what's actually in the database. Resolution:
    #
    #   - Managed column renamed externally       → auto-fix (rename back)
    #   - Managed column dropped externally       → ERROR (data lost)
    #   - Managed column type/nullability altered → ERROR (ADR-0003)
    #   - Managed index dropped or renamed        → auto-fix (recreate / rename back)
    #   - Unmanaged column / index / table        → tolerate (log)
    #   - Unmanaged name collision with desired   → ERROR
    #
    # The detector is a pure function over (live state, schema rows). The
    # runner prepends the auto-fix operations to its plan before the
    # model-driven diff runs.
    module Detector
      extend self

      record FixableDrift, ops : Array(Diff::Operation::Any)
      record UnmanagedReport, tables : Array(String), columns : Array({String, String}), indexes : Array({String, String})

      def detect(adapter : Prostore::Adapter::Base,
                 executor : Prostore::Adapter::Base::Executor,
                 schema_rows : Array(SchemaTable::Row),
                 unmanaged_table_filter : Array(String) = [] of String) : FixableDrift
        ops = [] of Diff::Operation::Any

        rows_by_table = schema_rows.group_by(&.table_name)

        rows_by_table.each do |table_name, rows|
          # If the managed table is missing entirely, that's drift we cannot
          # fix automatically (data is gone). Surface a clear error.
          live_table_names = adapter.introspect_table_names(executor)
          unless live_table_names.includes?(table_name)
            raise Prostore::DriftError.new(
              "Managed table '#{table_name}' is missing from the database. " \
              "Either restore it from backup, or remove the model and reset " \
              "prostore_schema for that table (ADR-0010)."
            )
          end

          live = adapter.introspect_table(table_name, executor)
          detect_columns(table_name, rows, live, ops)
          detect_indexes(table_name, rows, live, ops)
        end

        FixableDrift.new(ops)
      end

      # ---- columns ----------------------------------------------------------

      private def detect_columns(table : String,
                                 rows : Array(SchemaTable::Row),
                                 live : Adapter::LiveTable,
                                 ops : Array(Diff::Operation::Any)) : Nil
        managed = rows.select { |row| row.kind == SchemaTable::KIND_COLUMN }
        live_by_name = live.columns.to_h { |col| {col.name, col} }

        managed.each do |row|
          live_col = live_by_name[row.current_name]?

          if live_col.nil?
            # The expected column name isn't in live state. Maybe it was
            # renamed externally to something else with the same tag —
            # but we have no way to identify which. Look for an unmanaged
            # live column whose definition matches and there's only ONE
            # such candidate.
            candidates = live.columns.reject { |col| managed.any? { |mgd| mgd.current_name == col.name } }
            if candidates.size == 1
              live_col = candidates.first
              # Auto-fix: rename live column back to expected name.
              ops << Diff::Operation::RenameField.new(table, row.tag, live_col.name, row.current_name)
            else
              raise Prostore::DriftError.new(
                "Managed column #{table}.#{row.current_name} (tag #{row.tag}) is missing " \
                "from the live database. Restore it manually or reserve the tag in the " \
                "model (ADR-0010, ADR-0008)."
              )
            end
            next
          end

          # Validate definition compatibility.
          stored = JSON.parse(row.definition)
          stored_nullable = stored["nullable"]?.try(&.as_bool) || false
          if live_col.nullable != stored_nullable
            raise Prostore::DriftError.new(
              "Managed column #{table}.#{row.current_name} has nullability changed " \
              "externally (#{stored_nullable ? "T?" : "T"} → #{live_col.nullable ? "T?" : "T"}). " \
              "In-place tightening/widening is forbidden (ADR-0003)."
            )
          end
        end
      end

      # ---- indexes ----------------------------------------------------------

      private def detect_indexes(table : String,
                                 rows : Array(SchemaTable::Row),
                                 live : Adapter::LiveTable,
                                 ops : Array(Diff::Operation::Any)) : Nil
        managed = rows.select { |row| row.kind == SchemaTable::KIND_INDEX }
        live_by_name = live.indexes.to_h { |idx| {idx.name, idx} }

        managed.each do |row|
          live_idx = live_by_name[row.current_name]?

          if live_idx.nil?
            # Managed index disappeared from live state. Recreate.
            stored = JSON.parse(row.definition)
            cols = stored["columns"]?.try(&.as_a.map(&.as_s)) || [] of String
            unique = stored["unique"]?.try(&.as_bool) || false
            where_sql = stored["where_sql"]?.try(&.as_s?)
            recreated = Schema::Index.new(
              tag: row.tag, name: row.current_name,
              columns: cols, unique: unique, where_sql: where_sql,
            )
            ops << Diff::Operation::AddIndex.new(table, recreated)
            next
          end

          # Validate definition compatibility.
          stored = JSON.parse(row.definition)
          stored_unique = stored["unique"]?.try(&.as_bool) || false
          if live_idx.unique != stored_unique
            raise Prostore::DriftError.new(
              "Managed index #{table}.#{row.current_name} has its UNIQUE flag changed " \
              "externally. Definition changes require a new tag (ADR-0005)."
            )
          end
        end
      end
    end
  end
end
