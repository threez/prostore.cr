require "json"
require "../schema"
require "../drift/schema_table"
require "./operation"

module Prostore
  module Diff
    # Pure function: (desired model definitions, prostore_schema rows) →
    # ordered list of Operations.
    #
    # Compares each model's `Schema::Definition` against the rows in
    # `prostore_schema` (which is the library's record of the actual DB by
    # tag). Per-tag identity (ADR-0002) drives rename detection; reservations
    # (ADR-0008) drive drop detection. Type changes are detected here and
    # surfaced via the validator (ADR-0003).
    #
    # The engine does NOT consult live SQL DB metadata — that's the drift
    # detector's job. It trusts `prostore_schema` to reflect the actual DB
    # state, since the migration runner updates that table atomically with
    # each successful step.
    module Engine
      extend self

      # Top-level: diff every model in `models` against the schema-table
      # rows; produce the full ordered operation list.
      #
      # Tables in `models` whose name doesn't appear in `schema_rows` get
      # `CreateTable`. Tables in `schema_rows` whose name doesn't appear in
      # `models` are left alone — drop-table is the drift detector's
      # responsibility; an unmanaged table is the operator's problem.
      def diff(models : Array(Prostore::Model.class),
               schema_rows : Array(Drift::SchemaTable::Row)) : Array(Operation::Any)
        ops = [] of Operation::Any
        rows_by_table = schema_rows.group_by(&.table_name)

        # Split models by whether they need a CreateTable. Existing tables can
        # be diffed in declaration order (FKs go through their own steps).
        # New-table creates must be topologically ordered: a table referenced
        # by another's FK must be created first.
        new_models = [] of Prostore::Model.class
        existing_models = [] of Prostore::Model.class
        models.each do |model_class|
          if (rows_by_table[model_class.prostore_schema.table_name]? || [] of Drift::SchemaTable::Row).empty?
            new_models << model_class
          else
            existing_models << model_class
          end
        end

        topological_sort(new_models).each do |model_class|
          ops << Operation::CreateTable.new(model_class.prostore_schema)
        end

        existing_models.each do |model_class|
          definition = model_class.prostore_schema
          rows = rows_by_table[definition.table_name]
          ops.concat(diff_table(definition, rows))
        end

        ops
      end

      # Order new tables so a table is created after every table its foreign
      # keys reference. Edges are restricted to the new-models set: FKs that
      # reference an already-existing table need no ordering constraint.
      private def topological_sort(new_models : Array(Prostore::Model.class)) : Array(Prostore::Model.class)
        new_names = new_models.map(&.prostore_table_name).to_set
        by_name = new_models.to_h { |model| {model.prostore_table_name, model} }

        result = [] of Prostore::Model.class
        visited = Set(String).new
        visiting = Set(String).new

        visit = uninitialized String -> Nil
        visit = ->(name : String) do
          return if visited.includes?(name)
          if visiting.includes?(name)
            raise Prostore::SchemaError.new(
              "Foreign-key cycle among new tables: #{visiting.to_a.sort.join(", ")}"
            )
          end
          visiting << name

          model = by_name[name]
          model.prostore_schema.foreign_keys.each do |fk|
            next if fk.references_table == name # self-FK: no ordering constraint
            visit.call(fk.references_table) if new_names.includes?(fk.references_table)
          end

          visiting.delete(name)
          visited << name
          result << model
          nil
        end

        new_models.each { |model| visit.call(model.prostore_table_name) }
        result
      end

      # Per-table diff. Visible for unit testing.
      def diff_table(definition : Schema::Definition,
                     rows : Array(Drift::SchemaTable::Row)) : Array(Operation::Any)
        ops = [] of Operation::Any
        diff_fields(definition, rows, ops)
        diff_indexes(definition, rows, ops)
        diff_foreign_keys(definition, rows, ops)
        ops
      end

      # ---- internals --------------------------------------------------------

      private def diff_fields(definition : Schema::Definition,
                              rows : Array(Drift::SchemaTable::Row),
                              ops : Array(Operation::Any)) : Nil
        existing = rows.select { |row| row.kind == Drift::SchemaTable::KIND_COLUMN }
          .to_h { |row| {row.tag, row} }
        desired = definition.fields.to_h { |field| {field.tag, field} }

        # Adds: in desired, not in existing.
        desired.each do |tag, field|
          unless existing.has_key?(tag)
            ops << Operation::AddField.new(definition.table_name, field)
          end
        end

        # Drops: in existing, not in desired. Each drop must correspond to a
        # `reserved` tag in the model — otherwise the model has lost track of
        # a column without an explicit reservation.
        existing.each do |tag, row|
          next if desired.has_key?(tag)
          unless definition.reserved_field_tags.includes?(tag)
            raise Prostore::SchemaError.new(
              "Field tag #{tag} (column '#{row.current_name}') exists in the database " \
              "for table '#{definition.table_name}' but is neither declared nor reserved " \
              "in the model. Add `reserved #{tag}` to drop it (ADR-0002)."
            )
          end
          ops << Operation::DropField.new(definition.table_name, tag, row.current_name)
        end

        # Renames: present in both, name differs.
        desired.each do |tag, field|
          row = existing[tag]?
          next unless row
          if field.name.to_s != row.current_name
            ops << Operation::RenameField.new(definition.table_name, tag, row.current_name, field.name.to_s)
          end
        end
      end

      private def diff_indexes(definition : Schema::Definition,
                               rows : Array(Drift::SchemaTable::Row),
                               ops : Array(Operation::Any)) : Nil
        existing = rows.select { |row| row.kind == Drift::SchemaTable::KIND_INDEX }
          .to_h { |row| {row.tag, row} }
        desired = definition.indexes.to_h { |idx| {idx.tag, idx} }

        desired.each do |tag, idx|
          unless existing.has_key?(tag)
            ops << Operation::AddIndex.new(definition.table_name, idx)
          end
        end

        existing.each do |tag, row|
          next if desired.has_key?(tag)
          unless definition.reserved_index_tags.includes?(tag)
            raise Prostore::SchemaError.new(
              "Index tag #{tag} (index '#{row.current_name}') exists in the database " \
              "for table '#{definition.table_name}' but is neither declared nor reserved " \
              "in the model. Add `reserved_index #{tag}` to drop it (ADR-0005)."
            )
          end
          ops << Operation::DropIndex.new(definition.table_name, tag, row.current_name)
        end

        desired.each do |tag, idx|
          row = existing[tag]?
          next unless row
          if idx.name != row.current_name
            ops << Operation::RenameIndex.new(definition.table_name, tag, row.current_name, idx.name)
          end
        end
      end

      private def diff_foreign_keys(definition : Schema::Definition,
                                    rows : Array(Drift::SchemaTable::Row),
                                    ops : Array(Operation::Any)) : Nil
        existing = rows.select { |row| row.kind == Drift::SchemaTable::KIND_FOREIGN_KEY }
          .to_h { |row| {row.tag, row} }
        desired = definition.foreign_keys.to_h { |fk| {fk.tag, fk} }

        desired.each do |tag, fk|
          unless existing.has_key?(tag)
            ops << Operation::AddForeignKey.new(definition.table_name, fk)
          end
        end

        existing.each do |tag, row|
          next if desired.has_key?(tag)
          unless definition.reserved_foreign_key_tags.includes?(tag)
            raise Prostore::SchemaError.new(
              "Foreign key tag #{tag} (constraint '#{row.current_name}') exists in the database " \
              "for table '#{definition.table_name}' but is neither declared nor reserved " \
              "in the model. Add `reserved_foreign_key #{tag}` to drop it (ADR-0012)."
            )
          end
          ops << Operation::DropForeignKey.new(definition.table_name, tag, row.current_name)
        end
      end
    end
  end
end
