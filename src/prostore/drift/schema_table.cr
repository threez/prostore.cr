require "json"
require "../adapter/base"
require "../schema"
require "../migration/bookkeeping"

module Prostore
  module Drift
    # CRUD for the `prostore_schema` bookkeeping table (ADR-0010).
    #
    # The metadata used to live in a single `definition` JSON column. As of
    # internal schema version 2 it is promoted to typed columns; only the
    # three small identifier arrays (index columns, FK source/target columns)
    # remain JSON-encoded because neither SQLite nor Postgres expose a
    # portable native array type that fits a single-table layout.
    #
    # All operations run on a caller-supplied executor (DB::Database,
    # DB::Connection, or DB::Transaction).
    module SchemaTable
      extend self

      record Row,
        table_name : String,
        kind : String,
        tag : Int32,
        current_name : String,
        # KIND_COLUMN
        portable_type : String? = nil,
        nullable : Bool? = nil,
        primary : Bool? = nil,
        auto_increment : Bool? = nil,
        has_default : Bool? = nil,
        default_sql : String? = nil,
        has_backfill : Bool? = nil,
        backfill_sql : String? = nil,
        has_lazy : Bool? = nil,
        enum_members : Array(Schema::EnumMember)? = nil,
        enum_is_flags : Bool? = nil,
        # KIND_INDEX
        index_columns : Array(String)? = nil,
        index_unique : Bool? = nil,
        index_where_sql : String? = nil,
        # KIND_FOREIGN_KEY
        fk_columns : Array(String)? = nil,
        fk_references_table : String? = nil,
        fk_references_columns : Array(String)? = nil,
        fk_on_delete : String? = nil,
        fk_on_update : String? = nil

      KIND_COLUMN      = "column"
      KIND_INDEX       = "index"
      KIND_FOREIGN_KEY = "foreign_key"

      COLUMNS = %w[
        table_name kind tag current_name
        portable_type nullable is_primary auto_increment
        has_default default_sql has_backfill backfill_sql has_lazy
        enum_members enum_is_flags
        index_columns index_unique index_where_sql
        fk_columns fk_references_table fk_references_columns fk_on_delete fk_on_update
      ]

      private SELECT_LIST = COLUMNS.join(", ")

      # ---- read -------------------------------------------------------------

      def all(adapter : Prostore::Adapter::Base,
              executor : Prostore::Adapter::Base::Executor) : Array(Row)
        rows = [] of Row
        executor.query_each(
          "SELECT #{SELECT_LIST} FROM " \
          "#{adapter.quote_ident(Migration::Bookkeeping::SCHEMA_TABLE)} " \
          "ORDER BY table_name, kind, tag"
        ) do |rs|
          rows << read_row(rs)
        end
        rows
      end

      def for_table(adapter : Prostore::Adapter::Base,
                    executor : Prostore::Adapter::Base::Executor,
                    table : String) : Array(Row)
        all(adapter, executor).select { |row| row.table_name == table }
      end

      # ---- write ------------------------------------------------------------

      def upsert_field(adapter : Prostore::Adapter::Base,
                       executor : Prostore::Adapter::Base::Executor,
                       table : String, field : Schema::Field) : Nil
        upsert(adapter, executor, Row.new(
          table_name: table,
          kind: KIND_COLUMN,
          tag: field.tag,
          current_name: field.name.to_s,
          portable_type: field.portable_type.to_s,
          nullable: field.nullable,
          primary: field.primary,
          auto_increment: field.auto_increment,
          has_default: field.has_default,
          default_sql: field.default_sql,
          has_backfill: field.has_backfill,
          backfill_sql: field.backfill_sql,
          has_lazy: field.has_lazy,
          enum_members: field.enum_members,
          enum_is_flags: field.enum_members.nil? ? nil : field.enum_is_flags,
        ))
      end

      def upsert_index(adapter : Prostore::Adapter::Base,
                       executor : Prostore::Adapter::Base::Executor,
                       table : String, index : Schema::Index) : Nil
        upsert(adapter, executor, Row.new(
          table_name: table,
          kind: KIND_INDEX,
          tag: index.tag,
          current_name: index.name,
          index_columns: index.columns.map(&.to_s),
          index_unique: index.unique,
          index_where_sql: index.where_sql,
        ))
      end

      def upsert_foreign_key(adapter : Prostore::Adapter::Base,
                             executor : Prostore::Adapter::Base::Executor,
                             table : String, fk : Schema::ForeignKey) : Nil
        upsert(adapter, executor, Row.new(
          table_name: table,
          kind: KIND_FOREIGN_KEY,
          tag: fk.tag,
          current_name: fk.name,
          fk_columns: fk.columns.map(&.to_s),
          fk_references_table: fk.references_table,
          fk_references_columns: fk.references_columns.map(&.to_s),
          fk_on_delete: fk.on_delete.to_s,
          fk_on_update: fk.on_update.to_s,
        ))
      end

      def delete(adapter : Prostore::Adapter::Base,
                 executor : Prostore::Adapter::Base::Executor,
                 table : String, kind : String, tag : Int32) : Nil
        executor.exec(
          "DELETE FROM #{adapter.quote_ident(Migration::Bookkeeping::SCHEMA_TABLE)} " \
          "WHERE table_name = #{adapter.placeholder(1)} AND " \
          "kind = #{adapter.placeholder(2)} AND tag = #{adapter.placeholder(3)}",
          table, kind, tag,
        )
      end

      # ---- internals --------------------------------------------------------

      private def read_row(rs : DB::ResultSet) : Row
        Row.new(
          table_name: rs.read(String),
          kind: rs.read(String),
          tag: rs.read(Int32),
          current_name: rs.read(String),
          portable_type: rs.read(String?),
          nullable: read_bool(rs),
          primary: read_bool(rs),
          auto_increment: read_bool(rs),
          has_default: read_bool(rs),
          default_sql: rs.read(String?),
          has_backfill: read_bool(rs),
          backfill_sql: rs.read(String?),
          has_lazy: read_bool(rs),
          enum_members: read_enum_members(rs),
          enum_is_flags: read_bool(rs),
          index_columns: read_string_array(rs),
          index_unique: read_bool(rs),
          index_where_sql: rs.read(String?),
          fk_columns: read_string_array(rs),
          fk_references_table: rs.read(String?),
          fk_references_columns: read_string_array(rs),
          fk_on_delete: rs.read(String?),
          fk_on_update: rs.read(String?),
        )
      end

      private def read_bool(rs : DB::ResultSet) : Bool?
        case raw = rs.read
        when Nil  then nil
        when Bool then raw
        when Int  then raw != 0
        when Char then raw != '0'
        else
          raise "unexpected bool encoding: #{raw.class} #{raw.inspect}"
        end
      end

      private def read_string_array(rs : DB::ResultSet) : Array(String)?
        raw = rs.read(String?)
        return nil if raw.nil?
        Array(String).from_json(raw)
      end

      # Enum members are JSON-encoded as `[[name, value], ...]` — a compact
      # form (vs. the typed record's `[{"name":..,"value":..}, ...]`) keeps
      # the bookkeeping row small and avoids a JSON::Serializable dependency
      # on the schema record. Decode mirrors that shape.
      private def read_enum_members(rs : DB::ResultSet) : Array(Schema::EnumMember)?
        raw = rs.read(String?)
        return nil if raw.nil?
        parsed = JSON.parse(raw)
        arr = parsed.as_a?
        return nil if arr.nil?
        arr.compact_map do |entry|
          pair = entry.as_a?
          next nil if pair.nil? || pair.size != 2
          name = pair[0].as_s?
          val = pair[1].as_i64?
          next nil if name.nil? || val.nil?
          Schema::EnumMember.new(name: name, value: val)
        end
      end

      private def upsert(adapter : Prostore::Adapter::Base,
                         executor : Prostore::Adapter::Base::Executor,
                         row : Row) : Nil
        cols = COLUMNS
        placeholders = (1..cols.size).map { |i| adapter.placeholder(i) }.join(", ")
        assignments = cols[4..].map { |col| "#{col} = excluded.#{col}" }.join(", ")

        sql = <<-SQL
          INSERT INTO #{adapter.quote_ident(Migration::Bookkeeping::SCHEMA_TABLE)}
            (#{cols.join(", ")})
          VALUES (#{placeholders})
          ON CONFLICT (table_name, kind, tag) DO UPDATE SET
            #{assignments}
        SQL

        executor.exec(sql, args: row_values(row))
      end

      private def row_values(row : Row) : Array(::DB::Any)
        [
          row.table_name.as(::DB::Any),
          row.kind.as(::DB::Any),
          row.tag.as(::DB::Any),
          row.current_name.as(::DB::Any),
          row.portable_type.as(::DB::Any),
          bool_to_db(row.nullable),
          bool_to_db(row.primary),
          bool_to_db(row.auto_increment),
          bool_to_db(row.has_default),
          row.default_sql.as(::DB::Any),
          bool_to_db(row.has_backfill),
          row.backfill_sql.as(::DB::Any),
          bool_to_db(row.has_lazy),
          encode_enum_members(row.enum_members),
          bool_to_db(row.enum_is_flags),
          encode_string_array(row.index_columns),
          bool_to_db(row.index_unique),
          row.index_where_sql.as(::DB::Any),
          encode_string_array(row.fk_columns),
          row.fk_references_table.as(::DB::Any),
          encode_string_array(row.fk_references_columns),
          row.fk_on_delete.as(::DB::Any),
          row.fk_on_update.as(::DB::Any),
        ]
      end

      private def bool_to_db(value : Bool?) : ::DB::Any
        return nil if value.nil?
        (value ? 1 : 0).as(::DB::Any)
      end

      private def encode_string_array(value : Array(String)?) : ::DB::Any
        return nil if value.nil?
        value.to_json.as(::DB::Any)
      end

      private def encode_enum_members(value : Array(Schema::EnumMember)?) : ::DB::Any
        return nil if value.nil?
        JSON.build do |json|
          json.array do
            value.each do |member|
              json.array do
                json.string member.name
                json.number member.value
              end
            end
          end
        end.as(::DB::Any)
      end
    end
  end
end
