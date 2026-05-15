module Prostore
  module Schema
    # A single Crystal enum member captured from a `field` declaration whose
    # type resolves to an `Enum` subclass (ADR-0016, ADR-0017). Each member
    # carries:
    #
    # - `name`       — the source-level Crystal identifier (`BounceHard`),
    #                  used for display, error messages, and as the lookup
    #                  key when comparing schemas across migrations.
    # - `value`      — the underlying Int64-promoted integer value, used for
    #                  the int-backed wire form and `@[Flags]` arithmetic.
    # - `wire_name`  — the string that hits the database for `enum_string`
    #                  columns and that appears in the CHECK constraint
    #                  (ADR-0017). Defaults to `name` for backward
    #                  compatibility with declarations that don't opt into a
    #                  custom naming convention (`naming: :as_declared`).
    #                  For `enum_int` columns the wire form is the integer
    #                  value, but the field still travels through this
    #                  record so the bookkeeping table is uniform.
    record EnumMember,
      name : String,
      value : Int64,
      wire_name : String = ""

    struct EnumMember
      # When constructed without an explicit wire_name, fall back to the
      # source-level name so existing call sites and bookkeeping rows that
      # predate ADR-0017 stay valid.
      def wire_name : String
        w = @wire_name
        w.empty? ? @name : w
      end
    end

    # Translate a Crystal enum member's source-level name to the wire form
    # selected by the field's `naming:` option (ADR-0017). Pure function;
    # the macro calls this once per member when synthesising the schema
    # record so the result is cached for the lifetime of the process.
    #
    # The conversions are deliberately conservative:
    #   - `:as_declared` — no change (current 0.3.x behaviour).
    #   - `:snake_case`  — `BounceHard` → `bounce_hard`. Mirrors the
    #     regex pair Crystal's `String#underscore` uses (and the FK
    #     ref-table derivation already in `macros.cr`).
    #   - `:lower_case`  — `BounceHard` → `bouncehard`. For codebases that
    #     just downcase without word separation.
    #   - `:kebab_case`  — `BounceHard` → `bounce-hard`. Same separation
    #     rule as snake_case but with hyphens.
    module NameConversion
      extend self

      def apply(name : String, algorithm : Symbol) : String
        case algorithm
        when :as_declared then name
        when :snake_case  then underscore(name, '_')
        when :kebab_case  then underscore(name, '-')
        when :lower_case  then name.downcase
        else
          raise ArgumentError.new("unknown enum naming algorithm: #{algorithm}")
        end
      end

      private def underscore(name : String, separator : Char) : String
        name
          .gsub(/([A-Z]+)([A-Z][a-z])/, "\\1#{separator}\\2")
          .gsub(/([a-z\d])([A-Z])/, "\\1#{separator}\\2")
          .downcase
      end
    end
  end
end
