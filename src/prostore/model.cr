require "./schema"
require "./schema/fingerprint"
require "./types"

module Prostore
  # Global registry of declared model classes. Populated by the
  # `Prostore::Model.inherited` hook.
  @@models = [] of Prostore::Model.class

  def self.models : Array(Prostore::Model.class)
    @@models
  end

  # Reset the registry. Used in tests; not part of the public API.
  def self.__reset_for_test
    @@models.clear
  end

  # Default connection used by query/CRUD methods when no explicit
  # connection is supplied. Set once at app boot via `Prostore.connect(url)`.
  @@default_connection : Connection? = nil

  def self.connect(url : String) : Connection
    @@default_connection = Connection.open(url)
  end

  def self.default_connection=(conn : Connection?)
    @@default_connection = conn
  end

  def self.default_connection : Connection
    @@default_connection || raise Prostore::Error.new(
      "No default connection. Call `Prostore.connect(url)` at app boot " \
      "or assign `Prostore.default_connection = conn` for tests."
    )
  end

  def self.default_connection? : Connection?
    @@default_connection
  end

  # Base class for all prostore-managed models.
  #
  # Subclasses declare their schema in the class body via the macros installed
  # by `inherited` and the macros defined in `macros.cr`. At compile time, a
  # `Prostore::Schema::Definition` value is built and exposed as
  # `Class.prostore_schema`.
  abstract class Model
    @__prostore_persisted : Bool = false

    def persisted? : Bool
      @__prostore_persisted
    end

    def __prostore_mark_persisted! : Nil
      @__prostore_persisted = true
    end

    # Per-subclass accumulators set up here, and the `macro finished` that
    # synthesizes the schema struct. Nested inside `inherited` so it fires
    # per-subclass (the pattern verified in the macro spike).
    #
    # Default table name derivation: snake_case the class name with no
    # pluralization (ADR-0014). `OrderItem` → `order_item`.
    macro inherited
      # Macro-time accumulators populated by the DSL macros.
      FIELDS                     = [] of Nil
      INDEXES                    = [] of Nil
      FOREIGN_KEYS               = [] of Nil
      QUERIES                    = [] of Nil
      RESERVED_FIELD_TAGS        = [] of Nil
      RESERVED_INDEX_TAGS        = [] of Nil
      RESERVED_FOREIGN_KEY_TAGS  = [] of Nil

      # Default table name (overridden by `table_name`).
      {% snake_name = @type.name.stringify.gsub(/([A-Z])([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z\d])([A-Z])/, "\\1_\\2").gsub(/::/, "_").downcase %}
      TABLE_NAME = {{ snake_name }}

      # Register at runtime.
      ::Prostore.models << self

      macro finished
        # Resolve the table name override (if any) — the `table_name` macro
        # appends to a sentinel constant which we read here.
        {% verbatim do %}
          {%
            override = @type.constant("TABLE_NAME_OVERRIDE")
            table_name = override || @type.constant("TABLE_NAME")

            unless table_name.is_a?(StringLiteral) || table_name.is_a?(MacroId)
              raise "internal: TABLE_NAME for #{@type.name} is not a string"
            end

            if table_name.id.starts_with?("prostore_")
              raise "Table name '#{table_name.id}' starts with reserved 'prostore_' prefix (ADR-0009)"
            end
          %}

          # Validate: column names within the table must be unique.
          {%
            seen_names = {} of Nil => Nil
            @type.constant("FIELDS").each do |field|
              if seen_names.keys.includes?(field[:name])
                raise "Duplicate field name #{field[:name].id.symbolize} on #{@type.name} (tag #{field[:tag]})"
              end
              seen_names[field[:name]] = field[:tag]
            end
          %}

          # Validate: each field name does not start with `prostore_`.
          {%
            @type.constant("FIELDS").each do |field|
              if field[:name].id.stringify.starts_with?("prostore_")
                raise "Field name '#{field[:name].id}' on #{@type.name} starts with reserved 'prostore_' prefix"
              end
            end
          %}

          # Validate: a reserved field tag is not still referenced by a
          # non-reserved index or FK (ADR-0008 interlock).
          {%
            reserved_field_tags = @type.constant("RESERVED_FIELD_TAGS")
            field_names_by_tag = {} of Int32 => Symbol
            @type.constant("FIELDS").each { |field| field_names_by_tag[field[:tag]] = field[:name] }

            @type.constant("INDEXES").each do |i|
              i[:columns].each do |col|
                # Index columns are referenced by name; if the name belongs to
                # a reserved tag, that's an interlock violation. We need to
                # check whether the column name exists among active fields.
                col_name = col
                unless @type.constant("FIELDS").any? { |field| field[:name] == col_name }
                  raise "Index #{i[:tag]} on #{@type.name} references unknown or reserved field #{col_name.id.symbolize} (ADR-0008 interlock)"
                end
              end
            end

            @type.constant("FOREIGN_KEYS").each do |fk|
              fk[:columns].each do |col|
                col_name = col
                unless @type.constant("FIELDS").any? { |field| field[:name] == col_name }
                  raise "Foreign key #{fk[:tag]} on #{@type.name} references unknown or reserved source field #{col_name.id.symbolize} (ADR-0008 interlock)"
                end
              end
            end
          %}

          # Validate: `:set_default` on_delete/on_update requires `default:` on
          # the source field (ADR-0012).
          {%
            @type.constant("FOREIGN_KEYS").each do |fk|
              if fk[:on_delete] == :set_default || fk[:on_update] == :set_default
                fk[:columns].each do |col|
                  source = @type.constant("FIELDS").find { |field| field[:name] == col }
                  if source && !source[:has_default]
                    raise "Foreign key #{fk[:tag]} on #{@type.name} uses :set_default but source field #{col.id.symbolize} has no default: option (ADR-0012)"
                  end
                end
              end
            end
          %}

          # Synthesize Class.prostore_table_name, .prostore_schema,
          # .prostore_fingerprint.

          def self.prostore_table_name : String
            {{ table_name.id.stringify }}
          end

          def self.prostore_schema : ::Prostore::Schema::Definition
            ::Prostore::Schema::Definition.new(
              table_name: prostore_table_name,
              fields: [
                {% for f in @type.constant("FIELDS") %}
                  ::Prostore::Schema::Field.new(
                    tag: {{ f[:tag] }},
                    name: {{ f[:name].id.stringify }},
                    crystal_type: {{ f[:crystal_type] }},
                    portable_type: {{ f[:portable_type].id.stringify }},
                    nullable: {{ f[:nullable] }},
                    primary: {{ f[:primary] }},
                    auto_increment: {{ f[:auto_increment] }},
                    has_default: {{ f[:has_default] }},
                    default_sql: {{ f[:default_sql] }},
                    has_backfill: {{ f[:has_backfill] }},
                    backfill_sql: {{ f[:backfill_sql] }},
                    has_lazy: {{ f[:has_lazy] }},
                    {% if f[:is_enum] %}
                    enum_members: {{ f[:enum_class_id].id }}.values.map { |__m|
                      ::Prostore::Schema::EnumMember.new(name: __m.to_s, value: __m.value.to_i64)
                    },
                    enum_is_flags: {{ f[:enum_is_flags] }},
                    {% end %}
                  ),
                {% end %}
              ] of ::Prostore::Schema::Field,
              indexes: [
                {% for i in @type.constant("INDEXES") %}
                  ::Prostore::Schema::Index.new(
                    tag: {{ i[:tag] }},
                    name: {{ i[:name] }},
                    columns: [{% for c in i[:columns] %}{{ c.id.stringify }},{% end %}] of ::String,
                    unique: {{ i[:unique] }},
                    where_sql: {{ i[:where_sql] }},
                  ),
                {% end %}
              ] of ::Prostore::Schema::Index,
              foreign_keys: [
                {% for fk in @type.constant("FOREIGN_KEYS") %}
                  ::Prostore::Schema::ForeignKey.new(
                    tag: {{ fk[:tag] }},
                    name: {{ fk[:name] }},
                    columns: [{% for c in fk[:columns] %}{{ c.id.stringify }},{% end %}] of ::String,
                    references_table: {{ fk[:references_table] }},
                    references_columns: [{% for c in fk[:references_columns] %}{{ c.id.stringify }},{% end %}] of ::String,
                    on_delete: {{ fk[:on_delete] }},
                    on_update: {{ fk[:on_update] }},
                  ),
                {% end %}
              ] of ::Prostore::Schema::ForeignKey,
              queries: [
                {% for q in @type.constant("QUERIES") %}
                  ::Prostore::Schema::Query.new(
                    name: {{ q[:name] }},
                    calls: [
                      {% for c in q[:calls] %}
                        ::Prostore::Schema::Call.new(
                          name: {{ c[:name] }},
                          arity: {{ c[:arity] }},
                          named_arg_keys: [{% for k in c[:named_arg_keys] %}{{ k }},{% end %}] of ::String,
                          positional_symbols: [{% for s in c[:positional_symbols] %}{{ s }},{% end %}] of ::String,
                        ),
                      {% end %}
                    ] of ::Prostore::Schema::Call,
                  ),
                {% end %}
              ] of ::Prostore::Schema::Query,
              reserved_field_tags: [{% for t in @type.constant("RESERVED_FIELD_TAGS") %}{{ t }},{% end %}] of ::Int32,
              reserved_index_tags: [{% for t in @type.constant("RESERVED_INDEX_TAGS") %}{{ t }},{% end %}] of ::Int32,
              reserved_foreign_key_tags: [{% for t in @type.constant("RESERVED_FOREIGN_KEY_TAGS") %}{{ t }},{% end %}] of ::Int32,
            )
          end

          @@__cached_fingerprint : String?

          def self.prostore_fingerprint : String
            @@__cached_fingerprint ||= ::Prostore::Schema::Fingerprint.compute(prostore_schema)
          end

          # ---- Per-field accessors and row materialization ----------------
          {% for f in @type.constant("FIELDS") %}
            @{{ f[:name].id }} : {{ f[:ruby_type] }}?

            def {{ f[:name].id }} : {{ f[:ruby_type] }}{{ f[:nullable] ? "".id : "?".id }}
              {% if f[:has_lazy] %}
                # Lazy field: materialize via lambda if not yet set.
                raw = @{{ f[:name].id }}
                if raw.nil?
                  {% if f[:lazy_lambda].is_a?(ProcLiteral) && f[:lazy_lambda].args.size == 0 %}
                    computed = ({{ f[:lazy_lambda] }}).call
                  {% else %}
                    computed = ({{ f[:lazy_lambda] }}).call(self)
                  {% end %}
                  @{{ f[:name].id }} = computed
                  computed
                else
                  raw
                end
              {% else %}
                {% if f[:nullable] %}
                  @{{ f[:name].id }}
                {% else %}
                  raw = @{{ f[:name].id }}
                  if raw.nil?
                    raise Prostore::Error.new({{ "Field #{f[:name].id} on #{@type.name} is not set" }})
                  end
                  raw
                {% end %}
              {% end %}
            end

            def {{ f[:name].id }}=(value : {{ f[:ruby_type] }}{{ f[:nullable] ? "".id : "?".id }})
              @{{ f[:name].id }} = value
            end
          {% end %}

          # Load an instance from a column-name → value map (for backfill /
          # query results). Values mismatched against the field's type
          # surface as cast errors at access time.
          def self.__prostore_load(values : Hash(String, ::DB::Any)) : self
            instance = self.allocate
            {% for f in @type.constant("FIELDS") %}
              if v = values[{{ f[:name].id.stringify }}]?
                # Coerce common DB::Any → field type.
                instance.{{ f[:name].id }} = v.as({{ f[:ruby_type] }})
              end
            {% end %}
            instance.__prostore_mark_persisted!
            instance
          end

          # Run an eager Crystal-lambda backfill for the given column tag.
          # Iterates rows where the column IS NULL, calls the lambda, writes
          # the result back. The step executor delegates here when it sees a
          # BackfillCrystalLambda step for this model.
          def self.__prostore_run_backfill(adapter : ::Prostore::Adapter::Base,
                                          executor : ::Prostore::Adapter::Base::Executor,
                                          tag : ::Int32) : ::Nil
            schema = prostore_schema
            column_names = schema.fields.map(&.name)
            pk_column = (schema.primary_key.try(&.name)) || raise ::Prostore::MigrationError.new(
              "Crystal-lambda backfill on #{self.name} requires a primary key field"
            )

            case tag
            {% for f in @type.constant("FIELDS") %}
              {% if f[:backfill_lambda] %}
            when {{ f[:tag] }}
              ::Prostore::Records.run_lambda_backfill(
                adapter, executor, prostore_table_name,
                {{ f[:name].id.stringify }},
                column_names, pk_column,
                ->(values : ::Hash(::String, ::DB::Any)) {
                  row = self.__prostore_load(values)
                  {% if f[:backfill_lambda].is_a?(ProcLiteral) && f[:backfill_lambda].args.size == 0 %}
                    ({{ f[:backfill_lambda] }}).call.as(::DB::Any)
                  {% else %}
                    ({{ f[:backfill_lambda] }}).call(row).as(::DB::Any)
                  {% end %}
                },
              )
              {% end %}
            {% end %}
            else
              raise ::Prostore::MigrationError.new(
                "No Crystal-lambda backfill registered on #{self.name} for field tag #{tag}"
              )
            end
          end

          # Materialize an instance from a `DB::ResultSet` whose columns are
          # in the order this model's `prostore_schema.fields` declares.
          # The Builder's renderer SELECTs in that exact order so reads line
          # up with assignments.
          def self.__prostore_load_from_rs(rs : ::DB::ResultSet) : self
            instance = self.allocate
            {% for f in @type.constant("FIELDS") %}
              ___assign_from_rs(instance, rs, {{ f }})
            {% end %}
            instance.__prostore_mark_persisted!
            instance
          end

          # Partial materializer for projection-aware queries (`select`):
          # reads only the named columns in the given order, leaving other
          # ivars at their default (nil). Used by `Query::Builder` when the
          # user has constrained the SELECT list.
          def self.__prostore_load_partial(rs : ::DB::ResultSet, columns : ::Array(::String)) : self
            instance = self.allocate
            columns.each do |col|
              case col
              {% for f in @type.constant("FIELDS") %}
              when {{ f[:name].id.stringify }}
                ___assign_from_rs(instance, rs, {{ f }})
              {% end %}
              else
                raise ::Prostore::Error.new("Unknown column #{col} for {{ @type.name }} partial materialization")
              end
            end
            instance.__prostore_mark_persisted!
            instance
          end

          # Internal helper macro: reads one field from a result set and
          # assigns it on the instance, with coercion per portable type.
          # Custom types route through `Records.read_*` helpers that
          # dispatch on the actual returned class so the same macro works
          # for SQLite (String/Bytes wire form) and Postgres (UUID,
          # JSON::Any, PG::Numeric native decoders).
          private macro ___assign_from_rs(instance, rs, f)
            \{% pt = f[:portable_type] %}
            \{% if pt == "uuid" %}
              \{{ instance }}.\{{ f[:name].id }} = ::Prostore::Records.read_uuid(\{{ rs }})
            \{% elsif pt == "decimal" %}
              \{{ instance }}.\{{ f[:name].id }} = ::Prostore::Records.read_decimal(\{{ rs }})
            \{% elsif pt == "json" %}
              \{{ instance }}.\{{ f[:name].id }} = ::Prostore::Records.read_json(\{{ rs }})
            \{% elsif pt.starts_with?("array_") %}
              ___raw = ::Prostore::Records.read_array_json(\{{ rs }})
              \{{ instance }}.\{{ f[:name].id }} = ___raw.try { |s| \{{ f[:ruby_type] }}.from_json(s) }
            \{% elsif pt == "enum_string" %}
              ___raw = \{{ rs }}.read(::String?)
              \{{ instance }}.\{{ f[:name].id }} = ___raw.try { |s| \{{ f[:enum_class_id].id }}.parse(s) }
            \{% elsif pt == "enum_int" %}
              ___raw = ::Prostore::Records.read_int64(\{{ rs }})
              \{{ instance }}.\{{ f[:name].id }} = ___raw.try { |i| \{{ f[:enum_class_id].id }}.from_value(i) }
            \{% else %}
              \{{ instance }}.\{{ f[:name].id }} = \{{ rs }}.read(\{{ f[:ruby_type] }})
            \{% end %}
          end

          # Public class methods for ad-hoc queries. Each returns a
          # `Prostore::Query::Builder` which can be iterated, counted, or
          # extended further.
          def self.where(**kwargs) : ::Prostore::Query::Builder(self)
            ::Prostore::Model.__prostore_builder_for(self).where(**kwargs)
          end

          def self.where(predicate : ::Prostore::Query::AST::Predicate) : ::Prostore::Query::Builder(self)
            ::Prostore::Model.__prostore_builder_for(self).where(predicate)
          end

          def self.all : ::Prostore::Query::Builder(self)
            ::Prostore::Model.__prostore_builder_for(self)
          end

          def self.find?(id_value) : self?
            pk = prostore_schema.primary_key.try(&.name) ||
                 raise ::Prostore::Error.new("#{self.name}: find requires a primary key field")
            ::Prostore::Model.__prostore_builder_for(self)
              .where(::Prostore::Query::Q.eq(pk, id_value))
              .first
          end

          def self.find(id_value) : self
            find?(id_value) ||
              raise ::Prostore::Error.new("#{self.name}: no record found with primary key #{id_value.inspect}")
          end

          # ---- Instance CRUD ----------------------------------------------
          {% pk_field = @type.constant("FIELDS").find { |field| field[:primary] } %}
          {% if pk_field %}
            # INSERT (not yet persisted) or UPDATE (already persisted).
            def save : self
              conn = ::Prostore.default_connection

              if !@__prostore_persisted
                # Evaluate Crystal-lambda defaults for any field that's
                # still unset at INSERT time (ADR-0004 / ADR-0011 mechanism 2,
                # new-row half). SQL.expr defaults are applied by the DB via
                # the column DEFAULT clause; lambda defaults run here.
                {% for f in @type.constant("FIELDS") %}
                  {% if f[:default_lambda] %}
                    if @{{ f[:name].id }}.nil?
                      {% if f[:default_lambda].is_a?(ProcLiteral) && f[:default_lambda].args.size == 0 %}
                        @{{ f[:name].id }} = ({{ f[:default_lambda] }}).call.as({{ f[:ruby_type] }})
                      {% else %}
                        @{{ f[:name].id }} = ({{ f[:default_lambda] }}).call(self).as({{ f[:ruby_type] }})
                      {% end %}
                    end
                  {% end %}
                {% end %}

                cols = [] of ::String
                vals = [] of ::DB::Any
                {% for f in @type.constant("FIELDS") %}
                  {% if f[:primary] && f[:auto_increment] %}
                    # Auto-increment PK is omitted from INSERT.
                  {% else %}
                    cols << {{ f[:name].id.stringify }}
                    vals << ::Prostore::Records.coerce_for_write(@{{ f[:name].id }}, {{ f[:portable_type] }})
                  {% end %}
                {% end %}

                new_id = ::Prostore::Records.insert(
                  conn.adapter, conn.db, self.class.prostore_table_name,
                  cols, vals,
                  {{ pk_field[:auto_increment] }},
                )
                {% if pk_field[:auto_increment] %}
                  if new_id
                    @{{ pk_field[:name].id }} = new_id.as({{ pk_field[:ruby_type] }})
                  end
                {% end %}
                @__prostore_persisted = true
              else
                pk_value = @{{ pk_field[:name].id }}
                cols = [] of ::String
                vals = [] of ::DB::Any
                {% for f in @type.constant("FIELDS") %}
                  {% unless f[:primary] %}
                    cols << {{ f[:name].id.stringify }}
                    vals << ::Prostore::Records.coerce_for_write(@{{ f[:name].id }}, {{ f[:portable_type] }})
                  {% end %}
                {% end %}

                ::Prostore::Records.update(
                  conn.adapter, conn.db, self.class.prostore_table_name,
                  cols, vals,
                  {{ pk_field[:name].id.stringify }}, pk_value.as(::DB::Any),
                )
              end
              self
            end

            # DELETE the row identified by the instance's PK. Raises if the
            # instance has no PK set (i.e., was never saved).
            def destroy : Nil
              pk_value = @{{ pk_field[:name].id }} ||
                         raise ::Prostore::Error.new("Cannot destroy an unsaved {{ @type.name }} (PK is nil)")
              conn = ::Prostore.default_connection
              ::Prostore::Records.delete(
                conn.adapter, conn.db, self.class.prostore_table_name,
                {{ pk_field[:name].id.stringify }}, pk_value.as(::DB::Any),
              )
            end
          {% end %}
        {% end %}
      end
    end

    # Build a query Builder for the given model class using the default
    # Prostore connection. Used by macro-emitted class methods.
    def self.__prostore_builder_for(model_class : T.class) forall T
      conn = ::Prostore.default_connection
      ::Prostore::Query::Builder(T).new(
        table: model_class.prostore_table_name,
        field_names: model_class.prostore_schema.fields.map(&.name),
        materializer: ->(rs : ::DB::ResultSet) { model_class.__prostore_load_from_rs(rs) },
        adapter: conn.adapter,
        db: conn.db,
        partial_materializer: ->(rs : ::DB::ResultSet, cols : ::Array(::String)) {
          model_class.__prostore_load_partial(rs, cols)
        },
      )
    end
  end
end
