module Prostore
  module Schema
    # A column declaration captured from a `field` macro call (ADR-0002, 0004,
    # 0011, 0013, 0014).
    #
    # The actual default/backfill/lazy lambdas (when present) are not stored
    # here — they are captured separately at the macro level and referenced by
    # generated code. This struct holds only schema-level facts that survive
    # into the fingerprint, the diff engine, and the migration plan.
    # Note on String typing: while the user-facing DSL accepts Symbols
    # (`field 1, :id, ...`), the macro stores the column name as a String at
    # the schema-model level. This lets prostore round-trip schema state
    # through JSON for ADR-0009's persisted migration plan. The Crystal
    # type system can't construct Symbols at runtime, so a String here is
    # what makes resume work.
    record Field,
      tag : Int32,
      name : String,
      crystal_type : String,
      portable_type : String,
      nullable : Bool,
      primary : Bool,
      auto_increment : Bool,
      has_default : Bool,
      default_sql : String?,
      has_backfill : Bool,
      backfill_sql : String?,
      has_lazy : Bool do
      def has_lambda_default? : Bool
        has_default && default_sql.nil?
      end

      def has_lambda_backfill? : Bool
        has_backfill && backfill_sql.nil?
      end
    end
  end
end
