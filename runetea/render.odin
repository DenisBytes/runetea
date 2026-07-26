package runetea

import "core:strings"

// Naive inline renderer: rewind over the previous frame and repaint.
//
// Deliberately has no cell buffer and no diffing. At 60fps this pushes ~104 KB/s
// for a completely static screen -- fine locally, unusable over ssh. T3 replaces
// it with a diffed cell renderer, gated behind the golden-byte harness because
// that code fails silently and has no oracle (spec §10, §13.1).
//
// REWIND COUNTS PHYSICAL ROWS, NOT LOGICAL LINES (fixed T1). A terminal wraps
// any line wider than its column count into 2+ physical rows; \e[1A moves the
// cursor up exactly one PHYSICAL row. Rewinding once per logical `\n` therefore
// undershoots whenever a view line is wider than the terminal, and the error
// compounds every frame -- see docs/superpowers/render-width-decision.md for
// the pty-captured reproduction. last_rows is computed with width.odin's
// rows_for_line, which needs the terminal's column count.
Renderer :: struct {
	out:        ^strings.Builder,
	last_rows:  int,
	// 0 means "unknown" (no fd to query, or term_size() failed) -- see
	// rows_for_line's doc comment for why that degrades to exactly the old,
	// pre-fix one-row-per-line behavior rather than guessing or dividing by
	// zero. Set at construction from a real term_size() lookup where one is
	// possible (tea.odin's run(), loop_nbio.odin's run_nbio), and kept live
	// across SIGWINCH via renderer_set_width -- Window_Size_Msg already
	// arrives through the mailbox for that (signals.odin).
	term_width: int,
}

renderer_init :: proc(r: ^Renderer, out: ^strings.Builder, term_width := 0) {
	r.out = out
	r.last_rows = 0
	r.term_width = term_width
}

// renderer_set_width updates the width used to compute FUTURE rewinds. It
// deliberately does not retroactively touch r.last_rows: that value must keep
// describing what the PREVIOUS renderer_render call actually painted, at
// whatever width was in effect then, so the very next rewind is still
// correct even if a resize lands in between (see the resize-mid-run test).
renderer_set_width :: proc(r: ^Renderer, term_width: int) {
	r.term_width = term_width
}

renderer_render :: proc(r: ^Renderer, view: string) {
	// Rewind over the previous frame -- one \e[1A\e[2K pair per PHYSICAL row
	// last_rows recorded, not per logical line.
	//
	// No extra \e[G/\r is needed to fix up the cursor's column first: \e[2K
	// is erase-mode 2 (whole line), which is column-independent, and every
	// line this proc writes ends in "\r\n", so the cursor is always already
	// at column 1 before the very first \e[1A of the NEXT call. \e[1A itself
	// never changes column. So the column invariant (start of rewind ==
	// column 1) holds unconditionally, wrapped lines or not, without any
	// extra escape -- confirmed by the pty capture in
	// docs/superpowers/render-width-decision.md, not merely asserted here.
	for _ in 0 ..< r.last_rows {
		strings.write_string(r.out, "\e[1A")   // cursor up one PHYSICAL row
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
	// Wrapping itself is left entirely to the terminal (out of scope per the
	// design: no truncation/scrolling policy here) -- each logical line is
	// written once, whole, exactly as before. Only the ROW COUNT used for the
	// *next* rewind changes: rows_for_line(..., 0) always returns 1, so with
	// no known width this sum is identical to len(lines), the old behavior,
	// byte for byte.
	rows := 0
	for line in lines {
		strings.write_string(r.out, line)
		strings.write_string(r.out, "\r\n")    // raw mode: OPOST is off
		rows += rows_for_line(line, r.term_width)
	}
	r.last_rows = rows
}

renderer_clear :: proc(r: ^Renderer) {
	for _ in 0 ..< r.last_rows {
		strings.write_string(r.out, "\e[1A")
		strings.write_string(r.out, "\e[2K")
	}
	r.last_rows = 0
}
