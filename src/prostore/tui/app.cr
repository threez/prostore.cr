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
    class App
      TABLE_LIST_WIDTH = 22

      def self.run(conn : Connection) : Nil
        new(conn).run
      end

      def initialize(@conn : Connection)
        @browser  = Browser.new(@conn)
        @screen   = Screen.new
        @running  = true
        @focus    = 0  # 0 = table list, 1 = record grid
        @overlay  = nil.as(RecordDetail?)

        rows = @screen.rows
        cols = @screen.cols
        grid_w = cols - TABLE_LIST_WIDTH

        @table_list  = TableList.new(1, 1, TABLE_LIST_WIDTH, rows - 2, @browser)
        @record_grid = RecordGrid.new(TABLE_LIST_WIDTH + 1, 1, grid_w, rows - 2, @browser)

        wire_callbacks
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

      private def render : Nil
        if ov = @overlay
          ov.render(@screen)
        else
          @table_list.render(@screen)
          render_divider
          @record_grid.render(@screen)
        end
        render_status_bar
        @screen.flush
      end

      private def render_divider : Nil
        rows = @screen.rows
        # Vertical line between the two panes
        (2..rows - 3).each do |r|
          @screen.at(r, TABLE_LIST_WIDTH + 1, Term::VL)
        end
      end

      private def render_status_bar : Nil
        hint = if @overlay
                 " ESC:back  ↑↓:field  e:edit  f:follow-fk  s:save  d:delete"
               elsif @focus == 0
                 " Tab:→grid  ↑↓:table  q:quit"
               else
                 " Tab:←tables  ↑↓:row  Enter:detail  PgUp/Dn:page  n:new  d:delete  q:quit"
               end
        @screen.status_bar(@screen.rows - 1, hint)
      end

      private def handle_key(ev : KeyEvent) : Nil
        # Global quit
        if ev.key == Key::CtrlC || (ev.key == Key::Char && ev.char == 'q' && @overlay.nil?)
          @running = false
          return
        end

        if ov = @overlay
          ov.handle_key(ev)
          return
        end

        # Tab switches focus
        if ev.key == Key::Tab || ev.key == Key::ShiftTab
          @focus = (@focus + 1) % 2
          @table_list.focused  = (@focus == 0)
          @record_grid.focused = (@focus == 1)
          return
        end

        if @focus == 0
          @table_list.handle_key(ev)
        else
          @record_grid.handle_key(ev)
        end
      end

      private def wire_callbacks : Nil
        @table_list.on_select = ->(t : String) {
          @record_grid.load_table(t)
          nil
        }

        @record_grid.on_open_detail = ->(t : String, pk_val : String) {
          pk = @browser.pk_col(t)
          return nil unless pk
          open_detail(t, pk, pk_val)
          nil
        }

        @record_grid.on_new_row = ->(t : String) {
          open_new_record(t)
          nil
        }
      end

      private def open_detail(table : String, pk_col : String, pk_val : String) : Nil
        rows = @screen.rows
        cols = @screen.cols
        ov = RecordDetail.new(1, 1, cols, rows - 2, @browser, table, pk_col, pk_val)
        wire_detail(ov, table)
        @overlay = ov
      end

      private def open_new_record(table : String) : Nil
        rows = @screen.rows
        cols = @screen.cols
        ov = RecordDetail.for_new_record(1, 1, cols, rows - 2, @browser, table)
        wire_detail(ov, table)
        @overlay = ov
      end

      private def wire_detail(ov : RecordDetail, table : String) : Nil
        ov.on_close = -> {
          @overlay = nil
          @record_grid.reload
          nil
        }

        ov.on_follow_fk = ->(ref_table : String, ref_val : String) {
          @overlay = nil
          @table_list.reload
          ref_pk = @browser.pk_col(ref_table)
          if ref_pk
            @record_grid.load_table(ref_table)
            open_detail(ref_table, ref_pk, ref_val)
          end
          nil
        }
      end
    end
  end
end
