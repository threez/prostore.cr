module Prostore
  module TUI
    # Input validators used by the editor.  Pure functions over strings —
    # no widget state, no I/O.
    module Validation
      # Accepted time formats — ISO 8601 variants with optional T-separator,
      # fractional seconds, and timezone offset, plus bare date.
      TIME_FORMATS = [
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S.%L",
        "%Y-%m-%dT%H:%M:%S.%L",
        "%Y-%m-%d %H:%M:%S%z",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%d %H:%M:%S.%L%z",
        "%Y-%m-%dT%H:%M:%S.%L%z",
        "%Y-%m-%d",
      ]

      # True if the input parses successfully under any accepted format.
      def self.valid_time?(s : String) : Bool
        TIME_FORMATS.any? do |fmt|
          begin
            Time.parse(s.strip, fmt, Time::Location::UTC)
            true
          rescue
            false
          end
        end
      end
    end
  end
end
