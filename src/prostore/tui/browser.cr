require "db"
require "json"
require "../connection"
require "../adapter/live_state"
require "../migration/bookkeeping"

module Prostore
  module TUI
    # All row values are returned as String? (nil preserved, everything else
    # stringified). This sidesteps the PG vs SQLite DB::Any union mismatch and
    # is perfectly fine for a display/edit TUI.
    alias RowVal = String?
    alias Row    = Array(RowVal)

    class Browser
      def initialize(@conn : Connection)
      end

      def tables : Array(String)
        @conn.adapter.introspect_table_names
      end

      def schema(table : String) : Adapter::LiveTable
        @conn.adapter.introspect_table(table)
      end

      def count(table : String) : Int64
        qt = @conn.adapter.quote_ident(table)
        @conn.scalar("SELECT COUNT(*) FROM #{qt}").as(Int64)
      end

      # Returns column names and rows. Values are String or nil.
      def fetch_rows(table : String, limit : Int32, offset : Int32) : Tuple(Array(String), Array(Row))
        qt = @conn.adapter.quote_ident(table)
        ph_limit  = @conn.adapter.placeholder(1)
        ph_offset = @conn.adapter.placeholder(2)
        sql = "SELECT * FROM #{qt} LIMIT #{ph_limit} OFFSET #{ph_offset}"

        col_names = [] of String
        rows = [] of Row

        @conn.with_connection do |db_conn|
          db_conn.query(sql, limit, offset) do |rs|
            col_names = rs.column_names
            rs.each do
              row = Row.new(rs.column_count)
              rs.column_count.times do
                v = rs.read
                row << (v.nil? ? nil : v.to_s)
              end
              rows << row
            end
          end
        end

        {col_names, rows}
      end

      # Fetch a single row by its primary key value.
      def fetch_row(table : String, pk_col : String, pk_val : String) : Hash(String, RowVal)?
        qt  = @conn.adapter.quote_ident(table)
        qpk = @conn.adapter.quote_ident(pk_col)
        ph  = @conn.adapter.placeholder(1)
        sql = "SELECT * FROM #{qt} WHERE #{qpk} = #{ph} LIMIT 1"
        result = nil.as(Hash(String, RowVal)?)

        @conn.with_connection do |db_conn|
          db_conn.query(sql, pk_val) do |rs|
            names = rs.column_names
            rs.each do
              row = {} of String => RowVal
              names.each do |n|
                v = rs.read
                row[n] = v.nil? ? nil : v.to_s
              end
              result = row
            end
          end
        end

        result
      end

      def insert_row(table : String, data : Hash(String, String)) : Nil
        return if data.empty?
        qt   = @conn.adapter.quote_ident(table)
        cols = data.keys.map { |k| @conn.adapter.quote_ident(k) }.join(", ")
        phs  = (1..data.size).map { |n| @conn.adapter.placeholder(n) }.join(", ")
        sql  = "INSERT INTO #{qt} (#{cols}) VALUES (#{phs})"
        @conn.exec(sql, args: data.values)
      end

      def update_cell(table : String, pk_col : String, pk_val : String,
                      column : String, value : String) : Nil
        qt   = @conn.adapter.quote_ident(table)
        qcol = @conn.adapter.quote_ident(column)
        qpk  = @conn.adapter.quote_ident(pk_col)
        ph1  = @conn.adapter.placeholder(1)
        ph2  = @conn.adapter.placeholder(2)
        sql  = "UPDATE #{qt} SET #{qcol} = #{ph1} WHERE #{qpk} = #{ph2}"
        @conn.exec(sql, args: [value, pk_val])
      end

      def delete_row(table : String, pk_col : String, pk_val : String) : Nil
        qt  = @conn.adapter.quote_ident(table)
        qpk = @conn.adapter.quote_ident(pk_col)
        ph  = @conn.adapter.placeholder(1)
        sql = "DELETE FROM #{qt} WHERE #{qpk} = #{ph}"
        @conn.exec(sql, args: [pk_val])
      end

      # Returns the primary key column name, or nil if none found.
      def pk_col(table : String) : String?
        live = schema(table)
        pk = live.columns.find(&.primary)
        pk ? pk.name : nil
      end

      # Returns prostore portable type tags keyed by column name, read from the
      # prostore_schema bookkeeping table. Returns an empty hash if the table
      # doesn't exist (database not managed by prostore — caller should fall
      # back to SQL type_text inference).
      def portable_types(table : String) : Hash(String, String)
        result = {} of String => String
        qt  = @conn.adapter.quote_ident(Migration::Bookkeeping::SCHEMA_TABLE)
        ph1 = @conn.adapter.placeholder(1)
        ph2 = @conn.adapter.placeholder(2)
        sql = "SELECT current_name, definition FROM #{qt} " \
              "WHERE table_name = #{ph1} AND kind = #{ph2}"
        @conn.with_connection do |db_conn|
          db_conn.query_each(sql, table, Drift::SchemaTable::KIND_COLUMN) do |rs|
            name = rs.read(String)
            defn = rs.read(String)
            parsed = JSON.parse(defn)
            if pt = parsed["portable_type"]?.try(&.as_s?)
              result[name] = pt
            end
          end
        end
        result
      rescue
        {} of String => String
      end
    end
  end
end
