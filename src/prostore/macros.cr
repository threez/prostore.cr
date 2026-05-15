require "./model"
require "./sql_expr"
require "./types"

# DSL macros installed on `Prostore::Model`. Each macro validates its
# arguments at compile time (raising via `{% raise ... %}`) and pushes a
# normalized record into the per-subclass accumulator constants set up by
# `Prostore::Model.inherited`. The synthesis into `Prostore::Schema::*`
# value types happens in the nested `macro finished` (in `model.cr`).

class Prostore::Model
  # ----------------------------------------------------------------- field

  # `field tag, :name, Type, **opts`
  #
  # Options (ADR-0011, 0013, 0014):
  #   primary:        Bool             (default false)
  #   auto_increment: Bool             (default false; requires Int32/Int64 + primary)
  #   default:        SQL.expr | Proc  (new-row strategy)
  #   backfill:       SQL.expr | Proc  (existing-row strategy)
  #   lazy:           Proc             (mutex with default: / backfill:; requires T?)
  macro field(tag, name, type, **opts)
    {%
      # Tag must be a positive integer literal.
      unless tag.is_a?(NumberLiteral)
        raise "field tag must be an integer literal, got #{tag.class_name}"
      end
      tag_value = tag

      unless name.is_a?(SymbolLiteral)
        raise "field name must be a symbol literal, got #{name.class_name}"
      end

      # Reject reuse against already-reserved or already-declared tags.
      if @type.constant("RESERVED_FIELD_TAGS").includes?(tag_value)
        raise "field tag #{tag_value} on #{@type.name} was reserved (ADR-0002)"
      end
      if @type.constant("FIELDS").any? { |field| field[:tag] == tag_value }
        raise "field tag #{tag_value} on #{@type.name} is already declared"
      end

      # Decompose nullability via Crystal's type system.
      resolved = type.resolve
      if resolved.nilable?
        nullable = true
        non_nil = resolved.union_types.reject { |union_t| union_t == Nil }
        if non_nil.size != 1
          raise "field type must be a simple type or T?, got #{type} on #{@type.name}"
        end
        underlying = non_nil[0]
      else
        nullable = false
        underlying = resolved
      end

      type_name = underlying.id.stringify

      # Recognize Array(T) where T is a known portable type. The macro
      # emits a synthetic portable tag of the form "array_<inner>"; the
      # SQLite affinity collapses these to TEXT (JSON-encoded) and the PG
      # mapping collapses them to JSONB. Native PG arrays (INTEGER[] etc.)
      # are deferred — JSONB gives a uniform IO path on day one.
      portable_type = nil
      is_enum = false
      enum_is_flags = false
      if type_name.starts_with?("Array(")
        inner_name = type_name[6..(type_name.size - 2)]
        unless ::Prostore::Types::PORTABLE.keys.includes?(inner_name)
          raise "field type Array(#{inner_name.id}) on #{@type.name}: inner type must be a portable type (ADR-0014, custom-types extension)."
        end
        inner_portable = ::Prostore::Types::PORTABLE[inner_name]
        portable_type = "array_" + inner_portable
      elsif underlying <= ::Enum
        # Enum field (ADR-0016, ADR-0017). Default storage is String
        # (member name); `as: :int` selects Int64 (member.value). `@[Flags]`
        # enums are implicitly int-backed because combinations (Read |
        # Write) only round-trip cleanly through the integer wire form.
        is_enum = true
        enum_is_flags = !underlying.annotation(::Flags).nil?
        storage = opts[:as] || :string
        if enum_is_flags
          if opts[:as] != nil && opts[:as] != :int
            raise "field #{name} on #{@type.name}: @[Flags] enum #{type_name.id} must be int-backed; omit `as:` or pass `as: :int`."
          end
          storage = :int
        end
        unless storage == :string || storage == :int
          raise "field #{name} on #{@type.name}: as: must be :string or :int, got #{storage}"
        end
        portable_type = storage == :int ? "enum_int" : "enum_string"
        # `naming:` selects how member names are translated to the storage
        # wire form for `enum_string` columns (ADR-0017). `:as_declared`
        # (default) keeps Crystal's PascalCase. `:snake_case`, `:lower_case`,
        # and `:kebab_case` cover the conventions apps already expose in
        # external surfaces (JSON, Prometheus, HTML option values).
        enum_naming = opts[:naming] || :as_declared
        allowed_naming = [:as_declared, :snake_case, :lower_case, :kebab_case]
        unless allowed_naming.includes?(enum_naming)
          raise "field #{name} on #{@type.name}: naming: must be one of #{allowed_naming}, got #{enum_naming}"
        end
        if portable_type == "enum_int" && enum_naming != :as_declared
          raise "field #{name} on #{@type.name}: naming: applies only to enum_string columns; an int-backed enum stores integers."
        end
      elsif ::Prostore::Types::PORTABLE.keys.includes?(type_name)
        portable_type = ::Prostore::Types::PORTABLE[type_name]
      else
        raise "field type #{type_name.id} is not in the portable type set (ADR-0014, 0015, 0016). " \
              "Allowed: Int32, Int64, Float32, Float64, String, Bool, Time, Bytes, UUID, BigDecimal, JSON::Any, " \
              "Array(T), or any Crystal Enum subclass."
      end
      crystal_type = nullable ? type_name + "?" : type_name

      # Option parsing.
      primary = opts[:primary] == true
      auto_increment = opts[:auto_increment] == true

      # `auto_increment` only on Int32/Int64 + primary (ADR-0013). Enums are
      # not eligible even when int-backed — the value space is the enum's
      # discrete members, not a generator sequence.
      if auto_increment
        unless primary
          raise "field #{name} on #{@type.name}: auto_increment requires primary: true (ADR-0013)"
        end
        if is_enum
          raise "field #{name} on #{@type.name}: auto_increment is not supported on enum fields (ADR-0013/0016)"
        end
        unless portable_type == "int32" || portable_type == "int64"
          raise "field #{name} on #{@type.name}: auto_increment requires Int32 or Int64 (ADR-0013)"
        end
      end

      # `as:` is only meaningful for enum types — flag the misuse so it isn't
      # silently ignored on other types.
      if opts[:as] != nil && !is_enum
        raise "field #{name} on #{@type.name}: `as:` is only valid for Enum field types (ADR-0016)"
      end
      # Same guard for `naming:` (ADR-0017) — non-enum types have no member
      # set to name.
      if opts[:naming] != nil && !is_enum
        raise "field #{name} on #{@type.name}: `naming:` is only valid for Enum field types (ADR-0017)"
      end

      # `lazy:` mutually exclusive with `default:` / `backfill:`; requires T?
      # (ADR-0011, 0014).
      has_lazy = opts[:lazy] != nil
      has_default = opts[:default] != nil
      has_backfill = opts[:backfill] != nil

      if has_lazy && (has_default || has_backfill)
        raise "field #{name} on #{@type.name}: lazy: is mutually exclusive with default: / backfill: (ADR-0011)"
      end
      if has_lazy && !nullable
        raise "field #{name} on #{@type.name}: lazy: requires the field type to be T? (ADR-0004)"
      end

      # Scalar literals (Bool, Number, String) are auto-wrapped in their SQL
      # equivalents and *also* captured as Crystal values so the ORM seeds
      # `@field` on save when the user hasn't touched it (ADR-0011 mechanism
      # 2, new-row half; covers the `.new + .save` flow that the DDL DEFAULT
      # alone misses because the macro always emits the column in the INSERT
      # column list). Symbol literals are emitted verbatim as SQL keywords /
      # function calls (:CURRENT_TIMESTAMP → CURRENT_TIMESTAMP) — those have
      # no Crystal-side value and remain DB-side only. SQL.expr("...") and
      # Crystal lambdas are also accepted.
      default_sql = nil
      default_value = nil
      if has_default
        if opts[:default].is_a?(BoolLiteral) ||
           opts[:default].is_a?(NumberLiteral) ||
           opts[:default].is_a?(StringLiteral)
          default_value = opts[:default]
        end

        if opts[:default].is_a?(BoolLiteral)
          default_sql = opts[:default].id.stringify
        elsif opts[:default].is_a?(NumberLiteral)
          default_sql = opts[:default].id.stringify
        elsif opts[:default].is_a?(StringLiteral)
          default_sql = "'" + opts[:default].id.stringify.gsub(/'/, "''") + "'"
        elsif opts[:default].is_a?(SymbolLiteral)
          default_sql = opts[:default].id.stringify
        elsif opts[:default].is_a?(Call) && opts[:default].name.id.stringify == "expr"
          default_sql = opts[:default].args[0].is_a?(StringLiteral) ? opts[:default].args[0] : nil
          if default_sql.nil?
            raise "field #{name} on #{@type.name}: SQL.expr requires a string literal argument"
          end
        elsif !opts[:default].is_a?(ProcLiteral)
          raise "field #{name} on #{@type.name}: default: accepts SQL.expr(...), a Crystal lambda, " \
                "a scalar literal (Bool, Int, String), or a symbol for SQL keywords/functions. " \
                "Got #{opts[:default].class_name}."
        end
      end

      backfill_sql = nil
      if has_backfill
        if opts[:backfill].is_a?(BoolLiteral)
          backfill_sql = opts[:backfill].id.stringify
        elsif opts[:backfill].is_a?(NumberLiteral)
          backfill_sql = opts[:backfill].id.stringify
        elsif opts[:backfill].is_a?(StringLiteral)
          backfill_sql = "'" + opts[:backfill].id.stringify.gsub(/'/, "''") + "'"
        elsif opts[:backfill].is_a?(SymbolLiteral)
          backfill_sql = opts[:backfill].id.stringify
        elsif opts[:backfill].is_a?(Call) && opts[:backfill].name.id.stringify == "expr"
          backfill_sql = opts[:backfill].args[0].is_a?(StringLiteral) ? opts[:backfill].args[0] : nil
          if backfill_sql.nil?
            raise "field #{name} on #{@type.name}: SQL.expr requires a string literal argument"
          end
        elsif !opts[:backfill].is_a?(ProcLiteral)
          raise "field #{name} on #{@type.name}: backfill: accepts SQL.expr(...), a Crystal lambda, " \
                "a scalar literal (Bool, Int, String), or a symbol for SQL keywords/functions. " \
                "Got #{opts[:backfill].class_name}."
        end
      end

      # Nullable fields without an explicit default/backfill carry an
      # implicit NULL. Making this explicit in the metadata keeps the
      # schema record symmetric with non-nullable fields, lets `:set_default`
      # FK actions target the NULL fallback, and removes the implicit
      # "absence of default == NULL" rule from downstream consumers. Lazy
      # fields are skipped — `lazy:` is mutually exclusive with default/
      # backfill (ADR-0011).
      if nullable && !has_default && !has_lazy
        has_default = true
        default_sql = "NULL"
      end
      if nullable && !has_backfill && !has_lazy
        has_backfill = true
        backfill_sql = "NULL"
      end

      # Capture lambda AST nodes for runtime invocation. The macro_finished
      # synthesizer emits these as class constants per tag.
      lazy_lambda = (has_lazy && opts[:lazy].is_a?(ProcLiteral)) ? opts[:lazy] : nil
      default_lambda = (has_default && opts[:default].is_a?(ProcLiteral)) ? opts[:default] : nil
      backfill_lambda = (has_backfill && opts[:backfill].is_a?(ProcLiteral)) ? opts[:backfill] : nil

      @type.constant("FIELDS") << {
        tag:             tag_value,
        name:            name,
        crystal_type:    crystal_type,
        portable_type:   portable_type,
        nullable:        nullable,
        primary:         primary,
        auto_increment:  auto_increment,
        has_default:     has_default,
        default_sql:     default_sql,
        default_value:   default_value,
        has_backfill:    has_backfill,
        backfill_sql:    backfill_sql,
        has_lazy:        has_lazy,
        lazy_lambda:     lazy_lambda,
        default_lambda:  default_lambda,
        backfill_lambda: backfill_lambda,
        ruby_type:       type,
        is_enum:         is_enum,
        enum_is_flags:   enum_is_flags,
        enum_class_id:   is_enum ? underlying.id.stringify : nil,
        enum_naming:     is_enum ? enum_naming : nil,
      }
    %}
  end

  # `reserved tag` — permanently retire a field tag (ADR-0002).
  macro reserved(tag)
    {%
      unless tag.is_a?(NumberLiteral)
        raise "reserved tag must be an integer literal"
      end
      tag_value = tag

      if @type.constant("FIELDS").any? { |field| field[:tag] == tag_value }
        raise "field tag #{tag_value} on #{@type.name} is declared and cannot also be reserved"
      end
      if @type.constant("RESERVED_FIELD_TAGS").includes?(tag_value)
        raise "field tag #{tag_value} on #{@type.name} is already reserved"
      end

      @type.constant("RESERVED_FIELD_TAGS") << tag_value
    %}
  end

  # ----------------------------------------------------------------- index

  # `index tag, [:cols], unique: false, where: SQL.expr(...), name: "..."`
  macro index(tag, columns, **opts)
    {%
      unless tag.is_a?(NumberLiteral)
        raise "index tag must be an integer literal"
      end
      tag_value = tag

      if @type.constant("RESERVED_INDEX_TAGS").includes?(tag_value)
        raise "index tag #{tag_value} on #{@type.name} was reserved (ADR-0005)"
      end
      if @type.constant("INDEXES").any? { |i| i[:tag] == tag_value }
        raise "index tag #{tag_value} on #{@type.name} is already declared"
      end

      unless columns.is_a?(ArrayLiteral)
        raise "index columns must be an array literal of symbols, got #{columns.class_name}"
      end
      column_syms = columns.map do |col|
        unless col.is_a?(SymbolLiteral)
          raise "index columns must be symbol literals"
        end
        col
      end

      unique = opts[:unique] == true
      where_sql = nil
      if opts[:where] != nil
        if opts[:where].is_a?(Call) && opts[:where].name.id.stringify == "expr"
          where_sql = opts[:where].args[0].is_a?(StringLiteral) ? opts[:where].args[0] : nil
          if where_sql.nil?
            raise "index where: requires SQL.expr with a string literal"
          end
        else
          raise "index where: must be a SQL.expr"
        end
      end

      # Default name: <table>_<col1>_<col2>_idx. Override via name:.
      # Check TABLE_NAME_OVERRIDE first so a user-declared `table_name`
      # (which must come before this index) is reflected in the default name.
      effective_table = @type.constant("TABLE_NAME_OVERRIDE") || @type.constant("TABLE_NAME")
      name = opts[:name]
      if name == nil
        name = "#{effective_table.id}_" + column_syms.map(&.id.stringify).join("_") + "_idx"
      else
        unless name.is_a?(StringLiteral)
          raise "index name: must be a string literal"
        end
      end

      if name.id.stringify.starts_with?("prostore_")
        raise "index name '#{name.id}' on #{@type.name} starts with reserved 'prostore_' prefix"
      end

      @type.constant("INDEXES") << {
        tag:       tag_value,
        name:      name,
        columns:   column_syms,
        unique:    unique,
        where_sql: where_sql,
      }
    %}
  end

  macro reserved_index(tag)
    {%
      unless tag.is_a?(NumberLiteral)
        raise "reserved_index tag must be an integer literal"
      end
      tag_value = tag

      if @type.constant("INDEXES").any? { |i| i[:tag] == tag_value }
        raise "index tag #{tag_value} on #{@type.name} is declared and cannot also be reserved"
      end
      if @type.constant("RESERVED_INDEX_TAGS").includes?(tag_value)
        raise "index tag #{tag_value} on #{@type.name} is already reserved"
      end

      @type.constant("RESERVED_INDEX_TAGS") << tag_value
    %}
  end

  # ------------------------------------------------------------ foreign_key

  # `foreign_key tag, [:cols], references: TargetClass, ...`
  macro foreign_key(tag, columns, **opts)
    {%
      unless tag.is_a?(NumberLiteral)
        raise "foreign_key tag must be an integer literal"
      end
      tag_value = tag

      if @type.constant("RESERVED_FOREIGN_KEY_TAGS").includes?(tag_value)
        raise "foreign_key tag #{tag_value} on #{@type.name} was reserved (ADR-0012)"
      end
      if @type.constant("FOREIGN_KEYS").any? { |fk| fk[:tag] == tag_value }
        raise "foreign_key tag #{tag_value} on #{@type.name} is already declared"
      end

      unless columns.is_a?(ArrayLiteral)
        raise "foreign_key columns must be an array literal of symbols"
      end
      column_syms = columns.map do |col|
        raise "foreign_key columns must be symbol literals" unless col.is_a?(SymbolLiteral)
        col
      end

      ref = opts[:references]
      if ref == nil
        raise "foreign_key #{tag_value} on #{@type.name}: references: option is required"
      end

      ref_resolved = ref.resolve
      unless ref_resolved <= ::Prostore::Model
        raise "foreign_key #{tag_value} on #{@type.name}: references: must be a Prostore::Model subclass, got #{ref}"
      end

      # Default to PK at planner time; capture explicit references_fields when given.
      ref_columns = [] of ::Symbol
      if opts[:references_fields] != nil
        unless opts[:references_fields].is_a?(ArrayLiteral)
          raise "foreign_key references_fields: must be an array literal of symbols"
        end
        ref_columns = opts[:references_fields].map do |col|
          raise "foreign_key references_fields: entries must be symbol literals" unless col.is_a?(SymbolLiteral)
          col
        end
      end

      on_delete = opts[:on_delete] || :no_action
      on_update = opts[:on_update] || :no_action
      allowed = [:no_action, :restrict, :cascade, :set_null, :set_default]
      unless allowed.includes?(on_delete)
        raise "foreign_key on_delete must be one of #{allowed}, got #{on_delete}"
      end
      unless allowed.includes?(on_update)
        raise "foreign_key on_update must be one of #{allowed}, got #{on_update}"
      end

      effective_table = @type.constant("TABLE_NAME_OVERRIDE") || @type.constant("TABLE_NAME")
      name = opts[:name]
      if name == nil
        name = "#{effective_table.id}_" + column_syms.map(&.id.stringify).join("_") + "_fkey"
      else
        unless name.is_a?(StringLiteral)
          raise "foreign_key name: must be a string literal"
        end
      end

      if name.id.stringify.starts_with?("prostore_")
        raise "foreign_key name '#{name.id}' on #{@type.name} starts with reserved 'prostore_' prefix"
      end

      # Capture target table name as a string (model class default rule).
      # Inline snake-case conversion (matching Model.inherited's derivation).
      ref_table_name = ref_resolved.name.stringify.gsub(/([A-Z])([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z\d])([A-Z])/, "\\1_\\2").gsub(/::/, "_").downcase

      @type.constant("FOREIGN_KEYS") << {
        tag:                tag_value,
        name:               name,
        columns:            column_syms,
        references_table:   ref_table_name,
        references_columns: ref_columns,
        on_delete:          on_delete,
        on_update:          on_update,
      }
    %}
  end

  macro reserved_foreign_key(tag)
    {%
      unless tag.is_a?(NumberLiteral)
        raise "reserved_foreign_key tag must be an integer literal"
      end
      tag_value = tag

      if @type.constant("FOREIGN_KEYS").any? { |fk| fk[:tag] == tag_value }
        raise "foreign_key tag #{tag_value} on #{@type.name} is declared and cannot also be reserved"
      end
      if @type.constant("RESERVED_FOREIGN_KEY_TAGS").includes?(tag_value)
        raise "foreign_key tag #{tag_value} on #{@type.name} is already reserved"
      end

      @type.constant("RESERVED_FOREIGN_KEY_TAGS") << tag_value
    %}
  end

  # ----------------------------------------------------------------- query

  # `query :name, ->(args) { body }`
  #
  # The lambda body is walked as an AST chain; each method call becomes a
  # `Schema::Call` record consumed by `Query::Analyzer` for index planning.
  macro query(name, lambda)
    {%
      unless name.is_a?(SymbolLiteral)
        raise "query name must be a symbol literal"
      end
      if @type.constant("QUERIES").any? { |query| query[:name] == name }
        raise "query name #{name} on #{@type.name} is already declared"
      end
      unless lambda.is_a?(ProcLiteral)
        raise "query body must be a proc literal -> { ... }, got #{lambda.class_name}"
      end

      calls = [] of Nil
      body = lambda.body
      statements = body.is_a?(Expressions) ? body.expressions : [body]

      statements.each do |stmt|
        current = stmt
        (0...32).each do |_|
          if current.is_a?(Call)
            named_keys = [] of Nil
            if current.named_args
              current.named_args.each do |na|
                named_keys << na.name.id.stringify
              end
            end
            # For `where(Q.lt(:field, val))` etc., extract the field symbol from
            # comparison predicate args so the analyzer reports index coverage.
            if current.name.id.stringify == "where"
              current.args.each do |arg|
                if arg.is_a?(Call) && ["lt", "gt", "lte", "gte", "ne", "in", "like"].includes?(arg.name.id.stringify)
                  if arg.args.size > 0 && arg.args[0].is_a?(SymbolLiteral)
                    named_keys << arg.args[0].id.stringify
                  end
                end
              end
            end
            # Capture positional `SymbolLiteral` args so the analyzer can
            # recognize `order_by(:score, desc: true)` as a sort over
            # `:score` without requiring the named-arg form.
            positional_symbols = [] of Nil
            current.args.each do |arg|
              positional_symbols << arg.id.stringify if arg.is_a?(SymbolLiteral)
            end
            calls << {
              name:               current.name.id.stringify,
              arity:              current.args.size,
              named_arg_keys:     named_keys,
              positional_symbols: positional_symbols,
            }
            current = current.receiver
          end
        end
      end

      @type.constant("QUERIES") << {name: name, calls: calls}
    %}

    # Callable form: each named query becomes a class method that returns
    # a `Prostore::Query::Builder`. The lambda body executes inside
    # `with builder` so naked `where(...)`, `order_by(...)` etc. dispatch
    # to the builder. Closure variables (e.g., `e` in `->(e : String) { ... }`)
    # are still in scope.
    def self.{{ name.id }}({{ lambda.args.splat }})
      ::Prostore::Model.__prostore_builder_for(self).in_query do
        {{ lambda.body }}
      end
    end
  end

  # ------------------------------------------------------------- table_name

  # `table_name "users"` — overrides the default snake-case derivation.
  macro table_name(name)
    {%
      unless name.is_a?(StringLiteral)
        raise "table_name must be a string literal, got #{name.class_name}"
      end
      if name.starts_with?("prostore_")
        raise "table_name '#{name}' starts with reserved 'prostore_' prefix"
      end
    %}
    TABLE_NAME_OVERRIDE = {{ name }}
  end

  # ------------------------------------------------------------- sequence

  # Reserved DSL keyword for future standalone sequences (ADR-0013).
  # Currently excluded; only `auto_increment: true` on integer PKs is
  # supported.
  macro sequence(*args, **kwargs)
    {% raise "`sequence` is reserved for a future ADR; only `auto_increment: true` on integer PKs is supported (ADR-0013)" %}
  end
end
