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
