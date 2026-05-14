require "./term"
require "./keys"
require "./screen"
require "./widget"
require "./column_types"
require "./style"
require "./validation"
require "./browser"
require "./widgets/table_list"
require "./widgets/record_grid"
require "./widgets/record_detail"

module Prostore
  module TUI
    # Each entry on the navigation stack captures enough data to rebuild the
    # view when popping back to it.
    private record NavTableList
    private record NavRecordGrid, table : String
    private record NavRecordDetail, table : String, pk_col : String, pk_val : String
    private record NavNewRecord, table : String
    # Holds a reference to the source detail widget so it can be restored without
    # rebuilding from DB when the picker is dismissed.
    private record NavFKPicker, fk_table : String, col_name : String, detail : RecordDetail

    private alias NavEntry = NavTableList | NavRecordGrid | NavRecordDetail | NavNewRecord | NavFKPicker

    class App
      TABLE_LIST_WIDTH = 44

      def self.run(conn : Connection) : Nil
        new(conn).run
      end

      def initialize(@conn : Connection)
        @browser = Browser.new(@conn)
        @screen  = Screen.new
        @running = true
        @stack   = [NavTableList.new] of NavEntry

        rows   = @screen.rows
        cols   = @screen.cols
        grid_w = cols - TABLE_LIST_WIDTH

        @table_list    = TableList.new(1, 1, TABLE_LIST_WIDTH, rows - 2, @browser)
        @record_grid   = RecordGrid.new(TABLE_LIST_WIDTH + 1, 1, grid_w, rows - 2, @browser)
        @fk_picker     = RecordGrid.new(1, 1, cols, rows - 2, @browser)
        @record_detail = nil.as(RecordDetail?)

        wire_table_list
        wire_record_grid
        @table_list.focused = true
        @table_list.reload
      end

      def run : Nil
        Term.enter_raw
        begin
          while @running
            render
            ev = Keys.read(STDIN)
            handle_key(ev)
          end
        ensure
          print Term.show_cursor
          print Term.clear
          STDOUT.flush
          Term.exit_raw
        end
      end

      private def current : NavEntry
        @stack.last
      end

      private def push(entry : NavEntry) : Nil
        @stack << entry
        sync_detail
      end

      # Pop one entry. After popping, rebuild the detail widget if the new top
      # is itself a detail entry (so Esc through a chain of FK-follows works).
      private def pop(reload_grid : Bool = false) : Nil
        @stack.pop if @stack.size > 1
        @record_grid.reload if reload_grid
        sync_detail
      end

      private def sync_detail : Nil
        case nav = current
        when NavRecordDetail
          @record_detail = build_detail(nav.table, nav.pk_col, nav.pk_val)
        when NavNewRecord
          @record_detail = build_new_record(nav.table)
        when NavFKPicker
          # Managed by push_fk_picker / pop_fk_picker — do not rebuild detail.
          @record_detail = nil
        else
          @record_detail = nil
        end
      end

      private def render : Nil
        case current
        when NavFKPicker
          @fk_picker.render(@screen)
        when NavRecordDetail, NavNewRecord
          @record_detail.try &.render(@screen)
        else
          @table_list.focused  = current.is_a?(NavTableList)
          @record_grid.focused = current.is_a?(NavRecordGrid)
          @table_list.render(@screen)
          render_divider
          @record_grid.render(@screen)
        end
        render_status_bar
        @screen.flush
      end

      private def render_divider : Nil
        (2..@screen.rows - 3).each do |r|
          @screen.at(r, TABLE_LIST_WIDTH + 1, Term::VL)
        end
      end

      private def render_status_bar : Nil
        # Delegate to the focused widget — it knows its current state best.
        # NavFKPicker is kept inline since the picker is a RecordGrid in a
        # read-only role and its own `status_hint` would describe the
        # mutation-friendly nav-mode bindings.
        hint = case current
               when NavTableList                   then @table_list.status_hint
               when NavRecordGrid                  then @record_grid.status_hint
               when NavRecordDetail, NavNewRecord  then @record_detail.try(&.status_hint) || ""
               when NavFKPicker
                 " ESC:cancel  ↑↓:row  ←→:cols  Enter:select  PgUp/Dn:page"
               else
                 ""
               end
        @screen.status_bar(@screen.rows - 1, hint)
      end

      private def handle_key(ev : KeyEvent) : Nil
        in_detail = current.is_a?(NavRecordDetail) || current.is_a?(NavNewRecord) || current.is_a?(NavFKPicker)

        if ev.key == Key::CtrlC || (ev.key == Key::Char && ev.char == 'q' && !in_detail)
          @running = false
          return
        end

        case current
        when NavFKPicker
          if ev.key == Key::Esc
            pop_fk_picker(nil)
          elsif ev.key == Key::Enter
            pop_fk_picker(@fk_picker.selected_pk)
          elsif ev.key == Key::Char && (ev.char == 'd' || ev.char == 'n')
            nil  # read-only picker — suppress mutations
          else
            @fk_picker.handle_key(ev)
          end
        when NavTableList
          if ev.key == Key::Enter
            table = @table_list.selected_table
            if table
              @record_grid.load_table(table) if @record_grid.table != table
              push NavRecordGrid.new(table)
            end
          else
            @table_list.handle_key(ev)
          end
        when NavRecordGrid
          if ev.key == Key::Esc
            # Delegate first — the grid consumes Esc while its search input
            # is open so we don't accidentally pop back to the table list.
            consumed = @record_grid.handle_key(ev)
            pop unless consumed
          else
            @record_grid.handle_key(ev)
          end
        when NavRecordDetail, NavNewRecord
          if ev.key == Key::Esc
            # Delegate to detail first — if it's in edit mode, Esc cancels the
            # edit and the detail stays open. Only pop when not editing.
            consumed = @record_detail.try &.handle_key(ev)
            pop unless consumed
          else
            @record_detail.try &.handle_key(ev)
          end
        end
      end

      # Push the FK picker without going through sync_detail so the source
      # detail widget's unsaved edits are preserved.
      private def push_fk_picker(fk_table : String, col_name : String, source : RecordDetail) : Nil
        @fk_picker.load_table(fk_table)
        @fk_picker.focused = true
        @stack << NavFKPicker.new(fk_table, col_name, source)
        @record_detail = nil
      end

      # Pop the FK picker and restore the source detail widget.  If a PK value
      # was selected, write it directly into the source row before restoring.
      private def pop_fk_picker(selected_pk : String?) : Nil
        nav = current
        return unless nav.is_a?(NavFKPicker)
        @stack.pop if @stack.size > 1
        if pk = selected_pk
          nav.detail.set_row_value(nav.col_name, pk)
        end
        @record_detail = nav.detail
      end

      private def wire_table_list : Nil
        @table_list.on_select = ->(t : String) {
          @record_grid.load_table(t) if @record_grid.table != t
          nil
        }
      end

      private def wire_record_grid : Nil
        @record_grid.on_open_detail = ->(t : String, pk_val : String) {
          pk = @browser.pk_col(t)
          if pk
            push NavRecordDetail.new(t, pk, pk_val)
          end
          nil
        }

        @record_grid.on_new_row = ->(t : String) {
          push NavNewRecord.new(t)
          nil
        }
      end

      private def build_detail(table : String, pk_col : String, pk_val : String) : RecordDetail
        ov = RecordDetail.new(1, 1, @screen.cols, @screen.rows - 2,
                              @browser, table, pk_col, pk_val)
        wire_detail(ov)
        ov
      end

      private def build_new_record(table : String) : RecordDetail
        ov = RecordDetail.for_new_record(1, 1, @screen.cols, @screen.rows - 2,
                                          @browser, table)
        wire_detail(ov)
        ov
      end

      private def wire_detail(ov : RecordDetail) : Nil
        # Called after a successful insert or delete — pop and refresh the grid.
        ov.on_close = -> {
          pop(reload_grid: true)
          nil
        }

        # Follow an FK: push a new detail onto the stack without closing this one.
        ov.on_follow_fk = ->(ref_table : String, ref_val : String) {
          ref_pk = @browser.pk_col(ref_table)
          if ref_pk
            push NavRecordDetail.new(ref_table, ref_pk, ref_val)
          end
          nil
        }

        # Browse an FK table to pick a value; restores this detail on return.
        ov.on_pick_fk = ->(fk_table : String, col_name : String) {
          push_fk_picker(fk_table, col_name, ov)
          nil
        }
      end
    end
  end
end
