require "db"
require "../adapter/base"
require "../adapter/sqlite/adapter"
require "../adapter/sqlite/ddl"
require "../adapter/sqlite/rebuild"
require "../adapter/postgres/adapter"
require "../adapter/postgres/ddl"
require "../drift/schema_table"
require "./step"

module Prostore
  module Steps
    # Executes a single Step against the database, then updates
    # `prostore_schema` to reflect the new state.
    #
    # Each step runs in its own transaction (per `Steps.requires_transaction?`),
    # and `prostore_schema` is updated in the same transaction so the
    # bookkeeping stays consistent with the DDL outcome. Step status,
    # lease heartbeats, and resume are handled by the migration runner.
    module Executor
      extend self

      def execute(adapter : Prostore::Adapter::Base,
                  conn : DB::Connection,
                  step : Kind::Any,
                  pk_lookup : Hash(String, Array(String)) = {} of String => Array(String),
                  model_lookup : Hash(String, Prostore::Model.class) = {} of String => Prostore::Model.class) : Nil
        if Steps.requires_transaction?(step, adapter)
          conn.transaction { |tx| run(adapter, tx.connection, step, pk_lookup, model_lookup) }
        else
          run(adapter, conn, step, pk_lookup, model_lookup)
        end
      end

      private def run(adapter : Prostore::Adapter::Base,
                      executor : Prostore::Adapter::Base::Executor,
                      step : Kind::Any,
                      pk_lookup : Hash(String, Array(String)),
                      model_lookup : Hash(String, Prostore::Model.class)) : Nil
        case step
        when Kind::CreateTable
          run_create_table(adapter, executor, step, pk_lookup)
        when Kind::DropTable
          run_drop_table(adapter, executor, step)
        when Kind::AddColumn
          run_add_column(adapter, executor, step)
        when Kind::DropColumn
          run_drop_column(adapter, executor, step)
        when Kind::RenameColumn
          run_rename_column(adapter, executor, step)
        when Kind::AddIndex
          run_add_index(adapter, executor, step)
        when Kind::DropIndex
          run_drop_index(adapter, executor, step)
        when Kind::RenameIndex
          run_rename_index(adapter, executor, step)
        when Kind::AddColumnNullable
          run_add_column_nullable(adapter, executor, step)
        when Kind::BackfillSqlExpr
          run_backfill_sql_expr(adapter, executor, step)
        when Kind::BackfillCrystalLambda
          run_backfill_crystal_lambda(adapter, executor, step, model_lookup)
        when Kind::ApplyNotNull
          run_apply_not_null(adapter, executor, step)
        when Kind::AddForeignKey
          run_add_foreign_key(adapter, executor, step, pk_lookup)
        when Kind::DropForeignKey
          run_drop_foreign_key(adapter, executor, step)
        when Kind::ResetSequence
          run_reset_sequence(adapter, executor, step)
        end
      end

      # ---- ResetSequence (ADR-0013) ----------------------------------------

      private def run_reset_sequence(adapter, executor, step : Kind::ResetSequence) : Nil
        case adapter
        when Prostore::Adapter::SQLite::Adapter
          # SQLite: sqlite_sequence is auto-maintained on AUTOINCREMENT, but
          # explicit-ID inserts above the current seq value don't always
          # update it. Set it explicitly to MAX(col).
          max_value = executor.scalar(
            "SELECT COALESCE(MAX(#{adapter.quote_ident(step.column_name)}), 0) " \
            "FROM #{adapter.quote_ident(step.table_name)}"
          )
          executor.exec(
            "UPDATE sqlite_sequence SET seq = #{adapter.placeholder(1)} " \
            "WHERE name = #{adapter.placeholder(2)}",
            max_value, step.table_name,
          )
        when Prostore::Adapter::Postgres::Adapter
          # Postgres: setval(pg_get_serial_sequence(...), MAX(col)). The
          # COALESCE-with-1 keeps the sequence valid for empty tables.
          executor.exec(
            "SELECT setval(pg_get_serial_sequence(#{adapter.placeholder(1)}, #{adapter.placeholder(2)}), " \
            "(SELECT COALESCE(MAX(#{adapter.quote_ident(step.column_name)}), 1) " \
            "FROM #{adapter.quote_ident(step.table_name)}))",
            step.table_name, step.column_name,
          )
        else
          raise Prostore::MigrationError.new("ResetSequence not implemented for adapter #{adapter.class}")
        end
      end

      # ---- per-kind handlers ------------------------------------------------

      private def run_create_table(adapter, executor, step : Kind::CreateTable, pk_lookup) : Nil
        sql = case adapter
              when Prostore::Adapter::SQLite::Adapter
                adapter.render_create_table(step.definition, pk_lookup)
              when Prostore::Adapter::Postgres::Adapter
                adapter.render_create_table(step.definition, pk_lookup)
              else
                adapter.render_create_table(step.definition)
              end
        executor.exec(sql)

        step.definition.indexes.each do |idx|
          executor.exec(adapter.render_create_index(step.definition.table_name, idx))
        end

        step.definition.fields.each do |field|
          Drift::SchemaTable.upsert_field(adapter, executor, step.definition.table_name, field)
        end
        step.definition.indexes.each do |idx|
          Drift::SchemaTable.upsert_index(adapter, executor, step.definition.table_name, idx)
        end
        step.definition.foreign_keys.each do |fk|
          Drift::SchemaTable.upsert_foreign_key(adapter, executor, step.definition.table_name, fk)
        end
      end

      private def run_drop_table(adapter, executor, step : Kind::DropTable) : Nil
        executor.exec("DROP TABLE #{adapter.quote_ident(step.table_name)}")
        # Remove ALL bookkeeping rows for this table.
        executor.exec(
          "DELETE FROM #{adapter.quote_ident(Migration::Bookkeeping::SCHEMA_TABLE)} " \
          "WHERE table_name = #{adapter.placeholder(1)}",
          step.table_name,
        )
      end

      private def run_add_column(adapter, executor, step : Kind::AddColumn) : Nil
        col_def = case adapter
                  when Prostore::Adapter::SQLite::Adapter
                    Prostore::Adapter::SQLite::DDL.render_column(step.field)
                  when Prostore::Adapter::Postgres::Adapter
                    Prostore::Adapter::Postgres::DDL.render_column(step.field)
                  else
                    raise Prostore::MigrationError.new("AddColumn not implemented for adapter #{adapter.class}")
                  end
        executor.exec("ALTER TABLE #{adapter.quote_ident(step.table_name)} ADD COLUMN #{col_def}")
        Drift::SchemaTable.upsert_field(adapter, executor, step.table_name, step.field)
      end

      private def run_drop_column(adapter, executor, step : Kind::DropColumn) : Nil
        executor.exec(
          "ALTER TABLE #{adapter.quote_ident(step.table_name)} " \
          "DROP COLUMN #{adapter.quote_ident(step.column_name)}"
        )
        Drift::SchemaTable.delete(adapter, executor, step.table_name,
          Drift::SchemaTable::KIND_COLUMN, step.tag)
      end

      private def run_rename_column(adapter, executor, step : Kind::RenameColumn) : Nil
        executor.exec(
          "ALTER TABLE #{adapter.quote_ident(step.table_name)} " \
          "RENAME COLUMN #{adapter.quote_ident(step.from_name)} TO #{adapter.quote_ident(step.to_name)}"
        )
        # Update prostore_schema's current_name. We re-fetch the field's full
        # definition from the row's stored definition (unchanged by a rename).
        executor.exec(
          "UPDATE #{adapter.quote_ident(Migration::Bookkeeping::SCHEMA_TABLE)} " \
          "SET current_name = #{adapter.placeholder(1)} " \
          "WHERE table_name = #{adapter.placeholder(2)} AND " \
          "kind = #{adapter.placeholder(3)} AND tag = #{adapter.placeholder(4)}",
          step.to_name, step.table_name, Drift::SchemaTable::KIND_COLUMN, step.tag,
        )
      end

      private def run_add_index(adapter, executor, step : Kind::AddIndex) : Nil
        case adapter
        when Prostore::Adapter::Postgres::Adapter
          if adapter.supports_concurrent_index?
            run_add_index_concurrent_pg(adapter, executor, step)
          else
            executor.exec(adapter.render_create_index(step.table_name, step.index))
          end
        else
          executor.exec(adapter.render_create_index(step.table_name, step.index))
        end
        Drift::SchemaTable.upsert_index(adapter, executor, step.table_name, step.index)
      end

      # Postgres CONCURRENTLY index build with INVALID-index recovery. If a
      # previous attempt failed mid-flight, PG marks the index as INVALID
      # and won't use it for queries. We drop it CONCURRENTLY before
      # retrying so the next CREATE INDEX CONCURRENTLY can succeed.
      private def run_add_index_concurrent_pg(adapter, executor, step : Kind::AddIndex) : Nil
        invalid = executor.scalar(<<-SQL, step.index.name).as(Bool)
          SELECT EXISTS (
            SELECT 1 FROM pg_class c
            JOIN pg_index i ON i.indexrelid = c.oid
            WHERE c.relname = #{adapter.placeholder(1)} AND NOT i.indisvalid
          )
        SQL

        if invalid
          executor.exec(
            "DROP INDEX CONCURRENTLY IF EXISTS #{adapter.quote_ident(step.index.name)}"
          )
        end

        executor.exec(
          Prostore::Adapter::Postgres::DDL.render_create_index(
            step.table_name, step.index, concurrently: true)
        )
      end

      private def run_drop_index(adapter, executor, step : Kind::DropIndex) : Nil
        executor.exec("DROP INDEX #{adapter.quote_ident(step.index_name)}")
        Drift::SchemaTable.delete(adapter, executor, step.table_name,
          Drift::SchemaTable::KIND_INDEX, step.tag)
      end

      private def run_rename_index(adapter, executor, step : Kind::RenameIndex) : Nil
        # SQLite has no ALTER INDEX RENAME — the portable path is drop +
        # recreate. We need the definition to recreate, read from prostore_schema.
        case adapter
        when Prostore::Adapter::SQLite::Adapter
          row = single_row(executor, adapter, step.table_name, Drift::SchemaTable::KIND_INDEX, step.tag)
          stored = JSON.parse(row.definition)

          cols = (stored["columns"]?.try(&.as_a.map(&.as_s)) || [] of String)
          unique = stored["unique"]?.try(&.as_bool) || false
          where_sql = stored["where_sql"]?.try(&.as_s?)

          executor.exec("DROP INDEX #{adapter.quote_ident(step.from_name)}")

          io = IO::Memory.new
          io << "CREATE "
          io << "UNIQUE " if unique
          io << "INDEX " << adapter.quote_ident(step.to_name)
          io << " ON " << adapter.quote_ident(step.table_name) << " ("
          io << cols.map { |col| adapter.quote_ident(col) }.join(", ")
          io << ')'
          io << " WHERE " << where_sql if where_sql
          executor.exec(io.to_s)
        else
          executor.exec("ALTER INDEX #{adapter.quote_ident(step.from_name)} RENAME TO #{adapter.quote_ident(step.to_name)}")
        end

        executor.exec(
          "UPDATE #{adapter.quote_ident(Migration::Bookkeeping::SCHEMA_TABLE)} " \
          "SET current_name = #{adapter.placeholder(1)} " \
          "WHERE table_name = #{adapter.placeholder(2)} AND " \
          "kind = #{adapter.placeholder(3)} AND tag = #{adapter.placeholder(4)}",
          step.to_name, step.table_name, Drift::SchemaTable::KIND_INDEX, step.tag,
        )
      end

      # ---- Multi-phase handlers --------------------------------------------

      private def run_add_column_nullable(adapter, executor, step : Kind::AddColumnNullable) : Nil
        # Force nullable AND strip the default. The default is reapplied by
        # ApplyNotNull. Without this, ADD COLUMN would populate existing rows
        # with the default, defeating BackfillSqlExpr's WHERE col IS NULL.
        stripped = Schema::Field.new(
          tag: step.field.tag,
          name: step.field.name,
          crystal_type: step.field.crystal_type,
          portable_type: step.field.portable_type,
          nullable: true,
          primary: step.field.primary,
          auto_increment: step.field.auto_increment,
          has_default: false,
          default_sql: nil,
          has_backfill: step.field.has_backfill,
          backfill_sql: step.field.backfill_sql,
          has_lazy: step.field.has_lazy,
        )
        col_def = case adapter
                  when Prostore::Adapter::SQLite::Adapter
                    Prostore::Adapter::SQLite::DDL.render_column(stripped)
                  when Prostore::Adapter::Postgres::Adapter
                    Prostore::Adapter::Postgres::DDL.render_column(stripped)
                  else
                    raise Prostore::MigrationError.new("AddColumnNullable not implemented for adapter #{adapter.class}")
                  end
        executor.exec("ALTER TABLE #{adapter.quote_ident(step.table_name)} ADD COLUMN #{col_def}")

        # Bookkeeping reflects the FINAL field shape; the transient nullable
        # state during backfill is not the target — ApplyNotNull reaches it.
        Drift::SchemaTable.upsert_field(adapter, executor, step.table_name, step.field)
      end

      private def run_backfill_sql_expr(adapter, executor, step : Kind::BackfillSqlExpr) : Nil
        # ADR-0009 invariant 3: WHERE col IS NULL is the correctness predicate;
        # the loop is idempotent under retry because re-running skips
        # already-populated rows.
        executor.exec(
          "UPDATE #{adapter.quote_ident(step.table_name)} " \
          "SET #{adapter.quote_ident(step.column_name)} = #{step.sql_expr} " \
          "WHERE #{adapter.quote_ident(step.column_name)} IS NULL"
        )
      end

      private def run_backfill_crystal_lambda(adapter, executor, step : Kind::BackfillCrystalLambda,
                                              model_lookup : Hash(String, Prostore::Model.class)) : Nil
        model = model_lookup[step.table_name]?
        unless model
          raise Prostore::MigrationError.new(
            "Crystal-lambda backfill on #{step.table_name} field tag #{step.field_tag} " \
            "needs the model in the migration set. Either include the model class or " \
            "switch the backfill to a SQL.expr."
          )
        end
        model.__prostore_run_backfill(adapter, executor, step.field_tag)
      end

      private def run_apply_not_null(adapter, executor, step : Kind::ApplyNotNull) : Nil
        case adapter
        when Prostore::Adapter::SQLite::Adapter
          apply_not_null_sqlite(adapter, executor, step)
        when Prostore::Adapter::Postgres::Adapter
          apply_not_null_postgres(adapter, executor, step)
        else
          raise Prostore::MigrationError.new("ApplyNotNull not implemented for adapter #{adapter.class}")
        end
      end

      private def apply_not_null_postgres(adapter, executor, step : Kind::ApplyNotNull) : Nil
        # Postgres has native ALTER COLUMN — no table rebuild needed.
        executor.exec(
          "ALTER TABLE #{adapter.quote_ident(step.table_name)} " \
          "ALTER COLUMN #{adapter.quote_ident(step.column_name)} SET NOT NULL"
        )
        if d = step.default_sql
          executor.exec(
            "ALTER TABLE #{adapter.quote_ident(step.table_name)} " \
            "ALTER COLUMN #{adapter.quote_ident(step.column_name)} SET DEFAULT (#{d})"
          )
        end
      end

      private def apply_not_null_sqlite(adapter, executor, step : Kind::ApplyNotNull) : Nil
        # Read the live column list to reconstruct the rebuild DDL.
        live_table = adapter.introspect_table(step.table_name, executor)

        # Re-render every column from the live state, but force the target
        # column to NOT NULL and apply its desired default (carried in the
        # step). All other columns rebuild verbatim.
        col_defs = live_table.columns.map do |col|
          parts = [adapter.quote_ident(col.name), col.type_text] of String

          if col.primary && col.auto_increment
            parts << "PRIMARY KEY AUTOINCREMENT"
          elsif col.primary
            parts << "PRIMARY KEY"
          end

          if col.name == step.column_name
            parts << "NOT NULL"
            if d = step.default_sql
              parts << "DEFAULT (#{d})"
            elsif d = col.default_text
              # Live default is unlikely (AddColumnNullable strips it), but
              # fall back if anything's already there.
              parts << "DEFAULT #{d}"
            end
          else
            parts << "NOT NULL" unless col.nullable
            if d = col.default_text
              parts << "DEFAULT #{d}"
            end
          end

          parts.join(' ')
        end

        # Capture FK constraints for re-emission.
        fk_clauses = live_table.foreign_keys.map do |fk|
          src_cols = fk.columns.map { |col| adapter.quote_ident(col) }.join(", ")
          tgt_cols = fk.references_columns.map { |col| adapter.quote_ident(col) }.join(", ")
          on_del = Prostore::Adapter::SQLite::DDL.render_action(fk.on_delete)
          on_upd = Prostore::Adapter::SQLite::DDL.render_action(fk.on_update)
          "FOREIGN KEY (#{src_cols}) REFERENCES #{adapter.quote_ident(fk.references_table)} (#{tgt_cols}) " \
          "ON DELETE #{on_del} ON UPDATE #{on_upd}"
        end

        # Capture index recreation SQL.
        index_sql = Prostore::Adapter::SQLite::Rebuild.capture_index_statements(executor, step.table_name)

        # Pass-through column mapping: every column copies as-is.
        mapping = live_table.columns.map do |col|
          {old_expr: adapter.quote_ident(col.name), new_name: col.name}
        end

        Prostore::Adapter::SQLite::Rebuild.rebuild(
          adapter, executor, step.table_name,
          col_defs, fk_clauses, mapping, index_sql,
        )
      end

      # ---- Foreign-key handlers --------------------------------------------

      private def run_add_foreign_key(adapter, executor, step : Kind::AddForeignKey, pk_lookup) : Nil
        case adapter
        when Prostore::Adapter::SQLite::Adapter
          add_foreign_key_sqlite(adapter, executor, step, pk_lookup)
        when Prostore::Adapter::Postgres::Adapter
          add_foreign_key_postgres(adapter, executor, step, pk_lookup)
        else
          raise Prostore::MigrationError.new("AddForeignKey not implemented for adapter #{adapter.class}")
        end
        Drift::SchemaTable.upsert_foreign_key(adapter, executor, step.table_name, step.foreign_key)
      end

      private def run_drop_foreign_key(adapter, executor, step : Kind::DropForeignKey) : Nil
        case adapter
        when Prostore::Adapter::SQLite::Adapter
          drop_foreign_key_sqlite(adapter, executor, step)
        when Prostore::Adapter::Postgres::Adapter
          drop_foreign_key_postgres(adapter, executor, step)
        else
          raise Prostore::MigrationError.new("DropForeignKey not implemented for adapter #{adapter.class}")
        end
        Drift::SchemaTable.delete(adapter, executor, step.table_name,
          Drift::SchemaTable::KIND_FOREIGN_KEY, step.tag)
      end

      private def add_foreign_key_postgres(adapter, executor, step : Kind::AddForeignKey, pk_lookup) : Nil
        # Postgres online-FK pattern (ADR-0012): ADD CONSTRAINT NOT VALID
        # is fast (no row scan; only a brief ACCESS EXCLUSIVE for the
        # catalog write). VALIDATE CONSTRAINT runs the actual row check
        # online, holding only SHARE UPDATE EXCLUSIVE — concurrent reads
        # AND writes proceed during validation. The end state is identical
        # to a plain ADD CONSTRAINT but without the multi-minute lock.
        #
        # Idempotent under retry: we check pg_constraint and skip ADD if
        # already present; VALIDATE on an already-valid constraint is a
        # cheap no-op.
        fk = step.foreign_key
        ref_cols = fk.references_columns.empty? ? (pk_lookup[fk.references_table]? || [] of String) : fk.references_columns
        if ref_cols.empty?
          raise Prostore::MigrationError.new(
            "Cannot resolve target PK for FK #{fk.tag} → #{fk.references_table}; " \
            "ensure the target model is in the migration set."
          )
        end
        src = fk.columns.map { |col| adapter.quote_ident(col) }.join(", ")
        tgt = ref_cols.map { |col| adapter.quote_ident(col) }.join(", ")
        on_del = Prostore::Adapter::Postgres::DDL.render_action(fk.on_delete)
        on_upd = Prostore::Adapter::Postgres::DDL.render_action(fk.on_update)

        already_present = executor.scalar(
          "SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = #{adapter.placeholder(1)})",
          fk.name
        ).as(Bool)

        unless already_present
          executor.exec(
            "ALTER TABLE #{adapter.quote_ident(step.table_name)} " \
            "ADD CONSTRAINT #{adapter.quote_ident(fk.name)} " \
            "FOREIGN KEY (#{src}) REFERENCES #{adapter.quote_ident(fk.references_table)} (#{tgt}) " \
            "ON DELETE #{on_del} ON UPDATE #{on_upd} NOT VALID"
          )
        end

        executor.exec(
          "ALTER TABLE #{adapter.quote_ident(step.table_name)} " \
          "VALIDATE CONSTRAINT #{adapter.quote_ident(fk.name)}"
        )
      end

      private def drop_foreign_key_postgres(adapter, executor, step : Kind::DropForeignKey) : Nil
        executor.exec(
          "ALTER TABLE #{adapter.quote_ident(step.table_name)} " \
          "DROP CONSTRAINT #{adapter.quote_ident(step.constraint_name)}"
        )
      end

      private def add_foreign_key_sqlite(adapter, executor, step : Kind::AddForeignKey, pk_lookup) : Nil
        # Rebuild the table including the new FK constraint alongside any
        # already-existing FKs preserved verbatim.
        live_table = adapter.introspect_table(step.table_name, executor)

        # Render existing column DDL.
        col_defs = live_table.columns.map { |col| render_live_column(adapter, col) }

        # Existing FKs come from live introspection; the new FK is appended.
        existing_fk_clauses = live_table.foreign_keys.map do |fk|
          render_live_fk_clause(adapter, fk, fk_name_for_tag: nil)
        end

        # The new FK gets its named constraint (and resolved target columns).
        new_fk_clause = render_managed_fk_clause(adapter, step.foreign_key, pk_lookup)

        index_sql = Prostore::Adapter::SQLite::Rebuild.capture_index_statements(executor, step.table_name)
        mapping = live_table.columns.map do |col|
          {old_expr: adapter.quote_ident(col.name), new_name: col.name}
        end

        Prostore::Adapter::SQLite::Rebuild.rebuild(
          adapter, executor, step.table_name,
          col_defs, existing_fk_clauses + [new_fk_clause], mapping, index_sql,
        )
      end

      private def drop_foreign_key_sqlite(adapter, executor, step : Kind::DropForeignKey) : Nil
        # Read prostore_schema to identify which managed FK to drop. We drop
        # by re-rendering the FKs that are NOT this tag, against the live
        # column structure.
        live_table = adapter.introspect_table(step.table_name, executor)

        col_defs = live_table.columns.map { |col| render_live_column(adapter, col) }

        # Read the managed FK rows so we know which live FK belongs to which tag.
        managed_fks = Drift::SchemaTable.for_table(adapter, executor, step.table_name)
          .select { |row| row.kind == Drift::SchemaTable::KIND_FOREIGN_KEY }

        keep_clauses = [] of String
        live_table.foreign_keys.each do |live_fk|
          row = managed_fks.find { |mgd| mgd.current_name == live_fk_name(live_fk) || matches_columns?(mgd, live_fk) }
          # Keep all FKs except the one being dropped.
          if row && row.tag == step.tag
            next
          end
          keep_clauses << render_live_fk_clause(adapter, live_fk, fk_name_for_tag: row.try(&.current_name))
        end

        index_sql = Prostore::Adapter::SQLite::Rebuild.capture_index_statements(executor, step.table_name)
        mapping = live_table.columns.map do |col|
          {old_expr: adapter.quote_ident(col.name), new_name: col.name}
        end

        Prostore::Adapter::SQLite::Rebuild.rebuild(
          adapter, executor, step.table_name,
          col_defs, keep_clauses, mapping, index_sql,
        )
      end

      private def render_live_column(adapter, col : Adapter::LiveColumn) : String
        parts = [adapter.quote_ident(col.name), col.type_text] of String

        if col.primary && col.auto_increment
          parts << "PRIMARY KEY AUTOINCREMENT"
        elsif col.primary
          parts << "PRIMARY KEY"
        end
        parts << "NOT NULL" unless col.nullable
        if d = col.default_text
          parts << "DEFAULT #{d}"
        end
        parts.join(' ')
      end

      private def render_live_fk_clause(adapter, fk : Adapter::LiveForeignKey, fk_name_for_tag : String?) : String
        src = fk.columns.map { |col| adapter.quote_ident(col) }.join(", ")
        tgt = fk.references_columns.map { |col| adapter.quote_ident(col) }.join(", ")
        on_del = Prostore::Adapter::SQLite::DDL.render_action(fk.on_delete)
        on_upd = Prostore::Adapter::SQLite::DDL.render_action(fk.on_update)

        if fk_name_for_tag
          "CONSTRAINT #{adapter.quote_ident(fk_name_for_tag)} FOREIGN KEY (#{src}) " \
          "REFERENCES #{adapter.quote_ident(fk.references_table)} (#{tgt}) " \
          "ON DELETE #{on_del} ON UPDATE #{on_upd}"
        else
          "FOREIGN KEY (#{src}) REFERENCES #{adapter.quote_ident(fk.references_table)} (#{tgt}) " \
          "ON DELETE #{on_del} ON UPDATE #{on_upd}"
        end
      end

      private def render_managed_fk_clause(adapter, fk : Schema::ForeignKey, pk_lookup) : String
        ref_cols = fk.references_columns.empty? ? (pk_lookup[fk.references_table]? || [] of String) : fk.references_columns
        if ref_cols.empty?
          raise Prostore::MigrationError.new(
            "Cannot resolve target PK for FK #{fk.tag} → #{fk.references_table}; ensure the target model is in the migration set."
          )
        end
        src = fk.columns.map { |col| adapter.quote_ident(col) }.join(", ")
        tgt = ref_cols.map { |col| adapter.quote_ident(col) }.join(", ")
        on_del = Prostore::Adapter::SQLite::DDL.render_action(fk.on_delete)
        on_upd = Prostore::Adapter::SQLite::DDL.render_action(fk.on_update)
        "CONSTRAINT #{adapter.quote_ident(fk.name)} FOREIGN KEY (#{src}) " \
        "REFERENCES #{adapter.quote_ident(fk.references_table)} (#{tgt}) " \
        "ON DELETE #{on_del} ON UPDATE #{on_upd}"
      end

      private def live_fk_name(fk : Adapter::LiveForeignKey) : String?
        fk.name.empty? ? nil : fk.name
      end

      private def matches_columns?(row : Drift::SchemaTable::Row, live_fk : Adapter::LiveForeignKey) : Bool
        stored = JSON.parse(row.definition)
        stored_cols = stored["columns"]?.try(&.as_a.map(&.as_s)) || [] of String
        stored_cols == live_fk.columns
      end

      private def single_row(executor, adapter, table : String, kind : String, tag : Int32) : Drift::SchemaTable::Row
        rows = Drift::SchemaTable.all(adapter, executor)
        rows.find { |row| row.table_name == table && row.kind == kind && row.tag == tag } ||
          raise Prostore::MigrationError.new("Bookkeeping row missing for #{table}/#{kind}/tag=#{tag}")
      end
    end
  end
end
