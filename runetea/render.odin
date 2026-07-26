package runetea

import "core:strings"

// Naive inline renderer: rewind over the previous frame and repaint.
//
// Deliberately has no cell buffer and no diffing. At 60fps this pushes ~104 KB/s
// for a completely static screen -- fine locally, unusable over ssh. T3 replaces
// it with a diffed cell renderer, gated behind the golden-byte harness because
// that code fails silently and has no oracle (spec §10, §13.1).
Renderer :: struct {
	out:        ^strings.Builder,
	last_lines: int,
}

renderer_init :: proc(r: ^Renderer, out: ^strings.Builder) {
	r.out = out
	r.last_lines = 0
}

renderer_render :: proc(r: ^Renderer, view: string) {
	// Rewind over the previous frame.
	for _ in 0 ..< r.last_lines {
		strings.write_string(r.out, "\e[1A")   // cursor up one line
		strings.write_string(r.out, "\e[2K")   // erase entire line
	}

	lines := strings.split_lines(view)
	defer delete(lines)
	// A trailing "\n" in view is a terminator, not content: split_lines yields
	// one trailing empty element for it ("a\nb\n" -> ["a","b",""]), which would
	// otherwise paint a permanent, silent extra blank row every frame. Drop
	// exactly one -- a second "\n" ("a\n\n" -> ["a","",""]) IS content (one
	// real blank line) and must survive, matching wc -l / editor semantics.
	// Must come after the defer above: Odin evaluates defer arguments at the
	// defer statement, so the original full-length slice is still what gets
	// freed even though `lines` is reassigned to a shorter view below.
	if len(lines) > 1 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	for line in lines {
		strings.write_string(r.out, line)
		strings.write_string(r.out, "\r\n")    // raw mode: OPOST is off
	}
	r.last_lines = len(lines)
}

renderer_clear :: proc(r: ^Renderer) {
	for _ in 0 ..< r.last_lines {
		strings.write_string(r.out, "\e[1A")
		strings.write_string(r.out, "\e[2K")
	}
	r.last_lines = 0
}
