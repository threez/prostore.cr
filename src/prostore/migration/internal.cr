require "json"
require "../adapter/base"
require "../error"
require "./bookkeeping"
require "./state"

module Prostore
  module Migration
    # Internal-schema version tracking and stepwise upgrades for prostore's
    # own bookkeeping tables.
    #
    # Why this exists: prostore's `prostore_*` tables are managed by the
    # library itself, not by user-authored migrations. When their layout
    # changes between library versions (e.g., v2 lifts `prostore_schema`'s
    # JSON `definition` into typed columns) we need a controlled,
    # idempotent upgrade path against existing installs.
    #
    # `Migration::Runner` calls `Internal.run` at the top of the bootstrap
    # path, before `Bookkeeping.ensure_tables` and before any user-migration
    # work. The `prostore_meta` row `schema_version` tracks the applied
    # version; this module owns its read/write.
    module Internal
      extend self

      CURRENT_SCHEMA_VERSION = 2

      alias Step = Proc(Prostore::Adapter::Base, Prostore::Adapter::Base::Executor, Nil)

      def steps : Hash(Int32, Step)
        {
          2 => ->(adapter : Prostore::Adapter::Base, executor : Prostore::Adapter::Base::Executor) do
            split_definitions(adapter, executor)
          end,
        } of Int32 => Step
      end

      # Entry point. Always ensures `prostore_meta` exists, detects the
      # current version, then applies any pending step in ascending order.
      # Raises if user migrations are in flight (see `refuse_if_in_flight!`).
      def run(adapter : Prostore::Adapter::Base,
              executor : Prostore::Adapter::Base::Executor) : Nil
        ensure_meta_table(adapter, executor)
        current = detect_current_version(adapter, executor)

        pending = steps.keys.select { |v| v > current }.sort!
        if pending.empty?
          # Still seed the version row on first contact so subsequent runs
          # short-circuit via the read path instead of re-introspecting.
          write_version(adapter, executor, current) if read_version(adapter, executor).nil?
          return
        end

        refuse_if_in_flight!(adapter, executor)

        pending.each do |version|
          steps[version].call(adapter, executor)
          write_version(adapter, executor, version)
        end
      end

      # Returns the version the database is currently at. If `prostore_meta`
      # holds an explicit `schema_version`, that is authoritative. Otherwise
      # the layout of the legacy `prostore_schema` table tells us whether
      # we are at v1 (has a `definition` column) or already at the current
      # version (table absent or has the new shape).
      def detect_current_version(adapter : Prostore::Adapter::Base,
                                 executor : Prostore::Adapter::Base::Executor) : Int32
        stored = read_version(adapter, executor)
        return stored if stored

        if legacy_schema_table?(adapter, executor)
          1
        else
          CURRENT_SCHEMA_VERSION
        end
      end

      private def ensure_meta_table(adapter, executor) : Nil
        executor.exec(Bookkeeping.create_meta_sql(adapter))
      end

      private def read_version(adapter, executor) : Int32?
        sql = "SELECT value FROM #{adapter.quote_ident(Bookkeeping::META_TABLE)} " \
              "WHERE key = #{adapter.placeholder(1)}"
        raw : String? = nil
        executor.query_each(sql, "schema_version") do |rs|
          raw = rs.read(String)
        end
        raw.try(&.to_i32?)
      end

      private def write_version(adapter, executor, version : Int32) : Nil
        sql = <<-SQL
          INSERT INTO #{adapter.quote_ident(Bookkeeping::META_TABLE)} (key, value, updated_at)
          VALUES (#{adapter.placeholders(3)})
          ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
        SQL
        executor.exec(sql, "schema_version", version.to_s, Time.utc.to_rfc3339)
      end

      private def legacy_schema_table?(adapter, executor) : Bool
        return false unless adapter.introspect_table_names(executor).includes?(Bookkeeping::SCHEMA_TABLE)
        live = adapter.introspect_table(Bookkeeping::SCHEMA_TABLE, executor)
        live.columns.any? { |col| col.name == "definition" }
      end

      private def refuse_if_in_flight!(adapter, executor) : Nil
        # prostore_migration may not exist yet on a brand-new install.
        return unless adapter.introspect_table_names(executor).includes?(Bookkeeping::MIGRATION_TABLE)

        active = executor.scalar(
          "SELECT COUNT(*) FROM #{adapter.quote_ident(Bookkeeping::MIGRATION_TABLE)} " \
          "WHERE status IN (#{adapter.placeholders(2)})",
          State::MIGRATION_PENDING, State::MIGRATION_RUNNING
        )
        count = case active
                when Int64 then active
                when Int32 then active.to_i64
                else            0_i64
                end
        return if count == 0

        raise Prostore::MigrationError.new(
          "Cannot upgrade prostore internal schema while a user migration is in flight " \
          "(#{count} pending/running row(s) in #{Bookkeeping::MIGRATION_TABLE}). " \
          "Complete or abort the in-flight migration first, then retry."
        )
      end

      # ---- v2 step ----------------------------------------------------------
      # Lifts the JSON `definition` column on `prostore_schema` into typed
      # per-kind columns. Idempotent: if the legacy column is already gone
      # (e.g., partially applied earlier and recovered, or running against a
      # fresh install with the new shape), this is a no-op.

      private NEW_COLUMNS = [
        {"portable_type", "TEXT"},
        {"nullable", "INTEGER"},
        {"is_primary", "INTEGER"},
        {"auto_increment", "INTEGER"},
        {"has_default", "INTEGER"},
        {"default_sql", "TEXT"},
        {"has_backfill", "INTEGER"},
        {"backfill_sql", "TEXT"},
        {"has_lazy", "INTEGER"},
        {"index_columns", "TEXT"},
        {"index_unique", "INTEGER"},
        {"index_where_sql", "TEXT"},
        {"fk_columns", "TEXT"},
        {"fk_references_table", "TEXT"},
        {"fk_references_columns", "TEXT"},
        {"fk_on_delete", "TEXT"},
        {"fk_on_update", "TEXT"},
      ]

      private def split_definitions(adapter, executor) : Nil
        return unless legacy_schema_table?(adapter, executor)

        qt = adapter.quote_ident(Bookkeeping::SCHEMA_TABLE)

        NEW_COLUMNS.each do |(name, type)|
          executor.exec("ALTER TABLE #{qt} ADD COLUMN #{name} #{type}")
        end

        legacy = [] of {String, String, Int32, String}
        executor.query_each("SELECT table_name, kind, tag, definition FROM #{qt}") do |rs|
          legacy << {rs.read(String), rs.read(String), rs.read(Int32), rs.read(String)}
        end

        legacy.each do |(table_name, kind, tag, defn)|
          parsed = JSON.parse(defn)
          case kind
          when "column"
            update_column_row(adapter, executor, table_name, kind, tag, parsed)
          when "index"
            update_index_row(adapter, executor, table_name, kind, tag, parsed)
          when "foreign_key"
            update_foreign_key_row(adapter, executor, table_name, kind, tag, parsed)
          else
            raise Prostore::MigrationError.new(
              "Unknown prostore_schema kind '#{kind}' during internal v2 migration"
            )
          end
        end

        executor.exec("ALTER TABLE #{qt} DROP COLUMN definition")
      end

      private def update_column_row(adapter, executor,
                                    table_name : String, kind : String, tag : Int32,
                                    parsed : JSON::Any) : Nil
        qt = adapter.quote_ident(Bookkeeping::SCHEMA_TABLE)
        sql = <<-SQL
          UPDATE #{qt} SET
            portable_type  = #{adapter.placeholder(1)},
            nullable       = #{adapter.placeholder(2)},
            is_primary     = #{adapter.placeholder(3)},
            auto_increment = #{adapter.placeholder(4)},
            has_default    = #{adapter.placeholder(5)},
            default_sql    = #{adapter.placeholder(6)},
            has_backfill   = #{adapter.placeholder(7)},
            backfill_sql   = #{adapter.placeholder(8)},
            has_lazy       = #{adapter.placeholder(9)}
          WHERE table_name = #{adapter.placeholder(10)}
            AND kind = #{adapter.placeholder(11)}
            AND tag  = #{adapter.placeholder(12)}
        SQL
        executor.exec(
          sql,
          args: [
            json_string(parsed["portable_type"]?).as(::DB::Any),
            json_bool_int(parsed["nullable"]?).as(::DB::Any),
            json_bool_int(parsed["primary"]?).as(::DB::Any),
            json_bool_int(parsed["auto_increment"]?).as(::DB::Any),
            json_bool_int(parsed["has_default"]?).as(::DB::Any),
            json_string(parsed["default_sql"]?).as(::DB::Any),
            json_bool_int(parsed["has_backfill"]?).as(::DB::Any),
            json_string(parsed["backfill_sql"]?).as(::DB::Any),
            json_bool_int(parsed["has_lazy"]?).as(::DB::Any),
            table_name.as(::DB::Any),
            kind.as(::DB::Any),
            tag.as(::DB::Any),
          ]
        )
      end

      private def update_index_row(adapter, executor,
                                   table_name : String, kind : String, tag : Int32,
                                   parsed : JSON::Any) : Nil
        qt = adapter.quote_ident(Bookkeeping::SCHEMA_TABLE)
        cols = json_string_array(parsed["columns"]?)
        sql = <<-SQL
          UPDATE #{qt} SET
            index_columns   = #{adapter.placeholder(1)},
            index_unique    = #{adapter.placeholder(2)},
            index_where_sql = #{adapter.placeholder(3)}
          WHERE table_name = #{adapter.placeholder(4)}
            AND kind = #{adapter.placeholder(5)}
            AND tag  = #{adapter.placeholder(6)}
        SQL
        executor.exec(
          sql,
          args: [
            cols.to_json.as(::DB::Any),
            json_bool_int(parsed["unique"]?).as(::DB::Any),
            json_string(parsed["where_sql"]?).as(::DB::Any),
            table_name.as(::DB::Any),
            kind.as(::DB::Any),
            tag.as(::DB::Any),
          ]
        )
      end

      private def update_foreign_key_row(adapter, executor,
                                         table_name : String, kind : String, tag : Int32,
                                         parsed : JSON::Any) : Nil
        qt = adapter.quote_ident(Bookkeeping::SCHEMA_TABLE)
        cols = json_string_array(parsed["columns"]?)
        refs = json_string_array(parsed["references_columns"]?)
        sql = <<-SQL
          UPDATE #{qt} SET
            fk_columns            = #{adapter.placeholder(1)},
            fk_references_table   = #{adapter.placeholder(2)},
            fk_references_columns = #{adapter.placeholder(3)},
            fk_on_delete          = #{adapter.placeholder(4)},
            fk_on_update          = #{adapter.placeholder(5)}
          WHERE table_name = #{adapter.placeholder(6)}
            AND kind = #{adapter.placeholder(7)}
            AND tag  = #{adapter.placeholder(8)}
        SQL
        executor.exec(
          sql,
          args: [
            cols.to_json.as(::DB::Any),
            json_string(parsed["references_table"]?).as(::DB::Any),
            refs.to_json.as(::DB::Any),
            json_string(parsed["on_delete"]?).as(::DB::Any),
            json_string(parsed["on_update"]?).as(::DB::Any),
            table_name.as(::DB::Any),
            kind.as(::DB::Any),
            tag.as(::DB::Any),
          ]
        )
      end

      private def json_string(value : JSON::Any?) : String?
        return nil if value.nil?
        value.as_s?
      end

      private def json_bool_int(value : JSON::Any?) : Int32?
        return nil if value.nil?
        b = value.as_bool?
        return nil if b.nil?
        b ? 1 : 0
      end

      private def json_string_array(value : JSON::Any?) : Array(String)
        return [] of String if value.nil?
        arr = value.as_a?
        return [] of String if arr.nil?
        arr.compact_map(&.as_s?)
      end
    end
  end
end
