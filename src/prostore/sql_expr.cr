module Prostore
  # A literal SQL fragment passed verbatim to the backend.
  #
  # `SQL.expr("now()")` is intended for static expressions in `default:`,
  # `backfill:`, and `where:` (partial index predicate) options. The library
  # does not parse the fragment — portability across SQLite and PostgreSQL is
  # the user's responsibility when targeting both.
  #
  # The macro wrapper at `Prostore::SQL.expr` rejects non-string-literal
  # arguments at compile time to prevent accidental Crystal-value
  # interpolation that would produce SQL injection.
  module SQL
    # A wrapped literal SQL fragment.
    struct Expr
      getter sql : String

      def initialize(@sql : String)
      end

      def to_s(io : IO) : Nil
        io << @sql
      end
    end

    # `SQL.expr("...")` — must be a string literal.
    #
    # Compile error if argument is interpolation, a method call, or a variable.
    macro expr(literal)
      {% unless literal.is_a?(StringLiteral) %}
        {% raise "SQL.expr requires a string literal, got #{literal.class_name}. Crystal-value interpolation is not allowed; use a Crystal lambda for parameterized population." %}
      {% end %}
      ::Prostore::SQL::Expr.new({{ literal }})
    end
  end
end
