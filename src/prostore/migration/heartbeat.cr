require "db"
require "../connection"
require "./bookkeeping"
require "./lease"

module Prostore
  module Migration
    # Background fiber that renews the migration lease while a long step
    # is running (ADR-0009 invariant 5).
    #
    # Without a heartbeat, the lease only renews between steps in the
    # runner's loop. A single multi-minute step (large eager-Crystal-lambda
    # backfill, slow `CREATE INDEX CONCURRENTLY`, big table rebuild on
    # SQLite) can outlast the lease and lose it to another runner.
    #
    # The fiber wakes every `interval` (default 1 minute), tries to claim a
    # connection from the pool, calls `Lease.heartbeat`. If the pool can't
    # spare a connection (e.g., in-memory SQLite with pool size 1) the
    # heartbeat is silently skipped — the runner's between-steps heartbeat
    # is still in play, which is sufficient for the SQLite case where steps
    # are fast anyway. If `Lease.heartbeat` reports the lease was stolen,
    # the fiber sets `lost?` and the runner aborts before the next step.
    #
    # Cleanly stoppable via a `Channel`; `stop` waits for the fiber to
    # actually exit so the connection can be closed safely.
    class HeartbeatFiber
      DEFAULT_INTERVAL = 1.minute

      def initialize(@conn : Connection,
                     @migration_id : Int64,
                     @runner_id : String,
                     @interval : Time::Span = DEFAULT_INTERVAL,
                     @lease_duration : Time::Span = Lease::DEFAULT_DURATION)
        # Buffered (capacity 1) so `stop`'s send never blocks even when the
        # fiber has already exited via the lost-lease path. `done` is
        # buffered for the same reason — the fiber sends before main waits.
        @stop = Channel(Nil).new(1)
        @done = Channel(Nil).new(1)
        @lost = false
      end

      def start : Nil
        spawn do
          heartbeat_loop
          @done.send(nil)
        end
      end

      def stop : Nil
        @stop.send(nil)
        @done.receive
      end

      def lost? : Bool
        @lost
      end

      private def heartbeat_loop : Nil
        loop do
          select
          when @stop.receive
            return
          when timeout(@interval)
            unless attempt
              @lost = true
              return
            end
          end
        end
      end

      private def attempt : Bool
        @conn.with_connection do |db_conn|
          Lease.heartbeat(@conn.adapter, db_conn, @migration_id, @runner_id, @lease_duration)
        end
      rescue DB::PoolTimeout
        # Pool can't spare a connection (e.g., single-pool SQLite). The
        # runner's between-steps heartbeat keeps the lease alive, so this
        # is a graceful no-op rather than a failure.
        true
      rescue
        false
      end
    end
  end
end
