module Prostore
  module Adapter
    module SQLite
      # Portable type tag → SQLite affinity (ADR-0014, ADR-0007).
      #
      # SQLite's storage class system means most distinctions get folded:
      # all integers go to INTEGER (stored as 64-bit), both Float32 and
      # Float64 to REAL. We track the portable tag in `prostore_schema` so
      # the diff engine doesn't lose precision even when SQLite does.
      AFFINITY = {
        "int32"   => "INTEGER",
        "int64"   => "INTEGER",
        "float32" => "REAL",
        "float64" => "REAL",
        "string"  => "TEXT",
        "bool"    => "INTEGER",
        "time"    => "TEXT",
        "bytes"   => "BLOB",
        "uuid"    => "TEXT", # 36-char UUID string
        "decimal" => "TEXT", # arbitrary-precision; lossless round-trip via String
        "json"    => "TEXT", # SQLite JSON1 supports queries on TEXT-stored JSON
      }

      def self.affinity(portable : String) : String
        # Array tags collapse to TEXT (JSON-encoded) on SQLite.
        return "TEXT" if portable.starts_with?("array_")
        AFFINITY[portable]? ||
          raise Prostore::SchemaError.new("No SQLite affinity for portable type #{portable}")
      end
    end
  end
end
