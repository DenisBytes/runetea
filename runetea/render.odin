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
//
// T2-C ADDS A SECOND MODE AND KEEPS THIS ONE (spec §12 keeps both, and this one
// is what every existing byte-exact test and two of the three examples use).
// The inline renderer is correct for prompts, menus and short output -- it
// leaves the user's scrollback intact and composes with whatever the shell
// printed before it. Render_Mode.Full_Screen is the other half: an absolute
// repaint from a known origin, which is what an app needs before it can turn a
// mouse click into a screen position at all (examples/editor).
Renderer :: struct {
	out:        ^strings.Builder,
	mode:       Render_Mode,
	last_rows:  int,
	// 0 means "unknown" (no fd to query, or term_size() failed) -- see
	// rows_for_line's doc comment for why that degrades to exactly the old,
	// pre-fix one-row-per-line behavior rather than guessing or dividing by
	// zero. Set at construction from a real term_size() lookup where one is
	// possible (tea.odin's run(), loop_nbio.odin's run_nbio), and kept live
	// across SIGWINCH via renderer_set_width -- Window_Size_Msg already
	// arrives through the mailbox for that (signals.odin).
	term_width: int,
	// T2-C. The terminal's ROW count, and 0 means "unknown" for exactly the same
	// reasons term_width's 0 does (no fd to query, term_size() failed, or a test
	// that never supplied one). READ ONLY BY THE FULL-SCREEN PATH: the inline
	// renderer has no viewport to clamp against -- its frames sit wherever the
	// terminal happened to be and scroll the way any other program's output does
	// -- so a height would have nothing to mean there.
	//
	// term_size() has ALWAYS returned this and both event loops have ALWAYS
	// discarded it (`if w, _, ok := term_size(...)`); T2-C is the first thing
	// that needs it. Kept live across SIGWINCH via renderer_set_height, from the
	// same Window_Size_Msg that already carried `h` (signals.odin).
	//
	// Unknown height means NO TRUNCATION AT ALL -- see render_full_screen. That
	// is the same "do not guess with zero information" rule rows_for_line states
	// for an unknown width, and it is what keeps the golden harness (which has no
	// tty and therefore no size) from silently swallowing a view's tail.
	term_height: int,
	// How many PHYSICAL ROWS above HOME the previous renderer_render call left
	// the terminal's cursor, where HOME is column 1 of the row after the last
	// painted row. 0 means "the cursor is at home", which is where the
	// pre-cursor renderer unconditionally left it and what the rewind's column
	// invariant is proved against. See renderer_render for why this exists and
	// how it keeps that proof intact.
	//
	// ALWAYS 0 IN FULL-SCREEN MODE: that path places the cursor with an absolute
	// CUP, so there is no relative offset to remember and nothing to walk back.
	cursor_up:  int,
}

// Which of the two renderers a Renderer is.
//
// .Inline is the ZERO VALUE, so a Renderer (or a Program) written before T2-C
// keeps the rewind renderer with nothing said -- the same opt-in discipline
// term.odin's `kb`/`paste`/`mouse`/`focus`/`alt` defaults follow.
//
// The two are genuinely different renderers, not one with a flag:
//
//   .Inline       Rewinds over the previous frame with \e[1A\e[2K and repaints
//                 in place. Owns no part of the screen, leaves scrollback
//                 intact, and has NO ORIGIN -- a frame sits wherever the
//                 terminal's cursor happened to be. Correct for prompts, menus
//                 and short output.
//   .Full_Screen  Homes with \e[H and paints from the top-left cell every
//                 frame. Owns the whole viewport, so it needs the terminal's
//                 HEIGHT (content past the bottom is truncated -- see
//                 render_full_screen) and it has a fixed, knowable origin, which
//                 is what makes a Mouse_Msg's absolute (x, y) mean something to
//                 an application. Normally paired with the alternate screen
//                 buffer (term_enter_raw's `alt`), though nothing here requires
//                 that -- the first frame's \e[J clears whatever the shell left
//                 below it either way.
Render_Mode :: enum u8 {
	Inline,
	Full_Screen,
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

// `term_height` and `mode` are TRAILING DEFAULTED PARAMETERS for the same
// reason every opt-in in term.odin is (see term_enter_raw): every call site
// written before T2-C keeps compiling and keeps rendering byte for byte.
//
// The mode is fixed AT CONSTRUCTION and never changes afterwards. That is
// deliberate: switching modes mid-session would have to reconcile the inline
// renderer's relative bookkeeping (last_rows, cursor_up, which describe where
// the terminal's cursor physically is) against the full-screen renderer's
// absolute origin, mid-flight, with the previous frame already on screen. An
// application that wants both wants two sessions.
renderer_init :: proc(
	r:           ^Renderer,
	out:         ^strings.Builder,
	term_width:  int         = 0,
	term_height: int         = 0,
	mode:        Render_Mode = .Inline,
) {
	r.out = out
	r.mode = mode
	r.last_rows = 0
	r.term_width = term_width
	r.term_height = term_height
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

// CUP -- "\e[<row>;<col>H". BOTH PARAMETERS ARE 1-BASED, like every other
// terminal coordinate on the wire and unlike everything in this package's own
// API (Cursor.line/col and Mouse_Msg.x/y are all 0-based, deliberately, so an
// app can compare a click against a caret without a conversion). The +1s live
// at the single call site in render_full_screen, next to the clamp that proves
// the values are in range.
@(private = "file")
write_cup :: proc(b: ^strings.Builder, row, col: int) {
	strings.write_string(b, "\e[")
	strings.write_int(b, row)
	strings.write_string(b, ";")
	strings.write_int(b, col)
	strings.write_string(b, "H")
}

// Full-screen: home. Inline: the whole point is that there is no such thing.
@(private = "file")
HOME :: "\e[H"
// EL (erase in line, mode 0): from the cursor to the end of the PHYSICAL row.
@(private = "file")
EL :: "\e[K"
// ED (erase in display, mode 0): from the cursor to the end of the SCREEN.
@(private = "file")
ED :: "\e[J"

// renderer_set_width updates the width used to compute FUTURE rewinds. It
// deliberately does not retroactively touch r.last_rows: that value must keep
// describing what the PREVIOUS renderer_render call actually painted, at
// whatever width was in effect then, so the very next rewind is still
// correct even if a resize lands in between (see the resize-mid-run test).
renderer_set_width :: proc(r: ^Renderer, term_width: int) {
	r.term_width = term_width
}

// The height half of renderer_set_width, with one difference worth stating: a
// height change DOES take effect immediately and completely, because the
// full-screen renderer holds no record of the terminal's cursor position to
// keep consistent -- every frame re-homes. The reason renderer_set_width must
// not retroactively touch last_rows (a mid-run resize would make the very next
// REWIND wrong) simply has no analogue in a mode that never rewinds.
renderer_set_height :: proc(r: ^Renderer, term_height: int) {
	r.term_height = term_height
}

// Turns a Cursor's VIEW coordinates into a physical (row, column) offset within
// the frame that was just painted. SHARED BY BOTH MODES, and that sharing is
// the point rather than an economy: a wide rune before the caret, a caret past
// the terminal's width, and an out-of-range line all have to behave identically
// whether the frame is placed with a relative walk or an absolute CUP. Two
// copies of this arithmetic would be two chances to disagree.
//
// `rows_above` is the number of physical rows painted BEFORE the cursor's
// logical line, accumulated by the caller from the same rows_for_line sum that
// produces last_rows -- the same number, not a second computation.
// `rows_painted` is what the frame actually put on screen, which is what the
// result is clamped into (see each caller for why an out-of-frame answer is
// worse than a merely misplaced one).
//
// Both returned values are 0-BASED offsets within the frame.
@(private = "file")
cursor_cell :: proc(cur: Cursor, rows_above, rows_painted, term_width: int) -> (prow, col: int) {
	// A column past the terminal's width has wrapped onto a continuation row of
	// its own line -- the same arithmetic the terminal itself does, and the same
	// one rows_for_line does. With term_width unknown (0) no wrapping can be
	// assumed, so the column is used as-is: a column past the real last one is
	// clamped by the TERMINAL, harmlessly.
	col = max(cur.col, 0)
	extra := 0
	if term_width > 0 {
		extra = col / term_width
		col   = col % term_width
	}
	prow = clamp(rows_above + extra, 0, rows_painted - 1)
	return
}

// Whether `line` covers every cell of every physical row it occupies, so that an
// EL after it could only ever erase something the line itself just wrote. See
// render_full_screen for why that case is the one place the frame shape is
// conditional, and test_full_screen_omits_el_for_a_line_that_exactly_fills_its
// _row for the pending-wrap hazard it dodges.
//
// UNKNOWN WIDTH ANSWERS false: with no width there is no margin to be flush
// with, and "do not guess" is the same answer rows_for_line gives.
//
// Shares display_width's own limitation, stated rather than hidden: a line whose
// last cell is a WIDE rune straddling the margin measures as flush while the
// terminal actually leaves that final cell blank and wraps the rune. rows_for_line's
// ceil division has exactly the same blind spot, so the two stay consistent with
// each other -- the frame is uniformly one cell optimistic there, rather than
// internally contradictory.
@(private = "file")
line_fills_its_rows :: proc(line: string, term_width: int) -> bool {
	if term_width <= 0 { return false }
	w := display_width(line)
	return w > 0 && w % term_width == 0
}

// `cur` defaults to Cursor{} -- "no cursor declared" -- which emits ZERO extra
// bytes, so every call site written before T2 renders byte for byte as it did.
//
// THE SHARED SHELL OF A FRAME, and nothing else: the DECTCEM hide/show pair,
// the split into logical lines, and the dispatch to whichever renderer this
// Renderer was constructed as. Everything mode-specific lives in
// render_inline/render_full_screen below, so that neither can accidentally
// acquire a byte belonging to the other -- see
// test_inline_mode_emits_no_full_screen_escapes, which pins exactly that.
renderer_render :: proc(r: ^Renderer, view: string, cur := Cursor{}) {
	// HIDE WHILE ANYTHING MOVES. Two things can move the cursor in this frame:
	// placing one (cur.show), and walking last frame's parked one back home
	// (r.cursor_up > 0, inline only). Either way the user would otherwise watch
	// the caret skate up through the rewind and across every repainted row. A
	// frame that does neither writes no DECTCEM at all -- see Cursor's opt-in
	// note, and note that this holds in FULL-SCREEN mode too: a full-screen
	// repaint drags the caret across the whole viewport, but an app that never
	// declared a cursor has not asked us to touch the terminal's cursor state,
	// and the rule "write nothing you were not asked for" outranks the cosmetics.
	hide := cur.show || r.cursor_up > 0
	if hide {
		// ARMED BEFORE THE BYTES CAN LEAVE, exactly like term.odin's
		// kitty_enable/paste_enable set their flags before writing: the window
		// to be wrong in is the one where the terminal has seen the hide and
		// the restore does not know about it.
		cursor_hide_arm()
		strings.write_string(r.out, CURSOR_HIDE)
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

	switch r.mode {
	case .Inline:      render_inline(r, lines, cur)
	case .Full_Screen: render_full_screen(r, lines, cur)
	}

	if hide { strings.write_string(r.out, CURSOR_SHOW) }
}

// THE FULL-SCREEN RENDERER (T2-C). Paints from an absolute origin every frame:
// home, write each line, and clear what the previous frame left. DELIBERATELY
// SHARES NOTHING WITH THE REWIND MACHINERY -- no \e[1A, no walk home, no
// last_rows-driven erase loop -- because absolute positioning is the entire
// point, and a mode that both rewinds and homes would have two sources of truth
// about where the cursor is.
//
// THE SHAPE, and why each piece is where it is:
//
//   \e[H              HOME. Unconditional, first, every frame. This is what
//                     makes the origin knowable -- and what makes the mode
//                     self-healing: whatever a stray write, a resize or a
//                     terminal scroll did to the screen, the next frame starts
//                     from the top-left cell again.
//   <line>\e[K        The paint. EL clears the tail of the row the line ended
//                     on, which is the only place a LONGER previous frame can
//                     still show through once the rows below are cleared.
//                     Skipped when the line is flush with the right margin --
//                     see line_fills_its_rows.
//   \r\n              BETWEEN lines only, never after the last one. A \r\n
//                     written on the bottom row SCROLLS the screen, which slides
//                     every row of the frame off the absolute position this mode
//                     exists to guarantee. The truncation rule below is what
//                     makes "never after the last one" also mean "never on the
//                     bottom row".
//   \r\n\e[J          Clear everything BELOW the frame -- a taller previous
//                     frame's tail, or (on the very first frame, when there is
//                     no alt screen to have cleared it) whatever the shell left
//                     on screen. The \r\n is not decoration: it moves the cursor
//                     off the last painted row before the erase, so ED can only
//                     ever touch rows this frame did not write, and so the erase
//                     is never issued from a pending-wrap position (the hazard
//                     line_fills_its_rows documents). Emitted only when a row
//                     below actually exists.
//
// TRUNCATE AT THE BOTTOM is the policy for content taller than the viewport, and
// it is a policy, not an accident: scrolling is the APPLICATION's job -- exactly
// what rows_for_line's doc comment already establishes for wrapping -- and this
// renderer has no way to know which end of a view the user cares about.
// examples/editor scrolls itself, with its own viewport and its own `top`.
//
// The budget is counted in PHYSICAL ROWS (rows_for_line, the same sum last_rows
// uses), and a line is painted only if ALL of its rows fit. A line that would
// half-fit is dropped entirely rather than allowed to wrap past the bottom,
// because wrapping past the last row scrolls -- so "it does not fit" and "it
// would scroll" are the same condition, and refusing to paint is the only answer
// that keeps the origin true. With an UNKNOWN height (0) there is no budget and
// nothing is dropped.
@(private = "file")
render_full_screen :: proc(r: ^Renderer, lines: []string, cur: Cursor) {
	strings.write_string(r.out, HOME)

	// `cline` is clamped the same way the inline path clamps it, so a negative or
	// past-the-end line index behaves identically in both modes.
	cline      := clamp(cur.line, 0, len(lines) - 1)
	rows       := 0   // physical rows painted so far
	painted    := 0   // logical lines painted so far
	rows_above := 0   // physical rows above the cursor's own logical line
	for line, i in lines {
		need := rows_for_line(line, r.term_width)
		if r.term_height > 0 && rows + need > r.term_height { break }
		if painted > 0 { strings.write_string(r.out, "\r\n") }
		if i == cline { rows_above = rows }
		strings.write_string(r.out, line)
		if !line_fills_its_rows(line, r.term_width) { strings.write_string(r.out, EL) }
		rows    += need
		painted += 1
	}
	// The cursor's line was TRUNCATED AWAY. Point rows_above past the bottom and
	// let cursor_cell's clamp pull it back to the last painted row -- one clamp,
	// in one place, rather than a second rule here that could disagree with it.
	if cline >= painted { rows_above = rows }
	r.last_rows = rows

	switch {
	case painted == 0:
		// Nothing was painted, so the cursor is still at 1;1 (column 1, no
		// pending wrap) and ED from there blanks the whole screen. No \r\n: it
		// would step over the top row and leave it holding the previous frame.
		strings.write_string(r.out, ED)
	case r.term_height <= 0 || rows < r.term_height:
		// A row below the frame exists (or the height is unknown, in which case
		// "do not guess" cuts the other way: a stale tail left on screen is a
		// visible, permanent lie, while the \r\n's worst case is one scroll on a
		// frame that already exactly filled a screen we were never told the size
		// of).
		strings.write_string(r.out, "\r\n")
		strings.write_string(r.out, ED)
	}

	// ABSOLUTE CUP, not the inline mode's relative walk -- simpler, and with no
	// symmetric up/down pair to keep balanced there is nothing here that can
	// desynchronise a later frame. The clamp is still required, for a different
	// reason than inline's: a caret on a line TRUNCATION dropped would otherwise
	// point at a row this frame never wrote.
	if cur.show && painted > 0 {
		prow, col := cursor_cell(cur, rows_above, rows, r.term_width)
		write_cup(r.out, prow + 1, col + 1)
	}
}

// THE INLINE RENDERER -- unchanged by T2-C, byte for byte. Everything below this
// line is the T1/T2-A renderer with its own comments intact; only the enclosing
// proc changed (the hide/show and the line split moved up into renderer_render,
// which emits them in the same order and therefore the same bytes).
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
@(private = "file")
render_inline :: proc(r: ^Renderer, lines: []string, cur: Cursor) {
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
		// The column/row arithmetic lives in cursor_cell, SHARED with the
		// full-screen path so a wide rune before the caret cannot behave
		// differently in the two modes. Clamping into the frame is what keeps
		// this mode's symmetric up/down pair balanced -- see this proc's doc
		// comment on why an out-of-frame `up` would permanently desynchronise
		// home rather than merely misplace the caret. rows >= 1 always
		// (split_lines always yields at least one element), so up >= 1 here.
		prow, col := cursor_cell(cur, rows_above, rows, r.term_width)
		up := rows - prow
		write_csi(r.out, up, "A")
		write_csi(r.out, col + 1, "G")   // CHA is 1-based
		r.cursor_up = up
	}
}

// Tears the current frame down completely: after this the Renderer believes
// nothing is on screen, and the next renderer_render starts from scratch.
renderer_clear :: proc(r: ^Renderer) {
	if r.mode == .Full_Screen {
		// Home and erase to the end of the screen. No rewind and no walk home:
		// this mode parks nothing (cursor_up is always 0) and owns the whole
		// viewport, so there is no relative state to unwind and no reason to
		// erase row by row.
		strings.write_string(r.out, HOME)
		strings.write_string(r.out, ED)
		r.last_rows = 0
		return
	}

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
