require "json"
require "../adapter/base"
require "../schema"
require "../migration/bookkeeping"

module Prostore
  module Drift
    # CRUD for the `prostore_schema` bookkeeping table (ADR-0010).
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
        definition : String

      KIND_COLUMN      = "column"
      KIND_INDEX       = "index"
      KIND_FOREIGN_KEY = "foreign_key"

      # ---- read -------------------------------------------------------------

      def all(adapter : Prostore::Adapter::Base,
              executor : Prostore::Adapter::Base::Executor) : Array(Row)
        rows = [] of Row
        executor.query_each(
          "SELECT table_name, kind, tag, current_name, definition FROM " \
          "#{adapter.quote_ident(Migration::Bookkeeping::SCHEMA_TABLE)} " \
          "ORDER BY table_name, kind, tag"
        ) do |rs|
          rows << Row.new(
            table_name: rs.read(String),
            kind: rs.read(String),
            tag: rs.read(Int32),
            current_name: rs.read(String),
            definition: rs.read(String),
          )
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
          definition: encode_field(field),
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
          definition: encode_index(index),
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
          definition: encode_foreign_key(fk),
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

      private def upsert(adapter : Prostore::Adapter::Base,
                         executor : Prostore::Adapter::Base::Executor,
                         row : Row) : Nil
        sql = <<-SQL
          INSERT INTO #{adapter.quote_ident(Migration::Bookkeeping::SCHEMA_TABLE)}
            (table_name, kind, tag, current_name, definition)
          VALUES (#{adapter.placeholders(5)})
          ON CONFLICT (table_name, kind, tag) DO UPDATE SET
            current_name = excluded.current_name,
            definition   = excluded.definition
        SQL
        executor.exec(sql, row.table_name, row.kind, row.tag, row.current_name, row.definition)
      end

      private def encode_field(f : Schema::Field) : String
        {
          portable_type:  f.portable_type.to_s,
          nullable:       f.nullable,
          primary:        f.primary,
          auto_increment: f.auto_increment,
          has_default:    f.has_default,
          default_sql:    f.default_sql,
          has_backfill:   f.has_backfill,
          backfill_sql:   f.backfill_sql,
          has_lazy:       f.has_lazy,
        }.to_json
      end

      private def encode_index(i : Schema::Index) : String
        {
          columns:   i.columns.map(&.to_s),
          unique:    i.unique,
          where_sql: i.where_sql,
        }.to_json
      end

      private def encode_foreign_key(fk : Schema::ForeignKey) : String
        {
          columns:            fk.columns.map(&.to_s),
          references_table:   fk.references_table,
          references_columns: fk.references_columns.map(&.to_s),
          on_delete:          fk.on_delete.to_s,
          on_update:          fk.on_update.to_s,
        }.to_json
      end
    end
  end
end
