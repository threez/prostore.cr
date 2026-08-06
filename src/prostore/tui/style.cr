require "tui"

module Prostore
  module TUI
    # Application-level visual styling — prostore-domain colours and ornaments
    # built on top of tui.cr's generic ANSI/Cell primitives.
    #
    # tui.cr's TypeStyle knows generic SQL-type coloring. Style knows about
    # *prostore concepts* (portable types beyond what TypeStyle covers, FKs,
    # validation errors, soft-wrap).
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

      # Colour a value by data type.  Delegates to tui.cr's TypeStyle for the
      # generic SQL types it covers (ints, floats, bool, time, bytes); for
      # prostore-only categories it doesn't know about (uuid, json, native
      # enums), falls back to prostore's own colour choices so those types
      # don't silently lose their colouring.
      def self.value(portable_type : String?, type_text : String, s : String) : String
        if style = ::TUI::TypeStyle.for(portable_type, type_text)
          ::TUI::CellStyle.apply(style, s)
        elsif pt = portable_type
          extra_portable_type_fg(pt, s)
        else
          s
        end
      end

      # ---------------------------------------------------------------- private

      # Portable types TypeStyle doesn't cover — categorical/ID types that
      # are prostore-only concepts (native enums, uuid, json).
      private def self.extra_portable_type_fg(portable_type : String, s : String) : String
        code = case portable_type
               when "uuid"                    then "96" # bright cyan (IDs)
               when "json"                    then "93" # bright yellow
               when "enum_string", "enum_int" then "95" # bright magenta — categorical
               else                                ""   # string, array_* → default
               end
        code.empty? ? s : "\e[#{code}m#{s}\e[0m"
      end
    end
  end
end
