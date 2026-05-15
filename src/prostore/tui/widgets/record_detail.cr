require "../widget"
require "../browser"
require "../style"
require "../column_types"
require "../validation"

module Prostore
  module TUI
    class RecordDetail < Widget
      property on_close : Proc(Nil)?
      property on_follow_fk : Proc(String, String, Nil)?
      property on_pick_fk : Proc(String, String, Nil)?

      def initialize(x : Int32, y : Int32, width : Int32, height : Int32,
                     @browser : Browser, @table : String, @pk_col : String?,
                     @pk_val : String)
        super(x, y, width, height)
        @focused = true
        @row = {} of String => RowVal
        @schema = @browser.schema(@table)
        @portable_types = @browser.portable_types(@table)
        @enum_columns = @browser.enum_columns(@table)
        @cursor = 0       # focused field index
        @field_scroll = 0 # display-row offset for the field list
        @editing = false
        @edit_lines = [] of String
        @edit_row = 0 # cursor line within @edit_lines
        @edit_col = 0 # cursor column within current line
        @bool_editing = false
        @bool_pending = false
        @enum_editing = false           # radio picker for plain enums
        @enum_pending_index = 0         # which member is currently selected
        @enum_focus = 0                 # which member the cursor is highlighting
        @flags_editing = false          # checkbox picker for @[Flags] enums
        @flags_pending = Set(Int32).new # indices of currently-selected members
        @field_errors = {} of String => String
        @dirty = Set(String).new # column names mutated since last load
        @is_new = false
        @on_close = nil
        @on_follow_fk = nil
        @on_pick_fk = nil
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
        @row = {} of String => RowVal
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

        inner_w = width - 2
        max_name = @schema.columns.max_of?(&.name.size) || 8
        label_w = [max_name + 4, inner_w // 3].min
        val_w = compute_val_w
        available = height - 2 # -2 borders (hint now lives in the App's status bar)

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
              pointer = if fi == @cursor
                          "▸"
                        elsif @field_errors.has_key?(col.name)
                          Style.error("!")
                        else
                          " "
                        end
              raw_label = Term.fit("#{pointer} #{col.name}", label_w)
              label = dirty ? Term.bold(raw_label) : raw_label
              pk_tag = col.primary ? Term.dim(" [pk]") : ""
              fk_hint = fk_for_col(col.name)
              fk_label = fk_hint ? Style.fk_ref("  → #{fk_hint.references_table}") : ""
            else
              label = " " * label_w
              pk_tag = ""
              fk_label = ""
            end

            val_display = Term.fit(line_content, val_w - Term.visible_size(pk_tag) - Term.visible_size(fk_label))
            line = "#{label} #{val_display}#{pk_tag}#{fk_label}"

            if fi == @cursor && !@editing && !@bool_editing && !@enum_editing && !@flags_editing
              # Strip inner ANSI before applying reverse — otherwise the first
              # `\e[0m` from a colour segment cancels the reverse video mid-row.
              plain = Term.fit(Term.strip_ansi(line), inner_w)
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
        elsif @enum_editing
          handle_enum_edit_key(ev)
        elsif @flags_editing
          handle_flags_edit_key(ev)
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

      # Radio picker for plain (non-flags) enums.  ↑/↓ moves the focused
      # member, Space/Enter selects it and commits, Esc cancels without
      # writing back.
      private def handle_enum_edit_key(ev : KeyEvent) : Bool
        info = current_enum_info
        return false if info.nil?
        case ev.key
        when Key::Esc
          cancel_enum_edit
          true
        when Key::Enter
          @enum_pending_index = @enum_focus
          commit_enum_edit
          true
        when Key::Up
          @enum_focus = (@enum_focus - 1).clamp(0, info.members.size - 1)
          true
        when Key::Down
          @enum_focus = (@enum_focus + 1).clamp(0, info.members.size - 1)
          true
        when Key::Char
          case ev.char
          when ' '
            @enum_pending_index = @enum_focus
            commit_enum_edit
            true
          else
            false
          end
        else
          false
        end
      end

      # Checkbox picker for @[Flags] enums.  ↑/↓ moves the focused member,
      # Space toggles its membership in the pending set, Enter commits the
      # bitwise OR, Esc cancels.
      private def handle_flags_edit_key(ev : KeyEvent) : Bool
        info = current_enum_info
        return false if info.nil?
        case ev.key
        when Key::Esc
          cancel_flags_edit
          true
        when Key::Enter
          commit_flags_edit
          true
        when Key::Up
          @enum_focus = (@enum_focus - 1).clamp(0, info.members.size - 1)
          true
        when Key::Down
          @enum_focus = (@enum_focus + 1).clamp(0, info.members.size - 1)
          true
        when Key::Char
          case ev.char
          when ' '
            if @flags_pending.includes?(@enum_focus)
              @flags_pending.delete(@enum_focus)
            else
              @flags_pending << @enum_focus
            end
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
          true # consumed — app will not pop the stack
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
          fk = col ? fk_for_col(col.name) : nil
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
          fk = col ? fk_for_col(col.name) : nil
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
        if info = @enum_columns[col.name]?
          if info.is_flags
            @flags_pending = decode_flags_indices(@row[col.name]?, info)
            @enum_focus = 0
            @flags_editing = true
          else
            @enum_pending_index = decode_enum_index(@row[col.name]?, info,
              @portable_types[col.name]?)
            @enum_focus = @enum_pending_index
            @enum_editing = true
          end
        elsif ColumnTypes.bool?(@portable_types[col.name]?, col.type_text)
          @bool_pending = ColumnTypes.bool_truthy?(@row[col.name]?)
          @bool_editing = true
        else
          val = @row[col.name]?
          raw = val || ""
          @edit_lines = raw.split('\n')
          @edit_lines << "" if @edit_lines.empty?
          @edit_row = @edit_lines.size - 1
          @edit_col = @edit_lines[@edit_row].size
          @editing = true
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
        validate_edit(col, value)
        @editing = false
        @edit_lines.clear
        @edit_row = 0
        @edit_col = 0
      end

      # Run portable-type-driven validation on the just-committed value and
      # record an inline error if it fails. Empty values are never flagged —
      # nullability is the column-level constraint that handles those.
      private def validate_edit(col : Adapter::LiveColumn, value : String) : Nil
        pt = @portable_types[col.name]?
        if value.strip.empty?
          @field_errors.delete(col.name)
          return
        end
        if ColumnTypes.time?(pt, col.type_text)
          set_error(col, Validation.valid_time?(value),
            "invalid time — expected YYYY-MM-DD HH:MM:SS")
        elsif ColumnTypes.int?(pt, col.type_text)
          set_error(col, Validation.valid_int?(value), "invalid integer")
        elsif ColumnTypes.float?(pt, col.type_text)
          set_error(col, Validation.valid_float?(value), "invalid number")
        elsif ColumnTypes.decimal?(pt, col.type_text)
          set_error(col, Validation.valid_decimal?(value), "invalid decimal")
        else
          @field_errors.delete(col.name)
        end
      end

      private def set_error(col : Adapter::LiveColumn, ok : Bool, msg : String) : Nil
        if ok
          @field_errors.delete(col.name)
        else
          @field_errors[col.name] = msg
        end
      end

      private def commit_bool_edit : Nil
        col = current_col
        return unless col
        @row[col.name] = @bool_pending ? "true" : "false"
        @dirty << col.name
        @bool_editing = false
      end

      private def commit_enum_edit : Nil
        col = current_col
        return unless col
        info = @enum_columns[col.name]?
        return unless info
        member = info.members[@enum_pending_index]?
        return unless member
        pt = @portable_types[col.name]?
        # For enum_string columns the storage value is the wire form
        # (ADR-0017) — the picker displays member.name to the user but
        # writes member.wire_name to the row so reads/writes round-trip
        # under custom `naming:` algorithms.
        @row[col.name] = (pt == "enum_int") ? member.value.to_s : member.wire_name
        @dirty << col.name
        @field_errors.delete(col.name)
        @enum_editing = false
      end

      private def cancel_enum_edit : Nil
        @enum_editing = false
      end

      private def commit_flags_edit : Nil
        col = current_col
        return unless col
        info = @enum_columns[col.name]?
        return unless info
        composed = 0_i64
        @flags_pending.each do |i|
          member = info.members[i]?
          composed |= member.value if member
        end
        @row[col.name] = composed.to_s
        @dirty << col.name
        @field_errors.delete(col.name)
        @flags_editing = false
      end

      private def cancel_flags_edit : Nil
        @flags_editing = false
      end

      private def current_enum_info : EnumColumn?
        col = current_col
        col ? @enum_columns[col.name]? : nil
      end

      # Find the member index that matches the stored raw value.
      # For `enum_string` we compare by member wire_name (the stored form
      # under ADR-0017's naming algorithms); for `enum_int` by the
      # underlying integer. Returns 0 on no match so the picker always lands
      # on a defined member rather than a phantom index.
      private def decode_enum_index(raw : String?, info : EnumColumn,
                                    portable_type : String?) : Int32
        return 0 if raw.nil?
        if portable_type == "enum_int"
          parsed = raw.to_i64?
          return 0 if parsed.nil?
          idx = info.members.index { |member| member.value == parsed }
          idx || 0
        else
          idx = info.members.index { |member| member.wire_name == raw }
          idx || 0
        end
      end

      # For a stored bitmask, return the indices of members whose underlying
      # value is fully contained in the mask (`(mask & m.value) == m.value`).
      # Zero-valued members (e.g. `None = 0`) are intentionally excluded —
      # they would otherwise match every mask and lead to confusing UI.
      private def decode_flags_indices(raw : String?, info : EnumColumn) : Set(Int32)
        result = Set(Int32).new
        return result if raw.nil?
        mask = raw.to_i64?
        return result if mask.nil?
        info.members.each_with_index do |member, index|
          next if member.value == 0
          result << index if (mask & member.value) == member.value
        end
        result
      end

      private def cancel_edit : Nil
        @editing = false
        @edit_lines.clear
        @edit_row = 0
        @edit_col = 0
      end

      private def insert_newline : Nil
        line = @edit_lines[@edit_row]
        left = line[0...@edit_col]
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
        c_end = c_start + field_row_count(col, @cursor) - 1
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
        elsif (@enum_editing || @flags_editing) && fi == @cursor
          info = @enum_columns[col.name]?
          info ? [info.members.size, 1].max : 1
        elsif @editing && fi == @cursor
          count = @edit_lines.each_with_index.sum do |text, li|
            soft_wrap(li == @edit_row ? text + "█" : text, vw).size
          end
          [count, 1].max
        else
          val = @row[col.name]?
          val.nil? ? 1 : [val.split('\n').sum { |ln| soft_wrap(ln, vw).size }, 1].max
        end
      end

      # Returns the display lines for a field (without label prefix).
      # Long logical lines are soft-wrapped; non-final segments end with Term.wrap_cont.
      private def field_lines(col : Adapter::LiveColumn, fi : Int32) : Array(String)
        if @bool_editing && fi == @cursor
          bool_picker_lines
        elsif @enum_editing && fi == @cursor
          enum_picker_lines(col, radio: true)
        elsif @flags_editing && fi == @cursor
          enum_picker_lines(col, radio: false)
        elsif @editing && fi == @cursor
          editor_lines
        else
          display_lines(col)
        end
      end

      private def bool_picker_lines : Array(String)
        yes_part = @bool_pending ? "◉ yes" : "○ yes"
        no_part = @bool_pending ? "○ no" : "◉ no"
        ["#{yes_part}   #{no_part}"]
      end

      # Render the vertical picker for either the enum radio (`radio: true`)
      # or the flags checkbox (`radio: false`). Both share layout — the only
      # difference is the marker glyph and which set drives the highlight.
      #
      # For enum_string columns we label each row with the wire_name (what
      # actually hits storage under ADR-0017). For enum_int and @[Flags]
      # the wire form is an integer that wouldn't be human-readable, so we
      # fall back to the source-level member name.
      private def enum_picker_lines(col : Adapter::LiveColumn, radio : Bool) : Array(String)
        info = @enum_columns[col.name]?
        return [Term.dim("(no members)")] if info.nil? || info.members.empty?
        use_wire = (@portable_types[col.name]? == "enum_string")
        info.members.map_with_index do |member, index|
          pointer = (index == @enum_focus) ? "▸" : " "
          marker = if radio
                     (index == @enum_pending_index) ? "◉" : "○"
                   else
                     @flags_pending.includes?(index) ? "[x]" : "[ ]"
                   end
          label = use_wire ? member.wire_name : member.name
          "#{pointer} #{marker} #{label}"
        end
      end

      private def editor_lines : Array(String)
        vw = compute_val_w
        result = [] of String
        @edit_lines.each_with_index do |text, li|
          full = if li == @edit_row
                   left = text[0...@edit_col]
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
      end

      private def display_lines(col : Adapter::LiveColumn) : Array(String)
        val = @row[col.name]?
        return [Term.dim("(null)")] if val.nil?
        vw = compute_val_w
        pt = @portable_types[col.name]?
        has_error = @field_errors.has_key?(col.name)
        display = format_value(col, pt, val)
        result = [] of String
        display.split('\n').each do |ln|
          segs = soft_wrap(ln, vw)
          segs.each_with_index do |seg, si|
            colored = has_error ? Style.error(seg) : Style.value(pt, col.type_text, seg)
            result << (si < segs.size - 1 ? colored + Style.wrap_cont : colored)
          end
        end
        result
      end

      # Translate the raw stored string into the user-facing display form.
      # Most columns pass through as-is; the cases we sweeten:
      #   - bool   →  "yes" / "no"
      #   - enum_int (plain)  →  member name (raw int is unreadable)
      #   - enum_int (@[Flags]) →  "Read | Write" decomposition
      # The chosen forms are *display only*; storage and edit start values
      # always remain the raw stringified int / member name.
      private def format_value(col : Adapter::LiveColumn, pt : String?, val : String) : String
        return ColumnTypes.bool_display(val) if ColumnTypes.bool?(pt, col.type_text)
        info = @enum_columns[col.name]?
        return val if info.nil?
        if info.is_flags
          mask = val.to_i64?
          return val if mask.nil?
          names = info.members.compact_map do |member|
            next nil if member.value == 0
            ((mask & member.value) == member.value) ? member.name : nil
          end
          names.empty? ? val : names.join(" | ")
        elsif pt == "enum_int"
          parsed = val.to_i64?
          return val if parsed.nil?
          match = info.members.find { |member| member.value == parsed }
          match ? match.name : val
        else
          val
        end
      end

      # Context-aware hint surfaced in the App's global status bar.  All key
      # bindings reachable from the current state are listed here so the user
      # doesn't have to look in two places.
      def status_hint : String
        picker_hint = picker_status_hint
        return picker_hint if picker_hint
        cur_col = current_col
        cur_fk = cur_col.try { |col| fk_for_col(col.name) }
        if @editing
          editor_status_hint(cur_fk)
        else
          nav_status_hint(cur_col, cur_fk)
        end
      end

      private def picker_status_hint : String?
        if @bool_editing
          " ←→/Space:toggle  Enter/Esc:done"
        elsif @enum_editing
          " ↑↓:choose  Enter/Space:select  Esc:cancel"
        elsif @flags_editing
          " ↑↓:move  Space:toggle  Enter:done  Esc:cancel"
        end
      end

      private def editor_status_hint(cur_fk : Adapter::LiveForeignKey?) : String
        tab_part = (cur_fk && cur_fk.columns.size == 1) ? "  Tab:browse-fk" : ""
        " ↑↓←→:cursor  Enter:newline#{tab_part}  Esc:done"
      end

      private def nav_status_hint(cur_col : Adapter::LiveColumn?,
                                  cur_fk : Adapter::LiveForeignKey?) : String
        err = cur_col.try { |col| @field_errors[col.name]? }
        return " ✕ #{err}" if err
        rm_part = (cur_col && cur_col.nullable && !(cur_col.primary && !@is_new)) ? "  r:remove" : ""
        fk_tab = (cur_fk && cur_fk.columns.size == 1) ? "  Tab:browse-fk" : ""
        if @is_new
          " ↑↓:field  e:edit#{rm_part}#{fk_tab}  s:insert  Esc:back"
        else
          fk_follow = cur_fk ? "  f:follow-fk" : ""
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
        @schema.foreign_keys.find(&.columns.includes?(col_name))
      end

      private def pk_display : String
        pk = @pk_col
        return "?" unless pk
        "#{pk}=#{@row[pk]? || "?"}"
      end

      private def compute_val_w : Int32
        inner_w = width - 2
        max_name = @schema.columns.max_of?(&.name.size) || 8
        label_w = [max_name + 4, inner_w // 3].min
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
