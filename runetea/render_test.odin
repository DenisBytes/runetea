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
