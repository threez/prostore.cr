require "db"
require "../adapter/base"
require "./bookkeeping"
require "./state"

module Prostore
  module Migration
    # Lease-based mutex for migrations (ADR-0009 invariant 5).
    module Lease
      extend self

      DEFAULT_DURATION = 5.minutes

      # Returns true if the lease was successfully claimed; false if another
      # live lease is held.
      def claim(adapter, executor : Adapter::Base::Executor,
                migration_id : Int64, runner_id : String,
                duration : Time::Span = DEFAULT_DURATION) : Bool
        now = Time.utc
        until_ts = (now + duration).to_rfc3339

        executor.exec(
          "UPDATE #{adapter.quote_ident(Bookkeeping::MIGRATION_TABLE)} " \
          "SET claimed_by = #{adapter.placeholder(1)}, claimed_until = #{adapter.placeholder(2)} " \
          "WHERE id = #{adapter.placeholder(3)} AND " \
          "(claimed_by IS NULL OR claimed_until <= #{adapter.placeholder(4)})",
          runner_id, until_ts, migration_id, now.to_rfc3339
        )

        held = executor.scalar(
          "SELECT claimed_by FROM #{adapter.quote_ident(Bookkeeping::MIGRATION_TABLE)} " \
          "WHERE id = #{adapter.placeholder(1)}",
          migration_id
        ).as(String?)
        held == runner_id
      end

      def heartbeat(adapter, executor : Adapter::Base::Executor,
                    migration_id : Int64, runner_id : String,
                    duration : Time::Span = DEFAULT_DURATION) : Bool
        until_ts = (Time.utc + duration).to_rfc3339
        executor.exec(
          "UPDATE #{adapter.quote_ident(Bookkeeping::MIGRATION_TABLE)} " \
          "SET claimed_until = #{adapter.placeholder(1)} " \
          "WHERE id = #{adapter.placeholder(2)} AND claimed_by = #{adapter.placeholder(3)}",
          until_ts, migration_id, runner_id
        )

        held = executor.scalar(
          "SELECT claimed_by FROM #{adapter.quote_ident(Bookkeeping::MIGRATION_TABLE)} " \
          "WHERE id = #{adapter.placeholder(1)}",
          migration_id
        ).as(String?)
        held == runner_id
      end

      def release(adapter, executor : Adapter::Base::Executor,
                  migration_id : Int64, runner_id : String) : Nil
        executor.exec(
          "UPDATE #{adapter.quote_ident(Bookkeeping::MIGRATION_TABLE)} " \
          "SET claimed_by = NULL, claimed_until = NULL " \
          "WHERE id = #{adapter.placeholder(1)} AND claimed_by = #{adapter.placeholder(2)}",
          migration_id, runner_id
        )
      end

      def runner_id : String
        "#{Process.pid}-#{Random::Secure.hex(4)}"
      end
    end
  end
end
