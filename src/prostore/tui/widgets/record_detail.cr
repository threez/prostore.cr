require "tui"
require "../browser"
require "../style"
require "../column_types"

module Prostore
  module TUI
    class RecordDetail < ::TUI::Widget
      property on_close : Proc(Nil)?
      property on_follow_fk : Proc(String, String, Nil)?
      property on_pick_fk : Proc(String, String, Nil)?

      # Column names mutated since the last load/reload — also useful to an
      # embedding app deciding whether to prompt before discarding an
      # in-progress edit, not just for spec assertions.
      getter dirty : Set(String)

      # Per-column inline validation error messages, keyed by column name.
      getter field_errors : Hash(String, String)

      # The current in-memory row (raw stringified values, pre-save).
      getter row : Hash(String, RowVal)

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
        @text_editor = nil.as(::TUI::ScrollableField(::TUI::TextEdit)?)
        @input_editor = nil.as(::TUI::InputField?)
        @bool_editor = nil.as(::TUI::BoolField?)
        @enum_editor = nil.as(::TUI::EnumField?)
        @enum_focus = 0                 # which member the cursor is highlighting (flags only)
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

      def render : Nil
        title = @is_new ? "New · #{@table}" : "#{@table} · #{pk_display}"
        @buffer.box(0, 0, height, width, title)

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
            local_row = 1 + start + li
            next if local_row < 1 || local_row >= height - 1

            dirty = @dirty.includes?(col.name)
            if li == 0
              pointer = if fi == @cursor
                          "▸"
                        elsif @field_errors.has_key?(col.name)
                          Style.error("!")
                        else
                          " "
                        end
              raw_label = ::TUI::Term.fit("#{pointer} #{col.name}", label_w)
              label = dirty ? ::TUI::Term.bold(raw_label) : raw_label
              pk_tag = col.primary ? ::TUI::Term.dim(" [pk]") : ""
              fk_hint = fk_for_col(col.name)
              fk_label = fk_hint ? Style.fk_ref("  → #{fk_hint.references_table}") : ""
            else
              label = " " * label_w
              pk_tag = ""
              fk_label = ""
            end

            val_display = ::TUI::Term.fit(line_content, val_w - ::TUI::Term.visible_size(pk_tag) - ::TUI::Term.visible_size(fk_label))
            line = "#{label} #{val_display}#{pk_tag}#{fk_label}"

            if fi == @cursor && !@text_editor && !@input_editor && !@bool_editor && !@enum_editor && !@flags_editing
              # Strip inner ANSI before applying reverse — otherwise the first
              # `\e[0m` from a colour segment cancels the reverse video mid-row.
              plain = ::TUI::Term.fit(::TUI::Term.strip_ansi(line), inner_w)
              styled = dirty ? ::TUI::Term.bold(::TUI::Term.reverse(plain)) : ::TUI::Term.reverse(plain)
              @buffer.set(local_row, 1, styled)
            else
              @buffer.set(local_row, 1, ::TUI::Term.fit(line, inner_w))
            end
          end
        end
      end

      def handle_key(ev : ::TUI::KeyEvent) : Bool
        if @bool_editor
          handle_bool_edit_key(ev)
        elsif @enum_editor
          handle_enum_edit_key(ev)
        elsif @flags_editing
          handle_flags_edit_key(ev)
        elsif @text_editor
          handle_text_edit_key(ev)
        elsif @input_editor
          handle_input_edit_key(ev)
        else
          handle_nav_key(ev)
        end
      end

      # ---------------------------------------------------------------- private

      # BoolField has no Up/Down-moves-to-next-field gesture of its own
      # (only Left/Right/Space toggle, Esc/Enter commit) — Up/Down here
      # mirror the surrounding nav keys' "commit then move" behavior that
      # existed before this delegated to BoolField.
      private def handle_bool_edit_key(ev : ::TUI::KeyEvent) : Bool
        editor = @bool_editor
        return false unless editor
        case ev.key
        when ::TUI::Key::Up
          commit_bool_edit
          move_cursor(-1)
          true
        when ::TUI::Key::Down
          commit_bool_edit
          move_cursor(1)
          true
        else
          result = editor.handle_key(ev)
          commit_bool_edit if result == :commit
          true
        end
      end

      # Radio picker for plain (non-flags) enums, delegated to
      # ::TUI::EnumField — ↑/↓ moves the focused member, Space/Enter
      # selects it and commits, Esc cancels without writing back
      # (EnumField's own semantics, unchanged from the bespoke version).
      private def handle_enum_edit_key(ev : ::TUI::KeyEvent) : Bool
        editor = @enum_editor
        return false unless editor
        result = editor.handle_key(ev)
        case result
        when :commit
          commit_enum_edit
        when :cancel
          cancel_enum_edit
        end
        true
      end

      # Checkbox picker for @[Flags] enums.  ↑/↓ moves the focused member,
      # Space toggles its membership in the pending set, Enter commits the
      # bitwise OR, Esc cancels.
      private def handle_flags_edit_key(ev : ::TUI::KeyEvent) : Bool
        info = current_enum_info
        return false if info.nil?
        case ev.key
        when ::TUI::Key::Esc
          cancel_flags_edit
          true
        when ::TUI::Key::Enter
          commit_flags_edit
          true
        when ::TUI::Key::Up
          @enum_focus = (@enum_focus - 1).clamp(0, info.members.size - 1)
          true
        when ::TUI::Key::Down
          @enum_focus = (@enum_focus + 1).clamp(0, info.members.size - 1)
          true
        when ::TUI::Key::Char
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

      # TUI::TextEdit's own Up/Down move the cursor within the buffer (no
      # commit-and-move-field gesture, unlike the old bespoke editor) —
      # Esc commits and returns to nav mode; from there Up/Down move
      # fields as usual. No Tab/FK hand-off here: #start_edit routes
      # single-column FK fields straight to the picker, so a TextEdit is
      # never open on one.
      private def handle_text_edit_key(ev : ::TUI::KeyEvent) : Bool
        editor = @text_editor
        return false unless editor
        result = editor.handle_key(ev)
        commit_edit if result == :commit
        true
      end

      # Single-line InputField used by numeric columns. Same no-FK
      # rationale as #handle_text_edit_key above.
      private def handle_input_edit_key(ev : ::TUI::KeyEvent) : Bool
        editor = @input_editor
        return false unless editor
        result = editor.handle_key(ev)
        commit_input_edit if result == :commit
        true
      end

      private def handle_nav_key(ev : ::TUI::KeyEvent) : Bool
        case ev.key
        when ::TUI::Key::Up
          move_cursor(-1)
          true
        when ::TUI::Key::Down
          move_cursor(1)
          true
        when ::TUI::Key::Tab
          col = current_col
          fk = col ? fk_for_col(col.name) : nil
          if fk && col && fk.columns.size == 1
            @on_pick_fk.try &.call(fk.references_table, col.name)
            true
          else
            false
          end
        when ::TUI::Key::Char
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
        fk = fk_for_col(col.name)
        if fk && fk.columns.size == 1
          # A single-column FK is better edited by picking a row from the
          # referenced table than by typing its raw PK — hand off to the
          # same picker Tab already opens, rather than opening a local
          # editor for the underlying int/string column.
          @on_pick_fk.try &.call(fk.references_table, col.name)
        elsif info = @enum_columns[col.name]?
          if info.is_flags
            @flags_pending = decode_flags_indices(@row[col.name]?, info)
            @enum_focus = 0
            @flags_editing = true
          else
            use_wire = (@portable_types[col.name]? == "enum_string")
            options = info.members.map { |member|
              ::TUI::FormEnumOption.new(
                label: use_wire ? member.wire_name : member.name,
                wire_value: enum_wire_value(member, @portable_types[col.name]?))
            }
            editor = ::TUI::EnumField.new(options)
            editor.start(@row[col.name]? || "")
            @enum_editor = editor
          end
        elsif ColumnTypes.bool?(@portable_types[col.name]?, col.type_text)
          editor = ::TUI::BoolField.new
          editor.start(ColumnTypes.bool_truthy?(@row[col.name]?) ? "true" : "false")
          @bool_editor = editor
        elsif ColumnTypes.numeric?(@portable_types[col.name]?, col.type_text)
          editor = ::TUI::InputField.new
          editor.start(@row[col.name]? || "")
          @input_editor = editor
        else
          editor = ::TUI::ScrollableField(::TUI::TextEdit).new(->(v : String) { ::TUI::TextEdit.new(v) })
          editor.start(@row[col.name]? || "")
          # TextEdit.new always starts the cursor at (0, 0) — move it to
          # the end of the buffer so typing/backspace continues where the
          # old bespoke editor (which started at the end) left off. Down
          # is a no-op past the last visual row, so this unconditionally
          # reaches the last line without knowing the line count up front.
          value = @row[col.name]? || ""
          value.count('\n').times { editor.handle_key(::TUI::KeyEvent.new(::TUI::Key::Down)) }
          editor.handle_key(::TUI::KeyEvent.new(::TUI::Key::End))
          @text_editor = editor
        end
      end

      private def commit_edit : Nil
        col = current_col
        editor = @text_editor
        return unless col && editor
        value = editor.value
        # An empty edit on a nullable column means NULL, not the literal
        # empty string — otherwise the column would be coerced to "" on save
        # and the display would lose the (null) marker.
        @row[col.name] = (value.empty? && col.nullable) ? nil : value
        @dirty << col.name
        validate_edit(col, value)
        @text_editor = nil
      end

      private def commit_input_edit : Nil
        col = current_col
        editor = @input_editor
        return unless col && editor
        value = editor.value
        # Same NULL-on-empty rule as #commit_edit.
        @row[col.name] = (value.empty? && col.nullable) ? nil : value
        @dirty << col.name
        validate_edit(col, value)
        @input_editor = nil
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
          set_error(col, ::TUI::Validation.valid_time?(value),
            "invalid time — expected YYYY-MM-DD HH:MM:SS")
        elsif ColumnTypes.int?(pt, col.type_text)
          set_error(col, ::TUI::Validation.valid_int?(value), "invalid integer")
        elsif ColumnTypes.float?(pt, col.type_text)
          set_error(col, ::TUI::Validation.valid_float?(value), "invalid number")
        elsif ColumnTypes.decimal?(pt, col.type_text)
          set_error(col, ::TUI::Validation.valid_decimal?(value), "invalid decimal")
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
        editor = @bool_editor
        return unless col && editor
        @row[col.name] = editor.value
        @dirty << col.name
        @bool_editor = nil
      end

      private def commit_enum_edit : Nil
        col = current_col
        editor = @enum_editor
        return unless col && editor
        # editor.value is the FormEnumOption's wire_value — already built
        # as the wire form (wire_name for enum_string, value.to_s for
        # enum_int; see #enum_wire_value/ADR-0017) as of #start_edit, so
        # it round-trips into @row directly with no further translation.
        @row[col.name] = editor.value
        @dirty << col.name
        @field_errors.delete(col.name)
        @enum_editor = nil
      end

      private def cancel_enum_edit : Nil
        @enum_editor = nil
      end

      # The wire form a picked enum member writes back into @row: for
      # enum_string columns this is the wire_name (ADR-0017, so reads/
      # writes round-trip under custom `naming:` algorithms); for
      # enum_int it's the underlying integer, stringified since
      # FormEnumOption#wire_value is always a String.
      private def enum_wire_value(member : Schema::EnumMember, portable_type : String?) : String
        portable_type == "enum_int" ? member.value.to_s : member.wire_name
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

      # Ceiling on how many display rows an open text editor may claim —
      # ScrollableField owns its own internal Scroller/scrollbar, so a
      # value longer than this just scrolls inside a fixed-height window
      # instead of growing the field indefinitely (unlike the old bespoke
      # editor, which sized itself to the full wrapped line count).
      TEXT_EDIT_MAX_ROWS = 8

      private def field_row_count(col : Adapter::LiveColumn, fi : Int32) : Int32
        vw = compute_val_w
        if (@bool_editor || @input_editor) && fi == @cursor
          1
        elsif (@enum_editor || @flags_editing) && fi == @cursor
          info = @enum_columns[col.name]?
          info ? [info.members.size, 1].max : 1
        elsif @text_editor && fi == @cursor
          text_edit_row_count(col, vw)
        else
          val = @row[col.name]?
          val.nil? ? 1 : [val.split('\n').sum { |ln| soft_wrap(ln, vw).size }, 1].max
        end
      end

      # Sized off the pre-edit value's own wrapped row count (clamped to
      # TEXT_EDIT_MAX_ROWS) rather than TextEdit's live content_size —
      # ScrollableField doesn't expose the wrapped TextEdit it owns, so
      # there's no live row count to query; this reserves a reasonable
      # window instead and lets ScrollableField's own scrollbar handle
      # whatever doesn't fit (including new lines typed after opening).
      private def text_edit_row_count(col : Adapter::LiveColumn, vw : Int32) : Int32
        val = @row[col.name]?
        raw_count = val.nil? ? 1 : [val.split('\n').sum { |ln| soft_wrap(ln, vw).size }, 1].max
        raw_count.clamp(1, TEXT_EDIT_MAX_ROWS)
      end

      # Returns the display lines for a field (without label prefix).
      # Long logical lines are soft-wrapped; non-final segments end with ::TUI::Term.wrap_cont.
      private def field_lines(col : Adapter::LiveColumn, fi : Int32) : Array(String)
        if (editor = @bool_editor) && fi == @cursor
          bool_picker_lines(editor)
        elsif (editor = @enum_editor) && fi == @cursor
          enum_field_lines(editor)
        elsif @flags_editing && fi == @cursor
          flags_picker_lines(col)
        elsif (editor = @text_editor) && fi == @cursor
          text_editor_lines(editor, col)
        elsif (editor = @input_editor) && fi == @cursor
          input_editor_lines(editor)
        else
          display_lines(col)
        end
      end

      # BoolField renders into a Buffer at an explicit (y, x), not as a
      # plain string — render into a scratch single-row Buffer here and
      # read the cells back out as a string, so this still fits
      # field_lines's uniform Array(String) contract shared by every other
      # edit kind's *_lines method.
      private def bool_picker_lines(editor : ::TUI::BoolField) : Array(String)
        scratch = ::TUI::Buffer.new(compute_val_w, 1)
        editor.render(scratch, 0, 0, scratch.width)
        line = String.build do |str|
          scratch.width.times { |col| str << scratch.cell(0, col).char }
        end
        [line.rstrip]
      end

      # InputField renders into a Buffer at an explicit (y, x) like
      # BoolField — same scratch-buffer technique as #bool_picker_lines.
      private def input_editor_lines(editor : ::TUI::InputField) : Array(String)
        scratch = ::TUI::Buffer.new(compute_val_w, 1)
        editor.render(scratch, 0, 0, scratch.width)
        line = String.build do |str|
          scratch.width.times { |col| str << scratch.cell(0, col).char }
        end
        [line.rstrip]
      end

      # EnumField renders into a Buffer at an explicit (y, x) like
      # BoolField, but multi-row (one option per row) — build a scratch
      # buffer tall enough for every option and read each row back out,
      # same technique as #bool_picker_lines just not single-row.
      private def enum_field_lines(editor : ::TUI::EnumField) : Array(String)
        info = current_enum_info
        return [::TUI::Term.dim("(no members)")] if info.nil? || info.members.empty?
        height = info.members.size
        scratch = ::TUI::Buffer.new(compute_val_w, height)
        editor.render(scratch, 0, 0, scratch.width, height)
        height.times.map do |row|
          String.build do |str|
            scratch.width.times { |sc| str << scratch.cell(row, sc).char }
          end.rstrip
        end.to_a
      end

      # Render the vertical checkbox picker for @[Flags] enums — kept
      # bespoke (see README) since TUI::FlagsField composes its bitmask
      # by array index rather than the member's actual declared value,
      # which would silently corrupt non-contiguous flag sets.
      #
      # For enum_int the wire form is an integer that wouldn't be
      # human-readable, so we fall back to the source-level member name.
      private def flags_picker_lines(col : Adapter::LiveColumn) : Array(String)
        info = @enum_columns[col.name]?
        return [::TUI::Term.dim("(no members)")] if info.nil? || info.members.empty?
        use_wire = (@portable_types[col.name]? == "enum_string")
        info.members.map_with_index do |member, index|
          pointer = (index == @enum_focus) ? "▸" : " "
          marker = @flags_pending.includes?(index) ? "[x]" : "[ ]"
          label = use_wire ? member.wire_name : member.name
          "#{pointer} #{marker} #{label}"
        end
      end

      # ScrollableField renders into a Buffer at an explicit (y, x) over
      # `height` rows (own cursor, scrollbar, and wrap-marker included),
      # same scratch-buffer technique as #bool_picker_lines/
      # #enum_field_lines — height comes from #text_edit_row_count so
      # this always renders exactly as many rows as field_row_count
      # reserved for this field.
      private def text_editor_lines(editor : ::TUI::ScrollableField(::TUI::TextEdit),
                                    col : Adapter::LiveColumn) : Array(String)
        height = text_edit_row_count(col, compute_val_w)
        scratch = ::TUI::Buffer.new(compute_val_w, height)
        editor.render(scratch, 0, 0, scratch.width, height)
        height.times.map do |row|
          String.build do |str|
            scratch.width.times { |sc| str << scratch.cell(row, sc).char }
          end.rstrip
        end.to_a
      end

      private def display_lines(col : Adapter::LiveColumn) : Array(String)
        val = @row[col.name]?
        return [::TUI::Term.dim("(null)")] if val.nil?
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
        if @text_editor
          editor_status_hint
        elsif @input_editor
          input_status_hint
        else
          nav_status_hint(cur_col, cur_fk)
        end
      end

      private def picker_status_hint : String?
        if @bool_editor
          " ←→/Space:toggle  Enter/Esc:done"
        elsif @enum_editor
          " ↑↓:choose  Enter/Space:select  Esc:cancel"
        elsif @flags_editing
          " ↑↓:move  Space:toggle  Enter:done  Esc:cancel"
        end
      end

      # No Tab:browse-fk hint here — #start_edit routes single-column FK
      # fields straight to the picker (see there), so a TextEdit is never
      # open on one.
      private def editor_status_hint : String
        " ↑↓←→:cursor  Enter:newline  Esc:commit"
      end

      # InputField commits on both Enter and Esc — no newline gesture,
      # unlike #editor_status_hint's multi-line TextEdit. Same no-FK
      # rationale as #editor_status_hint above.
      private def input_status_hint : String
        " ←→:cursor  Enter/Esc:commit"
      end

      private def nav_status_hint(cur_col : Adapter::LiveColumn?,
                                  cur_fk : Adapter::LiveForeignKey?) : String
        err = cur_col.try { |col| @field_errors[col.name]? }
        return " ✕ #{err}" if err
        rm_part = (cur_col && cur_col.nullable && !(cur_col.primary && !@is_new)) ? "  r:remove" : ""
        # e:edit already opens the FK picker directly on a single-column FK
        # (see #start_edit) — no separate Tab:browse-fk hint needed here.
        if @is_new
          " ↑↓:field  e:edit#{rm_part}  s:insert  Esc:back"
        else
          fk_follow = cur_fk ? "  f:follow-fk" : ""
          " ↑↓:field  e:edit#{rm_part}#{fk_follow}  s:save  d:delete  Esc:back"
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
