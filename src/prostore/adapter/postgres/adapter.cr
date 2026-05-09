require "db"
require "pg"
require "../base"
require "./types"
require "./ddl"
require "./introspect"

module Prostore
  module Adapter
    module Postgres
      # PostgreSQL adapter (ADR-0007).
      #
      # Mirrors `Adapter::SQLite::Adapter` but emits Postgres-idiomatic DDL
      # and supports native ALTER TABLE extensions that SQLite lacks
      # (ALTER COLUMN SET NOT NULL, ALTER TABLE ADD CONSTRAINT FOREIGN KEY,
      # CREATE INDEX CONCURRENTLY).
      #
      # Capability flags below tell the planner which operations the adapter
      # can do natively. ApplyNotNull and AddForeignKey/DropForeignKey honor
      # these and avoid the SQLite table-rebuild dance.
      class Adapter < Prostore::Adapter::Base
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

        # Postgres supports native ALTER COLUMN SET NOT NULL.
        def supports_alter_set_not_null? : Bool
          true
        end

        # CREATE INDEX CONCURRENTLY runs outside a transaction and avoids
        # holding an exclusive lock — required for online index creation
        # against large production tables. The Steps executor consults this
        # flag to skip the transaction wrapper and route through the
        # recovery-aware concurrent path.
        def supports_concurrent_index? : Bool
          true
        end

        # Postgres supports ADD CONSTRAINT NOT VALID + VALIDATE CONSTRAINT
        # for online FK addition. Same caveat as concurrent_index — the
        # planner can adopt this in a future revision.
        def supports_add_constraint_not_valid? : Bool
          true
        end

        # No per-connection session setup required for Postgres beyond
        # what crystal-pg sets up (utf8 client encoding, etc.).
        def session_setup(conn : DB::Connection) : Nil
        end

        def bookkeeping_id_column_def : String
          "BIGSERIAL PRIMARY KEY"
        end

        def insert_returning_id(executor : Executor, sql : String, *args) : Int64
          executor.scalar(sql + " RETURNING id", *args).as(Int64)
        end

        def insert_returning_id(executor : Executor, sql : String, args : Array) : Int64
          executor.scalar(sql + " RETURNING id", args: args).as(Int64)
        end

        def placeholder(n : Int32) : String
          "$#{n}"
        end

        private def build_pk_lookup_for(definition : Schema::Definition) : Hash(String, Array(String))
          h = {} of String => Array(String)
          if pk = definition.primary_key
            h[definition.table_name] = [pk.name]
          end
          h
        end
      end
    end
  end
end
