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
	// costs rewind + full content. T3's diff renderer must reduce this to 0
	// bytes, and this test is what will prove it changed.
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
