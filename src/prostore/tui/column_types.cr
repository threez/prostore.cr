require "../types"

module Prostore
  module TUI
    # Pure column-type detection and value interpretation.
    #
    # All functions take primitives (portable type tag, SQL type_text, raw
    # string values) so callers needn't pass widget state.  Use this anywhere
    # the UI needs to ask "is this a bool / time / how do I render its value?"
    module ColumnTypes
      # True if the column stores booleans.  Prefers the prostore portable
      # type tag; otherwise inspects the SQL type text.
      def self.bool?(portable_type : String?, type_text : String) : Bool
        if pt = portable_type
          pt == "bool"
        else
          type_text.upcase.includes?("BOOL")
        end
      end

      # True if the column stores a date / time / timestamp.
      def self.time?(portable_type : String?, type_text : String) : Bool
        if pt = portable_type
          pt == "time"
        else
          t = type_text.upcase
          t.includes?("DATE") || t.includes?("TIME") || t.includes?("STAMP")
        end
      end

      # Interpret common truthy representations.  Used to normalise across
      # SQLite (0/1), Postgres (true/false), and user input ("yes"/"on"/…).
      def self.bool_truthy?(val : String?) : Bool
        case val.to_s.downcase
        when "true", "yes", "1", "t", "on" then true
        else                                    false
        end
      end

      # Canonical human-readable bool form.
      def self.bool_display(val : String) : String
        bool_truthy?(val) ? "yes" : "no"
      end

      # True if the column stores a native Crystal enum (either backed by
      # member name as TEXT — `enum_string` — or by underlying int — `enum_int`).
      # See ADR-0016. Pure portable-type check; no SQL type_text fallback
      # since enums are a prostore-only concept and never appear in unmanaged
      # databases.
      def self.enum?(portable_type : String?) : Bool
        pt = portable_type
        pt.nil? ? false : Prostore::Types.enum?(pt)
      end

      def self.enum_string?(portable_type : String?) : Bool
        portable_type == "enum_string"
      end

      def self.enum_int?(portable_type : String?) : Bool
        portable_type == "enum_int"
      end

      # True if the column stores an integer.  Prefers the portable type tag;
      # otherwise inspects the SQL type text for the common integer families.
      def self.int?(portable_type : String?, type_text : String) : Bool
        if pt = portable_type
          pt == "int32" || pt == "int64"
        else
          t = type_text.upcase
          # BIGINT/SMALLINT/INTEGER/SERIAL/INT.  Exclude "POINT" which shares
          # no substring with our targets.
          t.includes?("INT") || t.includes?("SERIAL")
        end
      end

      # True if the column stores a binary floating-point number (Float32/Float64).
      def self.float?(portable_type : String?, type_text : String) : Bool
        if pt = portable_type
          pt == "float32" || pt == "float64"
        else
          t = type_text.upcase
          t.includes?("REAL") || t.includes?("FLOAT") || t.includes?("DOUBLE")
        end
      end

      # True if the column stores a fixed-precision decimal.
      def self.decimal?(portable_type : String?, type_text : String) : Bool
        if pt = portable_type
          pt == "decimal"
        else
          t = type_text.upcase
          t.includes?("DECIMAL") || t.includes?("NUMERIC")
        end
      end

      # True if the column stores any numeric value — int, float, or decimal.
      def self.numeric?(portable_type : String?, type_text : String) : Bool
        int?(portable_type, type_text) ||
          float?(portable_type, type_text) ||
          decimal?(portable_type, type_text)
      end

      # True if the column stores free-form text suitable for LIKE search.
      # Prefers the prostore portable type tag ("string"); otherwise falls
      # back to inspecting the SQL type text for the common text families.
      # Intentionally narrow — UUID / JSON / etc. are excluded for now.
      def self.searchable_text?(portable_type : String?, type_text : String) : Bool
        if pt = portable_type
          pt == "string"
        else
          t = type_text.upcase
          t.includes?("TEXT") || t.includes?("CHAR") || t.includes?("CLOB")
        end
      end
    end
  end
end
