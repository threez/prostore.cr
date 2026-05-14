require "../widget"
require "../browser"

module Prostore
  module TUI
    class RecordGrid < Widget
      PAGE_SIZE = 50

      getter table : String?
      property on_open_detail : Proc(String, String, Nil)?
      property on_new_row : Proc(String, Nil)?

      def initialize(x : Int32, y : Int32, width : Int32, height : Int32, @browser : Browser)
        super(x, y, width, height)
        @table = nil
        @col_names = [] of String
        @rows = [] of Row
        @total = 0_i64
        @page = 0
        @cursor = 0
        @on_open_detail = nil
        @on_new_row = nil
      end

      def load_table(table : String) : Nil
        @table = table
        @page = 0
        @cursor = 0
        reload
      end

      def reload : Nil
        t = @table
        return unless t
        @total = @browser.count(t)
        @col_names, @rows = @browser.fetch_rows(t, PAGE_SIZE, @page * PAGE_SIZE)
      end

      def render(screen : Screen) : Nil
        t = @table || "(no table)"
        total_pages = [(@total.to_f / PAGE_SIZE).ceil.to_i, 1].max
        title_str = "#{t}  page #{@page + 1}/#{total_pages}  #{@total} rows"
        title = focused ? Term.bold(title_str) : title_str
        screen.box(y, x, height, width, title)

        inner_w = width - 2
        return if @col_names.empty?

        col_widths = compute_col_widths(inner_w)

        # Header
        header = build_row_str(@col_names.map { |n| Term.bold(n) }, col_widths)
        screen.at(y + 1, x + 1, Term.fit(header, inner_w))

        # Data rows
        @rows.each_with_index do |row, i|
          row_y = y + 2 + i
          break if row_y >= y + height - 1
          cells = row.map { |v| v.nil? ? Term.dim("(null)") : v }
          line = Term.fit(build_row_str(cells, col_widths), inner_w)
          if i == @cursor && focused
            screen.at(row_y, x + 1, Term.reverse(line))
          elsif i == @cursor
            screen.at(row_y, x + 1, Term.bold(line))
          else
            screen.at(row_y, x + 1, line)
          end
        end

      end

      def handle_key(ev : KeyEvent) : Bool
        t = @table
        return false unless t

        case ev.key
        when Key::Up
          @cursor = [@cursor - 1, 0].max
          true
        when Key::Down
          @cursor = [@cursor + 1, [@rows.size - 1, 0].max].min
          true
        when Key::PageDown
          total_pages = [(@total.to_f / PAGE_SIZE).ceil.to_i - 1, 0].max
          if @page < total_pages
            @page += 1
            @cursor = 0
            reload
          end
          true
        when Key::PageUp
          if @page > 0
            @page -= 1
            @cursor = 0
            reload
          end
          true
        when Key::Enter
          open_detail(t)
          true
        when Key::Char
          case ev.char
          when 'n'
            @on_new_row.try &.call(t)
            true
          when 'd'
            delete_current(t)
            true
          else
            false
          end
        else
          false
        end
      end

      private def open_detail(table : String) : Nil
        return if @rows.empty?
        pk = @browser.pk_col(table)
        return unless pk
        pk_idx = @col_names.index(pk)
        return unless pk_idx
        pk_val = @rows[@cursor][pk_idx]
        return unless pk_val
        @on_open_detail.try &.call(table, pk_val)
      end

      private def delete_current(table : String) : Nil
        return if @rows.empty?
        pk = @browser.pk_col(table)
        return unless pk
        pk_idx = @col_names.index(pk)
        return unless pk_idx
        pk_val = @rows[@cursor][pk_idx]
        return unless pk_val
        @browser.delete_row(table, pk, pk_val)
        reload
        @cursor = [@cursor, [@rows.size - 1, 0].max].min
      end

      private def compute_col_widths(inner_w : Int32) : Array(Int32)
        n = @col_names.size
        return [] of Int32 if n == 0
        per : Int32 = [((inner_w - n + 1).to_f / n).to_i, 4].max
        widths = Array(Int32).new(n, per)
        used = widths.sum(0) + (n - 1)
        widths[-1] += [inner_w - used, 0].max
        widths
      end

      private def build_row_str(cells : Array(String), widths : Array(Int32)) : String
        cells.each_with_index.map do |cell, i|
          w = widths[i]? || 4
          Term.fit(cell, w)
        end.join(Term::VL)
      end
    end
  end
end
