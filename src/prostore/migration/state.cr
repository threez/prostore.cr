require "db"
require "../adapter/base"
require "../steps/step"
require "../steps/codec"
require "./bookkeeping"

module Prostore
  module Migration
    # CRUD over the `prostore_migration` and `prostore_migration_step`
    # bookkeeping tables (ADR-0009). Pure data layer; the runner orchestrates
    # the higher-level state transitions.
    #
    # All SQL strings build placeholders via `adapter.placeholder(n)` so the
    # same code works against SQLite (`?`) and PostgreSQL (`$N`) — crystal-db
    # does not translate between the two.
    module State
      extend self

      MIGRATION_PENDING  = "pending"
      MIGRATION_RUNNING  = "running"
      MIGRATION_COMPLETE = "complete"
      MIGRATION_FAILED   = "failed"
      MIGRATION_ABORTED  = "aborted"

      STEP_PENDING  = "pending"
      STEP_RUNNING  = "running"
      STEP_COMPLETE = "complete"
      STEP_FAILED   = "failed"

      record MigrationRow,
        id : Int64,
        source_hash : String,
        target_hash : String,
        status : String,
        claimed_by : String?,
        claimed_until : Time?,
        started_at : Time?,
        completed_at : Time?,
        error : String?

      record StepRow,
        migration_id : Int64,
        ordinal : Int32,
        kind : String,
        params : String,
        status : String,
        progress : String?,
        started_at : Time?,
        completed_at : Time?

      # ---- migration row ---------------------------------------------------

      def find_in_progress(adapter, executor : Adapter::Base::Executor) : MigrationRow?
        rows = [] of MigrationRow
        executor.query_each(
          "SELECT id, source_hash, target_hash, status, claimed_by, claimed_until, " \
          "started_at, completed_at, error FROM " \
          "#{adapter.quote_ident(Bookkeeping::MIGRATION_TABLE)} " \
          "WHERE status IN (#{adapter.placeholders(3)}) ORDER BY id DESC LIMIT 1",
          MIGRATION_PENDING, MIGRATION_RUNNING, MIGRATION_FAILED
        ) do |rs|
          rows << read_migration_row(rs)
        end
        rows.first?
      end

      def insert_migration(adapter, executor : Adapter::Base::Executor,
                           source_hash : String, target_hash : String) : Int64
        adapter.insert_returning_id(
          executor,
          "INSERT INTO #{adapter.quote_ident(Bookkeeping::MIGRATION_TABLE)} " \
          "(source_hash, target_hash, status, started_at) " \
          "VALUES (#{adapter.placeholders(4)})",
          source_hash, target_hash, MIGRATION_PENDING, Time.utc.to_rfc3339
        )
      end

      def mark_migration_running(adapter, executor : Adapter::Base::Executor, id : Int64) : Nil
        executor.exec(
          "UPDATE #{adapter.quote_ident(Bookkeeping::MIGRATION_TABLE)} " \
          "SET status = #{adapter.placeholder(1)} WHERE id = #{adapter.placeholder(2)}",
          MIGRATION_RUNNING, id
        )
      end

      def mark_migration_complete(adapter, executor : Adapter::Base::Executor, id : Int64) : Nil
        executor.exec(
          "UPDATE #{adapter.quote_ident(Bookkeeping::MIGRATION_TABLE)} " \
          "SET status = #{adapter.placeholder(1)}, completed_at = #{adapter.placeholder(2)}, " \
          "claimed_by = NULL, claimed_until = NULL " \
          "WHERE id = #{adapter.placeholder(3)}",
          MIGRATION_COMPLETE, Time.utc.to_rfc3339, id
        )
      end

      def mark_migration_failed(adapter, executor : Adapter::Base::Executor,
                                id : Int64, error : String) : Nil
        executor.exec(
          "UPDATE #{adapter.quote_ident(Bookkeeping::MIGRATION_TABLE)} " \
          "SET status = #{adapter.placeholder(1)}, error = #{adapter.placeholder(2)}, " \
          "claimed_by = NULL, claimed_until = NULL " \
          "WHERE id = #{adapter.placeholder(3)}",
          MIGRATION_FAILED, error, id
        )
      end

      def mark_migration_aborted(adapter, executor : Adapter::Base::Executor, id : Int64) : Nil
        executor.exec(
          "UPDATE #{adapter.quote_ident(Bookkeeping::MIGRATION_TABLE)} " \
          "SET status = #{adapter.placeholder(1)}, claimed_by = NULL, claimed_until = NULL " \
          "WHERE id = #{adapter.placeholder(2)}",
          MIGRATION_ABORTED, id
        )
      end

      # ---- step rows --------------------------------------------------------

      def insert_steps(adapter, executor : Adapter::Base::Executor,
                       migration_id : Int64, steps : Array(Steps::Kind::Any)) : Nil
        steps.each_with_index do |step, ordinal|
          encoded = Steps::Codec.encode(step)
          executor.exec(
            "INSERT INTO #{adapter.quote_ident(Bookkeeping::MIGRATION_STEP_TABLE)} " \
            "(migration_id, ordinal, kind, params, status) " \
            "VALUES (#{adapter.placeholders(5)})",
            migration_id, ordinal, encoded[:kind], encoded[:params], STEP_PENDING
          )
        end
      end

      def steps_for(adapter, executor : Adapter::Base::Executor,
                    migration_id : Int64) : Array(StepRow)
        rows = [] of StepRow
        executor.query_each(
          "SELECT migration_id, ordinal, kind, params, status, progress, " \
          "started_at, completed_at FROM " \
          "#{adapter.quote_ident(Bookkeeping::MIGRATION_STEP_TABLE)} " \
          "WHERE migration_id = #{adapter.placeholder(1)} ORDER BY ordinal",
          migration_id
        ) do |rs|
          rows << read_step_row(rs)
        end
        rows
      end

      def mark_step_running(adapter, executor : Adapter::Base::Executor,
                            migration_id : Int64, ordinal : Int32) : Nil
        executor.exec(
          "UPDATE #{adapter.quote_ident(Bookkeeping::MIGRATION_STEP_TABLE)} " \
          "SET status = #{adapter.placeholder(1)}, started_at = #{adapter.placeholder(2)} " \
          "WHERE migration_id = #{adapter.placeholder(3)} AND ordinal = #{adapter.placeholder(4)}",
          STEP_RUNNING, Time.utc.to_rfc3339, migration_id, ordinal
        )
      end

      def mark_step_complete(adapter, executor : Adapter::Base::Executor,
                             migration_id : Int64, ordinal : Int32) : Nil
        executor.exec(
          "UPDATE #{adapter.quote_ident(Bookkeeping::MIGRATION_STEP_TABLE)} " \
          "SET status = #{adapter.placeholder(1)}, completed_at = #{adapter.placeholder(2)} " \
          "WHERE migration_id = #{adapter.placeholder(3)} AND ordinal = #{adapter.placeholder(4)}",
          STEP_COMPLETE, Time.utc.to_rfc3339, migration_id, ordinal
        )
      end

      def mark_step_failed(adapter, executor : Adapter::Base::Executor,
                           migration_id : Int64, ordinal : Int32) : Nil
        executor.exec(
          "UPDATE #{adapter.quote_ident(Bookkeeping::MIGRATION_STEP_TABLE)} " \
          "SET status = #{adapter.placeholder(1)} " \
          "WHERE migration_id = #{adapter.placeholder(2)} AND ordinal = #{adapter.placeholder(3)}",
          STEP_FAILED, migration_id, ordinal
        )
      end

      # ---- internals --------------------------------------------------------

      private def read_migration_row(rs) : MigrationRow
        MigrationRow.new(
          id: rs.read(Int64),
          source_hash: rs.read(String),
          target_hash: rs.read(String),
          status: rs.read(String),
          claimed_by: rs.read(String?),
          claimed_until: parse_time(rs.read(String?)),
          started_at: parse_time(rs.read(String?)),
          completed_at: parse_time(rs.read(String?)),
          error: rs.read(String?),
        )
      end

      private def read_step_row(rs) : StepRow
        StepRow.new(
          migration_id: rs.read(Int64),
          ordinal: rs.read(Int32),
          kind: rs.read(String),
          params: rs.read(String),
          status: rs.read(String),
          progress: rs.read(String?),
          started_at: parse_time(rs.read(String?)),
          completed_at: parse_time(rs.read(String?)),
        )
      end

      private def parse_time(s : String?) : Time?
        return nil unless s
        Time.parse_rfc3339(s)
      end
    end
  end
end
