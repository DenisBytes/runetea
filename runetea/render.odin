package runetea

import "core:strings"
import "core:sync"

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
	// that never supplied one).
	//
	// READ BY ALL THREE PATHS, and it means something different in the inline
	// one. .Full_Screen/.Diff use it as a VIEWPORT BUDGET and truncate content
	// past it. .Inline still truncates nothing -- its frames sit wherever the
	// terminal happened to be and scroll the way any other program's output does
	// -- but it needs the height to know how far a \e[<n>A can actually reach,
	// because CUU clamps at the top margin and anything scrolled past it is
	// unreachable forever. See render_inline's "A FRAME TALLER THAN THE SCREEN".
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

	// Whether the PREVIOUS frame left the terminal in a non-default SGR -- i.e.
	// whether the view's last painted line ended inside a style run it never
	// closed. Tracked in ALL THREE MODES, from the same predicate
	// (line_leaves_open), because all three used to amplify one unclosed escape
	// into a whole-region colour flood and each did it a different way:
	//
	//   .Inline       \e[1A\e[2K per row, with the leftover pen still set. \e[2K
	//                 erases with the ACTIVE background (BCE), so every row of
	//                 the frame region was erased to that colour and then
	//                 repainted in it, every frame, forever.
	//   .Full_Screen  the trailing \e[J did the same thing to every row BELOW
	//                 the frame, i.e. the rest of the screen.
	//   .Diff         worse than either, and it needed no BCE to do it: the
	//                 model's own `style` carried across frames (screen_copy
	//                 copies it), so screen_ed0 blanked with the leaked pen and
	//                 the diff then wrote those blanks out as literal spaces
	//                 under an open SGR. A measured probe floods a 46x10 screen
	//                 solid red on every terminal, not just BCE ones.
	//
	// The fix is one rule, applied in one place (paint_frame, plus the inline
	// rewind): A FRAME STARTS FROM THE DEFAULT SGR. This flag is what keeps
	// that rule from costing anything -- a view that closes its styles (every
	// RuneGloss-rendered view, and every byte-exact expectation in this
	// package) never sets it, so not one extra byte is written and the output
	// is unchanged.
	pen_open:   bool,
	// The OSC 8 half of pen_open, tracked separately because the two planes are
	// independent (\e[0m does not close a hyperlink). Same flood, one step
	// nastier: a view that leaves a link open does not merely tint what comes
	// next, it makes it CLICKABLE -- the whole of the following frame, and the
	// user's shell after the program exits. It is also the half the fuzz corpus
	// caught the moment it learned to resize: .Diff's forced repaint closes the
	// link and blanks its model while .Full_Screen carried it, so after any
	// resize the two modes rendered the same view with different link state.
	link_open:  bool,
	// Whether THIS renderer has hidden the terminal's caret and not shown it
	// again. Only .Full_Screen and .Diff set it -- see renderer_render's
	// "HIDE FOR THE DURATION OF A PAINT" note for why the mode that owns the
	// viewport gets a different answer from the mode that does not.
	//
	// The teardown is term.odin's, not this file's: cursor_hide_arm() makes
	// term_restore (and guard.odin's crash handler) write "\e[?25h" on every
	// exit path including a signal, which is the only place that can be made
	// safe. renderer_clear shows it too, for the orderly path.
	caret_hidden: bool,

	// F53. TRUE MEANS THIS RENDERER MAY NOT WRITE AN ESCAPE SEQUENCE AT ALL --
	// not CUP, not \e[H, not \e[2J, not \e[K, not SGR, and not the view's own
	// escapes either. The terminal has declared it has no capabilities
	// (term.odin's term_supports_escapes: TERM=dumb, TERM= or no TERM), so every
	// byte of that repertoire is rendered LITERALLY on screen.
	//
	// FALSE IS THE ZERO VALUE, so a Renderer constructed directly -- every test
	// in this package, tools/difftest, any embedder driving renderer_render
	// itself -- renders byte for byte as it always did, with no environment in
	// the loop. Deciding this from getenv inside renderer_init was the obvious
	// shape and is the wrong one: it makes the output of a pure function of
	// (view, width, mode) depend on the shell the test suite happens to run
	// under, so `TERM=dumb odin test runetea` would have failed a hundred
	// byte-exact assertions for reasons that have nothing to do with what they
	// assert.
	//
	// SET BY THE HOST, ONCE PER FRAME, from guarded_render (tea.odin) -- the one
	// paint path run() and run_nbio() share, which is what stops the two hosts
	// degrading differently. Re-read rather than cached for the same reason
	// term_supports_escapes itself is not cached: the environment is the answer,
	// and a copy of it is a second source of truth. Measured cost of the read:
	// 82 ns per getenv("TERM") (1M calls, -o:speed, this machine), i.e. 5 us per
	// second of wall clock at 60 frames.
	plain:        bool,

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
	// T3-C. The OSC 8 hyperlink payloads any cell may point at, interned on the
	// same terms and for the same reasons as `styles` -- see Style_Table. A
	// second table rather than a shared one: index 0 has to mean "no link" here
	// and "default SGR" there, and an overflow in one must not drop the other.
	links:        Style_Table,
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
	// The hyperlink the emitter believes is OPEN on the terminal, on exactly the
	// same terms as emit_style. 0 == none open.
	emit_link:    u16,
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
// `show` false -- THE ZERO VALUE -- means "no cursor declared". WHAT THAT NOW
// MEANS DEPENDS ON THE MODE, and the split is deliberate:
//
//   .Inline       Unchanged, and byte-for-byte the pre-T2 output: a frame with
//                 no cursor declared and none left over from the previous frame
//                 writes ZERO extra bytes. This mode owns no part of the
//                 screen, composes with whatever the shell printed before it,
//                 and rests the caret below its output where any other
//                 program's would be. Touching the terminal's cursor state on
//                 its own initiative would be taking over something the mode
//                 does not own -- but the APPLICATION may still declare
//                 term_enter_raw's Term_Opts{cursor_hide = true}, and then this
//                 mode hides the caret and keeps it hidden on exactly the terms
//                 the two below do. The decision belongs to the layer that
//                 owns the terminal, which for .Inline is not this one.
//   .Full_Screen  The caret is HIDDEN and stays hidden. These modes own the
//   .Diff         whole viewport, and the old answer -- "a program that never
//                 asks for a cursor must not have its output changed" -- put a
//                 blinking block in the middle of every dashboard, list and log
//                 viewer that has no text field in it, dragged it across all 24
//                 rows on every repaint, and offered no way to opt out
//                 (Cursor{show = false} is the zero value and reads as "no
//                 opinion"). It costs six bytes, once, for the session.
//
// Either way the terminal is not LEFT in a state this process entered: the hide
// arms term.odin's cursor_hide_arm, so term_restore, the crash handlers and the
// SIGTSTP path all write the matching "\e[?25h".
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
	r.pen_open  = false
	r.link_open = false
	// A fresh Renderer has not touched DECTCEM, so the caret is whatever the
	// terminal had it as -- which is "visible" for every terminal anyone has
	// ever shipped, and in any case not ours to assume otherwise about.
	r.caret_hidden = false
	// NOT term_supports_escapes(). See Renderer.plain: the environment is the
	// HOST's to read, on the frame path both hosts share, so that constructing a
	// Renderer stays deterministic.
	r.plain = false

	r.grid_ready    = false
	r.force_repaint = true
	r.front         = 0
	r.emit_x, r.emit_y = 0, 0
	r.emit_style    = 0
	r.emit_link     = 0
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
	style_table_destroy(&r.links)
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

// THE SCREEN UNDER US IS GONE -- ask the next frame to repaint from scratch.
//
// WHAT THIS IS FOR, and it is one specific hole rather than a general knob.
// guard.odin stops the process on SIGTSTP and rebuilds the terminal on the way
// back, and its resume used to kick a synthetic SIGWINCH so that run()'s
// Signal_Watcher would deliver a Window_Size_Msg "in case the window changed".
// That covers .Full_Screen and .Inline, which repaint or rewind every frame
// anyway. It does NOT cover .Diff: renderer_set_width/renderer_set_height only
// set force_repaint when the size actually CHANGED, so a `fg` at an UNCHANGED
// size resumed into a diff against a cell model that still described the frame
// from before the stop -- while the user's shell had, in the meantime, printed
// its prompt and their next command's output on top of it. The diff then
// patched only the cells the model thought had changed and left the shell's
// text on screen FOREVER, for the rest of the session. That is the same
// permanent-corruption class the stop handling itself was written to fix, and
// the resume was fixing only two thirds of it.
//
// A PROCESS-GLOBAL FLAG RATHER THAN A CALL ON THE RENDERER, because the callers
// that need it are signal handlers: guard.odin's tstp_handler and cont_handler
// are `proc "c"` with no arguments and no way to reach run()'s Renderer, which
// lives on run()'s stack. An atomic store to a package global is the one thing
// they can safely do (write(2)-class safety: a single instruction, no
// allocation, no locks, nothing the interrupted thread can be holding).
//
// PUBLIC, because the framework is not the only thing that can lose the screen.
// An application that shells out -- $EDITOR, `less`, a `git` pager, anything
// that paints -- comes back to exactly the same wreckage, and before this there
// was no way to say so. It is idempotent and cheap: the next frame consumes it.
//
// The flag is CONSUMED, not cleared by its setter, so a request that arrives
// mid-frame is honoured by the FOLLOWING frame rather than lost. Signal handlers
// interrupt a thread at an arbitrary instruction, including one inside
// renderer_render.
@(private = "file")
g_repaint_request: bool

request_repaint :: proc "contextless" () {
	sync.atomic_store(&g_repaint_request, true)
}

// Reads and clears in one operation, so two frames cannot both consume one
// request and -- more importantly -- a request landing between a plain load and
// a plain store cannot be dropped.
@(private = "file")
repaint_request_take :: proc "contextless" () -> bool {
	return sync.atomic_exchange(&g_repaint_request, false)
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

// What a line painted with the terminal already in state (`pen`, `link`) leaves
// those two planes in. The predicate behind Renderer.pen_open/link_open; see
// pen_open for what an unclosed style used to cost in each of the three modes.
//
// TWO PLANES, TRACKED SEPARATELY, because that is what they are: "\e[0m" does
// not close an OSC 8 hyperlink and an OSC 8 close does not reset SGR. Folding
// them into one "is anything open" flag would emit a link close for a frame
// that only left a colour set, which is 6 bytes of nothing on the common path.
//
// THE SGR RULE IS screen_sgr's, DELIBERATELY AND EXACTLY: an SGR whose
// parameter string is empty or "0" resets, and every other SGR leaves state
// set. Not "\e[0m closes whatever \e[31m opened" -- "\e[39m" (default
// foreground) is a perfectly good way to end a colour run on the wire and this
// reports it as still-set, because that is what the .Diff cell model believes
// too. The two must agree: the model erases with `style` and this decides
// whether the wire gets a reset before the erase, and a disagreement there is
// precisely the class of bug (model says default, terminal says red) the diff
// oracle exists to catch. Being conservative in the same direction as the model
// costs at most one redundant "\e[0m"; disagreeing with it costs a wrong screen.
//
// THE LINK RULE IS screen_osc8's, on the same terms: a terminated OSC 8 with a
// non-empty URI opens, one with an empty URI closes, and anything malformed or
// unterminated changes nothing (acting on half a URI would open a link nobody
// asked for).
@(private = "file")
line_leaves_open :: proc(line: string, pen_in, link_in: bool) -> (pen, link: bool) {
	pen, link = pen_in, link_in
	i := 0
	for i < len(line) {
		if line[i] != ESC { i += 1; continue }
		j   := skip_escape(line, i)   // always > i, so this loop always advances
		seq := line[i:j]
		i    = j
		if len(seq) >= 2 && seq[1] == ']' {
			if o, ok := osc8_opens(seq); ok { link = o }
			continue
		}
		if len(seq) < 3 || seq[1] != '[' { continue }
		if seq[len(seq) - 1] != 'm'      { continue }
		params := seq[2:len(seq) - 1]
		pen = !(params == "" || params == "0")
	}
	return
}

// screen_osc8's parse, reduced to the one bit this file needs. ok=false means
// "not a hyperlink escape, or not a well-formed one" -- leave the state alone.
@(private = "file")
osc8_opens :: proc(seq: string) -> (opens: bool, ok: bool) {
	if len(seq) < len(OSC8_OPEN) || seq[:len(OSC8_OPEN)] != OSC8_OPEN { return false, false }
	body := seq[len(OSC8_OPEN):]
	switch {
	case len(body) >= len(ST) && body[len(body) - len(ST):] == ST: body = body[:len(body) - len(ST)]
	case len(body) >= 1 && body[len(body) - 1] == BEL:             body = body[:len(body) - 1]
	case:                                                          return false, false
	}
	semi := -1
	for k in 0 ..< len(body) {
		if body[k] == ';' { semi = k; break }
	}
	if semi < 0 { return false, false }
	return semi + 1 < len(body), true
}

// Brings both planes back to the default, in whichever sinks are live, and only
// for the planes that are actually open. THE PAIRED HALVES OF "A FRAME STARTS
// FROM A KNOWN STATE": the byte and the model update are written once,
// together, so a future edit cannot move one without the other -- which is
// exactly how .Diff came to believe its blank rows were red while the wire had
// already cleared them.
@(private = "file")
frame_state_reset :: proc(out: ^strings.Builder, scr: ^Screen, pen, link: bool) {
	if pen {
		if out != nil { strings.write_string(out, SGR_RESET) }
		if scr != nil { scr.style = 0 }
	}
	if link {
		if out != nil { strings.write_string(out, LINK_CLOSE) }
		if scr != nil { scr.link = 0 }
	}
}

// `cur` defaults to Cursor{} -- "no cursor declared". In .Inline that still
// emits ZERO extra bytes, so every call site written before T2 renders byte for
// byte as it did; in the two viewport-owning modes it means "hide the caret and
// leave it hidden". See Cursor for why those two answers differ.
//
// THE SHARED SHELL OF A FRAME, and nothing else: the split into logical lines,
// the DECTCEM hide/show pair, and the dispatch to whichever renderer this
// Renderer was constructed as. Everything mode-specific lives in
// render_inline/render_full_screen below, so that neither can accidentally
// acquire a byte belonging to the other -- see
// test_inline_mode_emits_no_full_screen_escapes, which pins exactly that.
//
// THERE IS ONE DISPATCH THE MODE DOES NOT DECIDE (F53). Renderer.plain overrides
// all three: a terminal that has declared it has no capabilities gets
// render_plain, which is not a fourth mode an application can ask for but the
// floor all three degrade to. It is tested ahead of the DECTCEM pair and ahead
// of .Diff's early return, because each of those emits escapes of its own.
renderer_render :: proc(r: ^Renderer, view: string, cur := Cursor{}) {
	// SOMETHING ELSE PAINTED OVER US -- see request_repaint for who says so and
	// why they cannot say it any other way. Ahead of everything, including the
	// plain-terminal gate and .Diff's early return, because each of the three
	// things it resets belongs to a different one of the modes:
	//
	//   force_repaint  .Diff. Throw the cell model away; the next frame is a
	//                  real \e[2J repaint. This is the whole point.
	//   last_rows      .Inline. The rows we painted are not under the cursor any
	//                  more -- the shell's prompt and output are. Rewinding over
	//                  them would erase the USER's text and paint the frame into
	//                  the hole. Zero means "paint fresh, right here", which is
	//                  what an inline program resuming from a stop should do.
	//   caret_hidden   All three. Every path that can request a repaint went
	//                  through term_restore_c first, and term_restore_c writes
	//                  "\e[?25h" -- so a renderer that still believed the caret
	//                  was hidden would never re-hide it, and .Full_Screen/.Diff
	//                  would run the rest of the session with the blinking block
	//                  back in the middle of the viewport.
	//
	// .Full_Screen needs nothing of its own: it re-homes and repaints every row
	// every frame already.
	if repaint_request_take() {
		r.force_repaint = true
		r.last_rows     = 0
		r.caret_hidden  = false
	}

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

	// THE TERMINAL CANNOT READ ESCAPES, so write it none -- ahead of the mode
	// dispatch, ahead of the DECTCEM pair, and ahead of .Diff's cell model,
	// because every one of those three emits absolute addressing of its own.
	// See render_plain, and Renderer.plain for who sets this and when.
	if r.plain {
		render_plain(r, lines)
		return
	}

	if r.mode == .Diff {
		render_diff(r, lines, cur)
		return
	}

	// THE VIEW CONTRACT FOR THE OTHER TWO MODES (contract.odin's mode-general
	// tier). render_diff asserts the stricter one for itself, before anything
	// else in its frame; this is the same discipline for .Inline and
	// .Full_Screen, and it is new -- the predicate and the assertion both
	// existed and nothing called them, so the check was .Diff-only.
	//
	// It is not .Diff's check with a tab allowed and nothing else: these two
	// modes have no cell model and tolerate quite a lot, but they do BOTH count
	// the physical rows they painted -- .Inline rewinds exactly that many, and
	// .Full_Screen budgets the viewport against them -- so a view that moves the
	// terminal's cursor itself makes that count a lie, and .Inline then erases
	// the wrong rows every frame forever. See view_render_safe.
	when VIEW_STRICT {
		for line in lines { render_contract_assert(line) }
	}

	// HIDE FOR THE DURATION OF A PAINT -- and, in the mode that owns the
	// viewport, LEAVE IT HIDDEN.
	//
	// WHAT THIS USED TO BE, and what it cost. The rule was `hide := cur.show ||
	// r.cursor_up > 0`, justified as "write nothing you were not asked for".
	// Applied to .Full_Screen that is the wrong trade and the comment said so
	// out loud ("a full-screen repaint drags the caret across the whole
	// viewport ... the rule outranks the cosmetics"). The consequences, which
	// are not cosmetics:
	//
	//   * An application that supplies no `cursor` proc -- a dashboard, a list,
	//     a log viewer, a spinner, i.e. the normal case -- ran with the
	//     terminal's blinking block caret parked inside a viewport it otherwise
	//     owns, for the program's whole life. There was no way to ask for it to
	//     go away: Cursor{show = false} is the zero value and reads as "no
	//     opinion", and cursor_hide_arm is package-private, so an app that
	//     wrote "\e[?25l" itself got no paired show from term_restore and left
	//     the user's shell with an invisible caret. (That second half is now
	//     term.odin's Term_Opts.cursor_hide, and it is what `sticky` below
	//     reads: the mode-owns-the-viewport rule covers two of the three modes,
	//     and the application's declaration covers .Inline, which this file
	//     will not take over on its own.)
	//   * Every .Full_Screen repaint walked that visible caret across all 24
	//     rows, 60 times a second.
	//
	// So the mode that OWNS the viewport now hides the caret before it paints
	// and shows it again only where the application asked for one. The mode
	// that does NOT own the viewport keeps the old rule verbatim, and that
	// asymmetry is the point rather than an inconsistency: .Inline composes
	// with whatever the shell printed before it, leaves its frames in the
	// user's scrollback and rests the caret below its output exactly where any
	// other program's would be -- there is no viewport for a stray caret to sit
	// inside of, so hiding one would be this mode taking over terminal state it
	// explicitly does not own.
	//
	// It stays hidden ACROSS frames rather than being re-hidden and re-shown
	// per frame, which is what makes it 6 bytes once instead of 12 per frame,
	// and what stops the caret flickering back into view between repaints.
	// term.odin's cursor_hide_arm makes term_restore -- and guard.odin's
	// crash handler, and the SIGTSTP path -- write the matching "\e[?25h" on
	// every exit, including the ones this file never sees.
	// TWO WAYS TO EARN THE STICKY TREATMENT, and the second one is the
	// application's rather than the mode's. `owns_viewport` is the argument
	// above. `cursor_hide_requested()` is term.odin's Term_Opts.cursor_hide --
	// an .Inline program declaring that it wants no caret for the session --
	// and it has to be consulted HERE, not just at acquire time, for one
	// concrete reason: .Inline's rule below pairs its hide with a show at the
	// end of every frame, so a declaration this file did not know about would
	// be undone 60 times a second, six bytes at a time, with the caret
	// flickering back into view between every pair.
	//
	// THE FIRST FRAME RE-WRITES THE SIX BYTES term_acquire ALREADY SENT, and
	// that duplicate is deliberate rather than an oversight. DECSET 25 is a
	// boolean mode, so a second `\e[?25l` is a true no-op and it is paid once
	// per session -- but the reason it is written at all is that the two are
	// not the same stream. term.odin wrote its hide to g_term.fd; a frame goes
	// wherever run() was told to flush it, which may be a different fd, a pipe,
	// or nothing at all (the golden harness passes -1). A renderer that assumed
	// the acquire's hide was already on ITS output would leave the caret
	// visible on every one of those. Seeding r.caret_hidden from term.odin
	// instead would also need a second flag to say whether the acquire's hide
	// is still in force -- a frame that declares a cursor shows the caret again
	// -- which is more state, kept in two places, for six bytes.
	owns_viewport := r.mode == .Full_Screen
	sticky := owns_viewport || cursor_hide_requested()
	hide := sticky ? !r.caret_hidden : (cur.show || r.cursor_up > 0)
	if hide {
		// ARMED BEFORE THE BYTES CAN LEAVE, exactly like term.odin's
		// kitty_enable/paste_enable set their flags before writing: the window
		// to be wrong in is the one where the terminal has seen the hide and
		// the restore does not know about it.
		cursor_hide_arm()
		strings.write_string(r.out, CURSOR_HIDE)
		r.caret_hidden = true
	}

	switch r.mode {
	case .Inline:      render_inline(r, lines, cur)
	case .Full_Screen: render_full_screen(r, lines, cur)
	case .Diff:        unreachable()   // handled above, before the DECTCEM pair
	}

	// Put it back where the application asked for it. `cur.show` is the whole
	// condition under the sticky rule: an app that declared no cursor gets
	// none, which is what F24 was about. A frame that DOES declare one still
	// wins over a session-long Term_Opts.cursor_hide -- the declaration is a
	// default, not a veto, and the next cursor-less frame hides it again.
	if sticky {
		if cur.show && r.caret_hidden {
			strings.write_string(r.out, CURSOR_SHOW)
			r.caret_hidden = false
		}
	} else if hide {
		strings.write_string(r.out, CURSOR_SHOW)
		r.caret_hidden = false
	}
}

// THE PLAIN RENDERER (F53). What run() paints at a terminal that has told us it
// has no capabilities: TERM=dumb, TERM= or no TERM at all (term.odin's
// term_supports_escapes -- and see it for why that three-value rule is the
// whole test and not a terminfo lookup).
//
// WHAT THIS FIXES. term_enter_raw already gated its five opt-ins on that
// verdict, so no Kitty push, no bracketed paste, no mouse tracking, no focus
// reporting and no alternate screen reached a dumb terminal. The RENDERER did
// not: .Inline still wrote \e[1A\e[2K per row of the previous frame,
// .Full_Screen still wrote \e[H ... \e[K ... \e[J every frame, .Diff still
// wrote CUP for every changed cell, and all three passed the view's own SGR
// straight through. The real-world case is an Emacs comint/shell-mode pty,
// which answers all of that by PRINTING it: an app degraded its colour
// correctly (runegloss reads TERM too) and then painted a growing wall of
// literal escape text underneath itself.
//
// THE SHAPE, and why there is so little of it:
//
//   <line>\r\n     Every logical line, escapes REMOVED, each terminated. The
//                  \r is not decoration -- the tty is in raw mode with OPOST
//                  off, so a bare \n on this terminal is a linefeed that does
//                  not return the carriage and the next frame staircases.
//
// That is the entire repertoire, and each thing missing from it is missing for
// a reason that cannot be worked around at this terminal:
//
//   * NO REWIND. Erasing the previous frame is \e[1A\e[2K, which is the thing
//     we may not write. A frame therefore APPENDS, like teletype output. That
//     is a real loss of function -- an animated spinner becomes one line per
//     tick -- and it is the honest one: the alternative is painting escape text
//     at a terminal that shows it, which loses the function AND the screen.
//   * NO CURSOR PLACEMENT AND NO DECTCEM. Both are escapes; a declared Cursor
//     is ignored here rather than approximated, and cursor_hide_arm is never
//     armed, so term_restore stays silent too (the same "undo only what was
//     actually set" pairing term.odin enforces one layer up).
//   * THE VIEW'S OWN ESCAPES ARE STRIPPED, not passed through. This is the one
//     decision here that goes beyond "the renderer emits nothing", and it is
//     deliberate: RuneGloss drops COLOUR under TERM=dumb but still emits
//     attributes (\e[2m for a faint style, say), an application may hand-roll
//     an SGR of its own, and neither would be seen by anyone -- they would be
//     PRINTED. A last gate that removes what nobody downstream can remove is
//     worth more than a layering rule. It uses skip_escape, the same scanner
//     display_width and screen_write split on, so a byte this drops is exactly
//     a byte those two already declined to measure; nothing can drift. An
//     UNTERMINATED escape is consumed to the end of the line by that same
//     scanner, which is moot in practice: the contract assertion below rejects
//     a Truncated_Escape before this proc is reached in any build short of
//     -define:RUNETEA_VIEW_STRICT=false.
//
// last_rows/cursor_up go to zero and pen_open/link_open to false because none
// of the state they exist to bookkeep can be created here -- there is no rewind
// to size, no walk home to undo, and no pen left open at a terminal that never
// received one.
@(private = "file")
render_plain :: proc(r: ^Renderer, lines: []string) {
	// The mode-general view contract still applies, and this is the only place
	// that can still assert it for a .Diff program: the gate that sent us here
	// runs BEFORE render_diff, which is where .Diff's own stricter assertion
	// lives. A view that moves the cursor itself is a bug at every terminal,
	// and a developer who happens to be debugging under TERM=dumb should not be
	// the one person who stops being told about it.
	when VIEW_STRICT {
		for line in lines { render_contract_assert(line) }
	}

	for line in lines {
		write_escape_free(r.out, line)
		strings.write_string(r.out, "\r\n")
	}
	r.last_rows = 0
	r.cursor_up = 0
	r.pen_open  = false
	r.link_open = false
}

// Writes `s` with every escape sequence removed, splitting on ESC exactly the
// way display_width's pre-pass and screen_write do. Written as a copy loop over
// SEGMENTS rather than byte by byte so the common case -- a line with no escape
// in it at all -- is one write_string of the whole line and no per-byte work.
@(private = "file")
write_escape_free :: proc(b: ^strings.Builder, s: string) {
	seg := 0
	i   := 0
	for i < len(s) {
		if s[i] != ESC { i += 1; continue }
		if i > seg { strings.write_string(b, s[seg:i]) }
		i   = skip_escape(s, i)   // always > i, so this loop always advances
		seg = i
	}
	if seg < len(s) { strings.write_string(b, s[seg:]) }
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
//   \e[0m             ONLY when the PREVIOUS frame left a style open. A frame
//                     starts from the default SGR in all three modes -- see
//                     Renderer.pen_open for the flood each mode produced
//                     without it, and for why the condition is what keeps a
//                     well-behaved view's byte stream unchanged.
//   \e[H              HOME. Unconditional, first, every frame. This is what
//                     makes the origin knowable -- and what makes the mode
//                     self-healing: whatever a stray write, a resize or a
//                     terminal scroll did to the screen, the next frame starts
//                     from the top-left cell again.
//   <line>\e[K        The paint. EL clears the tail of the row the line ended
//                     on, which is the only place a LONGER previous frame can
//                     still show through once the rows below are cleared.
//                     Skipped when the line is flush with the right margin --
//                     see measure_line's `fills`.
//
//                     THE EL DELIBERATELY KEEPS THE VIEW'S OWN PEN. A line that
//                     opens a background and does not close it has its EL paint
//                     that background out to the margin, which is how a view
//                     paints a full-width bar without emitting cols-worth of
//                     spaces, and the .Diff cell model (screen_el0 fills with
//                     s.style) records exactly the same thing. Resetting here
//                     as well would make the two modes render the same view
//                     differently, which is the bug the frame-head and pre-ED
//                     resets exist to remove.
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
//                     measure_line's `fills` documents). Emitted only when a row
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
	rows, _, pen, link := paint_frame(r.out, nil, nil, lines, cur, r.term_width, r.term_height, r.pen_open, r.link_open)
	r.last_rows = rows
	r.pen_open  = pen
	r.link_open = link
}

// THE FULL-SCREEN FRAME, EMITTED AND/OR MODELLED (T3-A split this out of
// render_full_screen).
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
// `pen_open` says whether the previous frame left a non-default SGR active;
// `link_open`/`link_left` are the OSC 8 half, on the same terms.
// See Renderer.pen_open.
//
// Returns the physical row count (Renderer.last_rows' value) and ok=false if
// the style or link table overflowed while modelling (the caller retries once
// with an empty table and, if that overflows too, degrades to the repaint --
// see render_diff).
@(private = "file")
paint_frame :: proc(
	out:     ^strings.Builder,
	scr:     ^Screen,
	scratch: ^[dynamic]u8,
	lines:   []string,
	cur:     Cursor,
	term_width, term_height: int,
	pen_open, link_open: bool,
) -> (rows: int, ok: bool, pen_left, link_left: bool) {
	ok   = true
	pen  := pen_open
	link := link_open
	// THE FRAME STARTS AT THE DEFAULT SGR. Before this, a view that left a
	// style open at its last line had that style still active when the NEXT
	// frame homed and painted -- so the whole frame came out in it, and every
	// erase in it (\e[K, \e[J, and .Diff's modelled blanks) was filled with its
	// background. See Renderer.pen_open for the measured floods, and note the
	// second thing it fixes: .Diff's forced repaint blanked its model to the
	// default and emitted its own \e[0m, while .Full_Screen re-homed onto the
	// leftover pen, so from the first frame after ANY resize the two modes
	// rendered the same view differently. They now start every frame from the
	// same state, which is what makes "the diff renders what the repaint would
	// have" an invariant rather than a coincidence.
	if pen || link {
		frame_state_reset(out, scr, pen, link)
		pen, link = false, false
	}
	if out != nil { strings.write_string(out, HOME) }
	if scr != nil { screen_goto(scr, 0, 0) }

	// `cline` is clamped the same way the inline path clamps it, so a negative or
	// past-the-end line index behaves identically in both modes.
	cline      := clamp(cur.line, 0, len(lines) - 1)
	painted    := 0   // logical lines painted so far
	rows_above := 0   // physical rows above the cursor's own logical line
	for line, i in lines {
		// ONE MEASUREMENT, THREE ANSWERS (width.odin's measure_line). This used
		// to be two calls -- rows_for_line's ceil division for the budget and
		// line_fills_its_rows' `display_width % term_width == 0` for the EL --
		// and the two agreed with each other but not with where the text
		// actually lands. A line whose last cluster is WIDE and starts on the
		// last column is written IN that column with no continuation cell
		// (screen_put, and pyte), so it covers fewer columns than it measures:
		// the modulo could report "flush with the right margin" for a row that
		// ends short, the \e[K was skipped, and the tail of that row kept the
		// previous frame's characters -- permanently under .Diff, because the
		// model agreed with the omission and no later frame ever repainted it.
		// measure_line walks the placement instead, so `fills` is the real
		// question ("is the last row's final column written?") rather than an
		// arithmetic proxy for it.
		m := measure_line(line, term_width)
		if term_height > 0 && rows + m.rows > term_height { break }
		if painted > 0 {
			if out != nil { strings.write_string(out, "\r\n") }
			if scr != nil { screen_cr(scr); screen_index(scr) }
		}
		if i == cline { rows_above = rows }
		if out != nil { strings.write_string(out, line) }
		if scr != nil {
			if !screen_write(scr, line, scratch) { ok = false }
		}
		pen, link = line_leaves_open(line, pen, link)
		if !m.fills {
			if out != nil { strings.write_string(out, EL) }
			if scr != nil { screen_el0(scr) }
		}
		rows    += m.rows
		painted += 1
	}
	// The cursor's line was TRUNCATED AWAY. Point rows_above past the bottom and
	// let cursor_cell's clamp pull it back to the last painted row -- one clamp,
	// in one place, rather than a second rule here that could disagree with it.
	if cline >= painted { rows_above = rows }

	// THE PEN IS CLOSED BEFORE THE ED, NOT BEFORE THE EL. \e[J erases with the
	// ACTIVE background, and unlike the per-line EL -- which erases the tail of
	// a row the view itself just painted, and where extending the view's own
	// background is the whole point (see this proc's caller's frame-shape note)
	// -- the ED erases rows the frame did NOT write. Leaving the pen set there
	// paints every remaining row of the screen in whatever colour the view's
	// last line forgot to close. Conditional, so a view that closes its styles
	// (all of them, in practice) is unaffected byte for byte.
	if (pen || link) && (painted == 0 || term_height <= 0 || rows < term_height) {
		// THE LINK IS CLOSED HERE TOO, and that makes a documented limitation go
		// away rather than merely tidying up. screen.odin's blank_cell records an
		// erased cell as carrying NO hyperlink, and justifies it by saying the
		// diff emitter closes the link before every \e[K it writes -- while the
		// .Full_Screen repaint, which blasts the view's own bytes, "cannot". It
		// can, here: nothing of this frame is painted after the ED, so closing
		// first costs a view that never links exactly nothing and makes the
		// model right on every terminal instead of only on the diff's stream.
		// (The PER-LINE \e[K keeps the open link, because a link that spans a
		// wrapped line is a thing views legitimately produce and closing it there
		// would change what they render. That one stays a view-side contract.)
		frame_state_reset(out, scr, pen, link)
		pen, link = false, false
	}
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
	// A frame that exactly FILLED the viewport writes no trailing ED, so it can
	// still end with the pen set -- there was nothing left to erase with it,
	// which is why that case is not worth four bytes to close here. The next
	// frame's head reset (and renderer_clear, for the exit path) is what
	// collects it.
	pen_left, link_left = pen, link
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
// The 0-byte figure is a CONTRACT and it survived both of this wave's
// additions, which is why each of them is conditional. The caret is hidden once
// and left hidden, not hidden and shown around every frame (12 bytes a frame,
// and a caret that flickers back into view between repaints). The frame-head
// SGR/hyperlink reset is emitted only when the previous frame actually left one
// open, which for every view that closes its own styles is never -- and for one
// that does not, resetting is what STOPS the cost growing: the model used to
// re-accumulate the view's escape onto last frame's copy of it, so an idle
// screen cost +16 bytes more every frame until the style budget blew.
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
//   * VIEWS MAY CONTAIN STYLING AND HYPERLINKS, NOT MOTION. SGR escapes and
//     OSC 8 hyperlinks are both tracked per cell (T3-C). Any OTHER escape
//     (cursor movement, DCS, other OSCs) is consumed for width purposes --
//     exactly as display_width already does -- and otherwise ignored, which
//     means a view that moves the terminal's cursor itself is lying to the
//     model. .Full_Screen tolerates that; this mode cannot. view_diff_safe
//     (contract.odin) turns that sentence into something a caller can CHECK,
//     and a debug build asserts it on every frame -- see DIFF_STRICT.
//   * A HYPERLINK MUST BE CLOSED BEFORE THE END OF ITS LINE. The model treats
//     an erased cell as unlinked, and the diff emitter guarantees that by
//     closing the link before every \e[K it writes; the .Full_Screen repaint,
//     which blasts the view's own bytes, cannot. See docs/LIMITATIONS.md.
//   * A WIDE CLUSTER LANDING ON THE RIGHT MARGIN is modelled as written IN that
//     column (see screen.odin's header), which is also what pyte does and what
//     width.odin's measure_line now MEASURES -- the three finally agree, which
//     is what closed the stale-tail bug where the \e[K was skipped for a row
//     that ended short. xterm-family terminals instead leave the cell blank and
//     wrap the cluster; that divergence is real, it is documented in
//     screen.odin's header and docs/LIMITATIONS.md 3.8, and it is measured
//     against pyte by tools/difftest on every run.
//   * MORE THAN STYLE_TABLE_MAX-1 DISTINCT STYLES IN ONE FRAME degrades to the
//     .Full_Screen repaint for that frame. See render_diff's overflow handling.

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
//   drop_link    never re-emits an OSC 8 hyperlink. Catching this is what
//                proves the oracle actually SEES links rather than merely
//                tolerating them -- see difffuzz.odin's TOK_LINK.
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
		diff_repaint_fallback(r, lines, cur)
		return
	} else {

	// THE VIEW CONTRACT, ASSERTED RATHER THAN ONLY DOCUMENTED (contract.odin).
	// Debug builds only, and before anything else in the frame so the panic
	// points at the frame that caused it rather than at a screen that has
	// already drifted. Note it runs even on the degraded no-size path below:
	// that path emits .Full_Screen's bytes, which TOLERATE motion, so a view
	// that only ever ran without a known size would otherwise pass every test
	// and break the first time a real terminal size arrived.
	when DIFF_STRICT {
		for line in lines { diff_contract_assert(line) }
	}

	// NO SIZE, NO VIEWPORT, NO MODEL. Same "do not guess" rule rows_for_line
	// states for an unknown width -- and the same consequence: the frame is
	// simply .Full_Screen's, byte for byte, including its DECTCEM pair. The
	// model is invalidated so that the first frame after a real size arrives
	// (a Window_Size_Msg, or the initial term_size in run()) repaints in full
	// rather than diffing against a screen it never modelled.
	if r.term_width <= 0 || r.term_height <= 0 {
		diff_repaint_fallback(r, lines, cur)
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
		r.emit_link        = 0
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
	rows, ok, pen, link := paint_frame(nil, cur_s, &r.sgr_scratch, lines, cur, r.term_width, r.term_height, r.pen_open, r.link_open)
	r.last_rows = rows
	// pen/link are NOT committed to the Renderer yet, and that ordering is
	// load-bearing. Both the retry and the repaint fallback below re-run this
	// same frame, and both read r.pen_open/r.link_open as the state the frame
	// STARTS from. Committing here would advance them to the state the frame
	// ENDS in, so the second pass would begin from the wrong pen -- and since
	// .Full_Screen's renderer never takes either path, the two modes would then
	// disagree about whether the frame needs a leading reset. The fuzz corpus
	// found exactly that, within one run of learning to overflow a style table.

	if !ok {
		// The style table overflowed (STYLE_TABLE_MAX, or its byte budget
		// STYLE_BYTES_MAX; the link table has the same two caps). Interning any
		// further style would have to alias it onto an existing index, which
		// would make two visibly different cells compare equal -- a silent wrong
		// screen, the exact failure mode this whole design exists to avoid. Drop
		// the table, force a repaint, and redo the frame from scratch.
		if allow_retry {
			diff_styles_reset(r)
			render_diff(r, lines, cur, allow_retry = false)
			return
		}
		// THE RETRY OVERFLOWED TOO, i.e. this ONE frame contains more than
		// STYLE_TABLE_MAX-1 = 4095 distinct accumulated SGR strings (or more
		// than 1 MiB of them, or the same for OSC 8 payloads). An empty table
		// could not hold it, so no number of retries can.
		//
		// WHAT THIS USED TO DO: nothing. `ok` was dropped on the floor and the
		// frame was emitted from a model in which screen_sgr had silently kept
		// the PREVIOUS style for every cell past the 4095th (it returns false
		// without assigning s.style, and screen_write keeps writing). The user
		// got a screen that differs from what .Full_Screen would have painted,
		// with no diagnostic anywhere -- and because the retry had already
		// cleared force_repaint, the wrong frame persisted into later ordinary
		// frames whenever the overflowing view also left style or link state
		// open at its end. docs/LIMITATIONS.md 3.7 already CLAIMED this
		// degraded to a repaint; now it does.
		//
		// The fallback is .Full_Screen's own byte stream for this frame, not
		// merely "force a repaint next time": a repaint next frame does not
		// un-show the wrong frame the user is looking at now. It costs a full
		// repaint on a frame that was already pathological, and diff_styles_reset
		// leaves the tables empty and force_repaint set so the very next frame
		// resynchronises from a real \e[2J.
		diff_styles_reset(r)
		diff_repaint_fallback(r, lines, cur)
		return
	}
	// The frame stands: commit the state it leaves the terminal in.
	r.pen_open  = pen
	r.link_open = link

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

	// THE SAME CARET RULE .Full_Screen USES, and it has to be the same or the
	// oracle's cursor-visibility comparison would fail on a difference that is
	// this file's own invention: the mode that owns the viewport hides the
	// caret and leaves it hidden, and shows it only where the application asked
	// for one. See renderer_render's "HIDE FOR THE DURATION OF A PAINT".
	//
	// The extra `changed || !cur.show` term is what keeps the 0-byte contract:
	// an identical frame that declares a cursor already sits with the caret
	// visible at the right cell, so hiding and showing it again would cost 12
	// bytes to paint nothing. (.Full_Screen has no such term because it repaints
	// unconditionally -- `changed` is always true there.) A frame that does NOT
	// declare a cursor must still hide it even when nothing changed, because
	// "leave it hidden" is a state to reach, not a per-frame decoration.
	hide := !r.caret_hidden && (changed || !cur.show)
	if hide {
		// ARMED BEFORE THE BYTES CAN LEAVE, exactly as renderer_render does.
		cursor_hide_arm()
		strings.write_string(r.out, CURSOR_HIDE)
		r.caret_hidden = true
	}

	if repaint {
		// SGR first: \e[2J erases with the ACTIVE background, so clearing under
		// an unknown (or coloured) style would paint the screen that colour.
		strings.write_string(r.out, SGR_RESET)
		// AND CLOSE ANY OPEN HYPERLINK, for the same "the repaint block above
		// asserted the terminal is at a known state, so make it true" reason --
		// SGR_RESET does NOT close an OSC 8 link (they are independent attribute
		// planes) and a link left open by whatever ran before us would otherwise
		// be inherited by the first cell this frame writes.
		//
		// CONDITIONAL, unlike SGR_RESET, and that is the whole compatibility
		// story of T3-C: a program that never uses hyperlinks emits exactly the
		// bytes it emitted before. paint_frame has already run by this point, so
		// a first frame that DOES contain a link has already interned it and
		// takes this branch. See diff_links_in_play.
		if diff_links_in_play(r) { strings.write_string(r.out, LINK_CLOSE) }
		strings.write_string(r.out, HOME)
		strings.write_string(r.out, ED2)
	}

	for y in 0 ..< cur_s.rows { emit_row(r, y, prev, cur_s) }

	// CLOSE THE FRAME'S STYLE. Without this, a frame whose last written cell
	// sits inside a styled run (a full-width status bar is the ordinary case)
	// ends with the terminal still in that style, and everything the
	// application writes afterwards -- or the user's shell after exit --
	// inherits it. .Full_Screen never had this problem, but only because
	// RuneGloss closes every row it emits; a hand-written view owes nothing,
	// and this mode must not depend on its input being well-mannered.
	//
	// Clearing emit_style as well as writing the reset is what keeps the
	// 0-byte contract intact, and the two must move together. The alternative
	// -- write the reset but leave emit_style set -- would make the NEXT
	// identical frame emit a second reset for a style the terminal no longer
	// has, so an idle screen would cost 4 bytes a frame forever instead of 0.
	// Clearing it costs the cross-frame carry-over instead: the first styled
	// cell of the next frame re-emits its SGR. That only touches frames which
	// already change cells, and correctness of the terminal's exit state is
	// worth more than those few bytes.
	if r.emit_style != 0 {
		strings.write_string(r.out, SGR_RESET)
		r.emit_style = 0
	}
	// CLOSE THE FRAME'S HYPERLINK, on exactly the reasoning above and with one
	// extra edge to it: an OSC 8 link left open does not merely tint what comes
	// next, it makes it CLICKABLE -- including the user's shell prompt after the
	// program exits. Same emit_link-cleared-with-the-write discipline, same
	// 0-byte contract on an idle frame.
	if r.emit_link != 0 {
		strings.write_string(r.out, LINK_CLOSE)
		r.emit_link = 0
	}

	when DIFF_FAULT != "no_cursor" {
		// UNCONDITIONAL, and cheap: diff_move writes nothing when the cursor is
		// already there, which on an identical frame it always is. This is the
		// only thing that keeps the cursor in step with what the repaint would
		// have left behind even when the app declares no cursor at all -- the
		// repaint parks it after its trailing \e[J, and "the same screen" is not
		// the same screen if the caret is somewhere else.
		diff_move(r, tx, ty)
	}

	if cur.show && r.caret_hidden {
		strings.write_string(r.out, CURSOR_SHOW)
		r.caret_hidden = false
	}

	// The frame just painted IS the screen now.
	r.front = 1 - r.front
	}
}

// .Full_Screen's byte stream, emitted from .Diff mode, with the model declared
// invalid afterwards. THE ONE PLACE .Diff degrades, and there are exactly three
// callers: no known size (nothing to model), a single frame whose distinct
// styles cannot fit an empty intern table (nothing that can be modelled
// CORRECTLY), and the "repaint" fault injection that proves the oracle works
// before it has to catch anything.
//
// Byte-for-byte .Full_Screen's, DECTCEM included -- verified against a real
// .Full_Screen renderer rather than a transcribed literal, by
// test_diff_without_a_known_size_falls_back_to_the_full_screen_bytes. That is
// why the caret rule below is renderer_render's viewport-owning branch spelled
// out again rather than something simpler: a degraded .Diff frame that hid the
// caret differently from the repaint it is supposed to BE would be a divergence
// the oracle reports and nobody can act on.
@(private = "file")
diff_repaint_fallback :: proc(r: ^Renderer, lines: []string, cur: Cursor) {
	hide := !r.caret_hidden
	if hide {
		cursor_hide_arm()
		strings.write_string(r.out, CURSOR_HIDE)
		r.caret_hidden = true
	}
	rows, _, pen, link := paint_frame(r.out, nil, nil, lines, cur, r.term_width, r.term_height, r.pen_open, r.link_open)
	r.last_rows = rows
	r.pen_open  = pen
	r.link_open = link
	if cur.show && r.caret_hidden {
		strings.write_string(r.out, CURSOR_SHOW)
		r.caret_hidden = false
	}
	// The model describes a screen this frame did not paint through it.
	r.force_repaint = true
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
		style_table_init(&r.links)
		r.grid_ready = true
	}
	screen_init(&r.screens[0], w, h, &r.styles, &r.links)
	screen_init(&r.screens[1], w, h, &r.styles, &r.links)
	resize(&r.dirty, w)
	r.front         = 0
	r.force_repaint = true
}

// Drops BOTH intern tables, not just the one that overflowed. They are indexed
// out of the same cells, and screen_blank (below) resets every cell's `style`
// AND `link` to 0 -- so keeping one table alive would leave it holding entries
// nothing points at, which is not wrong but is not worth a second code path.
@(private = "file")
diff_styles_reset :: proc(r: ^Renderer) {
	style_table_destroy(&r.styles)
	style_table_init(&r.styles)
	style_table_destroy(&r.links)
	style_table_init(&r.links)
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
// The OSC 8 sequence that closes whatever hyperlink is open. See screen.odin's
// screen_osc8 for why an empty URI is the protocol's "close".
@(private = "file")
LINK_CLOSE :: OSC8_OPEN + ";" + ST

// Whether this Renderer has ever seen a hyperlink at all.
//
// THE ZERO-COST GUARD, and the reason every byte-exact expectation in this
// package is unchanged by T3-C: a program whose views contain no OSC 8 never
// interns one, so this is false forever and not one link byte is ever written.
// Index 0 is reserved at table init, so "> 1" is "at least one real entry".
@(private = "file")
diff_links_in_play :: proc(r: ^Renderer) -> bool {
	return len(r.links.spans) > 1
}

// Brings the terminal's open hyperlink to `l`, writing nothing if it is already
// there. The exact shape of diff_style, and it has to be: a hyperlink is
// terminal state that applies to everything written next, so the emitter owes
// it the same "establish before the cell, never assume" discipline.
//
// NO RESET-VIA-DEFAULT DANCE, unlike diff_style. An OSC 8 open REPLACES the
// current link outright rather than accumulating onto it, so going from link A
// to link B is one sequence, not a close and an open. (diff_style needs the
// round trip because a style is stored as bytes accumulated from a reset point;
// a link is stored whole.)
@(private = "file")
diff_link :: proc(r: ^Renderer, l: u16) {
	when DIFF_FAULT == "drop_link" {
		// INJECTED FAULT: the emitter never re-establishes a cell's hyperlink.
		return
	} else {
	if r.emit_link == l { return }
	if l == 0 {
		strings.write_string(r.out, LINK_CLOSE)
	} else {
		strings.write_string(r.out, OSC8_OPEN)
		strings.write_string(r.out, style_bytes(&r.links, l))
		strings.write_string(r.out, ST)
	}
	r.emit_link = l
	}
}

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
	//
	// A LINKED BLANK IS NOT ELIGIBLE EITHER (c.link != 0), for a stronger reason
	// than the styled case: \e[K would erase the cell, and the model says an
	// erased cell carries no link (blank_cell), so using EL there would drop a
	// hyperlink the frame asked for. Written as a real space under an open link
	// instead.
	tail := cols
	for tail > 0 {
		c := cur.cells[base + tail - 1]
		if c.len != 0 || c.width != 1 || c.style != 0 || c.link != 0 { break }
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
		diff_link(r, c.link)
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
		// CLOSE THE LINK BEFORE ERASING. Whether a terminal records the open
		// hyperlink on the cells \e[K blanks is not something the standards fix,
		// so the emitter refuses to find out: with nothing open, every terminal
		// agrees the erased tail is unlinked, which is exactly what blank_cell
		// models. The model is right by construction rather than by hope.
		diff_link(r, 0)
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
// coordinates.
//
// A FRAME TALLER THAN THE SCREEN -- what the `reachable` clamp below is for.
//
// CUU clamps at the top margin. A frame of R physical rows painted on a
// terminal of H rows scrolls the terminal, so once R >= H the frame's topmost
// R-(H-1) rows are no longer on screen at all: they are in SCROLLBACK, where no
// escape sequence can reach them. Recording last_rows = R and then asking for R
// \e[1A's therefore walks up FEWER rows than it asked for (the tail is eaten by
// the clamp) while the compensating \e[<n>B walks down the full n -- home slides
// by the difference, and because last_rows keeps over-counting, the error
// COMPOUNDS every frame rather than healing.
//
// The fix is to record what the rewind can actually reach rather than what was
// painted. After painting R rows (each terminated by "\r\n") the cursor sits at
// column 1 of screen row c = min(start_row + R, H), and the number of THIS
// frame's rows still on screen above it is exactly min(R, H-1):
//
//   - R <= H-1: c - R = min(start_row, H-R) >= 1 for any start_row >= 1, so
//     every painted row is still above the cursor. Nothing changes; this is the
//     overwhelmingly common case and it is byte-for-byte the old behaviour.
//   - R >= H:   the terminal scrolled until the cursor hit the bottom, so c = H
//     and precisely H-1 of the frame's rows remain visible above it.
//
// NOT TRUNCATION, unlike .Full_Screen/.Diff (see render_full_screen's "TRUNCATE
// AT THE BOTTOM"). Those modes own an absolute origin and repaint it every
// frame, so a line they refuse to paint is a line that would have destroyed the
// origin. .Inline owns no origin and exists precisely to LEAVE ITS OUTPUT IN THE
// USER'S SCROLLBACK -- dropping lines would be this mode discarding the very
// thing it is for, and it could not even be undone later, since the truncated
// rows would already have scrolled past. So every line is still written, in
// full; only the bookkeeping stops lying. What overflows scrolls away, which is
// the normal fate of anything printed to a terminal.
//
// RESIDUAL, and stated rather than promised away: the rows that scrolled off
// still hold the OLD frame's text, and no rewind will ever erase them, so a
// terminal scrolled back far enough shows stale frames above the live one. That
// is unavoidable -- scrollback is not addressable -- and it is bounded: the
// visible viewport is correct on every frame, and the moment frames fit again
// the mode is exactly as it was.
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
	//
	// ONE THING DOES HAVE TO PRECEDE IT: an SGR reset, when the previous frame
	// left a style open. \e[2K erases with the ACTIVE background, so a view
	// whose last line ended inside an unclosed background colour had every row
	// of the frame region erased to that colour and then repainted in it -- and
	// since the next frame's text was written with the same pen still set, the
	// flood renewed itself every frame for the life of the program. The most
	// ordinary hand-written-view mistake there is, amplified into a permanently
	// wrong screen by the DEFAULT render mode. Conditional on pen_open, so a
	// view that closes its styles writes exactly the bytes it always did.
	if r.pen_open || r.link_open {
		frame_state_reset(r.out, nil, r.pen_open, r.link_open)
		r.pen_open, r.link_open = false, false
	}
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
	pen, link := false, false   // the reset above put the terminal at the default
	for line, i in lines {
		if i == cline { rows_above = rows }
		strings.write_string(r.out, line)
		strings.write_string(r.out, "\r\n")    // raw mode: OPOST is off
		// measure_line, not the old ceil division: a line containing a \t now
		// costs the rows the tab expansion actually takes (a tab measured 0
		// before, so a tabbed line under-counted, the rewind erased one row too
		// few, and the frame slid one row down the screen every frame leaving a
		// complete stale copy above it), and a line whose last cluster is wide
		// and lands on the right margin costs one row rather than two.
		rows += rows_for_line(line, r.term_width)
		pen, link = line_leaves_open(line, pen, link)
	}
	// What the NEXT frame's rewind has to reset before it erases. .Inline has no
	// cell model -- the real terminal is the only thing that knows what the pen
	// is -- so this is the whole of its SGR and hyperlink bookkeeping.
	r.pen_open  = pen
	r.link_open = link
	// How many of those rows a later \e[<n>A can still reach -- see this proc's
	// doc comment. With the height UNKNOWN (0) there is nothing to clamp
	// against and this is `rows`, i.e. the pre-fix behaviour exactly, which is
	// what every byte-exact test in this package pins.
	reachable := rows
	if r.term_height > 0 { reachable = min(rows, r.term_height - 1) }
	r.last_rows = reachable

	if cur.show {
		// The column/row arithmetic lives in cursor_cell, SHARED with the
		// full-screen path so a wide rune before the caret cannot behave
		// differently in the two modes. Clamping into the frame is what keeps
		// this mode's symmetric up/down pair balanced -- see this proc's doc
		// comment on why an out-of-frame `up` would permanently desynchronise
		// home rather than merely misplace the caret. rows >= 1 always
		// (split_lines always yields at least one element), so up >= 1 here.
		//
		// CLAMPED TO `reachable` FOR THE SAME REASON THE REWIND IS. The caret's
		// own row is the one thing in this frame that can sit above the top
		// margin (its logical line may have scrolled off entirely), and a CUU
		// the terminal silently truncates unbalances the up/down pair exactly
		// like an over-long rewind does -- the \e[<n>B on the next frame would
		// walk down rows the \e[<n>A never walked up. Preferring a caret one or
		// more rows lower than asked over a permanently displaced home is the
		// same trade cursor_cell's own clamp already makes.
		prow, col := cursor_cell(cur, rows_above, rows, r.term_width)
		up := min(rows - prow, reachable)
		// up == 0 only on a one-row terminal, where nothing is reachable at
		// all. "\e[0A" is NOT a no-op -- a zero parameter means one -- so the
		// CUU is dropped entirely rather than emitted with a lying argument.
		if up > 0 { write_csi(r.out, up, "A") }
		write_csi(r.out, col + 1, "G")   // CHA is 1-based
		r.cursor_up = up
	}
}

// Tears the current frame down completely: after this the Renderer believes
// nothing is on screen, and the next renderer_render starts from scratch.
renderer_clear :: proc(r: ^Renderer) {
	// SHOW THE CARET AGAIN FIRST. .Full_Screen and .Diff hide it for as long as
	// they own the viewport (see renderer_render), and this proc is the orderly
	// end of that ownership -- after it, this Renderer believes nothing is on
	// screen, so it has no business still holding the terminal's caret hidden.
	// term.odin's cursor_hide_arm covers every path that does NOT come through
	// here (a crash, a signal, a caller that just stops rendering); this covers
	// the one that does, and writing "\e[?25h" twice is a true no-op -- DECSET
	// 25 is one boolean mode with no stack, which is exactly why term.odin lets
	// its own flag err towards writing.
	if r.caret_hidden {
		strings.write_string(r.out, CURSOR_SHOW)
		r.caret_hidden = false
	}
	if r.mode == .Diff {
		// Same bytes .Full_Screen writes, plus an SGR reset when one is needed:
		// \e[J erases with the ACTIVE background, and this mode is the only one
		// that can knowingly be sitting in a non-default style.
		if r.emit_style != 0 {
			strings.write_string(r.out, SGR_RESET)
			r.emit_style = 0
		}
		// And any open hyperlink, for the reason render_diff's frame-closing
		// reset gives: this is the last thing the renderer writes, so a link
		// left open here is a link the user's shell inherits.
		if r.emit_link != 0 {
			strings.write_string(r.out, LINK_CLOSE)
			r.emit_link = 0
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
		//
		// The reset is the same rule paint_frame applies before its own trailing
		// ED, for the same reason: \e[J erases with the ACTIVE background, so a
		// view that left a colour open would have this "clear" paint the whole
		// screen that colour instead of blanking it.
		if r.pen_open || r.link_open {
			frame_state_reset(r.out, nil, r.pen_open, r.link_open)
			r.pen_open, r.link_open = false, false
		}
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
	// Same reset render_inline puts in front of its own rewind, for the same
	// reason: \e[2K erases with the active background.
	if r.pen_open || r.link_open {
		frame_state_reset(r.out, nil, r.pen_open, r.link_open)
		r.pen_open, r.link_open = false, false
	}
	for _ in 0 ..< r.last_rows {
		strings.write_string(r.out, "\e[1A")
		strings.write_string(r.out, "\e[2K")
	}
	r.last_rows = 0
}
