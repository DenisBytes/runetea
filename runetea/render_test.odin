#+private
// ^ Every declaration in this file is package-private, so that `odin doc
//   runetea` / `odin doc runegloss` -- the command README.md and docs/API.md
//   hand a newcomer for symbol discovery -- lists the library rather than the
//   test fixtures. Pinned by tools/doccheck/run.sh's `apidoc` check, which is
//   also where the argument for it is written out.
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
	// 2) -- that half is unchanged and is what this test was written for.
	//
	// WHAT CHANGED, AND WHY THE OLD ANSWER WAS THE BUG. This test used to say
	// "at a 1-column terminal that is ceil(2/1) = 2 physical rows" and assert a
	// two-row rewind. The ceil division is exactly the model width.odin's
	// measure_line replaced, because it does not describe where a terminal puts
	// a wide cluster that does not fit before the right margin. Under the
	// placement rule -- screen_put's, and pyte's -- the cluster is written AT
	// the last column with no continuation cell and the cursor CLAMPS to
	// term_width, entering DECAWM's pending-wrap state; the wrap resolves on the
	// NEXT printable cluster, and there isn't one. So the content occupies ONE
	// row, and a two-row rewind would walk \e[1A up past the frame and \e[2K a
	// row that belongs to whatever the shell printed before the program started.
	//
	// Checked against pyte rather than reasoned about, since the whole point of
	// the change is that reasoning about this got it wrong once already:
	//
	//   cols=4  "abc<CJK>"   -> cursor (4,0), content on row 0 only
	//   cols=5  "abcd<CJK>"  -> cursor (5,0), content on row 0 only
	//   cols=6  "abcd<CJK>X" -> cursor (1,1); the NEXT char wraps, not the
	//                           cluster -- which is what "pending" means
	//   cols=1  "❤️"          -> content on row 0 only
	//
	// THE RESIDUAL, STATED RATHER THAN PAPERED OVER: .Inline is painted by the
	// REAL terminal, and xterm-family terminals do not do this. Alacritty
	// inserts a leading-wide-char spacer and wraps the cluster; foot pads with
	// spacers and forces a line wrap. On those, this content occupies TWO rows
	// and the rewind here is one row short. That divergence is screen.odin's
	// documented margin rule (see its header, and docs/LIMITATIONS.md 3.8),
	// taken deliberately because pyte -- the independent oracle tools/difftest
	// scores this package against -- takes this side, and because .Diff and
	// .Full_Screen are immune to it (they address every row absolutely, so a
	// model that agrees with itself paints a correct screen either way). .Inline
	// is the one mode it can still reach, and only for a line whose LAST cluster
	// is wide and starts on the LAST column.
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 1)

	renderer_render(&r, "❤️")
	testing.expect_value(t, r.last_rows, 1)
	strings.builder_reset(&b)

	renderer_render(&r, "x")
	testing.expect_value(t, strings.to_string(b), "\e[1A\e[2K" + "x\r\n")
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
//   \e[?25l                    hide, iff the caret is not already hidden. NOT
//                              conditional on a declared cursor any more -- this
//                              mode owns the viewport and hides the caret for as
//                              long as it does. See
//                              test_full_screen_hides_the_caret_it_owns.
//   \e[0m                      iff the PREVIOUS frame left an SGR open. A frame
//                              starts from the default pen, or the trailing
//                              \e[J below erases the rest of the screen in the
//                              view's leftover background.
//   \e[H                       HOME -- the absolute origin the whole mode exists for
//   <line>\e[K                 per painted line; \r\n BETWEEN lines, never after
//                              the last one (a \r\n on the bottom row SCROLLS,
//                              which would move every row off its absolute
//                              position -- exactly what this mode prevents)
//   \r\n\e[J                   clear everything below the frame, iff a row
//                              exists below it
//   \e[<row>;<col>H            place -- ABSOLUTE CUP, 1-based, not a relative walk
//   \e[?25h                    show, iff this frame DECLARED a cursor. A frame
//                              that declared none leaves the caret hidden --
//                              that is the whole point of hiding it.
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
	// \e[?25l WITH NO CURSOR DECLARED, and that is the change F24 asked for:
	// the mode that owns the viewport hides the caret before it paints and
	// leaves it hidden. See test_full_screen_hides_the_caret_it_owns.
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "\e[H" + "hello\e[K" + "\r\n" + "world\e[K" + "\r\n\e[J")
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
	testing.expect_value(t, strings.to_string(b), "\e[?25l" + "\e[H" + "a\e[K" + "\r\n" + "b\e[K")
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
		"\e[?25l" + "\e[H" + line + "\e[K" + "\r\n" + "second\e[K")
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
	testing.expect_value(t, strings.to_string(b), "\e[?25l" + "\e[H" + "\e[J")
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
		"\e[?25l" + "\e[H" + "a\e[K" + "\r\n" + "b\e[K" + "\r\n" + "c\e[K" + "\r\n" + "d\e[K" + "\r\n\e[J")
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
		"\e[?25l" + "\e[H" + "abcde" + "\r\n" + "xy\e[K" + "\r\n\e[J")

	// ...and a WRAPPED line that ends flush with the margin is the same case:
	// "abcdefghij" is 10 columns == 2 full rows at width 5.
	strings.builder_reset(&b)
	renderer_render(&r, "abcdefghij")
	// No \e[?25l: the frame above already hid the caret and this mode leaves it
	// hidden for as long as it owns the viewport.
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

// A full-screen program that never declares a cursor HIDES THE CARET AND LEAVES
// IT HIDDEN -- once, six bytes, for the life of the session.
//
// THIS TEST USED TO ASSERT THE OPPOSITE, under the name
// test_full_screen_without_a_cursor_writes_no_dectcem, and the rule it pinned
// ("a terminal must never be left in a state this process did not deliberately
// enter") was the right rule applied to the wrong mode. .Full_Screen owns the
// whole viewport; the caret sitting inside it is not the user's caret resting
// after some output, it is a blinking block parked in the middle of an
// application's UI -- and every repaint dragged it across all 24 rows, 60 times
// a second. There was also no way to opt out: Cursor{show = false} is the zero
// value and reads as "no opinion", and cursor_hide_arm is package-private, so an
// application that wrote \e[?25l itself got no paired \e[?25h from term_restore
// and left the user's shell with an invisible caret.
//
// The pairing that makes hiding safe is term.odin's, not this file's:
// cursor_hide_arm() makes term_restore -- and guard.odin's crash handler, and
// the SIGTSTP path -- write \e[?25h on every exit, including the ones no
// renderer ever sees. renderer_clear covers the orderly path.
@(test)
test_full_screen_hides_the_caret_it_owns :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 0, 10, .Full_Screen)

	renderer_render(&r, "a")
	renderer_render(&r, "b")
	// ONE hide, on the first frame, and no show at all: the second frame does
	// not re-hide (the caret is already hidden) and does not reveal it either.
	// A per-frame hide/show pair would cost 12 bytes a frame and flicker the
	// caret back into view between repaints.
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "\e[H" + "a\e[K" + "\r\n\e[J" + "\e[H" + "b\e[K" + "\r\n\e[J")
	testing.expect_value(t, strings.count(strings.to_string(b), "\e[?25l"), 1)
	testing.expect(t, !strings.contains(strings.to_string(b), "\e[?25h"),
		"a frame that declared no cursor must not show the caret again")

	// ...and renderer_clear gives it back, because that is where this mode's
	// ownership of the viewport ends.
	strings.builder_reset(&b)
	renderer_clear(&r)
	testing.expect_value(t, strings.to_string(b), "\e[?25h" + "\e[H\e[J")
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

// ============================================================================
// BUG 4: an inline frame TALLER than the screen.
//
// \e[<n>A clamps at the top margin. A frame of more physical rows than the
// terminal has scrolls its own top rows into scrollback, where CUU cannot reach
// them -- so a rewind that asks for all of them walks up FEWER rows than it
// asked for, while the matching \e[<n>B walks down all of them. Home slides by
// the difference, and because last_rows kept over-counting, the slide COMPOUNDED
// every frame: the display degraded permanently instead of recovering.
//
// These tests are byte-exact at a known height, which is the only way to pin
// it: the defect is entirely in a COUNT, and a count is invisible to anything
// weaker than the exact byte stream.
// ============================================================================

@(test)
test_inline_rewind_is_clamped_to_what_cuu_can_actually_reach :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	// Height 3, width unknown -- so rows_for_line is 1 per logical line and the
	// row count is exactly the line count, with nothing else in play.
	renderer_init(&r, &b, 0, 3)

	// Five rows onto a three-row terminal. Every line is still painted IN FULL:
	// .Inline exists to leave output in the user's scrollback, so truncating
	// here would discard the very thing the mode is for (contrast
	// render_full_screen's "TRUNCATE AT THE BOTTOM", which protects an absolute
	// origin .Inline does not have).
	renderer_render(&r, "a\nb\nc\nd\ne")
	testing.expect_value(t, strings.to_string(b), "a\r\nb\r\nc\r\nd\r\ne\r\n")

	// Only 2 of those 5 rows are still on screen above the cursor (the terminal
	// scrolled until the cursor hit the bottom row, leaving height-1 above it),
	// so the next frame must rewind exactly 2 -- not 5.
	strings.builder_reset(&b)
	renderer_render(&r, "x")
	testing.expect_value(t, strings.to_string(b),
		"\e[1A\e[2K" + "\e[1A\e[2K" + "x\r\n")

	// And it heals: one row fits, so the frame after that rewinds exactly 1 and
	// the mode is back to its ordinary behaviour with no residue.
	strings.builder_reset(&b)
	renderer_render(&r, "y")
	testing.expect_value(t, strings.to_string(b), "\e[1A\e[2K" + "y\r\n")
}

@(test)
test_inline_cursor_park_is_clamped_so_the_up_down_pair_stays_balanced :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 0, 3)

	// Caret on the FIRST line of a four-row frame on a three-row terminal. The
	// unclamped park is \e[4A, which the terminal truncates to 2 -- and then the
	// next frame's \e[4B walks down 4, permanently displacing home. The park is
	// therefore clamped to the same reachable count the rewind uses, so the pair
	// is symmetric by construction.
	renderer_render(&r, "a\nb\nc\nd", Cursor{line = 0, col = 0, show = true})
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "a\r\nb\r\nc\r\nd\r\n" + "\e[2A\e[1G" + "\e[?25h")

	// Walk back down by exactly what went up, then rewind exactly what is
	// reachable.
	strings.builder_reset(&b)
	renderer_render(&r, "z")
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "\e[2B\r" + "\e[1A\e[2K" + "\e[1A\e[2K" + "z\r\n" + "\e[?25h")
}

@(test)
test_inline_on_a_one_row_terminal_emits_no_zero_argument_cuu :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 0, 1)

	// Nothing is ever reachable on a one-row terminal: the cursor is on the only
	// row there is. "\e[0A" would NOT be a no-op -- a zero CSI parameter means
	// one -- so the CUU is dropped entirely rather than emitted with a lying
	// argument, and no frame ever rewinds.
	renderer_render(&r, "a\nb", Cursor{line = 0, col = 0, show = true})
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "a\r\nb\r\n" + "\e[1G" + "\e[?25h")

	strings.builder_reset(&b)
	renderer_render(&r, "c")
	testing.expect_value(t, strings.to_string(b), "c\r\n")
}

// THE PRE-EXISTING BEHAVIOUR MUST BE PRESERVED EXACTLY when the height is
// unknown (0) -- no fd to query, a failed ioctl, output redirected, or any of
// the many tests that never supply one. With no height there is no margin to
// clamp against and guessing one would be strictly worse than the old
// over-count, which at least matches what a tall terminal does.
@(test)
test_inline_with_an_unknown_height_rewinds_every_painted_row :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)   // width AND height unknown

	renderer_render(&r, "a\nb\nc\nd\ne")
	strings.builder_reset(&b)
	renderer_render(&r, "x")
	testing.expect_value(t, strings.to_string(b),
		"\e[1A\e[2K" + "\e[1A\e[2K" + "\e[1A\e[2K" + "\e[1A\e[2K" + "\e[1A\e[2K" + "x\r\n")
}

// ============================================================================
// F03 / F04 / F14 / F24: what a frame leaves behind, and what it measures.
// ============================================================================

// F03. \e[2K ERASES WITH THE ACTIVE BACKGROUND, so the rewind has to start from
// the default pen.
//
// The failure this pins was the most ordinary hand-written-view mistake there
// is -- a line that opens a background colour and never closes it -- amplified
// into a permanently wrong screen by the DEFAULT render mode. The rewind
// erased every row of the frame region to that colour, the repaint that
// followed was written in it, and because the next frame's view left the same
// escape open the flood renewed itself forever. Three rows here; a full-screen
// app's whole frame region in practice.
//
// The reset is CONDITIONAL, and the second half of this test is why that
// matters more than the four bytes: every byte-exact expectation in this file
// is a view that closes its styles, and not one of them may move.
@(test)
test_inline_resets_sgr_before_its_rewind :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 20)

	leaky :: "one\ntwo\n\e[41mthree"
	renderer_render(&r, leaky)
	testing.expect_value(t, strings.to_string(b), "one\r\ntwo\r\n\e[41mthree\r\n")
	testing.expect(t, r.pen_open, "the view left \\e[41m open; the renderer must know it")
	strings.builder_reset(&b)

	renderer_render(&r, leaky)
	// \e[0m BEFORE the first \e[1A. Not after the rewind and not per row: the
	// erase is what needs the default pen, and one reset covers all three.
	testing.expect_value(t, strings.to_string(b),
		"\e[0m" + "\e[1A\e[2K\e[1A\e[2K\e[1A\e[2K" + "one\r\ntwo\r\n\e[41mthree\r\n")

	// A view that closes its own style pays nothing at all.
	b2 := strings.builder_make(); defer strings.builder_destroy(&b2)
	r2: Renderer
	renderer_init(&r2, &b2, 20)
	tidy :: "one\ntwo\n\e[41mthree\e[0m"
	renderer_render(&r2, tidy)
	strings.builder_reset(&b2)
	renderer_render(&r2, tidy)
	testing.expect(t, !strings.contains(strings.to_string(b2), "\e[0m\e[1A"),
		"a view that closes its styles must not gain a reset")
	testing.expect(t, strings.has_prefix(strings.to_string(b2), "\e[1A\e[2K"),
		"a tidy view's frame must begin with the rewind, byte for byte as before")
}

// F03, the other two modes. .Full_Screen's trailing \e[J is the same hazard one
// scale larger -- it erases everything BELOW the frame, i.e. the rest of the
// screen -- and renderer_clear is the same hazard at exit.
@(test)
test_full_screen_resets_sgr_before_the_trailing_ed :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 10, 6, .Full_Screen)

	renderer_render(&r, "\e[41mbar")
	got := strings.to_string(b)
	// The line's OWN \e[K keeps the red -- that is how a view paints a bar out
	// to the right margin, and both .Full_Screen and .Diff model it that way.
	// The \e[0m sits between that and the \r\n\e[J, which erases rows the frame
	// never wrote.
	testing.expect_value(t, got,
		"\e[?25l" + "\e[H" + "\e[41mbar" + "\e[K" + "\e[0m" + "\r\n\e[J")
	testing.expect(t, !r.pen_open, "the pre-ED reset must clear the tracked pen too")

	// And a tidy view is untouched: no reset anywhere.
	b2 := strings.builder_make(); defer strings.builder_destroy(&b2)
	r2: Renderer
	renderer_init(&r2, &b2, 10, 6, .Full_Screen)
	renderer_render(&r2, "\e[41mbar\e[0m")
	testing.expect_value(t, strings.to_string(b2),
		"\e[?25l" + "\e[H" + "\e[41mbar\e[0m" + "\e[K" + "\r\n\e[J")
}

@(test)
test_renderer_clear_resets_sgr_before_it_erases :: proc(t: ^testing.T) {
	// A frame that FILLS the viewport writes no trailing \e[J, so it is the one
	// frame that can end with the pen still set -- which makes it the frame that
	// proves renderer_clear owes the reset rather than inheriting it.
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 10, 1, .Full_Screen)
	renderer_render(&r, "\e[41mbar")
	testing.expect(t, r.pen_open, "a viewport-filling frame ends with the view's pen still set")
	strings.builder_reset(&b)

	renderer_clear(&r)
	testing.expect_value(t, strings.to_string(b), "\e[?25h" + "\e[0m" + "\e[H\e[J")

	// Inline: same rule in front of the same erase.
	bi := strings.builder_make(); defer strings.builder_destroy(&bi)
	ri: Renderer
	renderer_init(&ri, &bi, 20)
	renderer_render(&ri, "\e[41mbar")
	strings.builder_reset(&bi)
	renderer_clear(&ri)
	testing.expect_value(t, strings.to_string(bi), "\e[0m" + "\e[1A\e[2K")
}

// F04, the RENDER half. The measurement half landed in width.odin (a \t now
// advances to the next tab stop instead of measuring 0); this is the assertion
// that the inline rewind actually consumes it.
//
// "col1\tcol2\tcol3\tcol4\tcol5\tcol6" at 40 columns: 24 columns of text, 44
// columns painted once the six tabs expand, so TWO physical rows. Measured as
// 24 it was one, last_rows recorded one, the next frame's rewind erased one row
// too few -- and the whole frame slid one row down the screen, every frame,
// leaving a complete stale copy of the previous frame above it. Forever: the
// error is a constant one row per frame, so the steady state is a terminal that
// scrolls without end with stale rows permanently visible.
@(test)
test_inline_rewinds_the_rows_a_tab_actually_painted :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 40)

	line :: "col1\tcol2\tcol3\tcol4\tcol5\tcol6"
	// The two measurements, side by side, so the test says what the bug was:
	// tab_stop = -1 restores the pre-fix "a tab is a zero-width control"
	// reading, which is the number the renderer used to believe.
	testing.expect_value(t, display_width(line, Width_Options{tab_stop = -1}), 24)
	testing.expect_value(t, display_width(line), 44)
	testing.expect_value(t, rows_for_line(line, 40), 2)

	renderer_render(&r, line)
	testing.expect_value(t, r.last_rows, 2)
	strings.builder_reset(&b)

	renderer_render(&r, "x")
	testing.expect_value(t, strings.to_string(b), "\e[1A\e[2K\e[1A\e[2K" + "x\r\n")
}

// F14. A WIDE CLUSTER THAT STRADDLES THE RIGHT MARGIN MAKES A ROW END SHORT,
// and the \e[K that clears it must not be skipped.
//
// "abcd界efgh" at 5 columns measures 10, and 10 % 5 == 0 -- so the old
// line_fills_its_rows said "flush with the right margin, nothing to erase" and
// the trailing EL was dropped. It is not flush. The 界 starts at column 4, the
// last one, so screen_put writes it THERE and clamps the cursor rather than
// giving it two columns; "efgh" then wraps and the second row ends at column 4
// of 5. Column 4 of that row is never written, and under .Diff it keeps the
// previous frame's character forever, because the model agreed with the
// omission and no later frame ever repaints it.
//
// measure_line answers the real question -- is the last row's final column
// written -- instead of the arithmetic proxy.
@(test)
test_full_screen_emits_el_when_a_wide_cluster_straddles_the_margin :: proc(t: ^testing.T) {
	view :: "abcd界efgh"
	testing.expect_value(t, display_width(view), 10)   // a multiple of 5: the old "fills" answer
	m := measure_line(view, 5)
	testing.expect_value(t, m.rows, 2)
	testing.expect_value(t, m.end_col, 4)              // one short of the margin
	testing.expect(t, !m.fills, "the last row ends at column 4 of 5, so it does not fill")

	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 5, 4, .Full_Screen)
	renderer_render(&r, view)
	testing.expect_value(t, strings.to_string(b),
		"\e[?25l" + "\e[H" + view + "\e[K" + "\r\n\e[J")
}

// ============================================================================
// F53: a terminal that declares no capabilities gets no escape sequences.
//
// term_enter_raw's five opt-ins were gated on term_supports_escapes() by the
// term-guard wave; the RENDERER was not, and the renderer is where the volume
// is. A TERM=dumb session got no alternate screen and then a wall of \e[H,
// \e[2J, \e[K, CUP and SGR painted literally on top of its own output.
//
// Every mode is exercised, because each one owns a different escape and a gate
// placed one line too low would let one of them through: .Inline's rewind,
// .Full_Screen's home/erase, and .Diff's cursor addressing.
// ============================================================================

@(test)
test_a_plain_renderer_writes_not_one_escape_in_any_mode :: proc(t: ^testing.T) {
	for mode in ([?]Render_Mode{.Inline, .Full_Screen, .Diff}) {
		b := strings.builder_make(); defer strings.builder_destroy(&b)
		r: Renderer
		renderer_init(&r, &b, 20, 5, mode)
		defer renderer_destroy(&r)
		r.plain = true

		// Two frames, so a rewind or a diff would have something to address,
		// and a declared cursor, so DECTCEM and CUP would both have a reason to
		// appear. The view carries its own SGR and a hyperlink -- RuneGloss
		// still emits attributes under TERM=dumb (it drops only colour), and
		// nothing downstream of here can remove them.
		renderer_render(&r, "\e[1mhello\e[0m\nworld", Cursor{line = 1, col = 2, show = true})
		renderer_render(&r, "\e]8;;https://example.com\e\\link\e]8;;\e\\\nagain")

		got := strings.to_string(b)
		testing.expectf(t, !strings.contains(got, "\e"),
			"%v: a terminal that declares no capabilities must see no ESC at all; got %q", mode, got)
		testing.expectf(t, got == "hello\r\nworld\r\n" + "link\r\nagain\r\n",
			"%v: the frames are the view's text and nothing else; got %q", mode, got)
	}
}

// The gate is on the RENDERER, not on the view: a plain frame must still be a
// faithful transcript of what the app painted, including every byte an escape
// happened to sit next to. This is the case a naive "drop everything from ESC
// to the next letter" strip gets wrong.
@(test)
test_a_plain_frame_keeps_every_byte_that_is_not_part_of_an_escape :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 0, 0)
	r.plain = true

	// [ and m are content here, not escape bytes; the OSC's payload contains a
	// ';' and a '/' that the terminator scan must not stop early on.
	renderer_render(&r, "a[b\e[31mc;d\e]8;;https://x/y\e\\e\e[0mf")
	testing.expect_value(t, strings.to_string(b), "a[bc;def\r\n")
}

// ---------------------------------------------------------------------------
// AN APPLICATION'S OWN "HIDE THE CARET FOR THIS PROGRAM" (F24's residual).
//
// The mode-owns-the-viewport rule hides the caret for .Full_Screen and .Diff.
// .Inline deliberately does not take the terminal's cursor state over on its
// own initiative -- it composes with the shell -- so the only way that mode can
// lose the blinking block is for the APPLICATION to say so, and until
// Term_Opts.cursor_hide there was no way to say it that came with a paired
// show. See term.odin's Term_Opts.cursor_hide for the full argument.
//
// What this pins is the half that lives here: .Inline's own hide/show pair is
// emitted per frame (hide, paint, show), so a declaration this file did not
// consult would be UNDONE at the end of every frame -- six bytes each way, sixty
// times a second, with the caret flickering back into view between every pair.
// ---------------------------------------------------------------------------
@(test)
test_an_inline_session_that_declared_cursor_hide_hides_once_and_never_shows :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)

	// The declaration lives on the TERMINAL, not on the Renderer: it is the
	// layer that owns the tty that gets to make this call, which for .Inline is
	// never this file. Frames still go to a Builder, so the pty sees only the
	// acquire's own hide.
	if !testing.expect(t, term_enter_raw(pty.slave, {cursor_hide = true}), "term_enter_raw failed") { return }
	defer term_restore()

	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 20)

	renderer_render(&r, "one")
	testing.expect_value(t, strings.to_string(b), "\e[?25l" + "one\r\n")

	strings.builder_reset(&b)
	renderer_render(&r, "two")
	got := strings.to_string(b)
	testing.expectf(t, !strings.contains(got, "\e[?25h"),
		"the second frame wrote %q -- an .Inline frame must not undo a session-long declaration at the end of every paint", got)
	testing.expectf(t, !strings.contains(got, "\e[?25l"),
		"the second frame wrote %q -- the caret is already hidden, so re-hiding it is six wasted bytes per frame", got)
}

// A frame that DOES declare a cursor still wins: the session-long declaration is
// a default, not a veto, or an app with a text field could never show its caret.
// The frame after it hides again, which is the sticky rule the viewport-owning
// modes have always used.
@(test)
test_a_declared_cursor_still_shows_over_a_session_long_cursor_hide :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)
	if !testing.expect(t, term_enter_raw(pty.slave, {cursor_hide = true}), "term_enter_raw failed") { return }
	defer term_restore()

	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 20)

	renderer_render(&r, "one")
	strings.builder_reset(&b)

	renderer_render(&r, "one", Cursor{line = 0, col = 2, show = true})
	got := strings.to_string(b)
	testing.expectf(t, strings.has_suffix(got, "\e[?25h"),
		"a frame that declares a cursor wrote %q, want it to end in a show", got)

	strings.builder_reset(&b)
	renderer_render(&r, "one")
	got2 := strings.to_string(b)
	testing.expectf(t, strings.contains(got2, "\e[?25l") && !strings.contains(got2, "\e[?25h"),
		"the next cursor-less frame wrote %q, want the caret hidden again and left that way", got2)
}

// ---------------------------------------------------------------------------
// A REPAINT NOBODY ON THE FRAME PATH CAN ASK FOR (F29's residual).
//
// guard.odin's SIGTSTP/SIGCONT handlers rebuild the terminal on resume and kick
// a synthetic SIGWINCH so the loop renders again. Under .Diff that was not
// enough: force_repaint is set only when the SIZE actually changed, so a `fg`
// at an unchanged window size diffed against a cell model that still described
// the pre-stop frame -- while the user's shell had printed a prompt and a
// command's output over it. The diff patched the cells it believed had changed
// and left the shell's text on screen for the rest of the session.
// ---------------------------------------------------------------------------
@(test)
test_a_repaint_request_makes_an_unchanged_diff_frame_repaint :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 10, 3, .Diff)
	defer renderer_destroy(&r)

	renderer_render(&r, "hi")
	first := strings.clone(strings.to_string(b)); defer delete(first)

	// The mode's whole point, and the trap: an identical view at an identical
	// size costs nothing, so nothing in the frame path can notice that the
	// screen underneath is no longer the one the model describes.
	strings.builder_reset(&b)
	renderer_render(&r, "hi")
	testing.expect_value(t, strings.to_string(b), "")

	strings.builder_reset(&b)
	request_repaint()
	renderer_render(&r, "hi")
	testing.expectf(t, strings.to_string(b) == first,
		"after a repaint request the frame wrote %q, want the first frame's bytes back %q -- a resume has to resynchronise from a real \\e[2J, not from a model of a screen the shell has written on", strings.to_string(b), first)
}

// The .Inline half of the same request, and it is not a repaint but its
// opposite: the rows this renderer painted are not under the cursor any more
// (the shell's prompt and its command output are), so rewinding over them would
// erase the USER'S text and paint the frame into the hole. Zero means "paint
// fresh, right here", which is what every other program resuming from a stop
// does.
@(test)
test_a_repaint_request_stops_the_next_inline_frame_rewinding :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 20)

	renderer_render(&r, "a\nb")
	strings.builder_reset(&b)

	request_repaint()
	renderer_render(&r, "a\nb")
	testing.expect_value(t, strings.to_string(b), "a\r\nb\r\n")
}

// The third thing the request resets, and the one that is easy to miss: every
// path that can request a repaint went through term_restore_c first, and
// term_restore_c writes "\e[?25h". A renderer that still believed the caret was
// hidden would never re-hide it, so a .Full_Screen or .Diff program would run
// the rest of the session with the blinking block back in the middle of the
// viewport it owns.
@(test)
test_a_repaint_request_re_hides_the_caret_the_teardown_showed :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 10, 3, .Full_Screen)

	renderer_render(&r, "hi")
	testing.expect(t, strings.contains(strings.to_string(b), "\e[?25l"),
		"the first full-screen frame must hide the caret")

	strings.builder_reset(&b)
	renderer_render(&r, "hi")
	testing.expect(t, !strings.contains(strings.to_string(b), "\e[?25l"),
		"it stays hidden across frames -- six bytes once, not twelve per frame")

	strings.builder_reset(&b)
	request_repaint()
	renderer_render(&r, "hi")
	testing.expect(t, strings.contains(strings.to_string(b), "\e[?25l"),
		"the teardown that preceded the request wrote \\e[?25h, so the frame after it has to hide the caret again")
}
