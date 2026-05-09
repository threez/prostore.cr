require "../schema"

module Prostore
  module Query
    # Static analysis of named queries (ADR-0006).
    #
    # Walks each `Schema::Query`'s call chain — captured at macro time as
    # `Schema::Call` records — and classifies every field reference:
    #
    #   :filtered   — appears in `where(field: ...)`
    #   :sorted     — appears in `order_by(:field, ...)` / `order_by(field, ...)`
    #   :grouped    — appears in `group_by(...)` (reserved)
    #
    # The analyzer drives two ADR-0006 outcomes:
    #
    #   1. **Required-index check.** Every (filtered or sorted) field on a
    #      query must be covered by a declared index in the model. ADR-0006
    #      strict-mode makes this a hard error.
    #
    #   2. **Lazy override.** A `lazy:` field that's referenced non-
    #      projectionally (filtered/sorted/joined) cannot remain lazy; the
    #      planner must materialize it eagerly. The override is reported and
    #      the field is treated as if `lazy:` were absent for index planning.
    module Analyzer
      extend self

      record Usage,
        filtered : Set(String),
        sorted : Set(String)

      record Report,
        per_query : Hash(Symbol, Usage),
        all_filtered : Set(String),
        all_sorted : Set(String),
        lazy_override_fields : Set(String) do
        def column_referenced?(name : String) : Bool
          all_filtered.includes?(name) || all_sorted.includes?(name)
        end
      end

      def analyze(definition : Schema::Definition) : Report
        per_query = {} of Symbol => Usage
        all_filtered = Set(String).new
        all_sorted = Set(String).new

        definition.queries.each do |query|
          usage = analyze_query(query)
          per_query[query.name] = usage
          all_filtered.concat(usage.filtered)
          all_sorted.concat(usage.sorted)
        end

        # Lazy override: any lazy field referenced non-projectionally.
        lazy_override = Set(String).new
        definition.fields.each do |field|
          if field.has_lazy && (all_filtered.includes?(field.name) || all_sorted.includes?(field.name))
            lazy_override << field.name
          end
        end

        Report.new(per_query: per_query,
          all_filtered: all_filtered,
          all_sorted: all_sorted,
          lazy_override_fields: lazy_override)
      end

      # Per-query classification.
      def analyze_query(q : Schema::Query) : Usage
        filtered = Set(String).new
        sorted = Set(String).new

        q.calls.each do |call|
          case call.name
          when "where"
            # Named-arg keys are field names: where(email: e) → ["email"].
            call.named_arg_keys.each { |k| filtered << k }
          when "order_by"
            # `order_by(:score, desc: true)` — positional SymbolLiterals
            # captured at macro time. `desc:` is the modifier flag, never
            # a sort field.
            call.positional_symbols.each { |sym| sorted << sym }
            # `order_by(field: :score)` — named-arg form. Skip `desc:`,
            # which carries direction not field name.
            call.named_arg_keys.each { |k| sorted << k unless k == "desc" }
          end
        end

        Usage.new(filtered: filtered, sorted: sorted)
      end

      # Required-index check (ADR-0006). Raises `Prostore::SchemaError` if a
      # filtered or sorted field on any named query lacks index coverage.
      #
      # Composite-index covering rule: a field is covered by an index if it
      # appears at position N of that index's column list AND every column
      # at positions [0, N) of that same index is also filtered in the same
      # query (the standard left-prefix rule). The leading column (N=0) is
      # always covered if the field is filtered or sorted at all.
      #
      # The primary key is treated as a single-column index covering the PK.
      def validate_indexes!(definition : Schema::Definition, report : Report = analyze(definition)) : Nil
        # Build the index list with the PK as a virtual single-column index.
        all_indexes = definition.indexes.map { |i| {name: i.name, columns: i.columns} }
        if pk = definition.primary_key
          all_indexes << {name: "(primary key)", columns: [pk.name]}
        end

        missing_per_query = {} of Symbol => Set(String)
        report.per_query.each do |q_name, usage|
          q_filtered = usage.filtered
          q_sorted = usage.sorted

          # For each field this query needs covered, check whether SOME index
          # covers it under the left-prefix rule given the same query's
          # filter set.
          (q_filtered + q_sorted).each do |field|
            covered = all_indexes.any? do |idx|
              field_at_index_position?(idx[:columns], field, q_filtered)
            end
            unless covered
              (missing_per_query[q_name] ||= Set(String).new) << field
            end
          end
        end

        return if missing_per_query.empty?

        details = missing_per_query.map do |query, fields|
          "  #{query.inspect}: #{fields.to_a.sort.join(", ")}"
        end.join("\n")

        raise Prostore::SchemaError.new(
          "Named queries on table '#{definition.table_name}' filter or sort by " \
          "fields without index coverage (ADR-0006 strict mode):\n#{details}\n" \
          "Declare a single-column or leading-prefix-aligned composite index."
        )
      end

      # Is `field` covered by the index whose columns are `index_cols`,
      # given that `query_filtered` is the set of fields the query also
      # filters on? Standard left-prefix rule.
      private def field_at_index_position?(index_cols : Array(String),
                                           field : String,
                                           query_filtered : Set(String)) : Bool
        idx_pos = index_cols.index(field)
        return false unless idx_pos
        return true if idx_pos == 0
        # Non-leading: every preceding column of this index must also be
        # filtered in the same query.
        index_cols[0...idx_pos].all? { |col| query_filtered.includes?(col) }
      end
    end
  end
end
