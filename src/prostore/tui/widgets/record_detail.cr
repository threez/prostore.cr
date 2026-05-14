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
        @focused = true
        @row = {} of String => RowVal
        @schema = @browser.schema(@table)
        @cursor = 0
        @editing = false
        @edit_buf = ""
        @is_new = false
        @on_close = nil
        @on_follow_fk = nil
        reload
      end

      def self.for_new_record(x : Int32, y : Int32, width : Int32, height : Int32,
                              browser : Browser, table : String) : RecordDetail
        # Dummy pk_val — won't be used until after save
        inst = new(x, y, width, height, browser, table, browser.pk_col(table), "")
        inst.set_new_mode
        inst
      end

      def set_new_mode : Nil
        @is_new = true
        @row = {} of String => RowVal
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

        inner_w = width - 2
        max_name = @schema.columns.map(&.name.size).max? || 8
        label_w  = [max_name + 4, inner_w // 3].min

        @schema.columns.each_with_index do |col, i|
          row_y = y + 1 + i
          break if row_y >= y + height - 2

          val_str = if @editing && i == @cursor
                      "#{@edit_buf}█"
                    else
                      format_val(@row[col.name]?)
                    end

          fk_hint  = fk_for_col(col.name)
          fk_label = fk_hint ? Term.dim("  → #{fk_hint.references_table}") : ""
          pk_tag   = col.primary ? Term.dim(" [pk]") : ""

          pointer   = (i == @cursor) ? "▸" : " "
          label     = Term.fit("#{pointer} #{col.name}", label_w)
          val_space = inner_w - label_w - 1 - visible_len(fk_label) - visible_len(pk_tag)
          val_disp  = Term.fit(val_str, [val_space, 1].max)

          line = "#{label} #{val_disp}#{pk_tag}#{fk_label}"

          if i == @cursor
            screen.at(row_y, x + 1, Term.reverse(Term.fit(line, inner_w)))
          else
            screen.at(row_y, x + 1, Term.fit(line, inner_w))
          end
        end

        hint = if @editing
                 " Enter:save-field  Esc:cancel"
               elsif @is_new
                 " ↑↓:field  e:edit  s:insert  Esc:back"
               else
                 fk_part = current_col.try { |c| fk_for_col(c.name) } ? "  f:follow-fk" : ""
                 " ↑↓:field  e:edit#{fk_part}  s:save  d:delete  Esc:back"
               end
        screen.at(y + height - 1, x + 1, Term.fit(Term.dim(hint), inner_w))
      end

      def handle_key(ev : KeyEvent) : Bool
        if @editing
          handle_edit_key(ev)
        else
          handle_nav_key(ev)
        end
      end

      private def handle_edit_key(ev : KeyEvent) : Bool
        case ev.key
        when Key::Enter
          commit_edit
          true
        when Key::Esc
          @editing = false
          @edit_buf = ""
          true
        when Key::Backspace
          @edit_buf = @edit_buf[0...-1] unless @edit_buf.empty?
          true
        when Key::Char
          @edit_buf += ev.char.to_s
          true
        else
          false
        end
      end

      private def handle_nav_key(ev : KeyEvent) : Bool
        case ev.key
        when Key::Up
          @cursor = [@cursor - 1, 0].max
          true
        when Key::Down
          @cursor = [@cursor + 1, @schema.columns.size - 1].min
          true
        when Key::Esc
          @on_close.try &.call
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

      private def start_edit : Nil
        col = current_col
        return unless col
        return if col.primary && !@is_new
        @edit_buf = @row[col.name]?.to_s
        @editing = true
      end

      private def commit_edit : Nil
        col = current_col
        return unless col
        @row[col.name] = @edit_buf
        @editing = false
        @edit_buf = ""
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
        val = @row[pk]?
        "#{pk}=#{val || "?"}"
      end

      private def format_val(v : RowVal) : String
        v.nil? ? Term.dim("(null)") : v
      end

      # Count visible characters (strips ANSI escape sequences).
      private def visible_len(s : String) : Int32
        s.gsub(/\e\[[0-9;]*m/, "").chars.size
      end
    end
  end
end
