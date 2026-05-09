require "db"
require "../live_state"
require "../base"

module Prostore
  module Adapter
    module SQLite
      # SQLite introspection. Reads `sqlite_master` (for table names and the
      # original CREATE TABLE SQL — useful for partial-index `WHERE` clauses
      # that PRAGMA doesn't surface) and the `pragma_*` table-valued
      # functions for column / index / FK details.
      module Introspect
        extend self

        # User tables (excludes sqlite_* internals; the planner caller
        # filters out our prostore_* bookkeeping).
        def table_names(executor : Prostore::Adapter::Base::Executor) : Array(String)
          names = [] of String
          executor.query_each(
            "SELECT name FROM sqlite_master WHERE type = 'table' " \
            "AND name NOT LIKE 'sqlite_%' ORDER BY name"
          ) do |rs|
            names << rs.read(String)
          end
          names
        end

        def columns(executor : Prostore::Adapter::Base::Executor, table : String) : Array(LiveColumn)
          # AUTOINCREMENT detection requires looking at the original CREATE
          # TABLE SQL — fetch it ONCE before iterating columns, since a
          # nested query inside `query_each` would deadlock a single-slot
          # connection pool.
          ai_table = has_autoincrement?(executor, table)

          # Materialize the column rows into memory before constructing
          # LiveColumn values, for the same reason.
          rows = [] of NamedTuple(name: String, type_text: String, notnull: Bool, default_text: String?, pk_index: Int32)
          executor.query_each("SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info(?)", table) do |rs|
            rows << {
              name:         rs.read(String),
              type_text:    rs.read(String),
              notnull:      rs.read(Int32) == 1,
              default_text: rs.read(String?),
              pk_index:     rs.read(Int32),
            }
          end

          rows.map do |row|
            LiveColumn.new(
              name: row[:name],
              type_text: row[:type_text],
              nullable: !row[:notnull],
              default_text: row[:default_text],
              primary: row[:pk_index] > 0,
              auto_increment: row[:pk_index] > 0 && row[:type_text].upcase.includes?("INT") && ai_table,
            )
          end
        end

        def indexes(executor : Prostore::Adapter::Base::Executor, table : String) : Array(LiveIndex)
          # Same pattern as `columns`: read the index list into memory before
          # any per-index sub-queries, to avoid nested-query deadlock.
          rows = [] of NamedTuple(name: String, uniq: Bool, origin: String, partial: Bool)
          executor.query_each("SELECT name, \"unique\", origin, partial FROM pragma_index_list(?)", table) do |rs|
            rows << {
              name:    rs.read(String),
              uniq:    rs.read(Int32) == 1,
              origin:  rs.read(String),
              partial: rs.read(Int32) == 1,
            }
          end

          out = [] of LiveIndex
          rows.each do |row|
            next if row[:origin] == "pk"

            cols = [] of String
            executor.query_each("SELECT name FROM pragma_index_info(?)", row[:name]) do |rs2|
              cols << rs2.read(String)
            end

            where_sql = nil
            if row[:partial]
              sql = executor.query_one?(
                "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?",
                row[:name], as: String?
              )
              where_sql = extract_where_clause(sql) if sql
            end

            out << LiveIndex.new(
              name: row[:name],
              columns: cols,
              unique: row[:uniq],
              where_sql: where_sql,
            )
          end
          out
        end

        def foreign_keys(executor : Prostore::Adapter::Base::Executor, table : String) : Array(LiveForeignKey)
          rows = [] of NamedTuple(id: Int32, seq: Int32, table: String, from: String, to: String?, on_update: String, on_delete: String)
          executor.query_each("SELECT id, seq, \"table\", \"from\", \"to\", on_update, on_delete FROM pragma_foreign_key_list(?)", table) do |rs|
            rows << {
              id:        rs.read(Int32),
              seq:       rs.read(Int32),
              table:     rs.read(String),
              from:      rs.read(String),
              to:        rs.read(String?),
              on_update: rs.read(String),
              on_delete: rs.read(String),
            }
          end

          rows.group_by(&.[:id]).map do |_, group|
            sorted = group.sort_by(&.[:seq])
            first = sorted.first
            LiveForeignKey.new(
              name: "",
              columns: sorted.map(&.[:from]),
              references_table: first[:table],
              references_columns: sorted.compact_map(&.[:to]),
              on_delete: parse_action(first[:on_delete]),
              on_update: parse_action(first[:on_update]),
            )
          end
        end

        def table(executor : Prostore::Adapter::Base::Executor, name : String) : LiveTable
          LiveTable.new(
            name: name,
            columns: columns(executor, name),
            indexes: indexes(executor, name),
            foreign_keys: foreign_keys(executor, name),
          )
        end

        # ---- internals ----

        private def has_autoincrement?(executor : Prostore::Adapter::Base::Executor, table : String) : Bool
          sql = executor.query_one?(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
            table, as: String?
          )
          sql.try(&.upcase).try(&.includes?("AUTOINCREMENT")) || false
        end

        private def parse_action(s : String) : Symbol
          case s.upcase
          when "NO ACTION"   then :no_action
          when "RESTRICT"    then :restrict
          when "CASCADE"     then :cascade
          when "SET NULL"    then :set_null
          when "SET DEFAULT" then :set_default
          else                    :no_action
          end
        end

        private def extract_where_clause(sql : String) : String?
          if idx = sql.upcase.index(" WHERE ")
            sql[(idx + 7)..].strip
          end
        end
      end
    end
  end
end
