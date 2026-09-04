#+private
package main

// Unit tests for the http example. See examples/spinner/main_test.odin's
// header for why an example carries tests at all, and why `#+private` on a
// `package main` file.
//
// NOTHING HERE TOUCHES THE NETWORK. check_server is the one proc in this file
// that dials, and it is a Cmd -- these tests drive update() and view(), which
// are pure. A test that needed example.com to be reachable would be a test
// that fails on an aeroplane.

import "core:strings"
import "core:testing"
import rt "../../runetea"

// main() seeds the two hosts from the environment; a zero Model has empty host
// strings, which would make "did the frame keep both checks" unfalsifiable.
// Deliberately NOT the real HOST/HOST2 defaults: nothing here dials, and a
// reader who sees example.com in a test tends to assume something did.
@(private = "file")
seeded_model :: proc() -> Model {
	m: Model
	m.st = make_styles()
	m.checks[0] = Check_Slot{host = "first.invalid",  port = 80}
	m.checks[1] = Check_Slot{host = "second.invalid", port = 80}
	return m
}

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

// THE CONSTANT THAT DID NOT EXIST, pinned to the renderer's arithmetic rather
// than to the number 3.
//
// .Inline terminates every line it paints with "\r\n", the last one included,
// so a frame of R rows occupies R+1 terminal rows. Until v1.0-audit this
// program had no height guard at all, on the reasoning that "two rows fit any
// terminal anyone has" -- measured on a real pty at 90 columns, a two-row
// terminal showed ONE line, because the first check's row was painted and
// immediately scrolled into scrollback, where r.last_rows' clamp to
// term_height-1 means no rewind can ever reach it again.
@(test)
test_the_http_minimum_height_leaves_a_row_for_inlines_terminator :: proc(t: ^testing.T) {
	m := seeded_model()
	m.term_w = 120   // wide enough that nothing wraps and the target column stays
	m.term_h = 24
	rows := frame_rows(view(m, context.temp_allocator), m.term_w)
	testing.expectf(t, MIN_ROWS == rows + 1,
		"MIN_ROWS is %d for a %d-row frame; .Inline needs one more row than it paints, so it must be %d",
		MIN_ROWS, rows, rows + 1)
	free_all(context.temp_allocator)
}

// F47's height half, and the property that matters is not the wording of the
// line -- it is that the frame the terminal is asked to hold is ONE row, so
// that it can actually be held. A frame of the normal shape at this height
// loses its first line silently and the program looks like it only ever
// checked one host.
@(test)
test_a_height_below_the_minimum_paints_one_row_instead_of_losing_a_check :: proc(t: ^testing.T) {
	m := seeded_model()
	m.term_w = 90
	for h in 1 ..< MIN_ROWS {
		m.term_h = h
		v := view(m, context.temp_allocator)
		testing.expectf(t, frame_rows(v, m.term_w) == 1,
			"at %d rows the frame is %d rows; below MIN_ROWS it must be exactly one, or the terminal scrolls part of it away",
			h, frame_rows(v, m.term_w))
		testing.expectf(t, strings.contains(v, "need"),
			"at %d rows the frame must SAY the window is too small, got %q", h, v)
	}
	// At the minimum itself the real view is back, in full.
	m.term_h = MIN_ROWS
	v := view(m, context.temp_allocator)
	testing.expectf(t, frame_rows(v, m.term_w) == MIN_ROWS - 1,
		"at exactly MIN_ROWS the full %d-row frame must be painted, got %d rows",
		MIN_ROWS - 1, frame_rows(v, m.term_w))
	testing.expect(t, strings.contains(v, "first.invalid"), "the full frame must carry the first check")
	testing.expect(t, strings.contains(v, "second.invalid"), "the full frame must carry the second check")
	free_all(context.temp_allocator)
}

// The too-small line is subject to the same rule it is reporting: a line that
// wraps costs a second physical row, so a "need 3 rows, have 2" that is wider
// than the window would re-create the very overflow it exists to prevent.
@(test)
test_the_too_small_frame_is_one_row_at_every_width :: proc(t: ^testing.T) {
	m := seeded_model()
	m.term_h = 1
	for w in 1 ..= 40 {
		m.term_w = w
		v := view(m, context.temp_allocator)
		testing.expectf(t, frame_rows(v, w) == 1,
			"the too-small frame is %d rows at %d columns; it must never wrap", frame_rows(v, w), w)
	}
	free_all(context.temp_allocator)
}

// The ioctl-failure sentinel reaches update() unfiltered
// (docs/LIMITATIONS.md 3.16). 0 means "unknown", not "zero rows": a program
// running without a tty must paint its real view, not a permanent "too small".
@(test)
test_a_zero_sized_window_message_never_trips_the_http_guards :: proc(t: ^testing.T) {
	m := seeded_model()
	m.term_w, m.term_h = 120, 24
	update(&m, rt.Window_Size_Msg{w = 0, h = 0}, context.temp_allocator)
	testing.expect_value(t, m.term_w, 120)
	testing.expect_value(t, m.term_h, 24)

	fresh := seeded_model()           // term_w == term_h == 0, i.e. never learned
	v := view(fresh, context.temp_allocator)
	testing.expect(t, strings.contains(v, "first.invalid"),
		"with the size unknown the full view must be painted, not the too-small line")
	free_all(context.temp_allocator)
}
