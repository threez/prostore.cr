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
        else                                     false
        end
      end

      # Canonical human-readable bool form.
      def self.bool_display(val : String) : String
        bool_truthy?(val) ? "yes" : "no"
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
