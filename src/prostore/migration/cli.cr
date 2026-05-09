require "../connection"
require "./bookkeeping"
require "./state"

module Prostore
  module Migration
    # CLI helpers (`bin/prostore`).
    #
    # Operator-facing surface: status, abort, drift check. Each takes a
    # `Prostore::Connection` and writes to an IO so callers can compose them
    # into a CLI binary or call them programmatically from tests.
    module CLI
      extend self

      # Print the current migration state. Lists in-progress and completed
      # migrations with their step status.
      def status(conn : Connection, io : IO = STDOUT) : Nil
        Bookkeeping.ensure_tables(conn.adapter, conn.db)

        io.puts "Migrations"
        conn.db.query_each(
          "SELECT id, target_hash, status, claimed_by, claimed_until, started_at, completed_at, error " \
          "FROM #{conn.adapter.quote_ident(Bookkeeping::MIGRATION_TABLE)} ORDER BY id"
        ) do |rs|
          id = rs.read(Int64)
          target = rs.read(String)
          status = rs.read(String)
          claimed_by = rs.read(String?)
          claimed_until = rs.read(String?)
          started_at = rs.read(String?)
          completed_at = rs.read(String?)
          error = rs.read(String?)

          io.puts "  ##{id}  #{status.ljust(10)}  target=#{target[0, 12]}…  started=#{started_at}"
          io.puts "       claimed_by=#{claimed_by} until=#{claimed_until}" if claimed_by
          io.puts "       completed=#{completed_at}" if completed_at
          io.puts "       error: #{error}" if error
        end

        io.puts ""
        io.puts "Drift"
        rows = Drift::SchemaTable.all(conn.adapter, conn.db)
        report = Drift::Detector.detect(conn.adapter, conn.db, rows)
        if report.ops.empty?
          io.puts "  none"
        else
          io.puts "  #{report.ops.size} fixable drift operation(s) pending. Run migrate to apply."
        end
      end

      # Abort an in-progress migration. Marks the migration `aborted` and
      # releases its lease. Per ADR-0009, completed steps are not reversed —
      # operators must use the removal lifecycle (ADR-0008) for full revert.
      def abort(conn : Connection, migration_id : Int64, io : IO = STDOUT) : Nil
        State.mark_migration_aborted(conn.adapter, conn.db, migration_id)
        io.puts "Migration #{migration_id} aborted. Completed steps are not reversed."
      end

      # Dry-run drift detection without applying any DDL.
      def drift_check(conn : Connection, io : IO = STDOUT) : Nil
        Bookkeeping.ensure_tables(conn.adapter, conn.db)
        rows = Drift::SchemaTable.all(conn.adapter, conn.db)

        report = Drift::Detector.detect(conn.adapter, conn.db, rows)
        if report.ops.empty?
          io.puts "No drift detected."
          return
        end

        io.puts "Detected #{report.ops.size} fixable drift operation(s):"
        report.ops.each do |op|
          io.puts "  - #{op.class.name}: #{op.inspect}"
        end
      end
    end
  end
end
