require "../widget"
require "../browser"

module Prostore
  module TUI
    class RecordDetail < Widget
      property on_close : Proc(Nil)?
      property on_follow_fk : Proc(String, String, Nil)?

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
        @is_new       = false
        @on_close     = nil
        @on_follow_fk = nil
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
      end

      def reload : Nil
        return if @is_new
        pk = @pk_col
        return unless pk
        r = @browser.fetch_row(@table, pk, @pk_val)
        @row = r || {} of String => RowVal
      end

      def render(screen : Screen) : Nil
        title = @is_new ? "New · #{@table}" : "#{@table} · #{pk_display}"
        screen.box(y, x, height, width, title)

        inner_w  = width - 2
        max_name = @schema.columns.map(&.name.size).max? || 8
        label_w  = [max_name + 4, inner_w // 3].min
        val_w    = [inner_w - label_w - 1, 4].max
        available = height - 3  # -2 borders -1 hint line

        row_offsets = compute_row_offsets
        ensure_cursor_visible(row_offsets, available)

        @schema.columns.each_with_index do |col, fi|
          start = row_offsets[fi] - @field_scroll
          lines = field_lines(col, fi)

          lines.each_with_index do |line_content, li|
            screen_row = y + 1 + start + li
            next if screen_row < y + 1 || screen_row >= y + height - 1

            if li == 0
              pointer  = (fi == @cursor) ? "▸" : " "
              label    = Term.fit("#{pointer} #{col.name}", label_w)
              pk_tag   = col.primary ? Term.dim(" [pk]") : ""
              fk_hint  = fk_for_col(col.name)
              fk_label = fk_hint ? Term.dim("  → #{fk_hint.references_table}") : ""
            else
              label    = " " * label_w
              pk_tag   = ""
              fk_label = ""
            end

            val_display = Term.fit(line_content, val_w - visible_len(pk_tag) - visible_len(fk_label))
            line = "#{label} #{val_display}#{pk_tag}#{fk_label}"

            if fi == @cursor && !@editing
              screen.at(screen_row, x + 1, Term.reverse(Term.fit(line, inner_w)))
            else
              screen.at(screen_row, x + 1, Term.fit(line, inner_w))
            end
          end
        end

        render_hint(screen, inner_w)
      end

      def handle_key(ev : KeyEvent) : Bool
        @editing ? handle_edit_key(ev) : handle_nav_key(ev)
      end

      # ---------------------------------------------------------------- private

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
        when Key::Char
          case ev.char
          when 'e'
            start_edit
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
        val = @row[col.name]?
        raw = val || ""
        @edit_lines = raw.split('\n')
        @edit_lines << "" if @edit_lines.empty?
        @edit_row = @edit_lines.size - 1
        @edit_col = @edit_lines[@edit_row].size
        @editing  = true
      end

      private def commit_edit : Nil
        col = current_col
        return unless col
        @row[col.name] = @edit_lines.join('\n')
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
        if @editing && fi == @cursor
          [@edit_lines.size, 1].max
        else
          val = @row[col.name]?
          val.nil? ? 1 : val.split('\n').size
        end
      end

      # Returns the display lines for a field (without label prefix).
      private def field_lines(col : Adapter::LiveColumn, fi : Int32) : Array(String)
        if @editing && fi == @cursor
          @edit_lines.map_with_index do |text, li|
            if li == @edit_row
              left  = text[0...@edit_col]
              right = text[@edit_col..]? || ""
              "#{left}█#{right}"
            else
              text
            end
          end
        else
          val = @row[col.name]?
          if val.nil?
            [Term.dim("(null)")]
          else
            val.split('\n').map { |l| Term.value_color(@portable_types[col.name]?, col.type_text, l) }
          end
        end
      end

      private def render_hint(screen : Screen, inner_w : Int32) : Nil
        hint = if @editing
                 " ↑↓←→:cursor  Enter:newline  Esc:done"
               elsif @is_new
                 " ↑↓:field  e:edit  s:insert  Esc:back"
               else
                 fk_part = current_col.try { |c| fk_for_col(c.name) } ? "  f:follow-fk" : ""
                 " ↑↓:field  e:edit#{fk_part}  s:save  d:delete  Esc:back"
               end
        screen.at(y + height - 1, x + 1, Term.fit(Term.dim(hint), inner_w))
      end

      # ---------------------------------------------------------------- actions

      private def move_cursor(delta : Int32) : Nil
        @cursor = (@cursor + delta).clamp(0, @schema.columns.size - 1)
      end

      private def save : Nil
        if @is_new
          data = {} of String => String
          @row.each { |k, v| data[k] = v.to_s if v }
          @browser.insert_row(@table, data)
          @on_close.try &.call
        else
          pk = @pk_col
          return unless pk
          @row.each do |col_name, val|
            next if col_name == pk
            @browser.update_cell(@table, pk, @pk_val, col_name, val.to_s)
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

      private def visible_len(s : String) : Int32
        s.gsub(/\e\[[0-9;]*m/, "").chars.size
      end
    end
  end
end
