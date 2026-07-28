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
	// How many PHYSICAL ROWS above HOME the previous renderer_render call left
	// the terminal's cursor, where HOME is column 1 of the row after the last
	// painted row. 0 means "the cursor is at home", which is where the
	// pre-cursor renderer unconditionally left it and what the rewind's column
	// invariant is proved against. See renderer_render for why this exists and
	// how it keeps that proof intact.
	cursor_up:  int,
}

// Where the application wants the terminal's cursor left at the end of a frame.
//
// COORDINATES ARE THE VIEW'S, NOT THE TERMINAL'S. `line` indexes the view
// string's "\n"-separated LOGICAL lines (0-based); the renderer converts that
// to a physical row itself, using the same rows_for_line sum it uses for
// last_rows, so the two can never disagree about where a wrapped line pushed
// everything below it.
//
// `col` IS A DISPLAY COLUMN, NOT A BYTE OR RUNE INDEX (0-based, within that
// logical line). An app computes it as display_width(prefix) over whatever it
// actually painted before the caret -- that is the only measure that puts the
// caret in the right place when the prefix contains wide runes, combining
// marks, or (now) styling escapes. A byte index puts it too far right on CJK,
// a rune index too far left; both are silently wrong rather than obviously so.
//
// `show` false -- THE ZERO VALUE -- means "no cursor declared", and a frame
// with no cursor declared and none left over from the previous frame writes
// ZERO extra bytes: byte-for-byte the pre-T2 output. That is deliberate and
// matches how every other terminal opt-in in this package works (term.odin's
// `kb`/`paste` defaults): a program that never asks for a cursor must not have
// its output changed, and a terminal must never be left in a state this
// process did not deliberately enter.
Cursor :: struct {
	line: int,
	col:  int,
	show: bool,
}

renderer_init :: proc(r: ^Renderer, out: ^strings.Builder, term_width := 0) {
	r.out = out
	r.last_rows = 0
	r.term_width = term_width
	r.cursor_up = 0
}

// DECTCEM -- `CSI ? 25 l` hides the cursor, `CSI ? 25 h` shows it. Named
// constants because the pairing is the whole safety property (see
// cursor_hide_arm in term.odin) and a typo'd literal in one of two places
// would be invisible.
@(private = "file")
CURSOR_HIDE :: "\e[?25l"
@(private = "file")
CURSOR_SHOW :: "\e[?25h"

// Writes "\e[<n><final>". Hand-assembled rather than fmt.sbprintf'd to match
// the rest of the escape-emitting code in this package (term.odin's
// kitty_push_seq) and to keep the renderer free of core:fmt.
@(private = "file")
write_csi :: proc(b: ^strings.Builder, n: int, final: string) {
	strings.write_string(b, "\e[")
	strings.write_int(b, n)
	strings.write_string(b, final)
}

// renderer_set_width updates the width used to compute FUTURE rewinds. It
// deliberately does not retroactively touch r.last_rows: that value must keep
// describing what the PREVIOUS renderer_render call actually painted, at
// whatever width was in effect then, so the very next rewind is still
// correct even if a resize lands in between (see the resize-mid-run test).
renderer_set_width :: proc(r: ^Renderer, term_width: int) {
	r.term_width = term_width
}

// `cur` defaults to Cursor{} -- "no cursor declared" -- which emits ZERO extra
// bytes, so every call site written before T2 renders byte for byte as it did.
//
// HOW CURSOR PLACEMENT KEEPS THE REWIND INVARIANT (the load-bearing part).
// The invariant the rewind below is proved against is: when the first \e[1A of
// a frame executes, the cursor is at HOME -- column 1 of the row after the
// previous frame's last painted row. Placing a cursor breaks that by
// construction, because the whole point is to leave the cursor somewhere else.
//
// The fix is NOT to teach the rewind about the offset -- that would mean
// re-deriving the proof, and the rewind loop is where a mistake compounds
// every frame. Instead this proc RESTORES HOME FIRST, before any rewind byte
// is written: \e[<n>B walks back down exactly the n rows the previous frame's
// \e[<n>A walked up, and \r puts the column back to 1 unconditionally. The
// rewind loop and its proof are then untouched, byte for byte, and the
// invariant holds again from that point on -- for wrapped lines too, because n
// is counted in PHYSICAL rows by the same rows_for_line sum that produces
// last_rows.
//
// The two moves are symmetric BY CONSTRUCTION, which is what makes this safe:
// \e[<n>A and \e[<n>B both stop at the screen's margins rather than scrolling,
// so an `up` that overshot the frame would be truncated on the way up and NOT
// on the way down, permanently desynchronising home. That is exactly why the
// placement below clamps into the painted frame instead of trusting the app's
// coordinates. (A frame TALLER than the screen breaks this, as it already
// breaks the plain rewind -- see the naive-renderer scope note at the top of
// this file. Unchanged, not newly introduced.)
//
// Absolute CHA (\e[<col+1>G) rather than relative CUF, even though the cursor
// is provably at column 1 after the paint: it costs the same handful of bytes,
// it makes the emitted sequence one fixed shape regardless of the target
// column, and it means a wrong COLUMN can never desynchronise anything -- only
// the row participates in the symmetric up/down pair, and \r re-establishes
// column 1 on the way back no matter where the cursor actually ended up.
renderer_render :: proc(r: ^Renderer, view: string, cur := Cursor{}) {
	// HIDE WHILE ANYTHING MOVES. Two things can move the cursor in this frame:
	// placing one (cur.show), and walking last frame's parked one back home
	// (r.cursor_up > 0). Either way the user would otherwise watch the caret
	// skate up through the rewind and across every repainted row. A frame that
	// does neither writes no DECTCEM at all -- see Cursor's opt-in note.
	hide := cur.show || r.cursor_up > 0
	if hide {
		// ARMED BEFORE THE BYTES CAN LEAVE, exactly like term.odin's
		// kitty_enable/paste_enable set their flags before writing: the window
		// to be wrong in is the one where the terminal has seen the hide and
		// the restore does not know about it.
		cursor_hide_arm()
		strings.write_string(r.out, CURSOR_HIDE)
	}

	// Restore HOME before the rewind -- see this proc's doc comment. Must come
	// before the loop below, not be folded into it: the rewind walks up ONE row
	// at a time erasing as it goes, so starting it from anywhere but home would
	// erase the wrong rows, not merely the wrong number of them.
	if r.cursor_up > 0 {
		write_csi(r.out, r.cursor_up, "B")
		strings.write_string(r.out, "\r")
		r.cursor_up = 0
	}

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
	//
	// `rows_above` accumulates the physical rows painted BEFORE the cursor's
	// logical line, from the same rows_for_line sum that produces last_rows --
	// the same number, not a second computation that could disagree with it.
	cline := clamp(cur.line, 0, len(lines) - 1)
	rows := 0
	rows_above := 0
	for line, i in lines {
		if i == cline { rows_above = rows }
		strings.write_string(r.out, line)
		strings.write_string(r.out, "\r\n")    // raw mode: OPOST is off
		rows += rows_for_line(line, r.term_width)
	}
	r.last_rows = rows

	if cur.show {
		// A column past the terminal's width has wrapped onto a continuation
		// row of its own line -- the same arithmetic the terminal itself does,
		// and the same one rows_for_line does. With term_width unknown (0) no
		// wrapping can be assumed, so the column is used as-is: CHA past the
		// real last column is clamped by the TERMINAL, harmlessly, because the
		// column never participates in the symmetric up/down pair.
		col   := max(cur.col, 0)
		extra := 0
		if r.term_width > 0 {
			extra = col / r.term_width
			col   = col % r.term_width
		}
		// Clamp into the frame: see this proc's doc comment on why an
		// out-of-frame `up` would permanently desynchronise home rather than
		// merely misplace the caret. rows >= 1 always (split_lines always
		// yields at least one element), so up >= 1 here.
		prow := clamp(rows_above + extra, 0, rows - 1)
		up   := rows - prow
		write_csi(r.out, up, "A")
		write_csi(r.out, col + 1, "G")   // CHA is 1-based
		r.cursor_up = up
	}

	if hide { strings.write_string(r.out, CURSOR_SHOW) }
}

renderer_clear :: proc(r: ^Renderer) {
	// Same reason renderer_render restores home first: the rewind below walks
	// up one row at a time and must start from home to erase the right ones.
	// No DECTCEM here -- nothing after this paints, so there is no skating to
	// hide, and the cursor is already visible (every frame that hides it shows
	// it again before returning).
	if r.cursor_up > 0 {
		write_csi(r.out, r.cursor_up, "B")
		strings.write_string(r.out, "\r")
		r.cursor_up = 0
	}
	for _ in 0 ..< r.last_rows {
		strings.write_string(r.out, "\e[1A")
		strings.write_string(r.out, "\e[2K")
	}
	r.last_rows = 0
}
