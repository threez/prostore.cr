module Prostore
  module Schema
    # A named query declaration (ADR-0006).
    #
    # Captures the name and the chain of DSL calls observed in the lambda
    # body (e.g., `where`, `order_by`, `limit`). The `Query::Analyzer`
    # consumes this to classify field accesses (filtered/sorted) and drive
    # index planning plus the eager-vs-lazy override.
    record Call,
      name : String,
      arity : Int32,
      named_arg_keys : Array(String),
      # Positional `SymbolLiteral` arguments — e.g., the `:score` in
      # `order_by(:score, desc: true)`. Captured at macro time so the
      # analyzer can recognize positional sort fields without forcing the
      # named-arg form on users.
      positional_symbols : Array(String) = [] of String

    record Query,
      name : Symbol,
      calls : Array(Call)
  end
end
