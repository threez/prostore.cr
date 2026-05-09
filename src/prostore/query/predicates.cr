require "./ast"

module Prostore
  module Query
    # Free-standing predicate constructors so users can build expressions
    # outside the named-arg `where` shorthand. The Builder also exposes
    # these as instance methods for use inside the `with builder` block
    # context emitted by the `query` macro.
    #
    # ```
    # User.where(Q.or(Q.eq(:status, "active"), Q.eq(:status, "pending")))
    # User.where(Q.gt(:score, 100))
    # User.where(Q.null?(:deleted_at))
    # ```
    module Q
      extend self

      def eq(field : Symbol | String, value) : AST::Predicate
        if value.nil?
          AST::IsNull.new(field.to_s)
        else
          AST::Eq.new(field.to_s, value.as(::DB::Any))
        end
      end

      def ne(field : Symbol | String, value) : AST::Predicate
        if value.nil?
          AST::IsNull.new(field.to_s, negated: true)
        else
          AST::Cmp.new(field.to_s, "!=", value.as(::DB::Any))
        end
      end

      def lt(field : Symbol | String, value) : AST::Predicate
        AST::Cmp.new(field.to_s, "<", value.as(::DB::Any))
      end

      def lte(field : Symbol | String, value) : AST::Predicate
        AST::Cmp.new(field.to_s, "<=", value.as(::DB::Any))
      end

      def gt(field : Symbol | String, value) : AST::Predicate
        AST::Cmp.new(field.to_s, ">", value.as(::DB::Any))
      end

      def gte(field : Symbol | String, value) : AST::Predicate
        AST::Cmp.new(field.to_s, ">=", value.as(::DB::Any))
      end

      def in(field : Symbol | String, values : Array) : AST::Predicate
        AST::In.new(field.to_s, values.map(&.as(::DB::Any)))
      end

      def null?(field : Symbol | String) : AST::Predicate
        AST::IsNull.new(field.to_s)
      end

      def not_null?(field : Symbol | String) : AST::Predicate
        AST::IsNull.new(field.to_s, negated: true)
      end

      def like(field : Symbol | String, pattern : String) : AST::Predicate
        AST::Like.new(field.to_s, pattern)
      end

      def all(*predicates : AST::Predicate) : AST::Predicate
        AST::All.new(predicates.to_a)
      end

      def any(*predicates : AST::Predicate) : AST::Predicate
        AST::Any.new(predicates.to_a)
      end

      def not(predicate : AST::Predicate) : AST::Predicate
        AST::Not.new(predicate)
      end
    end
  end

  # Convenience top-level constant.
  Q = Query::Q
end
