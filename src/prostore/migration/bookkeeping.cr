require "../adapter/base"

module Prostore
  module Migration
    # Bootstrap the three `prostore_*` bookkeeping tables (ADR-0009, ADR-0010).
    #
    # All operations run on a caller-supplied executor (DB::Database,
    # DB::Connection, or DB::Transaction) so the migration runner can pin
    # everything to a single checked-out connection (avoiding pool deadlock).
    module Bookkeeping
      extend self

      MIGRATION_TABLE      = "prostore_migration"
      MIGRATION_STEP_TABLE = "prostore_migration_step"
      SCHEMA_TABLE         = "prostore_schema"

      def ensure_tables(adapter : Prostore::Adapter::Base,
                        executor : Prostore::Adapter::Base::Executor) : Nil
        executor.exec(create_migration_sql(adapter))
        executor.exec(create_migration_step_sql(adapter))
        executor.exec(create_schema_sql(adapter))
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

      private def create_schema_sql(adapter : Prostore::Adapter::Base) : String
        <<-SQL
          CREATE TABLE IF NOT EXISTS #{adapter.quote_ident(SCHEMA_TABLE)} (
            table_name    TEXT    NOT NULL,
            kind          TEXT    NOT NULL,
            tag           INTEGER NOT NULL,
            current_name  TEXT    NOT NULL,
            definition    TEXT    NOT NULL,
            PRIMARY KEY (table_name, kind, tag)
          )
        SQL
      end
    end
  end
end
