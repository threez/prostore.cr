require "uuid"
require "big"
require "json"

module Prostore
  # Portable type taxonomy (ADR-0014).
  #
  # Each Crystal type used in a `field` declaration maps to one of these
  # portable tags. The adapter layer translates a tag plus a nullable flag
  # into backend-specific column DDL.
  #
  # **Coerced types** (UUID, BigDecimal, JSON::Any, Array(T)) move through
  # crystal-db as `String` values regardless of backend, with conversion at
  # the model boundary (see `__prostore_load_from_rs` and `save`). This
  # keeps the runtime IO surface uniform — only the *column DDL* differs
  # per backend (UUID on PG, TEXT on SQLite, etc.).
  module Types
    # Primitive types whose Crystal representation is the same as crystal-db
    # accepts directly. Values are passed through to the driver verbatim.
    PORTABLE = {
      "Int32"        => "int32",
      "Int64"        => "int64",
      "Float32"      => "float32",
      "Float64"      => "float64",
      "String"       => "string",
      "Bool"         => "bool",
      "Time"         => "time",
      "Bytes"        => "bytes",
      "Slice(UInt8)" => "bytes",
      "UUID"         => "uuid",
      "BigDecimal"   => "decimal",
      "JSON::Any"    => "json",
    }

    # Coerced portable types — values that need conversion to/from String at
    # the model boundary. The adapter still uses native column types for
    # these (NUMERIC for decimal on PG, etc.); the wire format is just String.
    COERCED = ["uuid", "decimal", "json"]

    # Enum portable tags (ADR-0016). Enum values move through the wire as
    # String (member name) or Int64 (underlying integer); the model boundary
    # reconstructs the Crystal enum via `EnumClass.parse` / `EnumClass.from_value`.
    ENUM_TAGS = ["enum_string", "enum_int"]

    def self.coerced?(portable_type : String) : Bool
      COERCED.includes?(portable_type) || array?(portable_type) || enum?(portable_type)
    end

    def self.array?(portable_type : String) : Bool
      portable_type.starts_with?("array_")
    end

    # Inner portable type of an array tag. `array_int32` → `int32`.
    def self.array_inner(portable_type : String) : String
      raise Prostore::SchemaError.new("not an array tag: #{portable_type}") unless array?(portable_type)
      portable_type[6..]
    end

    def self.enum?(portable_type : String) : Bool
      ENUM_TAGS.includes?(portable_type)
    end
  end
end
