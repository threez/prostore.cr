require "../widget"
require "../browser"
require "../style"
require "../column_types"
require "../validation"

module Prostore
  module TUI
    class RecordDetail < Widget
      property on_close    : Proc(Nil)?
      property on_follow_fk : Proc(String, String, Nil)?
      property on_pick_fk   : Proc(String, String, Nil)?

      def initialize(x : Int32, y : Int32, width : Int32, height : Int32,
                     @browser : Browser, @table : String, @pk_col : String?,
                     @pk_val : String)
        super(x, y, width, height)
        @focused        = true
        @row            = {} of String => RowVal
        @schema         = @browser.schema(@table)
        @portable_types = @browser.portable_types(@table)
        @cursor       = 0   # focused field index
        @field_scroll = 0   # display-row offset for the field list
        @editing      = false
        @edit_lines   = [] of String
        @edit_row     = 0   # cursor line within @edit_lines
        @edit_col     = 0   # cursor column within current line
        @bool_editing  = false
        @bool_pending  = false
        @field_errors  = {} of String => String
        @dirty         = Set(String).new   # column names mutated since last load
        @is_new        = false
        @on_close      = nil
        @on_follow_fk  = nil
        @on_pick_fk    = nil
        reload
      end

      def self.for_new_record(x : Int32, y : Int32, width : Int32, height : Int32,
                              browser : Browser, table : String) : RecordDetail
        inst = new(x, y, width, height, browser, table, browser.pk_col(table), "")
        inst.set_new_mode
        inst
      end

      def set_new_mode : Nil
        @is_new = true
        @row    = {} of String => RowVal
        @field_errors.clear
        @dirty.clear
      end

      def reload : Nil
        return if @is_new
        pk = @pk_col
        return unless pk
        r = @browser.fetch_row(@table, pk, @pk_val)
        @row = r || {} of String => RowVal
        @field_errors.clear
        @dirty.clear
      end

      def set_row_value(col_name : String, value : String) : Nil
        @row[col_name] = value
        @dirty << col_name
      end

      def render(screen : Screen) : Nil
        title = @is_new ? "New · #{@table}" : "#{@table} · #{pk_display}"
        screen.box(y, x, height, width, title)

        inner_w  = width - 2
        max_name = @schema.columns.map(&.name.size).max? || 8
        label_w  = [max_name + 4, inner_w // 3].min
        val_w    = compute_val_w
        available = height - 2  # -2 borders (hint now lives in the App's status bar)

        row_offsets = compute_row_offsets
        ensure_cursor_visible(row_offsets, available)

        @schema.columns.each_with_index do |col, fi|
          start = row_offsets[fi] - @field_scroll
          lines = field_lines(col, fi)

          lines.each_with_index do |line_content, li|
            screen_row = y + 1 + start + li
            next if screen_row < y + 1 || screen_row >= y + height - 1

            dirty = @dirty.includes?(col.name)
            if li == 0
              pointer  = if fi == @cursor
                             "▸"
                           elsif @field_errors.has_key?(col.name)
                             Style.error("!")
                           else
                             " "
                           end
              raw_label = Term.fit("#{pointer} #{col.name}", label_w)
              label     = dirty ? Term.bold(raw_label) : raw_label
              pk_tag    = col.primary ? Term.dim(" [pk]") : ""
              fk_hint   = fk_for_col(col.name)
              fk_label  = fk_hint ? Style.fk_ref("  → #{fk_hint.references_table}") : ""
            else
              label    = " " * label_w
              pk_tag   = ""
              fk_label = ""
            end

            val_display = Term.fit(line_content, val_w - Term.visible_size(pk_tag) - Term.visible_size(fk_label))
            line = "#{label} #{val_display}#{pk_tag}#{fk_label}"

            if fi == @cursor && !@editing && !@bool_editing
              # Strip inner ANSI before applying reverse — otherwise the first
              # `\e[0m` from a colour segment cancels the reverse video mid-row.
              plain  = Term.fit(Term.strip_ansi(line), inner_w)
              styled = dirty ? Term.bold(Term.reverse(plain)) : Term.reverse(plain)
              screen.at(screen_row, x + 1, styled)
            else
              screen.at(screen_row, x + 1, Term.fit(line, inner_w))
            end
          end
        end

      end

      def handle_key(ev : KeyEvent) : Bool
        if @bool_editing
          handle_bool_edit_key(ev)
        elsif @editing
          handle_edit_key(ev)
        else
          handle_nav_key(ev)
        end
      end

      # ---------------------------------------------------------------- private

      private def handle_bool_edit_key(ev : KeyEvent) : Bool
        case ev.key
        when Key::Esc, Key::Enter
          commit_bool_edit
          true
        when Key::Left, Key::Right
          @bool_pending = !@bool_pending
          true
        when Key::Up
          commit_bool_edit
          move_cursor(-1)
          true
        when Key::Down
          commit_bool_edit
          move_cursor(1)
          true
        when Key::Char
          case ev.char
          when ' '
            @bool_pending = !@bool_pending
            true
          else
            false
          end
        else
          false
        end
      end

      private def handle_edit_key(ev : KeyEvent) : Bool
        case ev.key
        when Key::Esc
          commit_edit
          true  # consumed — app will not pop the stack
        when Key::Enter
          insert_newline
          true
        when Key::Backspace
          edit_backspace
          true
        when Key::Delete
          edit_delete
          true
        when Key::Left
          edit_move_left
          true
        when Key::Right
          edit_move_right
          true
        when Key::Up
          if @edit_row > 0
            @edit_row -= 1
            @edit_col = [@edit_col, @edit_lines[@edit_row].size].min
          else
            commit_edit
            move_cursor(-1)
          end
          true
        when Key::Down
          if @edit_row < @edit_lines.size - 1
            @edit_row += 1
            @edit_col = [@edit_col, @edit_lines[@edit_row].size].min
          else
            commit_edit
            move_cursor(1)
          end
          true
        when Key::Home
          @edit_col = 0
          true
        when Key::End
          @edit_col = @edit_lines[@edit_row].size
          true
        when Key::Tab
          col = current_col
          fk  = col ? fk_for_col(col.name) : nil
          if fk && col && fk.columns.size == 1
            cancel_edit
            @on_pick_fk.try &.call(fk.references_table, col.name)
            true
          else
            false
          end
        when Key::Char
          line = @edit_lines[@edit_row]
          @edit_lines[@edit_row] = line[0...@edit_col] + ev.char.to_s + (line[@edit_col..]? || "")
          @edit_col += 1
          true
        else
          false
        end
      end

      private def handle_nav_key(ev : KeyEvent) : Bool
        case ev.key
        when Key::Up
          move_cursor(-1)
          true
        when Key::Down
          move_cursor(1)
          true
        when Key::Tab
          col = current_col
          fk  = col ? fk_for_col(col.name) : nil
          if fk && col && fk.columns.size == 1
            @on_pick_fk.try &.call(fk.references_table, col.name)
            true
          else
            false
          end
        when Key::Char
          case ev.char
          when 'e'
            start_edit
            true
          when 'r'
            remove_value
            true
          when 's'
            save
            true
          when 'd'
            delete_and_close unless @is_new
            true
          when 'f'
            follow_fk
            true
          else
            false
          end
        else
          false
        end
      end

      # ---------------------------------------------------------------- edit helpers

      private def start_edit : Nil
        col = current_col
        return unless col
        return if col.primary && !@is_new
        @field_errors.delete(col.name)
        if ColumnTypes.bool?(@portable_types[col.name]?, col.type_text)
          @bool_pending = ColumnTypes.bool_truthy?(@row[col.name]?)
          @bool_editing = true
        else
          val = @row[col.name]?
          raw = val || ""
          @edit_lines = raw.split('\n')
          @edit_lines << "" if @edit_lines.empty?
          @edit_row = @edit_lines.size - 1
          @edit_col = @edit_lines[@edit_row].size
          @editing  = true
        end
      end

      private def commit_edit : Nil
        col = current_col
        return unless col
        value = @edit_lines.join('\n')
        # An empty edit on a nullable column means NULL, not the literal
        # empty string — otherwise the column would be coerced to "" on save
        # and the display would lose the (null) marker.
        @row[col.name] = (value.empty? && col.nullable) ? nil : value
        @dirty << col.name
        if ColumnTypes.time?(@portable_types[col.name]?, col.type_text) && !value.strip.empty?
          if Validation.valid_time?(value)
            @field_errors.delete(col.name)
          else
            @field_errors[col.name] = "invalid time — expected YYYY-MM-DD HH:MM:SS"
          end
        else
          @field_errors.delete(col.name)
        end
        @editing = false
        @edit_lines.clear
        @edit_row = 0
        @edit_col = 0
      end

      private def commit_bool_edit : Nil
        col = current_col
        return unless col
        @row[col.name] = @bool_pending ? "true" : "false"
        @dirty << col.name
        @bool_editing = false
      end

      private def cancel_edit : Nil
        @editing = false
        @edit_lines.clear
        @edit_row = 0
        @edit_col = 0
      end

      private def insert_newline : Nil
        line  = @edit_lines[@edit_row]
        left  = line[0...@edit_col]
        right = line[@edit_col..]? || ""
        @edit_lines[@edit_row] = left
        @edit_lines.insert(@edit_row + 1, right)
        @edit_row += 1
        @edit_col = 0
      end

      private def edit_backspace : Nil
        if @edit_col > 0
          line = @edit_lines[@edit_row]
          @edit_lines[@edit_row] = line[0...(@edit_col - 1)] + (line[@edit_col..]? || "")
          @edit_col -= 1
        elsif @edit_row > 0
          prev = @edit_lines[@edit_row - 1]
          curr = @edit_lines[@edit_row]
          @edit_col = prev.size
          @edit_lines[@edit_row - 1] = prev + curr
          @edit_lines.delete_at(@edit_row)
          @edit_row -= 1
        end
      end

      private def edit_delete : Nil
        line = @edit_lines[@edit_row]
        if @edit_col < line.size
          @edit_lines[@edit_row] = line[0...@edit_col] + (line[(@edit_col + 1)..]? || "")
        elsif @edit_row < @edit_lines.size - 1
          @edit_lines[@edit_row] = line + @edit_lines[@edit_row + 1]
          @edit_lines.delete_at(@edit_row + 1)
        end
      end

      private def edit_move_left : Nil
        if @edit_col > 0
          @edit_col -= 1
        elsif @edit_row > 0
          @edit_row -= 1
          @edit_col = @edit_lines[@edit_row].size
        end
      end

      private def edit_move_right : Nil
        line = @edit_lines[@edit_row]
        if @edit_col < line.size
          @edit_col += 1
        elsif @edit_row < @edit_lines.size - 1
          @edit_row += 1
          @edit_col = 0
        end
      end

      # ---------------------------------------------------------------- scroll / layout

      private def compute_row_offsets : Array(Int32)
        cur = 0
        @schema.columns.map_with_index do |col, fi|
          start = cur
          cur += field_row_count(col, fi)
          start
        end
      end

      private def ensure_cursor_visible(row_offsets : Array(Int32), available : Int32) : Nil
        return if @schema.columns.empty?
        col = @schema.columns[@cursor]?
        return unless col
        c_start = row_offsets[@cursor]
        c_end   = c_start + field_row_count(col, @cursor) - 1
        if c_start < @field_scroll
          @field_scroll = c_start
        elsif c_end >= @field_scroll + available
          @field_scroll = c_end - available + 1
        end
        @field_scroll = [@field_scroll, 0].max
      end

      private def field_row_count(col : Adapter::LiveColumn, fi : Int32) : Int32
        vw = compute_val_w
        if @bool_editing && fi == @cursor
          1
        elsif @editing && fi == @cursor
          count = @edit_lines.each_with_index.sum do |text, li|
            soft_wrap(li == @edit_row ? text + "█" : text, vw).size
          end
          [count, 1].max
        else
          val = @row[col.name]?
          val.nil? ? 1 : [val.split('\n').sum { |l| soft_wrap(l, vw).size }, 1].max
        end
      end

      # Returns the display lines for a field (without label prefix).
      # Long logical lines are soft-wrapped; non-final segments end with Term.wrap_cont.
      private def field_lines(col : Adapter::LiveColumn, fi : Int32) : Array(String)
        if @bool_editing && fi == @cursor
          yes_part = @bool_pending ? "◉ yes" : "○ yes"
          no_part  = @bool_pending ? "○ no"  : "◉ no"
          ["#{yes_part}   #{no_part}"]
        elsif @editing && fi == @cursor
          vw = compute_val_w
          result = [] of String
          @edit_lines.each_with_index do |text, li|
            full = if li == @edit_row
                      left  = text[0...@edit_col]
                      right = text[@edit_col..]? || ""
                      "#{left}█#{right}"
                    else
                      text
                    end
            segs = soft_wrap(full, vw)
            segs.each_with_index do |seg, si|
              result << (si < segs.size - 1 ? seg + Style.wrap_cont : seg)
            end
          end
          result
        else
          val = @row[col.name]?
          if val.nil?
            [Term.dim("(null)")]
          else
            vw        = compute_val_w
            pt        = @portable_types[col.name]?
            has_error = @field_errors.has_key?(col.name)
            display   = ColumnTypes.bool?(pt, col.type_text) ? ColumnTypes.bool_display(val) : val
            result    = [] of String
            display.split('\n').each do |l|
              segs = soft_wrap(l, vw)
              segs.each_with_index do |seg, si|
                colored = has_error ? Style.error(seg) : Style.value(pt, col.type_text, seg)
                result << (si < segs.size - 1 ? colored + Style.wrap_cont : colored)
              end
            end
            result
          end
        end
      end

      # Context-aware hint surfaced in the App's global status bar.  All key
      # bindings reachable from the current state are listed here so the user
      # doesn't have to look in two places.
      def status_hint : String
        err     = !@bool_editing && !@editing ? current_col.try { |c| @field_errors[c.name]? } : nil
        cur_col = current_col
        cur_fk  = cur_col.try { |c| fk_for_col(c.name) }
        rm_part = (cur_col && cur_col.nullable && !(cur_col.primary && !@is_new)) ? "  r:remove" : ""
        if @bool_editing
          " ←→/Space:toggle  Enter/Esc:done"
        elsif @editing
          tab_part = (cur_fk && cur_fk.columns.size == 1) ? "  Tab:browse-fk" : ""
          " ↑↓←→:cursor  Enter:newline#{tab_part}  Esc:done"
        elsif err
          " ✕ #{err}"
        elsif @is_new
          tab_part = (cur_fk && cur_fk.columns.size == 1) ? "  Tab:browse-fk" : ""
          " ↑↓:field  e:edit#{rm_part}#{tab_part}  s:insert  Esc:back"
        else
          fk_follow = cur_fk ? "  f:follow-fk" : ""
          fk_tab    = (cur_fk && cur_fk.columns.size == 1) ? "  Tab:browse-fk" : ""
          " ↑↓:field  e:edit#{rm_part}#{fk_follow}#{fk_tab}  s:save  d:delete  Esc:back"
        end
      end

      # ---------------------------------------------------------------- actions

      private def move_cursor(delta : Int32) : Nil
        @cursor = (@cursor + delta).clamp(0, @schema.columns.size - 1)
      end

      private def save : Nil
        if @is_new
          # Pass nullable values through as-is — nil binds to NULL.  Columns
          # the user never touched aren't in @row and are omitted, so the
          # database default applies for them.
          @browser.insert_row(@table, @row)
          @on_close.try &.call
        else
          pk = @pk_col
          return unless pk
          @row.each do |col_name, val|
            next if col_name == pk
            @browser.update_cell(@table, pk, @pk_val, col_name, val)
          end
          reload
        end
      end

      private def delete_and_close : Nil
        pk = @pk_col
        return unless pk
        @browser.delete_row(@table, pk, @pk_val)
        @on_close.try &.call
      end

      private def follow_fk : Nil
        col = current_col
        return unless col
        fk = fk_for_col(col.name)
        return unless fk
        val = @row[col.name]?
        return unless val
        @on_follow_fk.try &.call(fk.references_table, val)
      end

      # Clear a nullable field to NULL.  Same guards as start_edit — PK of an
      # existing record can't be touched; non-nullable columns are skipped.
      private def remove_value : Nil
        col = current_col
        return unless col
        return if col.primary && !@is_new
        return unless col.nullable
        @row[col.name] = nil
        @dirty << col.name
        @field_errors.delete(col.name)
      end

      private def current_col : Adapter::LiveColumn?
        @schema.columns[@cursor]?
      end

      private def fk_for_col(col_name : String) : Adapter::LiveForeignKey?
        @schema.foreign_keys.find { |fk| fk.columns.includes?(col_name) }
      end

      private def pk_display : String
        pk = @pk_col
        return "?" unless pk
        "#{pk}=#{@row[pk]? || "?"}"
      end

      private def compute_val_w : Int32
        inner_w  = width - 2
        max_name = @schema.columns.map(&.name.size).max? || 8
        label_w  = [max_name + 4, inner_w // 3].min
        [inner_w - label_w - 1, 4].max
      end

      # Split plain text into chunks of at most (val_w-1) chars; last chunk
      # may be shorter. Returns at least one element (even for empty strings).
      private def soft_wrap(text : String, val_w : Int32) : Array(String)
        return [text] if val_w <= 1
        content_w = val_w - 1
        return [text] if text.size <= content_w
        segs = [] of String
        pos = 0
        while pos + content_w < text.size
          segs << text[pos, content_w]
          pos += content_w
        end
        segs << text[pos..]
        segs
      end

    end
  end
end
