require "tui"
require "./column_types"
require "./style"
require "./browser"
require "./widgets/table_list"
require "./widgets/record_grid"
require "./widgets/record_detail"

module Prostore
  module TUI
    # Picker(W) needs a single Widget with both #handle_key(ev) and
    # #selected_value — Window already provides the former (delegating to
    # its Scrollable content) but knows nothing about Pickable, so this
    # thin wrapper adds the latter for the one RecordGrid instance the FK
    # picker flow needs it on.
    private class PickerWindow < ::TUI::Window
      include ::TUI::Pickable

      def initialize(x : Int32, y : Int32, width : Int32, height : Int32, @grid : RecordGrid)
        super(x, y, width, height, @grid.as(::TUI::Scrollable))
      end

      def selected_value : String?
        @grid.selected_value
      end
    end

    class App
      TABLE_LIST_WIDTH = 44

      @quit_menu : ::TUI::KeyMenu
      @sidebar_menu : ::TUI::KeyMenu
      @fk_picker : ::TUI::Picker(PickerWindow)?
      @sidebar_width : Int32 = TABLE_LIST_WIDTH

      def self.run(conn : Connection) : Nil
        new(conn).run
      end

      def initialize(@conn : Connection)
        @browser = Browser.new(@conn)
        @screen = ::TUI::Screen.new

        rows = @screen.rows
        cols = @screen.cols

        @table_list = TableList.new(@browser)
        @record_grid = RecordGrid.new(@browser)
        @split = ::TUI::SplitWindow.new(1, 1, cols, rows - 1,
          @table_list.as(::TUI::Scrollable), @record_grid.as(::TUI::Scrollable), left_width: TABLE_LIST_WIDTH)

        @nav = ::TUI::NavStack(::TUI::Widget).new(@split.as(::TUI::Widget))
        @runtime = ::TUI::Runtime.new(@screen, @nav, ->(ev : ::TUI::KeyEvent) { handle_key(ev) })
        @quit_menu = build_quit_menu
        @sidebar_menu = build_sidebar_menu
        refresh_sidebar_hint

        wire_table_list
        wire_record_grid
        @table_list.reload
      end

      def run : Nil
        @runtime.run
      end

      private def build_quit_menu : ::TUI::KeyMenu
        menu = ::TUI::KeyMenu.new
        menu.bind('q', "q:quit", when: -> { !in_detail? }) { exit(0) }
        menu
      end

      # Kept separate from #build_quit_menu so its hint (pushed into
      # @split.extra_hint by #refresh_sidebar_hint) never has to be picked
      # apart from "q:quit" — RecordGrid/TableList each show their own
      # "q:quit" in their own #status_hint already, so #build_quit_menu's
      # hint is dispatch-only and is never rendered anywhere (nothing calls
      # @quit_menu.hint).
      private def build_sidebar_menu : ::TUI::KeyMenu
        menu = ::TUI::KeyMenu.new
        menu.bind('h', -> { @split.left_width == 0 ? "h:show sidebar" : "h:hide sidebar" },
          when: -> { !in_detail? }) { toggle_sidebar }
        # While the sidebar is hidden, Tab has nothing on the left to switch
        # into — SplitWindow's own Tab binding would just flip @active onto
        # an invisible 0-width pane. Intercepting it here ahead of @split
        # makes Tab double as "unhide" instead; once visible again, this
        # binding's `when` goes false and SplitWindow's normal switch-pane
        # Tab takes back over.
        menu.bind(::TUI::Key::Tab, "Tab:show sidebar",
          when: -> { !in_detail? && @split.left_width == 0 }) { show_sidebar }
        menu
      end

      # Collapses the table-list pane to width 0 (giving the grid the full
      # screen) or restores it — SplitWindow has no built-in "hidden pane"
      # concept, so this just drives left_width down to nothing rather than
      # removing the pane. Hiding while the table list is focused moves
      # focus to the grid first, since a 0-width pane can't usefully hold
      # keyboard focus (nothing to see, nowhere for Tab to click into).
      private def toggle_sidebar : Nil
        if @split.left_width > 0
          hide_sidebar
        else
          show_sidebar
        end
      end

      private def hide_sidebar : Nil
        @sidebar_width = @split.left_width
        @split.focus_right
        @split.left_width = 0
      end

      # Restores the remembered width and moves focus onto it — Tab-to-
      # unhide should land the user where they were headed (the sidebar),
      # not leave focus on the pane they were already on.
      private def show_sidebar : Nil
        @split.left_width = @sidebar_width
        @split.focus_left
      end

      # SplitWindow renders its own #status_hint fresh every frame, but it
      # only knows about its own Tab binding — the sidebar hide/show hint
      # lives in @sidebar_menu instead (see #build_sidebar_menu), so it has
      # to be pushed into @split.extra_hint explicitly. Called once up
      # front (for the very first frame) and again after every #handle_key
      # (see below), since @sidebar_menu's `when:` guards — and thus what
      # the hint should say — can change from things #handle_key triggers
      # (toggling the sidebar, entering/leaving detail view via Esc/Enter).
      private def refresh_sidebar_hint : Nil
        @split.extra_hint = @sidebar_menu.hint.strip
      end

      # True while a RecordDetail (existing or new-record) or the FK picker is
      # the active screen — 'q' must not quit out from under an in-progress
      # edit or a modal pick.
      private def in_detail? : Bool
        @nav.current.is_a?(RecordDetail) || !@fk_picker.nil?
      end

      private def handle_key(ev : ::TUI::KeyEvent) : Nil
        if picker = @fk_picker
          # Picker itself never pops the nav stack (it has no Runtime
          # reference) — on_pick/on_cancel (below) do that explicitly once
          # they've resolved the pick.
          picker.handle_key(ev)
          return
        end

        current = @nav.current

        if ev.key == ::TUI::Key::Esc
          @runtime.handle_esc(current.handle_key(ev)) { @split.focus_left }
          refresh_sidebar_hint
          return
        end

        consumed = @quit_menu.dispatch(ev) || @sidebar_menu.dispatch(ev)
        current.handle_key(ev) unless consumed
        refresh_sidebar_hint
      end

      private def wire_table_list : Nil
        @table_list.on_activate = ->(_index : Int32) {
          t = @table_list.selected_table
          @record_grid.load_table(t) if t && @record_grid.table != t
          nil
        }
      end

      private def wire_record_grid : Nil
        @record_grid.on_open_detail = ->(t : String, pk_val : String) {
          pk = @browser.pk_col(t)
          push_detail(t, pk, pk_val) if pk
          nil
        }

        @record_grid.on_new_row = ->(t : String) {
          push_new_record(t)
          nil
        }
      end

      private def push_detail(table : String, pk_col : String, pk_val : String) : Nil
        detail = RecordDetail.new(1, 1, 1, 1, @browser, table, pk_col, pk_val)
        wire_detail(detail)
        @runtime.push(detail.as(::TUI::Widget))
      end

      private def push_new_record(table : String) : Nil
        detail = RecordDetail.for_new_record(1, 1, 1, 1, @browser, table)
        wire_detail(detail)
        @runtime.push(detail.as(::TUI::Widget))
      end

      private def wire_detail(detail : RecordDetail) : Nil
        # Called after a successful insert or delete — pop and refresh the grid.
        detail.on_close = -> {
          @runtime.pop
          @record_grid.reload
          nil
        }

        # Follow an FK: push a new detail onto the stack without closing this one.
        detail.on_follow_fk = ->(ref_table : String, ref_val : String) {
          ref_pk = @browser.pk_col(ref_table)
          push_detail(ref_table, ref_pk, ref_val) if ref_pk
          nil
        }

        # Browse an FK table to pick a value; writes it back into this
        # detail's row and restores the detail (still on the nav stack,
        # untouched) once the picker resolves.
        detail.on_pick_fk = ->(fk_table : String, col_name : String) {
          push_fk_picker(fk_table, col_name, detail)
          nil
        }
      end

      private def push_fk_picker(fk_table : String, col_name : String, source : RecordDetail) : Nil
        picker_grid = RecordGrid.new(@browser)
        picker_grid.load_table(fk_table)
        picker_grid.focused = true
        picker_window = PickerWindow.new(1, 1, @screen.cols, @screen.rows - 1, picker_grid)
        @runtime.push(picker_window.as(::TUI::Widget))
        @fk_picker = ::TUI::Picker(PickerWindow).new(
          picker_window,
          ->(pk : String) {
            source.set_row_value(col_name, pk)
            @fk_picker = nil
            @runtime.pop
            nil
          },
          -> {
            @fk_picker = nil
            @runtime.pop
            nil
          },
          suppress: ['n', 'd'],
        )
      end
    end
  end
end
