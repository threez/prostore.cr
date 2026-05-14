require "./term"

module Prostore
  module TUI
    class Screen
      getter rows : Int32
      getter cols : Int32
      getter buf : String::Builder

      def initialize
        size = Term.size
        @rows = size[:rows]
        @cols = size[:cols]
        @buf = String::Builder.new
      end

      def refresh_size : Nil
        size = Term.size
        @rows = size[:rows]
        @cols = size[:cols]
      end

      def write(s : String) : Nil
        @buf << s
      end

      def at(row : Int32, col : Int32, s : String) : Nil
        @buf << Term.move(row, col) << s
      end

      def flush : Nil
        print Term.hide_cursor
        print Term.clear
        print @buf.to_s
        print Term.show_cursor
        STDOUT.flush
        @buf = String::Builder.new
      end

      # Draw a box. title is placed in the top border.
      def box(y : Int32, x : Int32, h : Int32, w : Int32, title : String = "") : Nil
        # Top border
        inner_w = w - 2
        top_fill = if title.empty?
                     Term::HL * inner_w
                   else
                     t = " #{title} "
                     pad = [inner_w - visible_len(t), 0].max
                     t + Term::HL * pad
                   end
        at(y, x, "#{Term::TL}#{top_fill}#{Term::TR}")

        # Sides
        (1..h - 2).each do |dy|
          at(y + dy, x, Term::VL)
          at(y + dy, x + w - 1, Term::VL)
        end

        # Bottom border
        at(y + h - 1, x, "#{Term::BL}#{Term::HL * inner_w}#{Term::BR}")
      end

      # Draw a horizontal separator spanning full width at y, merging with
      # a vertical line at `split_col` if provided.
      def hline(y : Int32, x : Int32, w : Int32, left_join : Bool = false, right_join : Bool = false) : Nil
        left  = left_join  ? Term::LJ : Term::BL
        right = right_join ? Term::RJ : Term::BR
        at(y, x, "#{left}#{Term::HL * (w - 2)}#{right}")
      end

      # Status bar: fill entire row with reverse-video text.
      def status_bar(row : Int32, text : String) : Nil
        fitted = Term.fit(text, @cols)
        at(row, 1, Term.reverse(fitted))
      end

      private def visible_len(s : String) : Int32
        s.gsub(/\e\[[0-9;]*m/, "").chars.size
      end
    end
  end
end
