require "../adapter/base"

module Prostore
  module Migration
    # Bootstrap the four `prostore_*` bookkeeping tables (ADR-0009, ADR-0010).
    #
    # All operations run on a caller-supplied executor (DB::Database,
    # DB::Connection, or DB::Transaction) so the migration runner can pin
    # everything to a single checked-out connection (avoiding pool deadlock).
    module Bookkeeping
      extend self

      MIGRATION_TABLE      = "prostore_migration"
      MIGRATION_STEP_TABLE = "prostore_migration_step"
      SCHEMA_TABLE         = "prostore_schema"
      META_TABLE           = "prostore_meta"

      def ensure_tables(adapter : Prostore::Adapter::Base,
                        executor : Prostore::Adapter::Base::Executor) : Nil
        executor.exec(create_migration_sql(adapter))
        executor.exec(create_migration_step_sql(adapter))
        executor.exec(create_schema_sql(adapter))
      end

      # Internal-version metadata (prostore_meta) is created by
      # `Migration::Internal.run` before the runner reaches `ensure_tables`,
      # so it isn't part of the standard bookkeeping bootstrap. The DDL lives
      # here for cohesion with the other bookkeeping table definitions.
      def create_meta_sql(adapter : Prostore::Adapter::Base) : String
        <<-SQL
          CREATE TABLE IF NOT EXISTS #{adapter.quote_ident(META_TABLE)} (
            key         TEXT NOT NULL PRIMARY KEY,
            value       TEXT NOT NULL,
            updated_at  TEXT NOT NULL
          )
        SQL
      end

      private def create_migration_sql(adapter : Prostore::Adapter::Base) : String
        <<-SQL
          CREATE TABLE IF NOT EXISTS #{adapter.quote_ident(MIGRATION_TABLE)} (
            id              #{adapter.bookkeeping_id_column_def},
            source_hash     TEXT    NOT NULL,
            target_hash     TEXT    NOT NULL,
            status          TEXT    NOT NULL,
            claimed_by      TEXT,
            claimed_until   TEXT,
            started_at      TEXT,
            completed_at    TEXT,
            error           TEXT
          )
        SQL
      end

      private def create_migration_step_sql(adapter : Prostore::Adapter::Base) : String
        <<-SQL
          CREATE TABLE IF NOT EXISTS #{adapter.quote_ident(MIGRATION_STEP_TABLE)} (
            migration_id   BIGINT  NOT NULL,
            ordinal        INTEGER NOT NULL,
            kind           TEXT    NOT NULL,
            params         TEXT    NOT NULL,
            status         TEXT    NOT NULL,
            progress       TEXT,
            started_at     TEXT,
            completed_at   TEXT,
            PRIMARY KEY (migration_id, ordinal)
          )
        SQL
      end

      # prostore_schema: one row per managed column/index/foreign_key.
      # Bool columns are INTEGER (0/1) for portability between SQLite and
      # Postgres. The three small arrays (index columns, FK columns, FK
      # referenced columns) remain JSON-encoded text — neither backend has
      # a portable native array type that fits a single-table layout.
      # `enum_members` is a JSON-encoded `[[name, value], ...]` array for
      # columns whose type resolves to an Enum (ADR-0016).
      private def create_schema_sql(adapter : Prostore::Adapter::Base) : String
        <<-SQL
          CREATE TABLE IF NOT EXISTS #{adapter.quote_ident(SCHEMA_TABLE)} (
            table_name             TEXT    NOT NULL,
            kind                   TEXT    NOT NULL,
            tag                    INTEGER NOT NULL,
            current_name           TEXT    NOT NULL,

            portable_type          TEXT,
            nullable               INTEGER,
            is_primary             INTEGER,
            auto_increment         INTEGER,
            has_default            INTEGER,
            default_sql            TEXT,
            has_backfill           INTEGER,
            backfill_sql           TEXT,
            has_lazy               INTEGER,
            enum_members           TEXT,
            enum_is_flags          INTEGER,

            index_columns          TEXT,
            index_unique           INTEGER,
            index_where_sql        TEXT,

            fk_columns             TEXT,
            fk_references_table    TEXT,
            fk_references_columns  TEXT,
            fk_on_delete           TEXT,
            fk_on_update           TEXT,

            PRIMARY KEY (table_name, kind, tag)
          )
        SQL
      end
    end
  end
end
