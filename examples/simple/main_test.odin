#+private
package main

// Unit tests for the simple example. See examples/spinner/main_test.odin's
// header for why an example carries tests at all, and why `#+private` on a
// `package main` file.

import "core:strings"
import "core:testing"
import rt "../../runetea"

// The same measurement render_inline makes -- see the identical helper in
// examples/spinner/main_test.odin for why it is rt.rows_for_line and not a
// count of '\n'.
@(private = "file")
frame_rows :: proc(v: string, w: int) -> int {
	lines := strings.split_lines(v, context.temp_allocator)
	if len(lines) > 1 && lines[len(lines) - 1] == "" { lines = lines[:len(lines) - 1] }
	rows := 0
	for line in lines { rows += rt.rows_for_line(line, w) }
	return rows
}

// THE CONSTANT THAT WAS OFF BY ONE, pinned to the renderer's own arithmetic
// rather than to a number.
//
// MIN_ROWS was 3 -- the number of lines view() paints -- and .Inline
// terminates every line it paints with "\r\n", the last one included, so a
// three-row frame occupies four terminal rows. Measured on a real pty at 60
// columns: at exactly three rows the greeting ("Hi. This program will exit on
// 'q'.") was painted, scrolled into scrollback, and never seen again, on a
// terminal the guard had just certified as big enough. r.last_rows clamps to
// term_height-1, so no later rewind can reach a row that has left the
// viewport: this is permanent for the session, not a one-frame flicker.
@(test)
test_the_simple_minimum_height_leaves_a_row_for_inlines_terminator :: proc(t: ^testing.T) {
	m := Model{term_h = 24}
	rows := frame_rows(view(m, context.temp_allocator), 100)
	testing.expectf(t, MIN_ROWS == rows + 1,
		"MIN_ROWS is %d for a %d-row frame; .Inline needs one more row than it paints, so it must be %d",
		MIN_ROWS, rows, rows + 1)
	free_all(context.temp_allocator)
}

// The property that makes the guard worth having: below the minimum the frame
// the terminal is asked to hold is ONE row, at every height the guard covers,
// so nothing it paints can be scrolled away. One row is the single height at
// which even that cannot be shown -- see docs/LIMITATIONS.md 3.20.
@(test)
test_every_height_below_the_simple_minimum_paints_exactly_one_row :: proc(t: ^testing.T) {
	for h in 1 ..< MIN_ROWS {
		m := Model{term_h = h}
		v := view(m, context.temp_allocator)
		testing.expectf(t, frame_rows(v, 100) == 1,
			"at %d rows the frame is %d rows; below MIN_ROWS it must be exactly one", h, frame_rows(v, 100))
		testing.expectf(t, strings.contains(v, "need"),
			"at %d rows the frame must SAY the window is too small, got %q", h, v)
	}
	// At the minimum itself the real view is back, in full.
	m := Model{term_h = MIN_ROWS}
	v := view(m, context.temp_allocator)
	testing.expectf(t, frame_rows(v, 100) == MIN_ROWS - 1,
		"at exactly MIN_ROWS the full %d-row frame must be painted, got %d rows",
		MIN_ROWS - 1, frame_rows(v, 100))
	testing.expect(t, strings.contains(v, "exit on 'q'"),
		"the full frame must carry the line that tells the user how to leave")
	free_all(context.temp_allocator)
}

// The ioctl-failure sentinel reaches update() unfiltered
// (docs/LIMITATIONS.md 3.16). 0 means "unknown", not "zero rows": a program
// running without a tty must paint its real view, not a permanent "too small".
@(test)
test_a_zero_sized_window_message_never_trips_the_simple_guard :: proc(t: ^testing.T) {
	m := Model{term_h = 24}
	update(&m, rt.Window_Size_Msg{w = 0, h = 0}, context.temp_allocator)
	testing.expect_value(t, m.term_h, 24)

	fresh: Model                      // term_h == 0, i.e. never learned
	v := view(fresh, context.temp_allocator)
	testing.expect(t, strings.contains(v, "exit on 'q'"),
		"with the height unknown the full view must be painted, not the too-small line")
	free_all(context.temp_allocator)
}
