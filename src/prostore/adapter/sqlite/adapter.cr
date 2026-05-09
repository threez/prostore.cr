require "db"
require "sqlite3"
require "../base"
require "./types"
require "./ddl"
require "./introspect"

module Prostore
  module Adapter
    module SQLite
      # The SQLite implementation of `Prostore::Adapter::Base`.
      class Adapter < Prostore::Adapter::Base
        # Pragma names whose values may be extracted from the connection URL
        # query string and applied per-connection via session_setup.
        PRAGMA_KEYS = %w[journal_mode synchronous cache_size temp_store]

        def initialize(@db : DB::Database, @pragmas : Hash(String, String) = {} of String => String)
          super(@db)
        end

        def quote_ident(name : String) : String
          DDL.quote_ident(name)
        end

        def quote_string(s : String) : String
          DDL.quote_string(s)
        end

        def render_create_table(definition : Schema::Definition) : String
          render_create_table(definition, build_pk_lookup_for(definition))
        end

        def render_create_table(definition : Schema::Definition,
                                pk_lookup : Hash(String, Array(String))) : String
          DDL.render_create_table(definition, pk_lookup)
        end

        def render_create_index(table : String, index : Schema::Index) : String
          DDL.render_create_index(table, index)
        end

        def introspect_table_names(executor : Executor = @db) : Array(String)
          Introspect.table_names(executor)
        end

        def introspect_table(name : String, executor : Executor = @db) : LiveTable
          Introspect.table(executor, name)
        end

        def session_setup(conn : DB::Connection) : Nil
          conn.exec "PRAGMA foreign_keys = ON"
          @pragmas.each do |key, value|
            conn.exec "PRAGMA #{key} = #{value}"
          end
        end

        def bookkeeping_id_column_def : String
          "INTEGER PRIMARY KEY AUTOINCREMENT"
        end

        def insert_returning_id(executor : Executor, sql : String, *args) : Int64
          executor.exec(sql, *args)
          executor.scalar("SELECT last_insert_rowid()").as(Int64)
        end

        def insert_returning_id(executor : Executor, sql : String, args : Array) : Int64
          executor.exec(sql, args: args)
          executor.scalar("SELECT last_insert_rowid()").as(Int64)
        end

        def placeholder(n : Int32) : String
          "?"
        end

        private def build_pk_lookup_for(definition : Schema::Definition) : Hash(String, Array(String))
          h = {} of String => Array(String)
          if pk = definition.primary_key
            h[definition.table_name] = [pk.name.to_s]
          end
          h
        end
      end
    end
  end
end
