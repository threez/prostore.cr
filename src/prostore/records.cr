require "db"
require "./adapter/base"

module Prostore
  # Record-layer helpers shared by every model class.
  #
  # The `Prostore::Model.__prostore_run_backfill` macro emits a call into
  # this module to perform a chunked Crystal-lambda backfill. Splitting the
  # loop into a free function keeps the per-model macro emission small.
  module Records
    extend self

    # ---- Type coercion at the model boundary ------------------------------
    #
    # UUID, BigDecimal, JSON::Any, and Array(T) are stored as String at the
    # crystal-db layer (the column type is still backend-native — UUID,
    # NUMERIC, JSONB, etc. — but the wire format is always String). The
    # macro-emitted `save` method routes each value through this dispatcher
    # to convert it to a `DB::Any`-compatible form.

    # Coerce values from application types to DB::Any-compatible wire form.
    # Method overloads dispatch on Crystal's static type at the call site
    # (the macro-emitted `save` knows each ivar's declared type), so each
    # overload sees a precisely-typed value.

    # Scalar coercion: UUID, BigDecimal, JSON::Any → String. Primitives
    # already fitting DB::Any pass through.
    alias CoerceScalar = ::UUID | ::BigDecimal | ::JSON::Any | ::DB::Any

    def coerce_for_write(value : CoerceScalar, portable_type : String) : ::DB::Any
      return nil if value.nil?
      case value
      when ::UUID
        value.to_s.as(::DB::Any)
      when ::BigDecimal
        value.to_s.as(::DB::Any)
      when ::JSON::Any
        value.to_json.as(::DB::Any)
      else
        value.as(::DB::Any)
      end
    end

    # Array coercion: JSON-encode the array. Crystal generics require a
    # `forall` overload because `Array(T)` can't appear in a regular union.
    def coerce_for_write(value : ::Array(T)?, portable_type : String) : ::DB::Any forall T
      value.nil? ? nil : value.to_json.as(::DB::Any)
    end

    # Enum coercion (ADR-0016). Dispatches on the portable tag: `enum_int`
    # stores the underlying integer (`Int64`-promoted), `enum_string` stores
    # the member's source-level name. The reverse trip lives in the
    # macro-emitted `___assign_from_rs` (uses `EnumClass.from_value` /
    # `EnumClass.parse`).
    def coerce_for_write(value : ::Enum?, portable_type : String) : ::DB::Any
      return nil if value.nil?
      case portable_type
      when "enum_int" then value.value.to_i64.as(::DB::Any)
      else                 value.to_s.as(::DB::Any)
      end
    end

    # ---- Type coercion at row-read time -----------------------------------
    #
    # SQLite returns these custom types as `String`/`Bytes`/`Nil`; Postgres
    # returns them through native decoders (`UUID`, `JSON::Any`,
    # `PG::Numeric`). Each helper does a runtime class dispatch so the
    # macro-emitted materializer is backend-agnostic.

    def read_uuid(rs : ::DB::ResultSet) : ::UUID?
      raw = rs.read
      case raw
      when ::UUID then raw
      when ::Nil  then nil
      when ::String
        raw.empty? ? nil : ::UUID.new(raw)
      else
        raise ::Prostore::Error.new("Unexpected wire type for UUID column: #{raw.class}")
      end
    end

    def read_decimal(rs : ::DB::ResultSet) : ::BigDecimal?
      raw = rs.read
      case raw
      when ::Nil         then nil
      when ::String      then raw.empty? ? nil : ::BigDecimal.new(raw)
      when ::PG::Numeric then ::BigDecimal.new(raw.to_s)
      else
        raise ::Prostore::Error.new("Unexpected wire type for decimal column: #{raw.class}")
      end
    end

    def read_json(rs : ::DB::ResultSet) : ::JSON::Any?
      raw = rs.read
      case raw
      when ::JSON::Any        then raw
      when ::JSON::PullParser then ::JSON::Any.new(raw)
      when ::Nil              then nil
      when ::String           then raw.empty? ? nil : ::JSON.parse(raw)
      else
        raise ::Prostore::Error.new("Unexpected wire type for JSON column: #{raw.class}")
      end
    end

    # Returns the JSON-encoded array body as a String, regardless of which
    # backend produced it (SQLite stores JSON in TEXT; Postgres returns
    # JSONB as a `JSON::PullParser`). The macro-emitted caller does the
    # per-row `Array(T).from_json(string)` step on the result.
    def read_array_json(rs : ::DB::ResultSet) : ::String?
      raw = rs.read
      case raw
      when ::Nil              then nil
      when ::String           then raw
      when ::JSON::Any        then raw.to_json
      when ::JSON::PullParser then ::JSON::Any.new(raw).to_json
      else
        raise ::Prostore::Error.new("Unexpected wire type for array column: #{raw.class}")
      end
    end

    # Read an `Int64?` from a result set, accepting any integer-typed wire
    # form. SQLite returns INTEGER columns as Int64 already; Postgres may
    # return Int32 for narrower column types. Used by the enum_int reader to
    # stay agnostic to the live column width.
    def read_int64(rs : ::DB::ResultSet) : ::Int64?
      raw = rs.read
      case raw
      when ::Nil   then nil
      when ::Int64 then raw
      when ::Int32 then raw.to_i64
      when ::Int16 then raw.to_i64
      when ::Int8  then raw.to_i64
      else
        raise ::Prostore::Error.new("Unexpected wire type for enum_int column: #{raw.class}")
      end
    end

    # ---- Instance CRUD helpers --------------------------------------------

    # INSERT a row from explicit column/value lists. If `auto_increment_pk`
    # is supplied, the column is omitted from the INSERT and the new ID is
    # returned via `adapter.insert_returning_id`. Otherwise the call returns
    # `nil` and the caller is responsible for whatever PK ergonomics fit.
    def insert(adapter : Adapter::Base,
               db : DB::Database,
               table : String,
               columns : Array(String),
               values : Array(::DB::Any),
               auto_increment : Bool) : Int64?
      cols = columns.map { |col| adapter.quote_ident(col) }.join(", ")
      placeholders = (1..columns.size).map { |i| adapter.placeholder(i) }.join(", ")
      sql = "INSERT INTO #{adapter.quote_ident(table)} (#{cols}) VALUES (#{placeholders})"

      if auto_increment
        adapter.insert_returning_id(db, sql, args: values)
      else
        db.exec(sql, args: values)
        nil
      end
    end

    def update(adapter : Adapter::Base,
               db : DB::Database,
               table : String,
               columns : Array(String),
               values : Array(::DB::Any),
               pk_column : String,
               pk_value : ::DB::Any) : Nil
      sets = columns.map_with_index { |col, idx| "#{adapter.quote_ident(col)} = #{adapter.placeholder(idx + 1)}" }.join(", ")
      sql = "UPDATE #{adapter.quote_ident(table)} SET #{sets} " \
            "WHERE #{adapter.quote_ident(pk_column)} = #{adapter.placeholder(values.size + 1)}"
      args = values.dup
      args << pk_value
      db.exec(sql, args: args)
    end

    def delete(adapter : Adapter::Base,
               db : DB::Database,
               table : String,
               pk_column : String,
               pk_value : ::DB::Any) : Nil
      db.exec(
        "DELETE FROM #{adapter.quote_ident(table)} " \
        "WHERE #{adapter.quote_ident(pk_column)} = #{adapter.placeholder(1)}",
        pk_value
      )
    end

    DEFAULT_CHUNK_SIZE = 1_000

    # Walk the table in chunks, invoking `lambda` on each row. The
    # `WHERE col IS NULL` filter is the correctness invariant from
    # ADR-0009 invariant 3 — re-running the loop is a no-op for already-
    # populated rows, which makes the operation idempotent under retry.
    def run_lambda_backfill(adapter : Adapter::Base,
                            executor : Adapter::Base::Executor,
                            table : String,
                            column : String,
                            column_names : Array(String),
                            pk_column : String,
                            lambda : Hash(String, DB::Any) -> DB::Any,
                            chunk_size : Int32 = DEFAULT_CHUNK_SIZE) : Nil
      column_quoted = adapter.quote_ident(column)
      table_quoted = adapter.quote_ident(table)
      pk_quoted = adapter.quote_ident(pk_column)

      loop do
        batch = [] of Hash(String, DB::Any)
        executor.query_each(
          "SELECT * FROM #{table_quoted} WHERE #{column_quoted} IS NULL " \
          "LIMIT #{adapter.placeholder(1)}",
          chunk_size
        ) do |rs|
          row = {} of String => DB::Any
          column_names.each do |name|
            row[name] = rs.read.as(DB::Any)
          end
          batch << row
        end

        break if batch.empty?

        batch.each do |row|
          new_value = lambda.call(row)
          pk_value = row[pk_column]? || raise Prostore::MigrationError.new(
            "Crystal-lambda backfill on #{table}: primary-key column '#{pk_column}' missing from row."
          )
          executor.exec(
            "UPDATE #{table_quoted} SET #{column_quoted} = #{adapter.placeholder(1)} " \
            "WHERE #{pk_quoted} = #{adapter.placeholder(2)}",
            new_value, pk_value
          )
        end
      end
    end
  end
end
