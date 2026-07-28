package runetea

import "core:strings"
import "core:testing"

@(test)
test_first_render_emits_content_only :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	renderer_render(&r, "hello\nworld")
	testing.expect_value(t, strings.to_string(b), "hello\r\nworld\r\n")
}

@(test)
test_second_render_rewinds_previous_lines :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	renderer_render(&r, "a\nb")
	strings.builder_reset(&b)
	renderer_render(&r, "c\nd")

	// 2 previous lines -> 2x (cursor-up + erase-line), then the new content
	testing.expect_value(t, strings.to_string(b), "\e[1A\e[2K\e[1A\e[2K" + "c\r\nd\r\n")
}

@(test)
test_identical_frame_costs_a_full_repaint :: proc(t: ^testing.T) {
	// Documents the naive renderer's defining weakness with an exact byte
	// expectation, not a >0 smoke check: an unchanged single-line frame still
	// costs rewind + full content.
	//
	// T3-A DID NOT CHANGE THIS, and must not: .Inline is still the rewind
	// renderer and still costs 14 bytes here. The 0-byte answer lives in the
	// third mode -- see test_diff_identical_frame_costs_zero_bytes in
	// diff_oracle_test.odin, which pins the same frame at 0 bytes through
	// .Diff. Both are true at once, which is the whole point of adding a mode
	// rather than rewriting one.
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	renderer_render(&r, "same")
	strings.builder_reset(&b)
	renderer_render(&r, "same")

	// 1 previous line -> one CUU+EL pair, then the identical content again.
	testing.expect_value(t, strings.to_string(b), "\e[1A\e[2K" + "same\r\n")
	testing.expect_value(t, len(strings.to_string(b)), 14)
}

@(test)
test_trailing_newline_is_a_terminator_not_a_row :: proc(t: ^testing.T) {
	// strings.split_lines("hello\nworld\n") yields ["hello","world",""] -- a
	// trailing empty element for the terminator. Without the trim this paints
	// a permanent, silent extra blank row. A view ending in "\n" must render
	// byte-for-byte identically to the same view without the trailing "\n".
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	renderer_render(&r, "hello\nworld\n")
	testing.expect_value(t, strings.to_string(b), "hello\r\nworld\r\n")
	testing.expect_value(t, r.last_rows, 2)
}

@(test)
test_double_trailing_newline_keeps_one_blank_line :: proc(t: ^testing.T) {
	// strings.split_lines("a\n\n") yields ["a","",""]. Only the LAST empty
	// element is the terminator; the trim must drop exactly one, leaving the
	// middle "" as a real blank line -- matching wc -l / editor semantics.
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	renderer_render(&r, "a\n\n")
	testing.expect_value(t, strings.to_string(b), "a\r\n\r\n")
	testing.expect_value(t, r.last_rows, 2)
}

@(test)
test_shrinking_frame_with_trailing_newlines_erases_cleanly :: proc(t: ^testing.T) {
	// First frame ends in "\n" and paints 3 rows (trimmed from 4 elements);
	// second frame ends in "\n" and paints 1 row. The rewind count for the
	// second render must match what the first render actually painted (3),
	// not the raw pre-trim element count (4).
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	renderer_render(&r, "a\nb\nc\n")
	testing.expect_value(t, r.last_rows, 3)
	strings.builder_reset(&b)

	renderer_render(&r, "x\n")
	testing.expect_value(t, strings.to_string(b), "\e[1A\e[2K\e[1A\e[2K\e[1A\e[2K" + "x\r\n")
	testing.expect_value(t, r.last_rows, 1)
}

// --- T1 regression: renderer must rewind PHYSICAL ROWS, not logical lines ---
//
// docs/superpowers/render-width-decision.md has the pty-captured reproduction
// this test encodes: examples/simple's own view string, at the exact 20-column
// width the reproduction used, run through the pty+pyte screen emulator and
// shown to leave stale rows on screen every frame. Before the fix, this test's
// second-frame rewind would be 3x "\e[1A\e[2K" (one per logical line: the
// program blurb, the blank line, the counter) even though the terminal
// actually painted 4 physical rows, because "Hi. This program will exit on
// 'q'." (34 columns) wraps at 20. This is the exact undercount that corrupted
// the display.
@(test)
test_regression_wide_line_rewinds_physical_rows_not_logical_lines :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 20)   // 20 columns -- the reproduction's narrow width

	view := "Hi. This program will exit on 'q'.\n\nKeys pressed: 0\n"
	line := "Hi. This program will exit on 'q'."
	testing.expect_value(t, len(line), 34)   // wraps at 20: ceil(34/20) = 2 rows

	renderer_render(&r, view)
	// Content bytes are UNCHANGED by the fix -- wrapping is the terminal's
	// job, not ours; we only count rows correctly for the NEXT rewind.
	testing.expect_value(t, strings.to_string(b), "Hi. This program will exit on 'q'.\r\n\r\nKeys pressed: 0\r\n")
	// 2 (wrapped first line) + 1 (blank) + 1 (counter) = 4 physical rows --
	// NOT 3, which is what the pre-fix logical-line count would have stored.
	testing.expect_value(t, r.last_rows, 4)
	strings.builder_reset(&b)

	renderer_render(&r, "Hi. This program will exit on 'q'.\n\nKeys pressed: 1\n")
	rewind :: "\e[1A\e[2K\e[1A\e[2K\e[1A\e[2K\e[1A\e[2K"   // 4x, matching the 4 rows actually painted
	testing.expect_value(t, strings.to_string(b), rewind + "Hi. This program will exit on 'q'.\r\n\r\nKeys pressed: 1\r\n")
}

@(test)
test_wide_cjk_line_wraps_and_rewinds_correctly :: proc(t: ^testing.T) {
	// 6 CJK runes = 18 bytes, 12 display columns. At 10 columns that is
	// ceil(12/10) = 2 physical rows -- a byte-length or rune-count measure
	// would both get this wrong (9 code points if counted as runes: still
	// not 12; 18 if counted as bytes: wildly over).
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 10)

	renderer_render(&r, "日本語日本語")
	testing.expect_value(t, strings.to_string(b), "日本語日本語\r\n")
	testing.expect_value(t, r.last_rows, 2)
	strings.builder_reset(&b)

	renderer_render(&r, "x")
	testing.expect_value(t, strings.to_string(b), "\e[1A\e[2K\e[1A\e[2K" + "x\r\n")
}

@(test)
test_emoji_with_vs16_wraps_and_rewinds_correctly :: proc(t: ^testing.T) {
	// "❤️" (U+2764 U+FE0F) is one grapheme cluster, corrected width 2 (defect
	// 2). At a 1-column terminal that is ceil(2/1) = 2 physical rows.
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 1)

	renderer_render(&r, "❤️")
	testing.expect_value(t, r.last_rows, 2)
	strings.builder_reset(&b)

	renderer_render(&r, "x")
	testing.expect_value(t, strings.to_string(b), "\e[1A\e[2K\e[1A\e[2K" + "x\r\n")
}

@(test)
test_resize_mid_run_rewind_matches_what_was_painted_at_old_width :: proc(t: ^testing.T) {
	// render (width 20) -> deliver a new width (80) -> render again. The
	// SECOND render's rewind must match the 2 rows the FIRST render actually
	// painted AT WIDTH 20, not a recomputation of that old line's row count
	// at the NEW width 80 (which would be 1 row, since 34 < 80) -- last_rows
	// is a record of what is ACTUALLY on screen, not a function of the
	// renderer's current width.
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 20)

	renderer_render(&r, "Hi. This program will exit on 'q'.")   // 34 cols -> 2 rows at width 20
	testing.expect_value(t, r.last_rows, 2)
	strings.builder_reset(&b)

	renderer_set_width(&r, 80)   // simulates a SIGWINCH-driven Window_Size_Msg landing here
	renderer_render(&r, "same")
	testing.expect_value(t, strings.to_string(b), "\e[1A\e[2K\e[1A\e[2K" + "same\r\n")
	// The new width now governs FUTURE rewinds: "same" is 1 row at width 80.
	testing.expect_value(t, r.last_rows, 1)
}

// ---------------------------------------------------------------------------
// T2-A part 2: real cursor placement.
//
// Every test below is byte-exact, in the style of the rewind tests above,
// because the whole hazard here is emitting the wrong ESCAPES, not computing
// the wrong number. The frame shape, once and for all:
//
//   \e[?25l                    hide, iff this frame moves the cursor at all
//   \e[<n>B \r                 walk back to HOME, iff the last frame parked one
//   (\e[1A\e[2K) x last_rows   the rewind, byte-for-byte unchanged
//   <content>\r\n per line     the paint, byte-for-byte unchanged
//   \e[<up>A \e[<col+1>G       place
//   \e[?25h                    show
//
// HOME is column 1 of the row after the last painted row -- exactly the
// position the pre-cursor renderer always left the cursor in, and exactly what
// the rewind's column invariant is proved against (render.odin's own comment).
// ---------------------------------------------------------------------------

@(test)
test_no_cursor_declared_emits_zero_extra_bytes :: proc(t: ^testing.T) {
	// The opt-in property, pinned rather than assumed: the default Cursor{}
	// must produce byte-for-byte the pre-T2 output. This is what keeps every
	// test above -- including the documented 14-byte baseline -- unchanged.
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	renderer_render(&r, "same", Cursor{})
	strings.builder_reset(&b)
	renderer_render(&r, "same", Cursor{})
	testing.expect_value(t, strings.to_string(b), "\e[1A\e[2K" + "same\r\n")
	testing.expect_value(t, len(strings.to_string(b)), 14)
	testing.expect_value(t, r.cursor_up, 0)
}

@(test)
test_cursor_placement_first_frame_is_byte_exact :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	renderer_render(&r, "hello", Cursor{line = 0, col = 0, show = true})
	// 1 row painted; the cursor must come back UP one row (from home) and to
	// column 1 (CHA parameter is 1-based: col 0 -> "\e[1G").
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "hello\r\n" + "\e[1A\e[1G" + "\e[?25h")
	testing.expect_value(t, r.last_rows, 1)
	testing.expect_value(t, r.cursor_up, 1)
}

@(test)
test_cursor_column_is_one_based_cha :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	renderer_render(&r, "hello", Cursor{line = 0, col = 3, show = true})
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "hello\r\n" + "\e[1A\e[4G" + "\e[?25h")
}

// THE REWIND INVARIANT, stated as bytes. The second frame must walk the cursor
// back DOWN to home and to column 1 BEFORE the first \e[1A of the rewind, so
// the rewind loop itself -- and the proof in render.odin's doc comment that it
// needs no column fixup -- is untouched by cursor placement.
@(test)
test_cursor_frame_returns_home_before_rewinding :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	cur := Cursor{line = 0, col = 2, show = true}
	renderer_render(&r, "hello", cur)
	testing.expect_value(t, r.cursor_up, 1)
	strings.builder_reset(&b)

	renderer_render(&r, "world", cur)
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "\e[1B\r" + "\e[1A\e[2K" + "world\r\n" + "\e[1A\e[3G" + "\e[?25h")
}

// A multi-row frame: the return move must be the SAME distance the placement
// moved (up 3 / down 3), or every subsequent rewind starts from the wrong row.
@(test)
test_cursor_return_distance_matches_the_placement_distance :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	cur := Cursor{line = 0, col = 0, show = true}   // top line of a 3-line frame
	renderer_render(&r, "a\nb\nc", cur)
	testing.expect_value(t, r.last_rows, 3)
	testing.expect_value(t, r.cursor_up, 3)
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "a\r\nb\r\nc\r\n" + "\e[3A\e[1G" + "\e[?25h")
	strings.builder_reset(&b)

	// Down 3 (back to home), then exactly 3 rewind pairs -- the count the
	// PREVIOUS frame actually painted.
	renderer_render(&r, "x\ny\nz", Cursor{line = 2, col = 0, show = true})
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "\e[3B\r" + "\e[1A\e[2K\e[1A\e[2K\e[1A\e[2K" +
		"x\r\ny\r\nz\r\n" + "\e[1A\e[1G" + "\e[?25h")
	testing.expect_value(t, r.cursor_up, 1)
}

// A frame that declares NO cursor after one that did still has to walk the
// parked cursor home before rewinding -- otherwise the rewind starts one row
// too high and eats a row it never painted. It also hides for that walk, and
// shows again at the end, leaving the cursor parked at home and VISIBLE: the
// same place and the same state the pre-cursor renderer always left it in.
@(test)
test_dropping_the_cursor_still_returns_home_first :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	renderer_render(&r, "a\nb", Cursor{line = 0, col = 0, show = true})
	testing.expect_value(t, r.cursor_up, 2)
	strings.builder_reset(&b)

	renderer_render(&r, "x")   // no cursor this frame
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "\e[2B\r" + "\e[1A\e[2K\e[1A\e[2K" + "x\r\n" + "\e[?25h")
	testing.expect_value(t, r.cursor_up, 0)
	strings.builder_reset(&b)

	// ...and once the cursor is back home, the NEXT frame is pure pre-T2
	// bytes again: no DECTCEM at all.
	renderer_render(&r, "y")
	testing.expect_value(t, strings.to_string(b), "\e[1A\e[2K" + "y\r\n")
}

// The whole reason `col` is a DISPLAY column and not a byte or rune index: a
// CJK prefix is 2 columns per rune and 3 bytes per rune, so a byte count would
// put the caret 2 columns too far right and a rune count 2 too far left.
@(test)
test_cursor_column_after_a_wide_rune_is_a_display_column :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	prefix := "日本"
	testing.expect_value(t, len(prefix), 6)             // bytes
	testing.expect_value(t, display_width(prefix), 4)   // columns -- what the caret needs

	// Caret sits just after "日本" on the first of two lines. Column 4 (0-based)
	// -> CHA 5. Byte-indexing would have emitted "\e[7G", rune-indexing "\e[3G".
	renderer_render(&r, "日本x\nabc", Cursor{line = 0, col = display_width(prefix), show = true})
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "日本x\r\nabc\r\n" + "\e[2A\e[5G" + "\e[?25h")
}

// Wrapping: the cursor's PHYSICAL row is the sum of rows_for_line over the
// lines above it PLUS how many times its own column has wrapped -- the exact
// same row arithmetic last_rows uses, so the two can never disagree.
@(test)
test_cursor_row_accounts_for_wrapped_lines_above_it :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 20)

	line :: "Hi. This program will exit on 'q'."   // 34 cols -> 2 rows at width 20
	renderer_render(&r, line + "\nsecond", Cursor{line = 1, col = 3, show = true})
	// 2 + 1 = 3 rows painted; the cursor's line starts at physical row 2, so
	// it is 3 - 2 = 1 row above home.
	testing.expect_value(t, r.last_rows, 3)
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + line + "\r\nsecond\r\n" + "\e[1A\e[4G" + "\e[?25h")
	testing.expect_value(t, r.cursor_up, 1)
}

@(test)
test_cursor_inside_a_wrapped_line_lands_on_the_continuation_row :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 20)

	line :: "Hi. This program will exit on 'q'."   // 34 cols -> 2 rows at width 20
	// Column 25 is on the line's SECOND physical row, at 25 % 20 == 5.
	renderer_render(&r, line, Cursor{line = 0, col = 25, show = true})
	testing.expect_value(t, r.last_rows, 2)
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + line + "\r\n" + "\e[1A\e[6G" + "\e[?25h")
}

// Out-of-range coordinates are CLAMPED INTO THE FRAME, not emitted as-is. This
// is not politeness: \e[<n>A stops at the top of the SCREEN, so an `up` larger
// than the frame would be silently truncated by the terminal while the
// matching \e[<n>B on the next frame would move the full distance -- the
// cursor would end up somewhere other than home and every rewind after that
// would be wrong. Clamping keeps the two moves provably symmetric.
@(test)
test_cursor_out_of_range_is_clamped_into_the_frame :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	renderer_render(&r, "a\nb", Cursor{line = 99, col = 0, show = true})
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "a\r\nb\r\n" + "\e[1A\e[1G" + "\e[?25h")   // clamped to the last row
	testing.expect_value(t, r.cursor_up, 1)
	strings.builder_reset(&b)

	renderer_render(&r, "a\nb", Cursor{line = -7, col = -7, show = true})
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "\e[1B\r" + "\e[1A\e[2K\e[1A\e[2K" + "a\r\nb\r\n" + "\e[2A\e[1G" + "\e[?25h")
}

// renderer_clear tears the frame down completely, so it must also undo the
// cursor parking -- otherwise the rewind inside it starts from the wrong row.
@(test)
test_renderer_clear_returns_the_cursor_home_first :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	renderer_render(&r, "a\nb", Cursor{line = 0, col = 0, show = true})
	strings.builder_reset(&b)

	renderer_clear(&r)
	testing.expect_value(t, strings.to_string(b),
		"\e[2B\r" + "\e[1A\e[2K\e[1A\e[2K")
	testing.expect_value(t, r.last_rows, 0)
	testing.expect_value(t, r.cursor_up, 0)
}

// The hide is only ARMED for term_restore_c when this process actually owns a
// terminal in raw mode. Without that gate, the golden harness (flush_fd = -1,
// term_enter_raw never called, g_term.fd still 0) would arm a show against
// fd 0 -- an unpaired "\e[?25h" written to the test runner's own stdin.
@(test)
test_cursor_hide_arms_the_restore_only_when_raw :: proc(t: ^testing.T) {
	saved := g_term
	defer g_term = saved

	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	g_term = {}   // not raw: no terminal of ours to leave broken
	renderer_render(&r, "x", Cursor{line = 0, col = 0, show = true})
	testing.expect(t, !g_term.cursor_hidden,
		"a renderer with no raw terminal behind it must not arm the paired show")

	g_term = {}
	g_term.raw_active = true
	renderer_render(&r, "x", Cursor{line = 0, col = 0, show = true})
	testing.expect(t, g_term.cursor_hidden,
		"hiding the cursor on a real raw terminal MUST arm the paired show in term_restore_c")
}

@(test)
test_unknown_width_falls_back_to_pre_fix_behavior_byte_for_byte :: proc(t: ^testing.T) {
	// term_width left at its zero value (never queried/never told -- the
	// golden harness's and every pre-existing test's situation) must render
	// BYTE FOR BYTE identically to the pre-fix renderer, even for a line that
	// would wrap on a real narrow terminal: with no known width there is
	// nothing sound to compute, so this falls back to one row per logical
	// line, exactly as before.
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)   // term_width defaults to 0 -- unknown

	line :: "Hi. This program will exit on 'q'."   // 34 cols; would wrap at 20
	renderer_render(&r, line)
	testing.expect_value(t, r.last_rows, 1)
	strings.builder_reset(&b)

	renderer_render(&r, line)
	testing.expect_value(t, strings.to_string(b), "\e[1A\e[2K" + line + "\r\n")
}

// ---------------------------------------------------------------------------
// T2-C: the FULL-SCREEN renderer.
//
// Every test below is byte-exact, in the style of the inline tests above, and
// for the same reason: the hazard is emitting the wrong ESCAPES, not computing
// the wrong number. NOTHING ABOVE THIS LINE CHANGED -- Render_Mode.Inline is
// the zero value and renderer_init's new parameters are trailing defaults, so
// every inline expectation in this file (including the documented 14-byte
// single-line-frame baseline) is byte-for-byte what it was before T2-C.
//
// THE FULL-SCREEN FRAME SHAPE, once and for all:
//
//   \e[?25l                    hide, iff this frame declares a cursor
//   \e[H                       HOME -- the absolute origin the whole mode exists for
//   <line>\e[K                 per painted line; \r\n BETWEEN lines, never after
//                              the last one (a \r\n on the bottom row SCROLLS,
//                              which would move every row off its absolute
//                              position -- exactly what this mode prevents)
//   \r\n\e[J                   clear everything below the frame, iff a row
//                              exists below it
//   \e[<row>;<col>H            place -- ABSOLUTE CUP, 1-based, not a relative walk
//   \e[?25h                    show
//
// There is no rewind and no return-to-home walk: absolute positioning is the
// point, so `cursor_up` stays 0 forever in this mode and the inline renderer's
// symmetric up/down pair (and its proof) is simply not in play.
// ---------------------------------------------------------------------------

@(test)
test_full_screen_first_frame_is_byte_exact :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 0, 0, .Full_Screen)   // width/height unknown

	renderer_render(&r, "hello\nworld")
	testing.expect_value(t, strings.to_string(b),
		"\e[H" + "hello\e[K" + "\r\n" + "world\e[K" + "\r\n\e[J")
	testing.expect_value(t, r.last_rows, 2)
	testing.expect_value(t, r.cursor_up, 0)
}

// THE POINT OF \e[K AND \e[J, proved rather than asserted: a frame SHORTER than
// the one before it must leave nothing of the old one on screen. The inline
// renderer achieves this by rewinding and erasing each row it painted; this mode
// never rewinds at all, so the erasure has to come from the two clears.
//
// Row 1 ("bbbb" -> "x") is cleaned by that line's own \e[K -- \e[J cannot do it,
// because the \r\n before \e[J has already moved the cursor off that row. Rows 2
// and 3 are cleaned by \e[J. Both clears are load-bearing and neither is
// redundant, which is exactly why the \r\n sits between them.
@(test)
test_full_screen_shorter_frame_leaves_no_stale_rows :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 0, 10, .Full_Screen)

	renderer_render(&r, "aaaa\nbbbb\ncccc")
	testing.expect_value(t, r.last_rows, 3)
	strings.builder_reset(&b)

	renderer_render(&r, "x")
	testing.expect_value(t, strings.to_string(b), "\e[H" + "x\e[K" + "\r\n\e[J")
	testing.expect_value(t, r.last_rows, 1)
}

// THE TALLER-THAN-THE-VIEWPORT POLICY: TRUNCATE AT THE BOTTOM. Scrolling is the
// application's job (rows_for_line's doc comment already establishes exactly
// that for wrapping), so a view with more rows than the terminal has simply
// loses its tail -- it is never scrolled into, never squeezed, and above all
// never allowed to run off the bottom, because writing past the last row
// SCROLLS the screen and slides every row of the frame off the absolute
// position this mode exists to guarantee.
@(test)
test_full_screen_truncates_content_taller_than_the_viewport :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 0, 2, .Full_Screen)   // a two-row terminal

	renderer_render(&r, "a\nb\nc\nd")
	// "c" and "d" are dropped, and there is NO trailing \r\n\e[J: the frame
	// fills the screen exactly, so there is no row below to clear and the \r\n
	// that would precede the clear would scroll.
	testing.expect_value(t, strings.to_string(b), "\e[H" + "a\e[K" + "\r\n" + "b\e[K")
	testing.expect_value(t, r.last_rows, 2)
}

// Truncation counts PHYSICAL ROWS, not logical lines -- the same lesson the
// inline rewind learned the hard way (see the T1 regression test above). A line
// that WRAPS eats two rows of the budget, so a 3-row terminal fits the wrapped
// line plus one more, not two more.
@(test)
test_full_screen_truncation_counts_physical_rows :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 20, 3, .Full_Screen)

	line :: "Hi. This program will exit on 'q'."   // 34 cols -> 2 rows at width 20
	renderer_render(&r, line + "\nsecond\nthird")
	testing.expect_value(t, strings.to_string(b),
		"\e[H" + line + "\e[K" + "\r\n" + "second\e[K")
	testing.expect_value(t, r.last_rows, 3)
}

// A LINE IS PAINTED ONLY IF ALL OF ITS PHYSICAL ROWS FIT. The degenerate case
// -- a single line taller than the whole terminal -- therefore paints nothing
// at all, and that is deliberate rather than an oversight: the alternative is
// letting it wrap past the bottom, which scrolls the screen and desynchronises
// every absolute position in the frame. \e[J alone (with no \r\n before it,
// because nothing was painted and the cursor is still at 1;1) blanks the
// screen, which is an honest empty frame rather than a corrupted one.
@(test)
test_full_screen_drops_a_line_that_cannot_fit_whole :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 10, 1, .Full_Screen)

	renderer_render(&r, "日本語日本語")   // 12 cols -> 2 rows at width 10, screen is 1
	testing.expect_value(t, strings.to_string(b), "\e[H" + "\e[J")
	testing.expect_value(t, r.last_rows, 0)
}

// UNKNOWN HEIGHT (0) MEANS "DO NOT GUESS", exactly as unknown WIDTH does for
// rows_for_line: with nothing to clamp against, everything is painted. This is
// the golden harness's and every widthless test's situation, and it is what
// keeps a Renderer that was never told a size from silently swallowing content.
@(test)
test_full_screen_unknown_height_paints_everything :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 0, 0, .Full_Screen)

	renderer_render(&r, "a\nb\nc\nd")
	testing.expect_value(t, strings.to_string(b),
		"\e[H" + "a\e[K" + "\r\n" + "b\e[K" + "\r\n" + "c\e[K" + "\r\n" + "d\e[K" + "\r\n\e[J")
	testing.expect_value(t, r.last_rows, 4)
}

// A LINE THAT EXACTLY FILLS ITS LAST PHYSICAL ROW GETS NO \e[K, and this is the
// one place the frame shape is conditional. Two independent reasons, and the
// first alone would be enough:
//
//  1. There is nothing to erase. The line covers every cell of every row it
//     occupies, so the clear could only ever be a no-op.
//  2. It would not be a no-op on a VT100-family terminal. After a glyph is
//     written into the LAST column, terminfo's `xenl` ("magic margin",
//     eat_newline_glitch) terminals leave the cursor AT that column with a wrap
//     pending rather than moving it to the next row -- and EL(0) erases from the
//     cursor's column INCLUSIVE, i.e. it would erase the glyph just written.
//     This is not reproducible with the emulator available here (pyte parks the
//     cursor one column past the end, where EL erases nothing), so it is guarded
//     rather than demonstrated -- which is the right way round for a hazard that
//     costs one visibly missing character per frame on a full-width border line,
//     the single most common exact-fill case in a full-screen UI.
//
// The trailing \r\n\e[J is safe against the same hazard by construction: the
// \r\n moves the cursor out of the pending-wrap state before the clear.
//
// With an UNKNOWN width there is no way to tell, so \e[K is always written --
// the same "do not guess" rule the rest of the width layer follows.
@(test)
test_full_screen_omits_el_for_a_line_that_exactly_fills_its_row :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 5, 4, .Full_Screen)

	// "abcde" is exactly 5 columns at width 5; "xy" is not.
	renderer_render(&r, "abcde\nxy")
	testing.expect_value(t, strings.to_string(b),
		"\e[H" + "abcde" + "\r\n" + "xy\e[K" + "\r\n\e[J")

	// ...and a WRAPPED line that ends flush with the margin is the same case:
	// "abcdefghij" is 10 columns == 2 full rows at width 5.
	strings.builder_reset(&b)
	renderer_render(&r, "abcdefghij")
	testing.expect_value(t, strings.to_string(b), "\e[H" + "abcdefghij" + "\r\n\e[J")
	testing.expect_value(t, r.last_rows, 2)
}

// CURSOR PLACEMENT IS ABSOLUTE CUP HERE, and that is the whole reason T2-C
// makes click-to-position well defined: with a known origin, `\e[<row>;<col>H`
// says exactly where the caret goes, with no relative walk to keep symmetric and
// no home to return to next frame.
@(test)
test_full_screen_cursor_is_absolute_cup :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 0, 10, .Full_Screen)

	renderer_render(&r, "hello\nworld", Cursor{line = 1, col = 3, show = true})
	// Row 2, column 4 -- both 1-based, both absolute.
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "\e[H" + "hello\e[K" + "\r\n" + "world\e[K" + "\r\n\e[J" +
		"\e[2;4H" + "\e[?25h")
	// No relative parking to undo, so the NEXT frame has no walk-home prefix.
	testing.expect_value(t, r.cursor_up, 0)
	strings.builder_reset(&b)

	renderer_render(&r, "hello\nworld", Cursor{line = 0, col = 0, show = true})
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "\e[H" + "hello\e[K" + "\r\n" + "world\e[K" + "\r\n\e[J" +
		"\e[1;1H" + "\e[?25h")
}

// The display-column computation is SHARED with the inline renderer (one
// cursor_cell helper, not two), so a wide rune before the caret behaves
// identically in both modes. This is the full-screen twin of
// test_cursor_column_after_a_wide_rune_is_a_display_column above: same view,
// same Cursor, and the caret lands in the same CELL -- column 5, 1-based --
// expressed as an absolute CUP instead of a walk.
@(test)
test_full_screen_cursor_column_after_a_wide_rune_is_a_display_column :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 0, 10, .Full_Screen)

	prefix := "日本"
	testing.expect_value(t, len(prefix), 6)             // bytes
	testing.expect_value(t, display_width(prefix), 4)   // columns -- what the caret needs

	renderer_render(&r, "日本x\nabc", Cursor{line = 0, col = display_width(prefix), show = true})
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "\e[H" + "日本x\e[K" + "\r\n" + "abc\e[K" + "\r\n\e[J" +
		"\e[1;5H" + "\e[?25h")
}

// A caret inside a WRAPPED line lands on the continuation ROW, using the same
// rows_for_line arithmetic the paint itself uses -- so the two can never
// disagree about which physical row a line starts on.
@(test)
test_full_screen_cursor_inside_a_wrapped_line :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 20, 10, .Full_Screen)

	line :: "Hi. This program will exit on 'q'."   // 34 cols -> 2 rows at width 20
	// Column 25 is on the line's SECOND physical row, at 25 % 20 == 5.
	renderer_render(&r, line, Cursor{line = 0, col = 25, show = true})
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "\e[H" + line + "\e[K" + "\r\n\e[J" + "\e[2;6H" + "\e[?25h")
}

// A caret on a line TRUNCATION dropped is clamped into what was actually
// painted, rather than pointing at a row the terminal never received. Same rule
// (and the same clamp) as the inline renderer's, for a different reason: there
// the danger was desynchronising the symmetric up/down pair, here it is simply
// that a CUP past the frame lands on stale or empty screen.
@(test)
test_full_screen_cursor_on_a_truncated_line_is_clamped :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 0, 2, .Full_Screen)

	renderer_render(&r, "a\nb\nc", Cursor{line = 2, col = 0, show = true})
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "\e[H" + "a\e[K" + "\r\n" + "b\e[K" + "\e[2;1H" + "\e[?25h")
}

// Nothing painted means nothing to place a caret on: no CUP at all, rather than
// a `\e[0;1H` (which a terminal reads as row 1) pointing at a blank screen.
@(test)
test_full_screen_places_no_cursor_when_nothing_was_painted :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 10, 1, .Full_Screen)

	renderer_render(&r, "日本語日本語", Cursor{line = 0, col = 0, show = true})
	testing.expect_value(t, strings.to_string(b), "\e[?25l" + "\e[H" + "\e[J" + "\e[?25h")
}

// A full-screen program that never declares a cursor writes not one DECTCEM
// byte -- the same opt-in property the inline mode has, and for the same reason
// (a terminal must never be left in a state this process did not deliberately
// enter). The caret simply rests wherever the paint left it, which is where the
// inline renderer's own cursor-less frames leave it too.
@(test)
test_full_screen_without_a_cursor_writes_no_dectcem :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 0, 10, .Full_Screen)

	renderer_render(&r, "a")
	renderer_render(&r, "b")
	testing.expect_value(t, strings.to_string(b),
		"\e[H" + "a\e[K" + "\r\n\e[J" + "\e[H" + "b\e[K" + "\r\n\e[J")
	testing.expect(t, !strings.contains(strings.to_string(b), "\e[?25"),
		"a cursor-less full-screen frame must not touch DECTCEM")
}

@(test)
test_full_screen_clear_blanks_the_screen :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 0, 10, .Full_Screen)

	renderer_render(&r, "a\nb", Cursor{line = 0, col = 0, show = true})
	strings.builder_reset(&b)

	// No rewind, no walk home: home and erase to the end of the screen. There is
	// no partial state to unwind because there is no relative position to unwind
	// from.
	renderer_clear(&r)
	testing.expect_value(t, strings.to_string(b), "\e[H\e[J")
	testing.expect_value(t, r.last_rows, 0)
	testing.expect_value(t, r.cursor_up, 0)
}

// Height is kept live across a resize exactly the way width is, and for the same
// reason: SIGWINCH delivers a Window_Size_Msg carrying BOTH (signals.odin has
// always filled in `h`; T2-C is the first thing to read it).
@(test)
test_renderer_set_height_governs_future_truncation :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 0, 2, .Full_Screen)

	renderer_render(&r, "a\nb\nc")
	testing.expect_value(t, r.last_rows, 2)
	strings.builder_reset(&b)

	renderer_set_height(&r, 4)
	renderer_render(&r, "a\nb\nc")
	testing.expect_value(t, strings.to_string(b),
		"\e[H" + "a\e[K" + "\r\n" + "b\e[K" + "\r\n" + "c\e[K" + "\r\n\e[J")
	testing.expect_value(t, r.last_rows, 3)
}

// The inline renderer must be UNAFFECTED by everything above: no \e[H, no \e[K,
// no \e[J, no CUP. This is the guard rail that stops a future edit to the shared
// entry point from leaking full-screen escapes into the mode two of the three
// examples and every existing byte-exact test still use.
@(test)
test_inline_mode_emits_no_full_screen_escapes :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 20, 5)   // mode defaults to .Inline even with a known size

	renderer_render(&r, "a\nb", Cursor{line = 0, col = 0, show = true})
	renderer_render(&r, "c")
	got := strings.to_string(b)
	testing.expect(t, !strings.contains(got, "\e[H"), "inline mode must never home the cursor")
	testing.expect(t, !strings.contains(got, "\e[K"), "inline mode must never clear to end of line")
	testing.expect(t, !strings.contains(got, "\e[J"), "inline mode must never clear to end of screen")
	testing.expect_value(t, got,
		"\e[?25l" + "a\r\nb\r\n" + "\e[2A\e[1G" + "\e[?25h" +
		"\e[?25l" + "\e[2B\r" + "\e[1A\e[2K\e[1A\e[2K" + "c\r\n" + "\e[?25h")
}
