require "../widget"
require "../browser"
require "../style"
require "../column_types"

module Prostore
  module TUI
    class RecordGrid < Widget
      PAGE_SIZE    =  50
      MIN_COL_WIDTH =  8

      getter table : String?
      property on_open_detail : Proc(String, String, Nil)?
      property on_new_row : Proc(String, Nil)?

      def initialize(x : Int32, y : Int32, width : Int32, height : Int32, @browser : Browser)
        super(x, y, width, height)
        @table = nil
        @col_names = [] of String
        @col_types       = {} of String => String  # SQL type_text fallback
        @portable_types  = {} of String => String
        @fk_refs         = {} of String => String  # col_name → referenced table
        @searchable_cols = [] of String            # text-like columns for LIKE search
        @rows = [] of Row
        @total = 0_i64
        @page = 0
        @cursor = 0
        @col_offset = 0
        @filter_term   = ""
        @search_active = false
        @on_open_detail = nil
        @on_new_row = nil
      end

      def search_active? : Bool
        @search_active
      end

      def load_table(table : String) : Nil
        @table = table
        @page = 0
        @cursor = 0
        @col_offset = 0
        @filter_term   = ""
        @search_active = false
        schema = @browser.schema(table)
        @col_types = schema.columns.each_with_object({} of String => String) do |c, h|
          h[c.name] = c.type_text
        end
        @fk_refs = schema.foreign_keys.each_with_object({} of String => String) do |fk, h|
          fk.columns.each { |c| h[c] = fk.references_table }
        end
        @portable_types = @browser.portable_types(table)
        @searchable_cols = schema.columns.select { |c|
          ColumnTypes.searchable_text?(@portable_types[c.name]?, c.type_text)
        }.map(&.name)
        reload
      end

      def reload : Nil
        t = @table
        return unless t
        f = current_filter
        @total = @browser.count(t, f)
        @col_names, @rows = @browser.fetch_rows(t, PAGE_SIZE, @page * PAGE_SIZE, f)
      end

      private def current_filter : Filter?
        return nil if @filter_term.empty? || @searchable_cols.empty?
        Filter.new(@filter_term, @searchable_cols)
      end

      def render(screen : Screen) : Nil
        t = @table || "(no table)"
        total_pages = [(@total.to_f / PAGE_SIZE).ceil.to_i, 1].max
        inner_w = width - 2

        from, to_col, col_widths = visible_col_range(inner_w)
        n = @col_names.size

        scroll_info  = n > (to_col - from + 1) ? "  col #{from + 1}-#{to_col + 1}/#{n}" : ""
        search_part  = if @search_active
                          "  /#{@filter_term}█"
                        elsif !@filter_term.empty?
                          "  /#{@filter_term}"
                        else
                          ""
                        end
        title_str = "#{t}  pg #{@page + 1}/#{total_pages}  #{@total} rows#{scroll_info}#{search_part}"
        title = focused ? Term.bold(title_str) : title_str
        screen.box(y, x, height, width, title)

        return if @col_names.empty?

        vis_names = @col_names[from..to_col]

        # Header
        header = build_row_str(vis_names.map { |n|
          ref = @fk_refs[n]?
          ref ? "#{Term.bold(n)} #{Style.fk_ref("→#{ref}")}" : Term.bold(n)
        }, col_widths)
        screen.at(y + 1, x + 1, Term.fit(header, inner_w))

        # Data rows
        @rows.each_with_index do |row, i|
          row_y = y + 2 + i
          break if row_y >= y + height - 1
          vis_cells = row[from..to_col].map_with_index do |v, ci|
            if v.nil?
              Term.dim("(null)")
            else
              col_name = vis_names[ci]
              pt       = @portable_types[col_name]?
              tt       = @col_types[col_name]? || ""
              if ColumnTypes.bool?(pt, tt)
                Style.bool_badge(v)
              elsif @fk_refs[col_name]?
                Style.fk_ref(v)
              else
                Style.value(pt, tt, v)
              end
            end
          end
          line = Term.fit(build_row_str(vis_cells, col_widths), inner_w)
          if i == @cursor && focused
            screen.at(row_y, x + 1, Term.reverse(Term.strip_ansi(line)))
          elsif i == @cursor
            screen.at(row_y, x + 1, Term.bold(Term.strip_ansi(line)))
          else
            screen.at(row_y, x + 1, line)
          end
        end
      end

      def status_hint : String
        if @search_active
          " type to filter  Backspace:erase  Enter/Esc:done"
        else
          " ESC:back  ↑↓:row  ←→:cols  Enter:detail  PgUp/Dn:page  /:search  n:new  d:delete  q:quit"
        end
      end

      def handle_key(ev : KeyEvent) : Bool
        t = @table
        return false unless t

        return handle_search_key(ev) if @search_active

        case ev.key
        when Key::Up
          @cursor = [@cursor - 1, 0].max
          true
        when Key::Down
          @cursor = [@cursor + 1, [@rows.size - 1, 0].max].min
          true
        when Key::Left
          @col_offset = [@col_offset - 1, 0].max
          true
        when Key::Right
          @col_offset = [@col_offset + 1, max_col_offset].min
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
          when '/'
            if @searchable_cols.empty?
              false
            else
              @search_active = true
              true
            end
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

      # Search-mode input handling.  Returns true for every key while the
      # input prompt is open so the keypress never bubbles to the app
      # (e.g. Esc must not also pop back to the table list).
      private def handle_search_key(ev : KeyEvent) : Bool
        case ev.key
        when Key::Esc, Key::Enter
          @search_active = false
        when Key::Backspace
          unless @filter_term.empty?
            @filter_term = @filter_term[0, @filter_term.size - 1]
            @page = 0
            @cursor = 0
            reload
          end
        when Key::Char
          @filter_term += ev.char.to_s
          @page = 0
          @cursor = 0
          reload
        end
        true
      end

      private def visible_col_range(inner_w : Int32) : Tuple(Int32, Int32, Array(Int32))
        n = @col_names.size
        return {0, 0, [inner_w] of Int32} if n == 0

        # How many columns fit at the minimum width (each col + one │ separator)?
        max_visible = [(inner_w + 1) // (MIN_COL_WIDTH + 1), 1].max

        from   = @col_offset.clamp(0, [n - max_visible, 0].max)
        to_col = [from + max_visible - 1, n - 1].min
        count  = to_col - from + 1

        # Distribute available width evenly, honouring the minimum
        seps   = count - 1
        per    = [(inner_w - seps) // count, MIN_COL_WIDTH].max
        widths = Array(Int32).new(count, per)
        used   = widths.sum(0) + seps
        widths[-1] += [inner_w - used, 0].max

        {from, to_col, widths}
      end

      private def max_col_offset : Int32
        n = @col_names.size
        inner_w = width - 2
        max_visible = [(inner_w + 1) // (MIN_COL_WIDTH + 1), 1].max
        [n - max_visible, 0].max
      end

      private def build_row_str(cells : Array(String), widths : Array(Int32)) : String
        cells.each_with_index.map do |cell, i|
          w = widths[i]? || MIN_COL_WIDTH
          Term.fit(cell, w)
        end.join(Term::VL)
      end

      # Returns the PK value of the currently highlighted row, or nil.
      def selected_pk : String?
        t = @table
        return nil unless t
        return nil if @rows.empty?
        pk = @browser.pk_col(t)
        return nil unless pk
        idx = @col_names.index(pk)
        return nil unless idx
        @rows[@cursor][idx]
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
    end
  end
end
