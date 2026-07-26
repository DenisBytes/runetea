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
	testing.expect_value(t, r.last_lines, 2)
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
	testing.expect_value(t, r.last_lines, 2)
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
	testing.expect_value(t, r.last_lines, 3)
	strings.builder_reset(&b)

	renderer_render(&r, "x\n")
	testing.expect_value(t, strings.to_string(b), "\e[1A\e[2K\e[1A\e[2K\e[1A\e[2K" + "x\r\n")
	testing.expect_value(t, r.last_lines, 1)
}
