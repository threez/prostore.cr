require "db"
require "../adapter/base"
require "./ast"
require "./predicates"
require "./renderer"

module Prostore
  module Query
    # Chainable query builder. Each chained call returns a new builder with
    # one extra clause; the original is unchanged. Materialization happens
    # via `to_a`, `each`, `first`, `count`, etc.
    #
    # Generic over `T` (the model instance type the builder yields). The
    # macro `query :name, ->(...) { ... }` emits a class method that
    # constructs a Builder(self) and runs the lambda body inside a
    # `with builder` block, so `where(...)`, `order_by(...)` etc. inside
    # the lambda dispatch to the builder.
    class Builder(T)
      getter table : String
      getter field_names : Array(String)
      getter adapter : Adapter::Base
      getter db : DB::Database

      def initialize(@table : String,
                     @field_names : Array(String),
                     @materializer : DB::ResultSet -> T,
                     @adapter : Adapter::Base,
                     @db : DB::Database,
                     @plan : Renderer::Plan = Renderer::Plan.new,
                     @partial_materializer : (DB::ResultSet, Array(String) -> T)? = nil)
      end

      # Inside-block builder for the macro-emitted class methods. The
      # `with builder yield` makes naked `where(...)` etc. inside the
      # lambda body resolve to instance methods on the builder.
      def in_query(&)
        with self yield
      end

      # ----- predicate adders -----

      def where(**kwargs) : Builder(T)
        new_preds = @plan.predicates.dup
        kwargs.each do |k, v|
          new_preds << build_predicate(k.to_s, v)
        end
        with_plan(@plan.copy_with(predicates: new_preds))
      end

      def where(predicate : AST::Predicate) : Builder(T)
        new_preds = @plan.predicates.dup << predicate
        with_plan(@plan.copy_with(predicates: new_preds))
      end

      # ----- ordering / paging -----

      def order_by(field : Symbol | String, desc : Bool = false) : Builder(T)
        new_orderings = @plan.orderings.dup << AST::Order.new(field.to_s, desc)
        with_plan(@plan.copy_with(orderings: new_orderings))
      end

      def limit(n : Int32) : Builder(T)
        with_plan(@plan.copy_with(limit: n))
      end

      def offset(n : Int32) : Builder(T)
        with_plan(@plan.copy_with(offset: n))
      end

      # Project only the named columns in the resulting SELECT (ADR-0014).
      # Materialized instances will have only the projected fields populated;
      # other ivars stay nil and accessing a non-projected non-nullable field
      # raises (per the model's standard accessor semantics).
      def select(*fields : Symbol | String) : Builder(T)
        names = fields.to_a.map(&.to_s)
        with_plan(@plan.copy_with(selected_fields: names))
      end

      # ----- joins -----

      # Explicit join with caller-supplied source/target column lists.
      def joins(target_table : String,
                source_columns : Array(String),
                target_columns : Array(String)) : Builder(T)
        new_joins = @plan.joins.dup << AST::Join.new(target_table, source_columns, target_columns)
        with_plan(@plan.copy_with(joins: new_joins))
      end

      # FK-resolved join. Looks for a foreign key linking `T` (the source
      # model) and `target_class`. If multiple FKs exist between the two,
      # `fk_tag` disambiguates.
      #
      # Resolution rules:
      #   1. FK on the *target* references the *source* (e.g., `User.joins(Order)`
      #      where Order has `foreign_key … references: User`):
      #        ON source.pk = target.fk_columns
      #   2. FK on the *source* references the *target* (e.g., `Order.joins(User)`):
      #        ON source.fk_columns = target.pk
      #   3. Neither found → raise `Prostore::Error`.
      def joins(target_class : Prostore::Model.class, fk_tag : Int32? = nil) : Builder(T)
        source_schema = T.prostore_schema
        target_schema = target_class.prostore_schema

        target_to_source = target_schema.foreign_keys.select do |fk|
          fk.references_table == source_schema.table_name && (fk_tag.nil? || fk.tag == fk_tag)
        end

        source_to_target = source_schema.foreign_keys.select do |fk|
          fk.references_table == target_schema.table_name && (fk_tag.nil? || fk.tag == fk_tag)
        end

        total = target_to_source.size + source_to_target.size
        if total > 1 && fk_tag.nil?
          raise Prostore::Error.new(
            "Ambiguous join between #{source_schema.table_name} and " \
            "#{target_schema.table_name}: #{total} foreign keys exist. " \
            "Pass `fk: <tag>` to disambiguate."
          )
        end

        if fk = target_to_source.first?
          src_pk = source_schema.primary_key.try(&.name) ||
                   raise Prostore::Error.new("Source #{source_schema.table_name} has no primary key for FK join")
          src_cols = fk.references_columns.empty? ? [src_pk] : fk.references_columns
          return joins(target_schema.table_name, src_cols, fk.columns)
        end

        if fk = source_to_target.first?
          tgt_pk = target_schema.primary_key.try(&.name) ||
                   raise Prostore::Error.new("Target #{target_schema.table_name} has no primary key for FK join")
          tgt_cols = fk.references_columns.empty? ? [tgt_pk] : fk.references_columns
          return joins(target_schema.table_name, fk.columns, tgt_cols)
        end

        raise Prostore::Error.new(
          "No foreign key found between #{source_schema.table_name} and " \
          "#{target_schema.table_name}. Either declare a `foreign_key` on one " \
          "side or use `joins(table, src_cols, tgt_cols)`."
        )
      end

      # ----- materialization -----

      def to_a : Array(T)
        rendered = Renderer.render_select(@table, @field_names, @plan, @adapter)
        out = [] of T
        @db.query_each(rendered.sql, args: rendered.args) do |rs|
          out << materialize(rs)
        end
        out
      end

      def each(&) : Nil
        rendered = Renderer.render_select(@table, @field_names, @plan, @adapter)
        @db.query_each(rendered.sql, args: rendered.args) do |rs|
          yield materialize(rs)
        end
      end

      private def materialize(rs : DB::ResultSet) : T
        if cols = @plan.selected_fields
          if pm = @partial_materializer
            pm.call(rs, cols)
          else
            raise Prostore::Error.new("`select` is in use but the model didn't supply a partial materializer")
          end
        else
          @materializer.call(rs)
        end
      end

      def first : T?
        limit(1).to_a.first?
      end

      def first! : T
        first || raise Prostore::Error.new("expected one row from #{@table}, got none")
      end

      def count : Int64
        rendered = Renderer.render_select(@table, @field_names, @plan, @adapter, count_only: true)
        @db.scalar(rendered.sql, args: rendered.args).as(Int64 | Int32).to_i64
      end

      def empty? : Bool
        count.zero?
      end

      def exists? : Bool
        !empty?
      end

      # ----- internals -----

      private def with_plan(plan : Renderer::Plan) : Builder(T)
        Builder(T).new(@table, @field_names, @materializer, @adapter, @db, plan, @partial_materializer)
      end

      private def build_predicate(field : String, value) : AST::Predicate
        case value
        when Nil
          AST::IsNull.new(field)
        when ::Range
          low = value.begin
          high = value.end
          exclusive = value.excludes_end?
          AST::RangePred.new(
            field,
            low.nil? ? nil : low.as(::DB::Any),
            high.nil? ? nil : high.as(::DB::Any),
            exclusive
          )
        when Array
          AST::In.new(field, value.map(&.as(::DB::Any)))
        when AST::Predicate
          value
        else
          AST::Eq.new(field, value.as(::DB::Any))
        end
      end
    end
  end
end
