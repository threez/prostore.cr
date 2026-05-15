require "db"
require "../connection"
require "../adapter/live_state"
require "../migration/bookkeeping"

module Prostore
  module TUI
    # All row values are returned as String? (nil preserved, everything else
    # stringified). This sidesteps the PG vs SQLite DB::Any union mismatch and
    # is perfectly fine for a display/edit TUI.
    alias RowVal = String?
    alias Row = Array(RowVal)

    # A WHERE-fragment built from a search term applied across one or more
    # text columns: `col1 LIKE '%term%' OR col2 LIKE '%term%' OR …`.
    # Held as plain values so Browser can compose them into both COUNT and
    # SELECT statements while still using parameterised placeholders.
    record Filter, term : String, columns : Array(String)

    class Browser
      def initialize(@conn : Connection)
      end

      def tables : Array(String)
        @conn.adapter.introspect_table_names
      end

      def schema(table : String) : Adapter::LiveTable
        @conn.adapter.introspect_table(table)
      end

      def count(table : String, filter : Filter? = nil) : Int64
        qt = @conn.adapter.quote_ident(table)
        where_sql, args = build_filter_where(filter)
        sql = "SELECT COUNT(*) FROM #{qt}#{where_sql}"
        if args.empty?
          @conn.scalar(sql).as(Int64)
        else
          @conn.scalar(sql, args: args).as(Int64)
        end
      end

      # Returns column names and rows. Values are String or nil.
      def fetch_rows(table : String, limit : Int32, offset : Int32,
                     filter : Filter? = nil) : Tuple(Array(String), Array(Row))
        qt = @conn.adapter.quote_ident(table)
        where_sql, args = build_filter_where(filter)
        ph_limit = @conn.adapter.placeholder(args.size + 1)
        ph_offset = @conn.adapter.placeholder(args.size + 2)
        sql = "SELECT * FROM #{qt}#{where_sql} LIMIT #{ph_limit} OFFSET #{ph_offset}"
        all_args = args + [limit.as(::DB::Any), offset.as(::DB::Any)]

        col_names = [] of String
        rows = [] of Row

        @conn.with_connection do |db_conn|
          db_conn.query(sql, args: all_args) do |rs|
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
        qt = @conn.adapter.quote_ident(table)
        qpk = @conn.adapter.quote_ident(pk_col)
        ph = @conn.adapter.placeholder(1)
        sql = "SELECT * FROM #{qt} WHERE #{qpk} = #{ph} LIMIT 1"
        result = nil.as(Hash(String, RowVal)?)

        @conn.with_connection do |db_conn|
          db_conn.query(sql, pk_val) do |rs|
            names = rs.column_names
            rs.each do
              row = {} of String => RowVal
              names.each do |name|
                v = rs.read
                row[name] = v.nil? ? nil : v.to_s
              end
              result = row
            end
          end
        end

        result
      end

      # `data` values may be nil to bind explicit NULL.  Columns the caller
      # wants the database default for should simply be omitted from `data`.
      def insert_row(table : String, data : Hash(String, String?)) : Nil
        return if data.empty?
        qt = @conn.adapter.quote_ident(table)
        cols = data.keys.map { |k| @conn.adapter.quote_ident(k) }.join(", ")
        phs = (1..data.size).map { |idx| @conn.adapter.placeholder(idx) }.join(", ")
        sql = "INSERT INTO #{qt} (#{cols}) VALUES (#{phs})"
        @conn.exec(sql, args: data.values.map(&.as(::DB::Any)))
      end

      def update_cell(table : String, pk_col : String, pk_val : String,
                      column : String, value : String?) : Nil
        qt = @conn.adapter.quote_ident(table)
        qcol = @conn.adapter.quote_ident(column)
        qpk = @conn.adapter.quote_ident(pk_col)
        ph1 = @conn.adapter.placeholder(1)
        ph2 = @conn.adapter.placeholder(2)
        sql = "UPDATE #{qt} SET #{qcol} = #{ph1} WHERE #{qpk} = #{ph2}"
        @conn.exec(sql, args: [value.as(::DB::Any), pk_val.as(::DB::Any)])
      end

      def delete_row(table : String, pk_col : String, pk_val : String) : Nil
        qt = @conn.adapter.quote_ident(table)
        qpk = @conn.adapter.quote_ident(pk_col)
        ph = @conn.adapter.placeholder(1)
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
        qt = @conn.adapter.quote_ident(Migration::Bookkeeping::SCHEMA_TABLE)
        ph1 = @conn.adapter.placeholder(1)
        ph2 = @conn.adapter.placeholder(2)
        sql = "SELECT current_name, portable_type FROM #{qt} " \
              "WHERE table_name = #{ph1} AND kind = #{ph2}"
        @conn.with_connection do |db_conn|
          db_conn.query_each(sql, table, Drift::SchemaTable::KIND_COLUMN) do |rs|
            name = rs.read(String)
            pt = rs.read(String?)
            result[name] = pt if pt
          end
        end
        result
      rescue
        {} of String => String
      end

      # Builds the ` WHERE …` fragment (leading space included) and the
      # corresponding ordered argument list for a filter, or `{"", []}` when
      # the filter is nil / blank / has no columns to match against.
      private def build_filter_where(filter : Filter?) : Tuple(String, Array(::DB::Any))
        empty = {"", [] of ::DB::Any}
        return empty unless filter
        return empty if filter.term.empty? || filter.columns.empty?

        like = @conn.adapter.like_operator
        pattern = "%#{filter.term}%"
        clauses = filter.columns.map_with_index do |col, i|
          "#{@conn.adapter.quote_ident(col)} #{like} #{@conn.adapter.placeholder(i + 1)}"
        end
        args = Array(::DB::Any).new(filter.columns.size, pattern)
        {" WHERE #{clauses.join(" OR ")}", args}
      end
    end
  end
end
