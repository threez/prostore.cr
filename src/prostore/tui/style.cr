module Prostore
  module TUI
    # Application-level visual styling — prostore-domain colours and ornaments
    # built on top of Term's generic ANSI primitives.
    #
    # Term knows about terminal escape sequences.  Style knows about
    # *prostore concepts* (portable types, FKs, validation errors, soft-wrap).
    module Style
      # Foreign-key reference — regular cyan, distinct from all the bright-*
      # data-type colours so FK values read as "linkable".
      def self.fk_ref(s : String) : String
        "\e[36m#{s}\e[0m"
      end

      # Validation error — bright red.
      def self.error(s : String) : String
        "\e[91m#{s}\e[0m"
      end

      # Soft-wrap continuation marker: dim magenta backslash.  Signals that
      # the logical value continues on the next display line.
      def self.wrap_cont : String
        "\e[2;35m\\\e[0m"
      end

      # Render a raw bool value ("true"/"false"/"1"/"0"/…) as a coloured
      # badge — background colour rather than foreground so it reads as a
      # status chip, not plain text.
      def self.bool_badge(raw : String) : String
        ColumnTypes.bool_truthy?(raw) ? "\e[42;30m yes \e[0m" : "\e[41;30m no \e[0m"
      end

      # Colour a value by data type.  Prefers prostore portable_type tag
      # (precise — "bool" stays green even when the SQL type is INTEGER);
      # falls back to inferring from SQL type_text when no portable type
      # is known (database not managed by prostore).
      def self.value(portable_type : String?, type_text : String, s : String) : String
        if pt = portable_type
          portable_type_fg(pt, s)
        else
          type_fg(type_text, s)
        end
      end

      # ---------------------------------------------------------------- private

      # Bright pastel-on-dark variants so different types are distinguishable
      # without being garish.
      private def self.portable_type_fg(portable_type : String, s : String) : String
        code = case portable_type
               when "int32", "int64"                then "96" # bright cyan
               when "float32", "float64", "decimal" then "93" # bright yellow
               when "bool"                          then "92" # bright green
               when "time"                          then "94" # bright blue
               when "bytes"                         then "95" # bright magenta
               when "uuid"                          then "96" # bright cyan (IDs)
               when "json"                          then "93" # bright yellow
               when "enum_string", "enum_int"       then "95" # bright magenta — categorical
               else                                      ""   # string, array_* → default
               end
        code.empty? ? s : "\e[#{code}m#{s}\e[0m"
      end

      private def self.type_fg(type_text : String, s : String) : String
        t = type_text.upcase
        code = if t.includes?("INT") || t.includes?("SERIAL")
                 "96" # bright cyan
               elsif t.includes?("REAL") || t.includes?("FLOAT") ||
                     t.includes?("DOUBLE") || t.includes?("NUMERIC") ||
                     t.includes?("DECIMAL")
                 "93" # bright yellow
               elsif t.includes?("BOOL")
                 "92" # bright green
               elsif t.includes?("DATE") || t.includes?("TIME") || t.includes?("STAMP")
                 "94" # bright blue
               elsif t.includes?("BLOB") || t.includes?("BYTE") || t.includes?("BINARY")
                 "95" # bright magenta
               else
                 "" # TEXT, VARCHAR, etc.
               end
        code.empty? ? s : "\e[#{code}m#{s}\e[0m"
      end
    end
  end
end
