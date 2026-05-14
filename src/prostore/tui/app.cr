require "./term"
require "./keys"
require "./screen"
require "./widget"
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

    private alias NavEntry = NavTableList | NavRecordGrid | NavRecordDetail | NavNewRecord

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
        else
          @record_detail = nil
        end
      end

      private def render : Nil
        case current
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
        hint = case current
               when NavTableList
                 " ↑↓:table  Enter:open  q:quit"
               when NavRecordGrid
                 " ESC:back  ↑↓:row  ←→:cols  Enter:detail  PgUp/Dn:page  n:new  d:delete  q:quit"
               when NavRecordDetail, NavNewRecord
                 " ESC:back  ↑↓:field  e:edit  s:save  d:delete"
               else
                 ""
               end
        @screen.status_bar(@screen.rows - 1, hint)
      end

      private def handle_key(ev : KeyEvent) : Nil
        in_detail = current.is_a?(NavRecordDetail) || current.is_a?(NavNewRecord)

        if ev.key == Key::CtrlC || (ev.key == Key::Char && ev.char == 'q' && !in_detail)
          @running = false
          return
        end

        case current
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
            pop
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
      end
    end
  end
end
