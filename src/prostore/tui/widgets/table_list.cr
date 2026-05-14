require "../widget"
require "../browser"

module Prostore
  module TUI
    class TableList < Widget
      getter selected_table : String?
      property on_select : Proc(String, Nil)?

      def initialize(x : Int32, y : Int32, width : Int32, height : Int32, @browser : Browser)
        super(x, y, width, height)
        @tables = [] of String
        @cursor = 0
        @scroll = 0
        @selected_table = nil
        @on_select = nil
      end

      def reload : Nil
        @tables = @browser.tables
        @cursor = 0
        @scroll = 0
        select_current
      end

      def render(screen : Screen) : Nil
        title = focused? ? Term.bold("Tables") : "Tables"
        screen.box(y, x, height, width, title)

        @tables.each_with_index do |name, i|
          next if i < @scroll
          row_y = y + 1 + (i - @scroll)
          break if row_y >= y + height - 1

          label = Term.fit(" #{i == @cursor ? "▸" : " "} #{name}", width - 2)
          if i == @cursor && focused?
            screen.at(row_y, x + 1, Term.reverse(label))
          elsif i == @cursor
            screen.at(row_y, x + 1, Term.bold(label))
          else
            screen.at(row_y, x + 1, label)
          end
        end
      end

      def status_hint : String
        " ↑↓:table  Enter:open  q:quit"
      end

      def handle_key(ev : KeyEvent) : Bool
        case ev.key
        when Key::Up
          if @cursor > 0
            @cursor -= 1
            @scroll = @cursor if @cursor < @scroll
            select_current
          end
          true
        when Key::Down
          if @cursor < @tables.size - 1
            @cursor += 1
            visible = height - 2
            @scroll = @cursor - visible + 1 if @cursor >= @scroll + visible
            select_current
          end
          true
        else
          false
        end
      end

      private def select_current : Nil
        return if @tables.empty?
        @selected_table = @tables[@cursor]
        @on_select.try &.call(@tables[@cursor])
      end
    end
  end
end
