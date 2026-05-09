require "db"
require "../adapter/base"
require "./ast"

module Prostore
  module Query
    # Render an AST into adapter-specific SQL plus a positional argument
    # list. Placeholder syntax comes from the adapter (`?` for SQLite,
    # `$N` for Postgres) so the same renderer works for both backends.
    module Renderer
      record Rendered, sql : String, args : Array(::DB::Any)

      record Plan,
        predicates : Array(AST::Predicate) = [] of AST::Predicate,
        orderings : Array(AST::Order) = [] of AST::Order,
        joins : Array(AST::Join) = [] of AST::Join,
        limit : Int32? = nil,
        offset : Int32? = nil,
        # `select(:cols)` projection (ADR-0014). When nil, the renderer
        # SELECTs every field declared on the model.
        selected_fields : Array(String)? = nil

      def self.render_select(table : String,
                             fields : Array(String),
                             plan : Plan,
                             adapter : Adapter::Base,
                             count_only : Bool = false) : Rendered
        args = [] of ::DB::Any
        param_index = 0

        next_placeholder = -> {
          param_index += 1
          adapter.placeholder(param_index)
        }

        io = IO::Memory.new
        io << "SELECT "
        if count_only
          io << "COUNT(*)"
        else
          effective_fields = plan.selected_fields || fields
          io << effective_fields.map { |field| %("#{table}"."#{field}") }.join(", ")
        end
        io << " FROM " << adapter.quote_ident(table)

        plan.joins.each do |join|
          io << " INNER JOIN " << adapter.quote_ident(join.target_table) << " ON "
          conds = join.source_columns.zip(join.target_columns).map do |src, tgt|
            %("#{table}"."#{src}" = "#{join.target_table}"."#{tgt}")
          end
          io << conds.join(" AND ")
        end

        unless plan.predicates.empty?
          io << " WHERE "
          io << plan.predicates.map { |pred| render_predicate(pred, args, next_placeholder) }.join(" AND ")
        end

        unless plan.orderings.empty?
          io << " ORDER BY "
          io << plan.orderings.map { |ordering| %("#{table}"."#{ordering.field}") + (ordering.desc ? " DESC" : " ASC") }.join(", ")
        end

        if l = plan.limit
          io << " LIMIT " << next_placeholder.call
          args << l.as(::DB::Any)
        end

        if o = plan.offset
          io << " OFFSET " << next_placeholder.call
          args << o.as(::DB::Any)
        end

        Rendered.new(io.to_s, args)
      end

      def self.render_predicate(p : AST::Predicate,
                                args : Array(::DB::Any),
                                next_placeholder : -> String) : String
        case p
        when AST::Eq
          args << p.value
          %("#{p.field}" = #{next_placeholder.call})
        when AST::Cmp
          args << p.value
          %("#{p.field}" #{p.op} #{next_placeholder.call})
        when AST::In
          if p.values.empty?
            "1 = 0" # IN () with empty list: never matches
          else
            placeholders = p.values.map do |v|
              args << v
              next_placeholder.call
            end
            %("#{p.field}" IN (#{placeholders.join(", ")}))
          end
        when AST::RangePred
          parts = [] of String
          if low = p.low
            args << low
            parts << %("#{p.field}" >= #{next_placeholder.call})
          end
          if high = p.high
            args << high
            op = p.exclusive_high? ? "<" : "<="
            parts << %("#{p.field}" #{op} #{next_placeholder.call})
          end
          parts.empty? ? "1 = 1" : parts.join(" AND ")
        when AST::IsNull
          %("#{p.field}" IS#{p.negated? ? " NOT" : ""} NULL)
        when AST::Like
          args << p.pattern.as(::DB::Any)
          %("#{p.field}" LIKE #{next_placeholder.call})
        when AST::All
          if p.predicates.empty?
            "1 = 1"
          else
            "(" + p.predicates.map { |pred| render_predicate(pred, args, next_placeholder) }.join(" AND ") + ")"
          end
        when AST::Any
          if p.predicates.empty?
            "1 = 0"
          else
            "(" + p.predicates.map { |pred| render_predicate(pred, args, next_placeholder) }.join(" OR ") + ")"
          end
        when AST::Not
          "NOT (" + render_predicate(p.predicate, args, next_placeholder) + ")"
        else
          raise Prostore::Error.new("unknown predicate kind: #{p.class}")
        end
      end
    end
  end
end
