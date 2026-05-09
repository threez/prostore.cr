require "db"

module Prostore
  module Query
    # Query AST nodes — pure data, no runtime behavior.
    #
    # The Builder constructs these; the Renderer walks them to emit SQL.
    # Predicates form a tree (And/Or/Not are recursive); leaf predicates
    # (Eq, Cmp, In, Range, IsNull, Like) reference a column name and value.
    module AST
      abstract class Predicate
      end

      class Eq < Predicate
        getter field : String
        getter value : ::DB::Any

        def initialize(@field, @value)
        end
      end

      class Cmp < Predicate
        getter field : String
        getter op : String # "<", "<=", ">", ">=", "!="
        getter value : ::DB::Any

        def initialize(@field, @op, @value)
        end
      end

      class In < Predicate
        getter field : String
        getter values : Array(::DB::Any)

        def initialize(@field, @values)
        end
      end

      class RangePred < Predicate
        getter field : String
        getter low : ::DB::Any?
        getter high : ::DB::Any?
        getter? exclusive_high : Bool

        def initialize(@field, @low, @high, @exclusive_high = false)
        end
      end

      class IsNull < Predicate
        getter field : String
        getter? negated : Bool

        def initialize(@field, @negated = false)
        end
      end

      class Like < Predicate
        getter field : String
        getter pattern : String

        def initialize(@field, @pattern)
        end
      end

      class All < Predicate
        getter predicates : Array(Predicate)

        def initialize(@predicates)
        end
      end

      class Any < Predicate
        getter predicates : Array(Predicate)

        def initialize(@predicates)
        end
      end

      class Not < Predicate
        getter predicate : Predicate

        def initialize(@predicate)
        end
      end

      record Order, field : String, desc : Bool

      record Join,
        target_table : String,
        source_columns : Array(String),
        target_columns : Array(String)
    end
  end
end
