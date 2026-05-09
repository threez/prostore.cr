require "../../schema"
require "../live_state"
require "./types"

module Prostore
  module Adapter
    module SQLite
      # SQLite DDL string builders. Pure functions; no DB interaction here.
      module DDL
        extend self

        def quote_ident(name : String) : String
          # SQLite double-quotes identifiers; embedded quotes are doubled.
          %("#{name.gsub(%("), %(""))}")
        end

        def quote_string(s : String) : String
          %('#{s.gsub(%('), %(''))}')
        end

        def render_action(action : Symbol) : String
          case action
          when :no_action   then "NO ACTION"
          when :restrict    then "RESTRICT"
          when :cascade     then "CASCADE"
          when :set_null    then "SET NULL"
          when :set_default then "SET DEFAULT"
          else                   raise Prostore::SchemaError.new("unknown FK action: #{action}")
          end
        end

        def render_column(field : Schema::Field) : String
          parts = [quote_ident(field.name.to_s)] of String
          parts << SQLite.affinity(field.portable_type)

          # SQLite quirk: AUTOINCREMENT must appear with INTEGER PRIMARY KEY
          # at the column level. Only single-column PKs are supported, so
          # primary + auto_increment + INTEGER all combine on one column.
          if field.primary && field.auto_increment
            parts << "PRIMARY KEY AUTOINCREMENT"
          elsif field.primary
            parts << "PRIMARY KEY"
          end

          parts << "NOT NULL" unless field.nullable

          if sql = field.default_sql
            parts << "DEFAULT (#{sql})"
          end

          parts.join(' ')
        end

        def render_foreign_key_clause(fk : Schema::ForeignKey, target_pk_columns : Array(String)) : String
          ref_cols = fk.references_columns.empty? ? target_pk_columns : fk.references_columns.map(&.to_s)
          src_cols = fk.columns.map { |col| quote_ident(col.to_s) }.join(", ")
          tgt_cols = ref_cols.map { |col| quote_ident(col) }.join(", ")

          "CONSTRAINT #{quote_ident(fk.name)} FOREIGN KEY (#{src_cols}) " \
          "REFERENCES #{quote_ident(fk.references_table)} (#{tgt_cols}) " \
          "ON DELETE #{render_action(fk.on_delete)} " \
          "ON UPDATE #{render_action(fk.on_update)}"
        end

        # Resolve target PK columns for a model definition (for FKs that omit
        # references_fields:). The caller passes a lookup table from
        # references_table → primary key column names.
        def render_create_table(definition : Schema::Definition,
                                pk_lookup : Hash(String, Array(String))) : String
          io = IO::Memory.new
          io << "CREATE TABLE " << quote_ident(definition.table_name) << " (\n"

          parts = [] of String
          definition.fields.sort_by(&.tag).each do |field|
            parts << "  " + render_column(field)
          end
          definition.foreign_keys.sort_by(&.tag).each do |fk|
            target_pk = pk_lookup[fk.references_table]? ||
                        raise Prostore::SchemaError.new(
                          "Foreign key #{fk.tag} references unknown table #{fk.references_table}")
            parts << "  " + render_foreign_key_clause(fk, target_pk)
          end
          io << parts.join(",\n") << "\n)"
          io.to_s
        end

        def render_create_index(table : String, idx : Schema::Index) : String
          io = IO::Memory.new
          io << "CREATE "
          io << "UNIQUE " if idx.unique
          io << "INDEX " << quote_ident(idx.name)
          io << " ON " << quote_ident(table) << " ("
          io << idx.columns.map { |col| quote_ident(col.to_s) }.join(", ")
          io << ')'
          if where = idx.where_sql
            io << " WHERE " << where
          end
          io.to_s
        end
      end
    end
  end
end
