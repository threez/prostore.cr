require "db"
require "../live_state"
require "../base"

module Prostore
  module Adapter
    module Postgres
      # PostgreSQL introspection via information_schema and pg_catalog
      # (ADR-0010 drift detection backbone).
      module Introspect
        extend self

        def table_names(executor : Prostore::Adapter::Base::Executor) : Array(String)
          out = [] of String
          executor.query_each(
            "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename"
          ) do |rs|
            out << rs.read(String)
          end
          out
        end

        def columns(executor : Prostore::Adapter::Base::Executor, table : String) : Array(LiveColumn)
          rows = [] of NamedTuple(name: String, data_type: String, is_nullable: String, column_default: String?, is_identity: String)
          executor.query_each(<<-SQL, table) do |rs|
            SELECT column_name, data_type, is_nullable, column_default, is_identity
            FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = $1
            ORDER BY ordinal_position
          SQL
            rows << {
              name:           rs.read(String),
              data_type:      rs.read(String),
              is_nullable:    rs.read(String),
              column_default: rs.read(String?),
              is_identity:    rs.read(String),
            }
          end

          # Resolve primary-key columns separately.
          pk_set = Set(String).new
          executor.query_each(<<-SQL, table) do |rs|
            SELECT a.attname
            FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = ($1::regclass) AND i.indisprimary
          SQL
            pk_set << rs.read(String)
          end

          rows.map do |row|
            LiveColumn.new(
              name: row[:name],
              type_text: row[:data_type],
              nullable: row[:is_nullable] == "YES",
              default_text: row[:column_default],
              primary: pk_set.includes?(row[:name]),
              auto_increment: row[:is_identity] == "YES",
            )
          end
        end

        def indexes(executor : Prostore::Adapter::Base::Executor, table : String) : Array(LiveIndex)
          out = [] of LiveIndex
          executor.query_each(<<-SQL, table) do |rs|
            SELECT i.relname AS index_name, ix.indisunique, am.amname,
                   array_to_string(array(SELECT a.attname FROM pg_attribute a
                                         WHERE a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
                                         ORDER BY array_position(ix.indkey, a.attnum)), ',') AS cols,
                   pg_get_expr(ix.indpred, ix.indrelid) AS predicate,
                   ix.indisprimary
            FROM pg_class t
            JOIN pg_index ix ON ix.indrelid = t.oid
            JOIN pg_class i ON i.oid = ix.indexrelid
            JOIN pg_am am ON am.oid = i.relam
            WHERE t.relname = $1 AND NOT ix.indisprimary
          SQL
            name = rs.read(String)
            uniq = rs.read(Bool)
            _amname = rs.read(String)
            cols_str = rs.read(String)
            predicate = rs.read(String?)
            _pk = rs.read(Bool)

            cols = cols_str.split(',').reject(&.empty?)
            out << LiveIndex.new(
              name: name, columns: cols, unique: uniq, where_sql: predicate,
            )
          end
          out
        end

        def foreign_keys(executor : Prostore::Adapter::Base::Executor, table : String) : Array(LiveForeignKey)
          out = [] of LiveForeignKey
          # Group by constraint name; aggregate src/tgt columns ordered by position.
          constraints = {} of String => {table_name: String, src_cols: Array(String), ref_table: String, tgt_cols: Array(String), on_delete: Symbol, on_update: Symbol}

          executor.query_each(<<-SQL, table) do |rs|
            SELECT tc.constraint_name, tc.table_name,
                   kcu.column_name, ccu.table_name AS ref_table, ccu.column_name AS ref_column,
                   rc.delete_rule, rc.update_rule
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
            JOIN information_schema.referential_constraints rc
              ON tc.constraint_name = rc.constraint_name
            JOIN information_schema.constraint_column_usage ccu
              ON ccu.constraint_name = tc.constraint_name
            WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_name = $1
            ORDER BY kcu.ordinal_position
          SQL
            cname = rs.read(String)
            tname = rs.read(String)
            src_col = rs.read(String)
            ref_table = rs.read(String)
            tgt_col = rs.read(String)
            del_rule = rs.read(String)
            upd_rule = rs.read(String)

            entry = constraints[cname]? ||
                    {table_name: tname, src_cols: [] of String, ref_table: ref_table,
                     tgt_cols: [] of String, on_delete: parse_action(del_rule),
                     on_update: parse_action(upd_rule)}
            entry[:src_cols] << src_col
            entry[:tgt_cols] << tgt_col
            constraints[cname] = entry
          end

          constraints.each do |name, entry|
            out << LiveForeignKey.new(
              name: name,
              columns: entry[:src_cols],
              references_table: entry[:ref_table],
              references_columns: entry[:tgt_cols],
              on_delete: entry[:on_delete],
              on_update: entry[:on_update],
            )
          end
          out
        end

        def table(executor : Prostore::Adapter::Base::Executor, name : String) : LiveTable
          LiveTable.new(
            name: name,
            columns: columns(executor, name),
            indexes: indexes(executor, name),
            foreign_keys: foreign_keys(executor, name),
          )
        end

        private def parse_action(s : String) : Symbol
          case s
          when "NO ACTION"   then :no_action
          when "RESTRICT"    then :restrict
          when "CASCADE"     then :cascade
          when "SET NULL"    then :set_null
          when "SET DEFAULT" then :set_default
          else                    :no_action
          end
        end
      end
    end
  end
end
