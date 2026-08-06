require "tui"
require "../browser"

module Prostore
  module TUI
    # In-memory (no DB round-trip) ListDataSource over Browser#tables —
    # the full table-name list is always small enough to hold as an
    # Array(String) and substring-filter locally, unlike RecordGrid's
    # row search which stays server-side because row counts aren't.
    class TableListSource < ::TUI::ListDataSource
      getter table_at : Array(String)

      def initialize(@browser : Browser)
        @all = [] of String
        @table_at = [] of String
      end

      def size : Int32
        @table_at.size
      end

      def title(filter : String, sort_key : Symbol) : String
        "Tables"
      end

      def sort_keys : Array(Symbol)
        [:name]
      end

      def reload(filter : String, sort : Symbol) : Nil
        @all = @browser.tables
        @table_at = filter.empty? ? @all : @all.select(&.includes?(filter))
      end
    end

    class TableList < ::TUI::ListView
      scroll header: 0

      def initialize(browser : Browser)
        @list_source = TableListSource.new(browser)
        super(@list_source)
      end

      def selected_table : String?
        idx = selected_index
        idx ? @list_source.table_at[idx] : nil
      end

      def row_content(index : Int32) : String
        @list_source.table_at[index]
      end
    end
  end
end
