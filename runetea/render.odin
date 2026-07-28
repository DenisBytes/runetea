package runetea

import "core:strings"

// Naive inline renderer: rewind over the previous frame and repaint.
//
// Deliberately has no cell buffer and no diffing. At 60fps this pushes ~104 KB/s
// for a completely static screen -- fine locally, unusable over ssh.
//
// T3-A ADDS THE DIFFED CELL RENDERER AS A THIRD MODE (.Diff, below) rather than
// replacing this one. The same ~104 KB/s static screen costs 0 bytes there,
// measured. It is a third mode and not a rewrite of .Full_Screen for the reason
// the spec gives for being afraid of this code at all (§10, §13.1 -- "no oracle
// and fails silently"): the full-screen repaint is the REFERENCE the diff is
// checked against, frame for frame, so it has to keep existing and keep being
// byte-for-byte what it always was. See diff_oracle_test.odin.
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

	// --- T3-A, .Diff ONLY. Untouched (and unallocated) in the other two modes.
	//
	// TWO SCREENS, NOT ONE PLUS A DIFF LIST. `front` selects which of these two
	// holds the state currently ON THE TERMINAL; the other is scratch for the
	// frame being built. They alternate rather than one being copied into the
	// other at the end, so a frame costs one O(cells) copy total -- and that
	// copy is also what compacts the cluster-byte pool (screen_copy).
	// A RENDERER IS USED THROUGH A POINTER AND MUST NOT BE COPIED BY VALUE in
	// .Diff mode: both Screens hold a ^Style_Table pointing at `styles` below,
	// i.e. into this very struct, so a by-value copy would leave the copy's
	// screens interning into the ORIGINAL's table. Nothing in this package
	// copies a Renderer (run() and run_nbio() both keep one local and pass
	// &r everywhere), and render_diff re-establishes the two back-pointers on
	// every frame so that even a copy heals itself on its next render -- but the
	// rule is written down rather than left to be rediscovered.
	screens:      [2]Screen,
	front:        int,
	styles:       Style_Table,
	// Reused across frames so a frame allocates nothing: SGR accumulation
	// scratch, and the per-row dirty mask the emitter expands wide pairs into.
	sgr_scratch:  [dynamic]u8,
	dirty:        [dynamic]bool,
	// False until the two screens have been sized. Also the flag that says
	// "nothing here is allocated", which is what makes renderer_destroy safe to
	// call on a renderer that never ran in diff mode.
	grid_ready:   bool,
	// The next frame must be painted from a known-blank terminal: the first
	// frame, a resize, a renderer_clear, a style-table overflow, or any frame
	// that had to fall back to a plain repaint because the size was unknown.
	// ALWAYS SET, NEVER CLEARED, BY ANYTHING THAT INVALIDATES THE MODEL -- the
	// one rule that keeps "what we think is on screen" from quietly becoming
	// fiction.
	force_repaint: bool,
	// WHERE THE EMITTER BELIEVES THE TERMINAL'S CURSOR AND SGR ARE, as opposed
	// to where the MODEL's cursor is (screens[front].x/y, which tracks what the
	// repaint stream would have done). The two are deliberately separate: the
	// diff writes a completely different byte stream from the repaint, so the
	// only thing that may drive a cursor-move decision is what the diff itself
	// emitted. emit_x may equal cols, meaning "pending wrap" -- which never
	// compares equal to a real column, so the next write always re-homes.
	emit_x:       int,
	emit_y:       int,
	emit_style:   u16,
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
//   .Diff         (T3-A) The SAME frame .Full_Screen paints, delivered as the
//                 minimum set of writes that turns what is already on screen
//                 into it. An identical consecutive frame costs ZERO bytes; a
//                 changed cell costs a cursor move and that cell. Needs the
//                 terminal's width AND height (it is modelling a viewport);
//                 with either unknown it degrades to exactly .Full_Screen's
//                 byte stream for that frame -- see render_diff.
Render_Mode :: enum u8 {
	Inline,
	Full_Screen,
	Diff,
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

	r.grid_ready    = false
	r.force_repaint = true
	r.front         = 0
	r.emit_x, r.emit_y = 0, 0
	r.emit_style    = 0
}

// Releases the cell grids. NO-OP unless this Renderer actually ran in .Diff
// mode with a known size -- the other two modes never allocate, so every call
// site written before T3-A is free to add this (or not) with no behavioural
// change. Safe to call twice, and safe to call on a zero-value Renderer.
//
// This is the only proc in the file that owns memory, and the leak audit in
// tools/test.sh is the reason it is a hard requirement rather than a nicety:
// a diff-mode Renderer that is never destroyed shows up as a new, unallowlisted
// leak site and fails the gate.
renderer_destroy :: proc(r: ^Renderer) {
	if !r.grid_ready { return }
	screen_destroy(&r.screens[0])
	screen_destroy(&r.screens[1])
	style_table_destroy(&r.styles)
	delete(r.sgr_scratch)
	delete(r.dirty)
	r.sgr_scratch = nil
	r.dirty       = nil
	r.grid_ready  = false
	// A destroyed grid is not a valid model of anything; if this Renderer is
	// somehow used again it must repaint from scratch rather than diff against
	// freed state.
	r.force_repaint = true
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
	// In .Diff mode a width change resizes the viewport the cell grid models,
	// and every cell's position within it. Nothing survives that, so the model
	// is discarded and the next frame repaints from a real \e[2J -- the same
	// answer render_diff gives for its own first frame. Set unconditionally
	// rather than only when the value changed: a redundant repaint costs one
	// frame, and a missed one is a permanently wrong screen.
	if r.mode == .Diff && term_width != r.term_width { r.force_repaint = true }
	r.term_width = term_width
}

// The height half of renderer_set_width, with one difference worth stating: a
// height change DOES take effect immediately and completely, because the
// full-screen renderer holds no record of the terminal's cursor position to
// keep consistent -- every frame re-homes. The reason renderer_set_width must
// not retroactively touch last_rows (a mid-run resize would make the very next
// REWIND wrong) simply has no analogue in a mode that never rewinds.
renderer_set_height :: proc(r: ^Renderer, term_height: int) {
	if r.mode == .Diff && term_height != r.term_height { r.force_repaint = true }
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
	// THE LINE SPLIT MOVED ABOVE THE DECTCEM PAIR (T3-A) and emits no bytes, so
	// the output is unchanged for both older modes. .Diff needs the lines before
	// it can decide whether this frame writes anything at all -- and that
	// decision is what its own hide/show is conditioned on (a hidden-then-shown
	// cursor around zero painting would cost 12 bytes on an identical frame,
	// which is the entire point of the mode).
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

	if r.mode == .Diff {
		render_diff(r, lines, cur)
		return
	}

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

	switch r.mode {
	case .Inline:      render_inline(r, lines, cur)
	case .Full_Screen: render_full_screen(r, lines, cur)
	case .Diff:        unreachable()   // handled above, before the DECTCEM pair
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
	rows, _ := paint_frame(r.out, nil, nil, lines, cur, r.term_width, r.term_height)
	r.last_rows = rows
}

// THE FULL-SCREEN FRAME, EMITTED AND/OR MODELLED (T3-A split this out of
// render_full_screen; the byte stream is unchanged, statement for statement).
//
// `out != nil` writes the repaint's bytes. `scr != nil` applies the SAME frame
// to a cell model -- the terminal operation each byte sequence stands for, in
// the same order. Both may be non-nil; either may be nil.
//
// WHY ONE PROC AND NOT TWO. The diff renderer's target grid must be exactly
// "the screen the full-screen repaint would have produced". Written as two
// procedures -- one emitting bytes, one laying out cells -- those two would be a
// pair of hand-maintained transcriptions of the same frame shape, and the day
// they disagreed the diff would render a screen the repaint never would, with
// nothing to notice. Here every frame decision (which lines fit, where the
// \r\n goes, whether the EL is emitted, whether the trailing \r\n\e[J is) is
// made ONCE and fed to both sinks, so they cannot drift apart. What the byte
// stream MEANS -- what \e[K does to a row, what \r\n does at the bottom of the
// screen -- is not shared, and that is precisely what the diff oracle checks:
// it replays the real bytes through an independent emulator (diff_oracle_test)
// and compares against what the diff renderer, driven by this model, produced.
//
// Returns the physical row count (Renderer.last_rows' value) and ok=false if
// the style table overflowed while modelling (the caller forces a repaint).
@(private = "file")
paint_frame :: proc(
	out:     ^strings.Builder,
	scr:     ^Screen,
	scratch: ^[dynamic]u8,
	lines:   []string,
	cur:     Cursor,
	term_width, term_height: int,
) -> (rows: int, ok: bool) {
	ok = true
	if out != nil { strings.write_string(out, HOME) }
	if scr != nil { screen_goto(scr, 0, 0) }

	// `cline` is clamped the same way the inline path clamps it, so a negative or
	// past-the-end line index behaves identically in both modes.
	cline      := clamp(cur.line, 0, len(lines) - 1)
	painted    := 0   // logical lines painted so far
	rows_above := 0   // physical rows above the cursor's own logical line
	for line, i in lines {
		need := rows_for_line(line, term_width)
		if term_height > 0 && rows + need > term_height { break }
		if painted > 0 {
			if out != nil { strings.write_string(out, "\r\n") }
			if scr != nil { screen_cr(scr); screen_index(scr) }
		}
		if i == cline { rows_above = rows }
		if out != nil { strings.write_string(out, line) }
		if scr != nil {
			if !screen_write(scr, line, scratch) { ok = false }
		}
		if !line_fills_its_rows(line, term_width) {
			if out != nil { strings.write_string(out, EL) }
			if scr != nil { screen_el0(scr) }
		}
		rows    += need
		painted += 1
	}
	// The cursor's line was TRUNCATED AWAY. Point rows_above past the bottom and
	// let cursor_cell's clamp pull it back to the last painted row -- one clamp,
	// in one place, rather than a second rule here that could disagree with it.
	if cline >= painted { rows_above = rows }

	switch {
	case painted == 0:
		// Nothing was painted, so the cursor is still at 1;1 (column 1, no
		// pending wrap) and ED from there blanks the whole screen. No \r\n: it
		// would step over the top row and leave it holding the previous frame.
		if out != nil { strings.write_string(out, ED) }
		if scr != nil { screen_ed0(scr) }
	case term_height <= 0 || rows < term_height:
		// A row below the frame exists (or the height is unknown, in which case
		// "do not guess" cuts the other way: a stale tail left on screen is a
		// visible, permanent lie, while the \r\n's worst case is one scroll on a
		// frame that already exactly filled a screen we were never told the size
		// of).
		if out != nil { strings.write_string(out, "\r\n"); strings.write_string(out, ED) }
		if scr != nil { screen_cr(scr); screen_index(scr); screen_ed0(scr) }
	}

	// ABSOLUTE CUP, not the inline mode's relative walk -- simpler, and with no
	// symmetric up/down pair to keep balanced there is nothing here that can
	// desynchronise a later frame. The clamp is still required, for a different
	// reason than inline's: a caret on a line TRUNCATION dropped would otherwise
	// point at a row this frame never wrote.
	if cur.show && painted > 0 {
		prow, col := cursor_cell(cur, rows_above, rows, term_width)
		if out != nil { write_cup(out, prow + 1, col + 1) }
		if scr != nil { screen_goto(scr, col, prow) }
	}
	return
}

// ============================================================================
// THE DIFF RENDERER (T3-A)
// ============================================================================
//
// WHAT IT IS: .Full_Screen's frame, delivered as the smallest set of writes
// that turns the screen already in front of the user into it. The frame itself
// -- which lines fit, where they wrap, what gets erased -- is decided by
// paint_frame, the SAME proc that emits .Full_Screen's bytes, driving a cell
// model instead of (or as well as) a byte stream. So this mode never invents a
// frame of its own; it only re-delivers .Full_Screen's.
//
// WHY THAT SPLIT IS THE WHOLE DESIGN. The spec's warning (§10, §13.1) is that a
// diff renderer "has no oracle and fails silently". It has one here, and this
// is what makes the oracle possible: the reference output for any frame
// sequence is just the same sequence through .Full_Screen, and the invariant is
// "replaying the diff bytes through a VT100 lands on exactly the same screen
// and cursor as replaying the repaint bytes". That is checked, fuzzed, over
// hundreds of random frame sequences, in diff_oracle_test.odin -- and
// independently against pyte (a third-party VT100 emulator) by tools/difftest.
//
// WHAT IT COSTS ON THE WIRE:
//   identical consecutive frame ....... 0 bytes
//   one changed cell .................. a cursor move + that cell
//   a cleared tail .................... a cursor move + \e[K
//   nothing ever re-sent that is already on screen.
//
// WHAT IT COSTS IN CPU: one O(cols*rows) copy plus one O(cols*rows) compare per
// frame, whether or not anything changed. That is the deliberate trade -- the
// resource this mode exists to conserve is the TERMINAL LINK (104 KB/s of
// repaint at 60fps is unusable over ssh), not the local CPU.
//
// KNOWN LIMITS, stated rather than discovered later:
//   * NEEDS A KNOWN WIDTH AND HEIGHT. It models a viewport; without one there
//     is nothing to model. With either unknown the frame degrades to
//     .Full_Screen's exact byte stream and the model is invalidated, so the
//     first frame after a size arrives repaints in full.
//   * VIEWS MAY CONTAIN STYLING, NOT MOTION. SGR escapes are tracked per cell.
//     Any other escape (cursor movement, OSC, DCS) is consumed for width
//     purposes -- exactly as display_width already does -- and otherwise
//     ignored, which means a view that moves the terminal's cursor itself is
//     lying to the model. .Full_Screen tolerates that; this mode cannot.
//   * A WIDE CLUSTER LANDING ON THE RIGHT MARGIN is modelled as written IN that
//     column (see screen.odin's header). xterm-family terminals instead leave
//     the cell blank and wrap the cluster. This is the same one-cell optimism
//     rows_for_line and line_fills_its_rows have always had, not a new one.

// Fault injection for the oracle's non-vacuity proof. "" -- the default, and
// what every real build compiles -- costs nothing: each site below is a `when`
// on a compile-time constant, so the faults are not present in the binary at
// all. See diff_oracle_test.odin for what each one is supposed to break and the
// test that proves the oracle catches it.
//
//   repaint      the "diff" is a plain full repaint. MUST STILL PASS -- this is
//                the control that proves the harness works before it has to
//                catch anything.
//   skip_cell    drops the last changed cell of every row.
//   drop_style   never re-emits SGR.
//   narrow_wide  advances the cursor by one column after a wide cluster.
//   no_pair_expand  drops the wide-cell expansion in emit_row. MUST NOT
//                DIVERGE, and that is a finding, not an oversight -- see
//                emit_row's own note on why the expansion is currently
//                provably inert, and diff_oracle_test for the assertion that
//                pins it.
//   no_cursor    never issues the frame's final cursor move.
DIFF_FAULT :: #config(RUNETEA_DIFF_FAULT, "")

// SGR reset. Named because the diff emitter's entire style discipline rests on
// "the accumulated style bytes reproduce the style exactly WHEN APPLIED TO A
// DEFAULT TERMINAL" -- so every transition out of a non-default style goes
// through this constant first.
@(private = "file")
SGR_RESET :: "\e[0m"
// ED (erase in display, mode 2): the whole screen, cursor unmoved.
@(private = "file")
ED2 :: "\e[2J"

// A run of UNCHANGED cells shorter than this is rewritten rather than skipped:
// a CHA (\e[<n>G) costs 4-6 bytes, so hopping over three unchanged narrow cells
// costs more than repainting them. Only ever applied to runs of width-1 cells
// (see emit_row) -- hopping is mandatory across a wide cluster, where rewriting
// half of one is not a cheaper way to do the same thing, it is a corruption.
@(private = "file")
GAP_MERGE_MAX :: 4

// \e[K is used instead of writing spaces only when it replaces at least this
// many cell writes. Below that it is pure overhead (3 bytes plus a possible SGR
// reset, against 1 byte per space).
@(private = "file")
EL_MIN_RUN :: 4

@(private = "file")
render_diff :: proc(r: ^Renderer, lines: []string, cur: Cursor, allow_retry := true) {
	when DIFF_FAULT == "repaint" {
		// INJECTED FAULT (control case): not a diff at all. The oracle must
		// still pass -- see this file's DIFF_FAULT note.
		rows, _ := paint_frame(r.out, nil, nil, lines, cur, r.term_width, r.term_height)
		r.last_rows     = rows
		r.force_repaint = true
		return
	} else {

	// NO SIZE, NO VIEWPORT, NO MODEL. Same "do not guess" rule rows_for_line
	// states for an unknown width -- and the same consequence: the frame is
	// simply .Full_Screen's, byte for byte, including its DECTCEM pair. The
	// model is invalidated so that the first frame after a real size arrives
	// (a Window_Size_Msg, or the initial term_size in run()) repaints in full
	// rather than diffing against a screen it never modelled.
	if r.term_width <= 0 || r.term_height <= 0 {
		hide := cur.show
		if hide { cursor_hide_arm(); strings.write_string(r.out, CURSOR_HIDE) }
		rows, _ := paint_frame(r.out, nil, nil, lines, cur, r.term_width, r.term_height)
		r.last_rows = rows
		if hide { strings.write_string(r.out, CURSOR_SHOW) }
		r.force_repaint = true
		return
	}

	diff_grid_ensure(r)
	// See Renderer.screens: cheap insurance against a by-value copy, two stores
	// a frame.
	r.screens[0].styles = &r.styles
	r.screens[1].styles = &r.styles

	prev := &r.screens[r.front]
	cur_s := &r.screens[1 - r.front]

	// Captured BEFORE it is cleared: everything downstream (whether the frame
	// counts as "changed", whether the \e[2J prologue is written) keys off the
	// value this frame started with.
	repaint := r.force_repaint
	if repaint {
		// After the prologue below the terminal is provably blank, at the
		// default SGR, cursor home. Making the model say the same thing is what
		// re-synchronises the two.
		screen_blank(prev)
		r.emit_x, r.emit_y = 0, 0
		r.emit_style       = 0
		r.force_repaint    = false
	}

	// cur_s starts as what is on screen and has this frame applied to it, in
	// exactly the operations .Full_Screen's bytes stand for. Starting from the
	// PREVIOUS state rather than from blank is not an optimisation: the repaint
	// does not rewrite every cell in every case (a line flush with the right
	// margin emits no \e[K; a frame that fills the viewport emits no trailing
	// \e[J), so "what is on screen afterwards" genuinely depends on what was on
	// screen before.
	screen_copy(cur_s, prev)
	rows, ok := paint_frame(nil, cur_s, &r.sgr_scratch, lines, cur, r.term_width, r.term_height)
	r.last_rows = rows

	if !ok {
		// The style table overflowed (STYLE_TABLE_MAX). Interning any further
		// style would have to alias it onto an existing index, which would make
		// two visibly different cells compare equal -- a silent wrong screen,
		// the exact failure mode this whole design exists to avoid. Drop the
		// table, force a repaint, and redo the frame from scratch. `allow_retry`
		// bounds this at one: a single frame containing more than
		// STYLE_TABLE_MAX distinct styles would otherwise recurse forever.
		if allow_retry {
			diff_styles_reset(r)
			render_diff(r, lines, cur, allow_retry = false)
			return
		}
	}

	// The cursor the frame asks for, in terminal terms. min(): the model allows
	// x == cols (DECAWM pending wrap), which is a state no absolute move can
	// reproduce -- and does not need to be, since the next frame's first write
	// always issues its own absolute move. See the oracle's cursor comparison.
	tx := min(cur_s.x, r.term_width - 1)
	ty := cur_s.y

	// WHETHER THIS FRAME WRITES ANYTHING AT ALL, decided before a byte is
	// emitted -- because the DECTCEM pair has to go OUTSIDE the painting, and a
	// hide/show around zero painting would cost 12 bytes on an identical frame.
	changed := repaint || (tx != r.emit_x) || (ty != r.emit_y) || screens_differ(prev, cur_s)

	hide := cur.show && changed
	if hide {
		// ARMED BEFORE THE BYTES CAN LEAVE, exactly as renderer_render does.
		cursor_hide_arm()
		strings.write_string(r.out, CURSOR_HIDE)
	}

	if repaint {
		// SGR first: \e[2J erases with the ACTIVE background, so clearing under
		// an unknown (or coloured) style would paint the screen that colour.
		strings.write_string(r.out, SGR_RESET)
		strings.write_string(r.out, HOME)
		strings.write_string(r.out, ED2)
	}

	for y in 0 ..< cur_s.rows { emit_row(r, y, prev, cur_s) }

	when DIFF_FAULT != "no_cursor" {
		// UNCONDITIONAL, and cheap: diff_move writes nothing when the cursor is
		// already there, which on an identical frame it always is. This is the
		// only thing that keeps the cursor in step with what the repaint would
		// have left behind even when the app declares no cursor at all -- the
		// repaint parks it after its trailing \e[J, and "the same screen" is not
		// the same screen if the caret is somewhere else.
		diff_move(r, tx, ty)
	}

	if hide { strings.write_string(r.out, CURSOR_SHOW) }

	// The frame just painted IS the screen now.
	r.front = 1 - r.front
	}
}

// Allocates (or re-allocates) the two grids for the current size. Any size
// change discards both and forces a repaint: every cell's position, and whether
// it exists at all, is a function of the viewport.
@(private = "file")
diff_grid_ensure :: proc(r: ^Renderer) {
	w, h := r.term_width, r.term_height
	if r.grid_ready && r.screens[0].cols == w && r.screens[0].rows == h { return }
	if !r.grid_ready {
		style_table_init(&r.styles)
		r.grid_ready = true
	}
	screen_init(&r.screens[0], w, h, &r.styles)
	screen_init(&r.screens[1], w, h, &r.styles)
	resize(&r.dirty, w)
	r.front         = 0
	r.force_repaint = true
}

@(private = "file")
diff_styles_reset :: proc(r: ^Renderer) {
	style_table_destroy(&r.styles)
	style_table_init(&r.styles)
	screen_blank(&r.screens[0])
	screen_blank(&r.screens[1])
	r.force_repaint = true
}

@(private = "file")
screens_differ :: proc(a, b: ^Screen) -> bool {
	for i in 0 ..< len(b.cells) {
		if !cell_eq(a, a.cells[i], b, b.cells[i]) { return true }
	}
	return false
}

// Moves the terminal's cursor to (x, y), 0-based, writing nothing if it is
// already there. THE ONLY PLACE r.emit_x/emit_y are advanced by a move.
//
// \r for column 0 (1 byte) beats CHA (4+); CHA for any other column on the
// CURRENT row beats CUP; CUP for a row change. No CUU/CUD/CUF/CUB: they save at
// most a byte or two over CHA and each one is a separate chance to be off by
// one against a terminal's own clamping. This is the "start with CUP + writes +
// EL and measure" the brief asks for, and the measurements are in the report --
// the remaining repertoire buys single-digit percentages against a baseline
// that is already ~99% smaller than a repaint.
@(private = "file")
diff_move :: proc(r: ^Renderer, x, y: int) {
	if r.emit_y == y && r.emit_x == x { return }
	if r.emit_y == y {
		if x == 0 {
			// CR also clears a pending wrap, which is the state emit_x == cols
			// records -- so this is correct there too, not merely cheap.
			strings.write_string(r.out, "\r")
		} else {
			write_csi(r.out, x + 1, "G")   // CHA is 1-based
		}
	} else {
		write_cup(r.out, y + 1, x + 1)
	}
	r.emit_x, r.emit_y = x, y
}

// Brings the terminal's SGR to style `s`, writing nothing if it is already
// there.
//
// ALWAYS VIA THE DEFAULT. A style is stored as the bytes accumulated since the
// last reset (see Style_Table), so applying it to a DEFAULT terminal reproduces
// it exactly -- and applying it to some other style does not. Hence: reset
// first unless we are already at the default. Costs 4 bytes per style
// transition and removes an entire class of "the leftover attribute from three
// cells ago is still on" bugs.
@(private = "file")
diff_style :: proc(r: ^Renderer, s: u16) {
	when DIFF_FAULT == "drop_style" {
		// INJECTED FAULT: the emitter never re-establishes a cell's style.
		return
	} else {
	if r.emit_style == s { return }
	if r.emit_style != 0 { strings.write_string(r.out, SGR_RESET) }
	if s != 0 { strings.write_string(r.out, style_bytes(&r.styles, s)) }
	r.emit_style = s
	}
}

// Emits whatever it takes to turn row `y` of `prev` into row `y` of `cur`.
// Writes NOTHING when the row is unchanged -- the property the whole mode
// exists for.
@(private = "file")
emit_row :: proc(r: ^Renderer, y: int, prev, cur: ^Screen) {
	cols := cur.cols
	base := y * cols

	any_dirty := false
	for x in 0 ..< cols {
		d := !cell_eq(prev, prev.cells[base + x], cur, cur.cells[base + x])
		r.dirty[x] = d
		if d { any_dirty = true }
	}
	if !any_dirty { return }

	// THE WIDE-CELL INVARIANT, and the one place it is enforced.
	//
	// A wide cluster owns TWO columns and is a single, indivisible write. Two
	// separate hazards, both of which this expansion closes:
	//
	//   * Writing the head. It consumes both columns, so the second column is
	//     rewritten whether the diff intended it or not -- it must therefore be
	//     part of the region the diff is responsible for, or the emitter's idea
	//     of the cursor's column goes wrong immediately after it.
	//   * OVERWRITING a wide cluster that was already there. Painting a narrow
	//     cell over the LEFT half leaves the right half in a state the standards
	//     do not fix (xterm blanks both; others leave a stray half-glyph). The
	//     only portable answer is to repaint BOTH columns explicitly, so that
	//     whatever the terminal did with the first write is overwritten by the
	//     second. Painting over the RIGHT half is the mirror image and needs the
	//     head repainted for the same reason.
	//
	// Hence: any dirty column drags in the other half of its pair, in EITHER
	// frame, to a fixpoint (a single pass can only propagate one step, and a
	// newly-dirtied column can itself be half of a pair in the other frame).
	//
	// AND IT IS, TODAY, PROVABLY INERT -- measured, not assumed. Removing it
	// (DIFF_FAULT=no_pair_expand) changes not one byte of output across the
	// whole fuzz corpus and every hand-written wide-cell test. The reason is a
	// global invariant the model happens to maintain: a continuation cell exists
	// if and only if the cell to its left is a wide head, and both are written
	// by the same screen_put with the same style -- so the two halves can never
	// differ from the previous frame independently, and the "one half dirty,
	// the other clean" state this loop exists to fix is unreachable.
	//
	// IT STAYS ANYWAY, for two reasons worth writing down rather than deleting
	// six lines over. That invariant is global (it depends on every erase and
	// every write in screen.odin agreeing about pairs), while this loop makes
	// the emitter's wide-cell correctness LOCAL -- true by inspection of this
	// proc alone. And the hazard it names is real on real hardware even when the
	// model cannot express it: no cell model represents what an actual xterm
	// does to the far half of a wide glyph when you write over the near one, so
	// "always repaint both halves" is the only rule that does not depend on
	// which terminal is on the other end of the socket.
	when DIFF_FAULT != "no_pair_expand" {
	for {
		grew := false
		for x in 0 ..< cols {
			if !r.dirty[x] { continue }
			if x + 1 < cols {
				if (cur.cells[base + x].width == 2 || prev.cells[base + x].width == 2) && !r.dirty[x + 1] {
					r.dirty[x + 1] = true
					grew = true
				}
			}
			if x > 0 {
				if (cur.cells[base + x].width == 0 || prev.cells[base + x].width == 0) && !r.dirty[x - 1] {
					r.dirty[x - 1] = true
					grew = true
				}
			}
		}
		if !grew { break }
	}
	}

	first := 0
	for !r.dirty[first] { first += 1 }
	last := cols - 1
	for !r.dirty[last] { last -= 1 }

	// \e[K OPPORTUNITY. `tail` is the leftmost column from which this frame's
	// row is blank-at-the-default-style all the way to the right margin -- which
	// is exactly the state \e[K leaves behind, provided the SGR is default when
	// it runs (\e[K erases with the ACTIVE background). A non-default blank tail
	// is deliberately NOT eligible: whether an erase records underline, strike
	// or only the background is terminal-dependent, so those cells are written
	// as real spaces instead. That is the "if you scope styling down, say what
	// you did" line, and this is the one place it is scoped down.
	tail := cols
	for tail > 0 {
		c := cur.cells[base + tail - 1]
		if c.len != 0 || c.width != 1 || c.style != 0 { break }
		tail -= 1
	}
	use_el := false
	el_at  := 0
	if tail <= last {
		// Erasing from before the first change is harmless (those cells already
		// hold what \e[K would leave) but pointless, so start no earlier.
		el_at = max(tail, first)
		if last - el_at + 1 >= EL_MIN_RUN { use_el = true }
	}
	write_end := last
	if use_el { write_end = el_at - 1 }

	x := first
	for x <= write_end {
		if !r.dirty[x] {
			// A run of cells that did not change. Hop over it if that is
			// cheaper than rewriting it -- and ALWAYS hop if it contains any
			// part of a wide cluster, because "rewriting an unchanged cell" is
			// only a no-op for a cell that owns exactly one column.
			j := x
			for j <= write_end && !r.dirty[j] { j += 1 }
			narrow := true
			for k in x ..< j {
				if cur.cells[base + k].width != 1 { narrow = false; break }
			}
			if !narrow || j - x > GAP_MERGE_MAX {
				x = j
				continue
			}
		}
		c := cur.cells[base + x]
		if c.width == 0 {
			// The right half of a wide cluster. Its head was dirty too (the
			// expansion above guarantees it) and painting the head already
			// covered this column.
			x += 1
			continue
		}
		when DIFF_FAULT == "skip_cell" {
			// INJECTED FAULT: the last changed cell of the row is never sent.
			if x == last { x += max(int(c.width), 1); continue }
		}
		diff_move(r, x, y)
		diff_style(r, c.style)
		if c.len == 0 {
			// A blank is painted as a space. Indistinguishable on screen, and
			// the model normalises the two (see put_cell), so this cannot make
			// the next frame think the cell changed.
			strings.write_string(r.out, " ")
		} else {
			strings.write_string(r.out, cell_bytes(cur, c))
		}
		when DIFF_FAULT == "narrow_wide" {
			// INJECTED FAULT: a wide cluster is treated as one column wide.
			r.emit_x = min(x + 1, cols)
		} else {
			r.emit_x = min(x + int(c.width), cols)
		}
		x += max(int(c.width), 1)
	}

	if use_el {
		diff_move(r, el_at, y)
		diff_style(r, 0)
		strings.write_string(r.out, EL)
		// \e[K does not move the cursor.
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
	if r.mode == .Diff {
		// Same bytes .Full_Screen writes, plus an SGR reset when one is needed:
		// \e[J erases with the ACTIVE background, and this mode is the only one
		// that can knowingly be sitting in a non-default style.
		if r.emit_style != 0 {
			strings.write_string(r.out, SGR_RESET)
			r.emit_style = 0
		}
		strings.write_string(r.out, HOME)
		strings.write_string(r.out, ED)
		// The model must say what the terminal now is: blank, cursor home.
		if r.grid_ready {
			screen_blank(&r.screens[0])
			screen_blank(&r.screens[1])
		}
		r.emit_x, r.emit_y = 0, 0
		r.last_rows = 0
		return
	}

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
