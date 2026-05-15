require "digest/sha256"
require "../connection"
require "../schema"
require "../diff/engine"
require "../diff/validator"
require "../drift/schema_table"
require "../drift/detector"
require "../query/analyzer"
require "../steps/planner"
require "../steps/executor"
require "../steps/codec"
require "./bookkeeping"
require "./internal"
require "./state"
require "./lease"

module Prostore
  module Migration
    # The migration runner (ADR-0009).
    #
    # Boot sequence:
    #   1. ensure_tables — bookkeeping schema present
    #   2. compute target fingerprint over the model registry
    #   3. find_in_progress — is there a pending/running/failed migration?
    #      - If yes: verify target_hash matches; reuse the migration id.
    #      - If no: validate, diff, plan, persist, insert a new migration row.
    #   4. claim the lease (refuse if another live lease holds it)
    #   5. for each pending step in ordinal order:
    #         mark_step_running → execute → mark_step_complete → heartbeat
    #   6. mark_migration_complete; release lease
    #
    # Plan-at-start (ADR-0009 invariant 2): step list is persisted before any
    # DDL runs. Resume reads the steps and continues from the first non-
    # complete one — the model is NOT consulted to recompute on resume.
    #
    # Schema-fingerprint enforcement (invariant 4): if the current model's
    # target hash doesn't match an in-progress migration's target_hash, the
    # runner refuses to start. Operator must either wait, abort, or fix the
    # version skew.
    class Runner
      def self.migrate(conn : Connection,
                       models : Array(Prostore::Model.class) = Prostore.models,
                       runner_id : String = Lease.runner_id) : Nil
        new(conn, models, runner_id).run
      end

      def initialize(@conn : Connection,
                     @models : Array(Prostore::Model.class),
                     @runner_id : String = Lease.runner_id)
      end

      def run : Nil
        @conn.with_connection do |db_conn|
          # Evolve prostore's own bookkeeping schema first; for legacy
          # installs this lifts `prostore_schema.definition` JSON into
          # typed columns before the rest of the runner reads them.
          Internal.run(@conn.adapter, db_conn)

          Bookkeeping.ensure_tables(@conn.adapter, db_conn)

          source_hash = compute_source_hash_internal(db_conn)
          target_hash = compute_target_hash_internal

          existing = State.find_in_progress(@conn.adapter, db_conn)

          # Fingerprint-mismatch enforcement comes BEFORE the no-op short-
          # circuit: an in-progress migration targeting a different schema
          # is an operator error regardless of the local diff result.
          if existing && existing.target_hash != target_hash
            raise Prostore::FingerprintError.new(
              "An in-progress migration targets schema #{existing.target_hash[0, 12]}…, " \
              "but the application's current schema is #{target_hash[0, 12]}…. " \
              "Either deploy the version that started the migration, abort it via " \
              "`prostore migrate abort #{existing.id}`, or wait for it to complete (ADR-0009)."
            )
          end

          # ADR-0006 strict mode: every named query's filtered/sorted field
          # must have an index. Validated up front for every model in the set
          # so the runner doesn't proceed against a configuration the planner
          # can't execute reliably.
          @models.each do |model|
            Query::Analyzer.validate_indexes!(model.prostore_schema)
          end

          # If no in-progress migration AND there's no drift AND the model
          # diff is empty, nothing to do.
          unless existing
            schema_rows = Drift::SchemaTable.all(@conn.adapter, db_conn)
            Diff::Validator.validate(@models, schema_rows)
            drift_report = Drift::Detector.detect(@conn.adapter, db_conn, schema_rows)
            model_ops = Diff::Engine.diff(@models, schema_rows)
            return if drift_report.ops.empty? && model_ops.empty?
          end

          migration_id =
            if existing
              existing.id
            else
              plan_new_migration_from_diff(db_conn, source_hash, target_hash)
            end

          # Claim the lease — refuse if held by another live runner.
          unless Lease.claim(@conn.adapter, db_conn, migration_id, @runner_id)
            held = current_lease_holder(db_conn, migration_id)
            raise Prostore::MigrationError.new(
              "Cannot claim migration #{migration_id}: lease held by #{held.inspect}. " \
              "Wait for the other runner, or if it has crashed, the lease will expire " \
              "(default 5m) and become stealable."
            )
          end

          State.mark_migration_running(@conn.adapter, db_conn, migration_id)

          begin
            execute_pending_steps(db_conn, migration_id)
            State.mark_migration_complete(@conn.adapter, db_conn, migration_id)
          rescue ex : Exception
            State.mark_migration_failed(@conn.adapter, db_conn, migration_id, ex.message || ex.class.name)
            raise ex
          ensure
            Lease.release(@conn.adapter, db_conn, migration_id, @runner_id)
          end
        end
      end

      # ---- planning --------------------------------------------------------

      # Public so tests / tooling can compute the same hash the runner uses.
      def compute_source_hash(executor : Adapter::Base::Executor) : String
        compute_source_hash_internal(executor)
      end

      def compute_target_hash : String
        compute_target_hash_internal
      end

      private def compute_source_hash_internal(executor : Adapter::Base::Executor) : String
        rows = Drift::SchemaTable.all(@conn.adapter, executor)
        io = IO::Memory.new
        io << "prostore-source\n"
        rows.sort_by { |row| {row.table_name, row.kind, row.tag} }.each do |row|
          io << row.table_name << ':' << row.kind << ':' << row.tag << ':' << row.current_name << ':'
          io << canonical_definition(row) << '\n'
        end
        Digest::SHA256.hexdigest(io.to_s)
      end

      # Deterministic per-kind serialization of a row's typed definition.
      # Keys are emitted in a fixed order so the hash is stable across runs.
      # NOTE: this is a content fingerprint, not the on-disk shape — the
      # storage format moved from a single JSON blob (internal v1) to typed
      # columns (v2), but the hash format is determined here.
      private def canonical_definition(row : Drift::SchemaTable::Row) : String
        case row.kind
        when Drift::SchemaTable::KIND_COLUMN
          String.build do |io|
            io << "portable_type=" << row.portable_type
            io << "|nullable=" << bool_canonical(row.nullable)
            io << "|primary=" << bool_canonical(row.primary)
            io << "|auto_increment=" << bool_canonical(row.auto_increment)
            io << "|has_default=" << bool_canonical(row.has_default)
            io << "|default_sql=" << row.default_sql.inspect
            io << "|has_backfill=" << bool_canonical(row.has_backfill)
            io << "|backfill_sql=" << row.backfill_sql.inspect
            io << "|has_lazy=" << bool_canonical(row.has_lazy)
          end
        when Drift::SchemaTable::KIND_INDEX
          String.build do |io|
            io << "columns=" << (row.index_columns || [] of String).join(",")
            io << "|unique=" << bool_canonical(row.index_unique)
            io << "|where_sql=" << row.index_where_sql.inspect
          end
        when Drift::SchemaTable::KIND_FOREIGN_KEY
          String.build do |io|
            io << "columns=" << (row.fk_columns || [] of String).join(",")
            io << "|references_table=" << row.fk_references_table
            io << "|references_columns=" << (row.fk_references_columns || [] of String).join(",")
            io << "|on_delete=" << row.fk_on_delete
            io << "|on_update=" << row.fk_on_update
          end
        else
          "kind=#{row.kind}"
        end
      end

      private def bool_canonical(value : Bool?) : String
        case value
        when true  then "1"
        when false then "0"
        else            ""
        end
      end

      private def compute_target_hash_internal : String
        io = IO::Memory.new
        io << "prostore-target\n"
        @models.sort_by(&.prostore_table_name).each do |model|
          io << model.prostore_table_name << '|' << model.prostore_fingerprint << '\n'
        end
        Digest::SHA256.hexdigest(io.to_s)
      end

      private def plan_new_migration_from_diff(db_conn : DB::Connection,
                                               source_hash : String,
                                               target_hash : String) : Int64
        schema_rows = Drift::SchemaTable.all(@conn.adapter, db_conn)

        # Drift fixes get prepended to the model-driven diff.
        drift_report = Drift::Detector.detect(@conn.adapter, db_conn, schema_rows)
        model_ops = Diff::Engine.diff(@models, schema_rows)
        operations = drift_report.ops + model_ops

        steps = Steps::Planner.plan(operations)
        validate_sqlite_not_null!(steps)

        migration_id = State.insert_migration(@conn.adapter, db_conn, source_hash, target_hash)
        State.insert_steps(@conn.adapter, db_conn, migration_id, steps)
        migration_id
      end

      # ---- execution -------------------------------------------------------

      private def execute_pending_steps(db_conn : DB::Connection, migration_id : Int64) : Nil
        pk_lookup = build_pk_lookup
        model_lookup = build_model_lookup
        rows = State.steps_for(@conn.adapter, db_conn, migration_id)

        # Background heartbeat fiber renews the lease while a long step is
        # running. If the pool can't spare a second connection (in-memory
        # SQLite), the fiber is a graceful no-op — between-steps heartbeat
        # below still keeps the lease alive. See `HeartbeatFiber`.
        heartbeat = HeartbeatFiber.new(@conn, migration_id, @runner_id)
        heartbeat.start

        begin
          rows.each do |row|
            next if row.status == State::STEP_COMPLETE

            if heartbeat.lost?
              raise Prostore::MigrationError.new(
                "Lease lost (heartbeat reported failure on migration #{migration_id}). " \
                "Another runner stole it; this runner is aborting before the next step."
              )
            end

            step = Steps::Codec.decode(row.kind, row.params)

            State.mark_step_running(@conn.adapter, db_conn, migration_id, row.ordinal)
            begin
              Steps::Executor.execute(@conn.adapter, db_conn, step, pk_lookup, model_lookup)
              State.mark_step_complete(@conn.adapter, db_conn, migration_id, row.ordinal)

              # Belt-and-suspenders: also renew between steps. Cheap, and
              # covers the case where the heartbeat fiber wasn't viable
              # (single-connection pool).
              unless Lease.heartbeat(@conn.adapter, db_conn, migration_id, @runner_id)
                raise Prostore::MigrationError.new(
                  "Lease lost mid-migration (id=#{migration_id}). Another runner stole it; " \
                  "this runner is aborting before the next step."
                )
              end
            rescue ex : Exception
              State.mark_step_failed(@conn.adapter, db_conn, migration_id, row.ordinal)
              raise ex
            end
          end
        ensure
          heartbeat.stop
        end
      end

      # Raises a clear error when an ApplyNotNull step would trigger a SQLite
      # table rebuild on a table referenced by FK — that rebuild fails with
      # foreign_keys=ON. Called before persisting the step list.
      private def validate_sqlite_not_null!(steps : Array(Steps::Kind::Any)) : Nil
        return unless @conn.adapter.is_a?(Adapter::SQLite::Adapter)

        referenced_by = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
        @models.each do |model|
          model.prostore_schema.foreign_keys.each do |fk|
            referenced_by[fk.references_table] << model.prostore_table_name
          end
        end

        steps.each do |step|
          next unless step.is_a?(Steps::Kind::ApplyNotNull)
          refs = referenced_by[step.table_name]?
          next if refs.nil? || refs.empty?
          raise Prostore::MigrationError.new(
            "Cannot apply NOT NULL to `#{step.table_name}.#{step.column_name}` on SQLite — " \
            "table is referenced by FK from: #{refs.sort.join(", ")}.\n" \
            "SQLite requires a table rebuild for ApplyNotNull, which fails with foreign_keys=ON.\n" \
            "Fix: declare the field nullable (T?) and normalize nil reads at call sites, " \
            "or use the same SQL.expr for both default: and backfill: to take the " \
            "single-step ADD COLUMN path instead."
          )
        end
      end

      private def current_lease_holder(db_conn : DB::Connection, migration_id : Int64) : String?
        db_conn.scalar(
          "SELECT claimed_by FROM #{@conn.adapter.quote_ident(Bookkeeping::MIGRATION_TABLE)} " \
          "WHERE id = #{@conn.adapter.placeholder(1)}",
          migration_id
        ).as(String?)
      end

      private def build_pk_lookup : Hash(String, Array(String))
        h = {} of String => Array(String)
        @models.each do |model|
          if pk = model.prostore_schema.primary_key
            h[model.prostore_table_name] = [pk.name.to_s]
          end
        end
        h
      end

      private def build_model_lookup : Hash(String, Prostore::Model.class)
        @models.to_h { |model| {model.prostore_table_name, model} }
      end
    end
  end
end
