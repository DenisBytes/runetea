// Package edit is examples/editor's model/update/view, split out of `package
// main` for ONE reason: a `package main` cannot be imported, so an example
// that lives entirely in main.odin can only ever be validated by running the
// binary and looking at it. Everything here is driven by editor_test.odin
// through the real rt.run() event loop with scripted input bytes -- the same
// instrument runetea/golden_test.odin uses -- so the key handling below is a
// tested artifact rather than a demo someone once eyeballed.
//
// main.odin is then a ~40-line shell: terminal setup, program_init, run.
package edit

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import rg "../../../runegloss"
import rt "../../../runetea"

// Fixed capacities, no [dynamic] anywhere in Model, and that is still
// deliberate -- though the reason has narrowed. Model is copied by value in
// several places that remain (rt's `view` signature takes T by value; these
// tests pass whole Models around as fixtures), and a [dynamic]Line field would
// survive such a copy only by ALIASING: both copies would point at one backing
// store. rt.run's guarded update (guard.odin) can longjmp out of a panicking
// update after an append has already realloc'd that store, leaving the other
// copy's header pointing at freed memory. Fixed arrays make a copy the whole
// truth, with nothing shared behind it.
//
// NOTE this is NOT box()'s POD rule -- Model is never boxed; only Msgs are
// (arena.odin's MESSAGE OWNERSHIP CONTRACT). It happens to be POD anyway.
//
// THE CAPACITIES USED TO BE 32x64 FOR A TOOLCHAIN REASON, AND THAT REASON IS
// GONE. Recorded because it shaped this file, not because it still binds:
//
// rt's update signature used to be `proc(model: T, msg: any, ...) -> (T, Cmd)`
// -- model in by value, model out by value, assigned back into p.model by
// apply(). LLVM code generation for that one call was superlinear in
// sizeof(T), which put a hard ceiling on how big a RuneTea model could be.
// Measured on this toolchain, `odin build examples/editor`, wall clock, with
// `-show-timings` attributing >96% of it to "LLVM API Code Gen":
//
//   ~2 KiB model    1.3 s
//   ~8 KiB model   10.1 s
//   ~18 KiB model  122.2 s
//   ~32 KiB model  did not finish in 150 s
//
// That is why these were 32x64 (~8 KiB) and not 64x128, and the old comment
// here warned people off "generously" raising them.
//
// The signature is now `proc(model: ^T, msg: any, ...) -> Cmd` -- see
// rt.Program.update (runetea/tea.odin) for the full measurement table, the
// bisection that pinned it to that single call, and the crash-safety property
// the change cost. Build time is now FLAT in sizeof(T), so these capacities
// were raised ~8x/4x -- a ~252 KiB Model against the old ~8 KiB one, and 4x
// past the 64 KiB size that used to not finish compiling in 200 s at all.
// This example is the regression test for that fix: if the ceiling ever comes
// back, THIS is what stops compiling. (Measured after the change: the whole
// example builds in ~0.9 s.)
//
// 250 AND NOT 256 FOR AN UNRELATED, MUCH SOFTER LIMIT. Odin emits
// "Declaration of 'x' may cause a stack overflow" for any local whose type
// exceeds exactly 262144 bytes (bisected on this toolchain: 262144 is silent,
// 262145 warns). 256 lines puts Model at 264232 and trips it -- 33 warnings
// across this file and editor_test.odin, which pass Models around as fixtures.
// 250 lines puts it at 258048, just under. Note what this limit is and is not:
// it is about STACK LOCALS in application code, not about the framework, and
// the fix for an app that genuinely wants a bigger model is to heap-allocate
// its Program -- unlike the old codegen ceiling, which no amount of
// application-side care could work around.
MAX_LINES :: 250
MAX_COLS  :: 256
TAB_WIDTH :: 4

// THE TEXT AREA IS DERIVED FROM term_h, AND IT USED TO BE A CONSTANT 10.
//
// `VIEWPORT :: 10` was a compile-time constant while the Model has tracked
// term_h since T2-C, so on a 30-row terminal seventeen rows were dead space
// below the status bar and on a 14-row one the status bar was pushed off the
// bottom of the screen entirely. The frame is now exactly term_h rows: the two
// preamble rows, the text area, and the two closing rows (CHROME_ROWS).
//
// TEN IS STILL THE ANSWER WHEN term_h IS 0. Zero is this app's "size unknown"
// -- no tty (editor_test.odin drives run() with flush_fd = -1), or an ioctl
// that failed -- and it is also the width/height the RENDERER assumes in that
// case, so the layout and the paint stay wrong together or right together.
// Ten specifically because it is what this example painted before, so a
// size-less run produces the frame its golden already pins.
VIEWPORT_UNSIZED :: 10

// Header, the rule under it, the rule above the status bar, and the status bar.
// `cursor` and `click_target` depend on the first two being exactly HEADER_LINES
// physical rows, which is true because header_line and rule_line are both
// TRUNCATED to term_w rather than left to wrap.
CHROME_ROWS :: HEADER_LINES + 2

// Below either of these the editor paints a single "too small" line instead of
// a layout (F47). The numbers are what the layout needs, not a preference:
// MIN_ROWS is CHROME_ROWS plus two text rows, and MIN_COLS is the width at
// which the gutter still leaves a usable text column and the status bar can
// still show `Ln n, Col n`. At exactly 20x6 the real editor is painted -- these
// are the smallest supported size, not the smallest comfortable one.
MIN_COLS :: 20
MIN_ROWS :: 6

// Runes, not bytes: the cursor is then a rune index and every movement,
// insert and delete is plain integer arithmetic that cannot land in the
// middle of a UTF-8 sequence. Storing bytes would mean re-deriving rune
// boundaries in Left/Right/Backspace/Delete/word-jump -- six places to get
// wrong in a file whose entire point is that the key handling is correct.
//
// A RUNE INDEX IS NOT A CARET POSITION, though, and treating it as one was a
// real defect: `e` + U+0301 is one visible character in one cell and two
// runes, so Left moved m.cx and did not move the caret. m.cx is now always a
// GRAPHEME CLUSTER BOUNDARY -- see the cluster section below for the walk that
// finds them and for everything that had to start going through it.
Line :: struct {
	r: [MAX_COLS]rune,
	n: int,
}

// What the last keypress did. An enum, not a string, so the status line costs
// nothing to maintain and so the tests can assert on INTENT ("that Ctrl+Right
// was decoded as a word jump") separately from effect ("the column moved").
Action :: enum u8 {
	None, Insert, Newline, Backspace, Delete,
	Left, Right, Up, Down,
	Word_Left, Word_Right,
	Home, End, Page_Up, Page_Down,
	Indent, Toggle_Help, Paste,
	// T2-B. APPENDED, like every other member added to an enum in this repo --
	// ACTION_NAME below is an [Action]string, so an inserted member would
	// silently shift every existing label.
	Scroll_Up, Scroll_Down,
	// T2-C. Appended for the same reason.
	Click,
	// A REFUSAL, and the reason there are two of them. Every edit in this file
	// used to fail SILENTLY at its capacity: insert_rune returned with the line
	// at MAX_COLS, split_line returned with the document at MAX_LINES, and
	// join_next copied what fit and then deleted the source line anyway --
	// which destroyed a whole line of text per keypress and still reported
	// "last:delete" (the F22 data loss). A refusal the status bar names is the
	// difference between a cap and a bug.
	Line_Full, Doc_Full,
}

ACTION_NAME := [Action]string{
	.None = "-", .Insert = "insert", .Newline = "newline",
	.Backspace = "backspace", .Delete = "delete",
	.Left = "left", .Right = "right", .Up = "up", .Down = "down",
	.Word_Left = "word-left", .Word_Right = "word-right",
	.Home = "home", .End = "end", .Page_Up = "page-up", .Page_Down = "page-down",
	.Indent = "indent", .Toggle_Help = "help", .Paste = "paste",
	.Scroll_Up = "scroll-up", .Scroll_Down = "scroll-down",
	.Click = "click",
	.Line_Full = "LINE FULL", .Doc_Full = "DOC FULL",
}

Model :: struct {
	lines:   [MAX_LINES]Line,
	nlines:  int,
	cy, cx:  int,    // cursor: line index, rune index within that line
	top:     int,    // first visible line -- the scroll offset
	pasting: bool,   // between Paste_Start_Msg and Paste_End_Msg
	// F56. The last pasted rune was a CR, so an LF arriving next is the second
	// half of one CRLF line break and must NOT split a second time.
	//
	// STATE RATHER THAN LOOKAHEAD because a paste is STREAMED: input.odin emits
	// one Key_Msg per rune between Paste_Start_Msg and Paste_End_Msg
	// (LIMITATIONS 2.1 -- a `string` field in a Msg is illegal, so there is no
	// message carrying the whole payload), and update() therefore never sees
	// the byte after the one it is handling. Without this a CRLF document --
	// anything produced on Windows, and anything a terminal that passes paste
	// bytes through verbatim delivers (Alacritty and foot do; VTE sends CR
	// only) -- gained a blank line after every source line: 18 lines pasted in
	// came out as 22 with "alpha / <blank> / beta".
	paste_cr: bool,
	help:    bool,   // toggled by Ctrl+I -- see apply_key
	// What the terminal actually answered to term_enter_raw's `CSI ? u`
	// query. false means no reply came back, i.e. the legacy encoding, i.e.
	// Tab and Ctrl+I below are the same byte and only one of them can win.
	// The view prints this so the Tab-vs-Ctrl+I demonstration is visibly
	// conditional rather than silently so.
	kitty:   bool,
	last:    Action,
	// T2-C. The terminal's size, as this app last knew it. IT IS NOW THE WHOLE
	// LAYOUT, and it used to be click-to-position and a status field.
	//
	// It was already load-bearing for CLICK-TO-POSITION: turning a Mouse_Msg's
	// absolute screen row into a view line means knowing how many PHYSICAL rows
	// each view line above it occupies, and that is a function of the width
	// (rt.rows_for_line). What it was NOT used for was the chrome, and the cost
	// was measurable at the industry-default 80x24: a 101-column header wrapped
	// onto a second row, a 74-dash rule stopped six columns short, and the text
	// area stayed at ten rows while ten more sat empty below the status bar. At
	// 40x14 the header ate three rows and pushed the status bar off the screen.
	// header_line, rule_line, text_rows and the help panel are all derived from
	// these two now; `term_h` in particular is what decides how many text rows
	// the frame has, so a resize changes the layout rather than only a label.
	//
	// SEEDED BY main.odin from rt.term_size at startup and kept live here from
	// Window_Size_Msg; 0 means "unknown", which rt.rows_for_line reads as "assume
	// one row per line". That is the same assumption the RENDERER makes with an
	// unknown width, which is the property that matters: the mapping and the
	// paint are wrong together or right together, never inconsistent with each
	// other. An unknown height means VIEWPORT_UNSIZED text rows, for the same
	// reason.
	term_w:  int,
	term_h:  int,
	// T3-B. WHICH COLOURS THIS TERMINAL CAN SHOW -- one byte, and the only
	// styling state this Model carries.
	//
	// The alternative was to store the six built rg.Styles themselves. A
	// rg.Style IS storable in a model (it is POD by construction -- see
	// runegloss/style.odin, and examples/spinner does exactly that), but not in
	// THIS model: Model is already ~258 KiB and deliberately sized to stay under
	// the 262144-byte stack-local warning threshold documented on MAX_LINES, and
	// six Styles is ~1 KiB of that budget spent to avoid rebuilding six structs
	// that cost no allocation to build. So the ENVIRONMENT-DEPENDENT half lives
	// here and `palette` below derives the rest per frame.
	//
	// ZERO VALUE IS .None -- no colour escapes at all -- so a Model that nobody
	// told about the terminal renders exactly the bytes this example rendered
	// before RuneGloss existed. main.odin passes rg.default_profile(); the tests
	// force one (see editor_test's TEST_PROFILE) so the golden cannot depend on
	// whatever $TERM the machine running it happens to have.
	profile: rg.Profile,
}

// ---------------------------------------------------------------------------
// styling
// ---------------------------------------------------------------------------

// The editor's six styles, derived from the one thing that varies between
// terminals. Built fresh per frame and that is deliberate: rg.Style construction
// is pure struct assignment with no allocation, and a palette that is a FUNCTION
// of (profile, width) cannot drift out of date the way a cached copy would after
// a resize.
//
// EVERY STYLE IS BUILT WITH new_style_profile, NEVER new_style. new_style() reads
// the process-wide detected profile, which is a function of $TERM/$COLORTERM --
// so a view built on it renders different bytes on different machines, and the
// golden in testdata/ would be untestable. Threading the profile through from the
// model is what makes this view a pure function of the model.
Palette :: struct {
	header:     rg.Style,   // the key-help line at the top
	rule:       rg.Style,   // the two horizontal rules, and the "~" filler rows
	gutter:     rg.Style,   // line numbers
	gutter_cur: rg.Style,   // ...on the line the caret is on
	status:     rg.Style,   // the bottom bar
	help:       rg.Style,   // the Ctrl+I panel
}

// #7D56F4 is Lipgloss's own signature purple, kept here on purpose: this file is
// the thing people will copy, and a shared accent between the header, the caret's
// gutter and the status bar is what makes three separately-styled regions read as
// one interface.
ACCENT :: "#7D56F4"

// ANSI 244, a mid grey. A PALETTE INDEX rather than a hex literal because grey is
// the one colour a user's terminal theme should be allowed to have an opinion
// about -- rg.color(244) is passed through untouched on any profile that has 256
// colours, where a hex grey would be quantised to whichever palette slot happens
// to be nearest.
MUTED :: 244

palette :: proc(p: rg.Profile, term_w, term_h: int) -> Palette {
	pal: Palette

	pal.header = rg.new_style_profile(p)
	rg.fg(&pal.header, rg.color(ACCENT))
	rg.bold(&pal.header, true)

	pal.rule = rg.new_style_profile(p)
	rg.faint(&pal.rule, true)

	pal.gutter = rg.new_style_profile(p)
	rg.fg(&pal.gutter, rg.color(MUTED))

	pal.gutter_cur = rg.new_style_profile(p)
	rg.fg(&pal.gutter_cur, rg.color(ACCENT))
	rg.bold(&pal.gutter_cur, true)

	pal.status = rg.new_style_profile(p)
	rg.fg(&pal.status, rg.color("#FFFFFF"))
	rg.bg(&pal.status, rg.color(ACCENT))
	// EXACT COLUMNS, and the `.Truncate` is not decoration. rg.width used to be
	// a FLOOR: a status string longer than the window rendered in full and the
	// terminal wrapped it onto a second row, which in a frame budgeted to
	// exactly term_h rows costs the bottom row of the text area. It is a clamp
	// now (runegloss's F06/F21 fix), and the clamp's DEFAULT is .Wrap -- which
	// would produce the same second row by a different route. .Truncate with an
	// ellipsis is the only overflow policy that keeps this bar one row tall at
	// every width, and the fields are ordered most-useful-first (Ln/Col before
	// the term size) precisely because the tail is what gets cut.
	// term_w == 0 is this app's "size unknown" and rg.width(0) is
	// "unconstrained", so the two agree with no `if` here.
	rg.width(&pal.status, term_w)
	rg.overflow(&pal.status, .Truncate)
	rg.ellipsis(&pal.status, "…")

	pal.help = rg.new_style_profile(p)
	rg.fg(&pal.help, rg.color(MUTED))
	// NO BORDER WHEN THERE IS NO ROOM FOR CONTENT INSIDE ONE. A rounded border
	// costs two of the text area's rows and two of its columns; at 20x6 the
	// area is two rows tall, so a bordered panel is an EMPTY BOX -- verified
	// under a pty before this branch existed. The border is chrome and the help
	// text is the point, so below three rows the chrome goes and the prose gets
	// the whole area.
	if text_area_rows(term_h) >= 3 {
		rg.border(&pal.help, rg.ROUNDED)
		rg.border_fg(&pal.help, rg.color(ACCENT))
		rg.padding(&pal.help, 0, 1)
	}
	// F23. THE PANEL IS SIZED TO THE WINDOW, and it was the only styled element
	// here that never was -- pal.status four lines above has taken term_w since
	// T3-B. Without a width the box was pinned at its longest content line (74)
	// + padding (2) + border (2) = 78 columns forever, so below 78 the terminal
	// wrapped it: the top border broke across two rows, the right `│` landed
	// mid-sentence and the closing `╯` sat alone on a line of its own. Without a
	// height it was appended after a fixed 14-row layout with no reference to
	// term_h at all, so at 18 rows it opened with a top border, three content
	// rows and NO BOTTOM BORDER.
	//
	// Both are now exact (rg.width/rg.height include the border, lipgloss v2's
	// rule), and the panel occupies the TEXT AREA rather than being appended
	// below the status bar -- see view(). .Wrap, not .Truncate: the panel is
	// prose and the whole point of it is to be read, so a narrow window should
	// reflow it, not cut it. 0 for either axis when the size is unknown, which
	// restores the natural 78x5 box the golden pins.
	// 78 when the width is unknown -- the box's own old pinned size, chosen for
	// the same reason VIEWPORT_UNSIZED is 10 and RULE_UNSIZED_COLS is 74: an
	// app that cannot measure its terminal should paint what this example
	// always painted. Leaving it unconstrained instead was tried and is worse
	// than the bug it replaces: with the panel's text now written as reflowable
	// paragraphs rather than pre-broken lines, "unconstrained" means one
	// 200-column line and a box wider than any terminal.
	rg.width(&pal.help, term_w > 0 ? term_w : HELP_UNSIZED_COLS)
	rg.height(&pal.help, text_area_rows(term_h))

	return pal
}

// The physical rows the text area gets, from the terminal height alone. Split
// out of text_rows(Model) so palette() -- which is handed the two sizes and not
// the Model -- computes the help panel's height from the same expression the
// text rows it replaces are computed from.
@(private)
text_area_rows :: proc(term_h: int) -> int {
	if term_h <= 0 { return VIEWPORT_UNSIZED }
	return max(1, term_h - CHROME_ROWS)
}

// How many physical rows this frame's text area has. See text_area_rows.
text_rows :: proc(m: Model) -> int { return text_area_rows(m.term_h) }

// F47. Below this the layout has nowhere to go and view() paints a single line
// saying so instead of a frame whose parts have been squeezed into nonsense.
//
// A 0 on either axis is "size unknown", NOT "zero", and must never trip this:
// every test in this package runs with no tty, and a real ioctl failure is
// reported the same way (rt sets both to 0). Unknown means "assume the
// defaults", which is what the rest of this file does with it.
too_small :: proc(m: Model) -> bool {
	return (m.term_w > 0 && m.term_w < MIN_COLS) || (m.term_h > 0 && m.term_h < MIN_ROWS)
}

// ---------------------------------------------------------------------------
// text primitives
// ---------------------------------------------------------------------------

// `profile` is a TRAILING DEFAULTED PARAMETER, the same opt-in shape
// rt.term_enter_raw and rt.renderer_init use: .None renders no colour escapes at
// all, so every existing call site (and every test fixture) keeps its old bytes
// with nothing said, and only main.odin -- which alone knows what terminal it is
// attached to -- passes rg.default_profile().
// THE LOADER SANITISES CONTROL CHARACTERS, and that is a correctness
// requirement rather than tidiness -- caught by rt.view_diff_safe, which is
// what test_the_editors_view_satisfies_the_diff_renderers_contract runs over a
// real view.
//
// Every other route into this document already refused to admit a C0 byte:
// apply_key's paste branch takes only `k.r >= 0x20`, and the Tab KEY inserts
// TAB_WIDTH spaces rather than a 0x09. init did not, so loading a tab-indented
// file -- which is what an editor is FOR -- put a literal 0x09 straight into
// the view. Under rt.Render_Mode.Diff that is silent corruption: a tab is a
// MOVE to the next tab stop, the cell model does not perform it, and every cell
// after it on that row is somewhere the renderer does not think it is. Under
// .Full_Screen (what this example actually runs) it merely renders, which is
// precisely why it survived unnoticed.
//
//   * TAB expands to the same TAB_WIDTH spaces the Tab key inserts, so a loaded
//     document and a typed one indent identically.
//   * ANY OTHER C0 (and DEL) is DROPPED, matching the paste branch exactly. A
//     substitute glyph would be an editor inventing content it cannot save back.
init :: proc(text: string, profile: rg.Profile = .None) -> Model {
	m: Model
	m.profile = profile
	m.nlines = 1
	for r in text {
		if r == '\n' {
			if m.nlines >= MAX_LINES { break }
			m.nlines += 1
			continue
		}
		l := &m.lines[m.nlines - 1]
		if r == '\t' {
			for _ in 0 ..< TAB_WIDTH {
				if l.n >= MAX_COLS { break }
				l.r[l.n] = ' '
				l.n += 1
			}
			continue
		}
		if r < 0x20 || r == 0x7F { continue }
		if l.n < MAX_COLS { l.r[l.n] = r; l.n += 1 }
	}
	return m
}

// line returns the text of line i as a fresh string. Callers own it; the view
// hands it the frame allocator, so it dies with the frame (arena.odin's
// LIFETIME CONTRACT).
line_text :: proc(m: Model, i: int, alloc: mem.Allocator) -> string {
	if i < 0 || i >= m.nlines { return "" }
	sb := strings.builder_make(alloc)
	for k in 0 ..< m.lines[i].n { strings.write_rune(&sb, m.lines[i].r[k]) }
	return strings.to_string(sb)
}

// Returns false when the line is at MAX_COLS and the rune was NOT inserted.
// The bool exists so the caller can say so in the status bar: a keystroke that
// is silently discarded is indistinguishable from a keystroke the terminal
// never delivered, and this line had exactly that failure mode for its whole
// life.
@(private)
insert_rune :: proc(m: ^Model, r: rune) -> bool {
	l := &m.lines[m.cy]
	if l.n >= MAX_COLS { return false }
	for k := l.n; k > m.cx; k -= 1 { l.r[k] = l.r[k - 1] }
	l.r[m.cx] = r
	l.n += 1
	m.cx += 1
	return true
}

// ---------------------------------------------------------------------------
// grapheme clusters
//
// THE CARET MOVES BY CLUSTER, NOT BY RUNE, and until rt.Cluster_Iter became
// public (width.odin's F46) it could not: whole-string display_width was the
// only public measure, so an application had no way to ask where one user-
// perceived character ends and the next begins.
//
// What that cost, exactly: type `e` then U+0301 (COMBINING ACUTE) -- one
// visible `é`, one cell, two runes -- and press Left. `m.cx` went from 2 to 1,
// the status bar's Col counter changed, and the CARET DID NOT MOVE, because
// cursor() measures the display width of the prefix and U+0301 is zero-width.
// A dead keystroke, repeatable for every combining mark, every regional
// indicator pair and every ZWJ emoji sequence in the document. Backspace was
// the same shape from the other side: it removed the mark and left the base
// letter, so `é` became `e` and the user had to press it twice.
//
// The walk is O(line) per keypress on a line capped at 256 runes, which is why
// this is three stack buffers and no cache: a cached cluster table would have
// to be invalidated by every insert, delete, paste and join in this file, and
// the thing it would save is a memcpy of at most 1 KiB.
// ---------------------------------------------------------------------------

// Fills `out` with the RUNE INDEX at which each grapheme cluster of `l` starts,
// and returns how many there are. out must hold at least l.n + 1 entries.
@(private)
cluster_starts :: proc(l: Line, out: []int) -> int {
	// The line as UTF-8, because rt.cluster_iter_make takes a string and this
	// Model stores runes (see Line). MAX_COLS * 4 is the exact worst case.
	buf: [MAX_COLS * 4]u8
	p := 0
	for k in 0 ..< l.n {
		b, n := utf8.encode_rune(l.r[k])
		copy(buf[p:], b[:n])
		p += n
	}
	ci := rt.cluster_iter_make(string(buf[:p]))
	count, ri := 0, 0
	for {
		span, _, ok := rt.cluster_next(&ci)
		if !ok { break }
		out[count] = ri
		count += 1
		ri += utf8.rune_count_in_string(span)
	}
	return count
}

// The rune index of the start of the cluster that ENDS at cx -- i.e. where the
// caret lands when it moves one cluster left, and what Backspace removes back to.
@(private)
cluster_left :: proc(l: Line, cx: int) -> int {
	if cx <= 0 { return 0 }
	starts: [MAX_COLS + 1]int
	n := cluster_starts(l, starts[:])
	at := 0
	for i in 0 ..< n {
		if starts[i] >= cx { break }
		at = starts[i]
	}
	return at
}

// The rune index of the start of the cluster AFTER the one containing cx --
// i.e. where the caret lands moving one cluster right, and what Delete removes
// forward to. l.n when cx is inside the last cluster.
@(private)
cluster_right :: proc(l: Line, cx: int) -> int {
	if cx >= l.n { return l.n }
	starts: [MAX_COLS + 1]int
	n := cluster_starts(l, starts[:])
	for i in 0 ..< n {
		if starts[i] > cx { return starts[i] }
	}
	return l.n
}

// Snaps a rune index back to the start of the cluster containing it. A click
// (and only a click) can name a position inside a cluster; every other route
// into m.cx already produces a boundary.
@(private)
cluster_snap :: proc(l: Line, cx: int) -> int {
	if cx <= 0 || cx >= l.n { return clamp(cx, 0, l.n) }
	return cluster_left(l, cx + 1)
}

// Splits the current line at the cursor -- Enter, and every '\n' inside a
// paste (see apply_key: inside a paste there are no key semantics, so a
// newline arrives as Key_Msg{code = .Rune, r = '\n'}, not as .Enter).
// Returns false when the document is at MAX_LINES and nothing was split -- the
// same silent-refusal problem insert_rune had, reported the same way.
@(private)
split_line :: proc(m: ^Model) -> bool {
	if m.nlines >= MAX_LINES { return false }
	for i := m.nlines; i > m.cy + 1; i -= 1 { m.lines[i] = m.lines[i - 1] }
	m.nlines += 1

	cur  := &m.lines[m.cy]
	next := &m.lines[m.cy + 1]
	next^ = Line{}
	for k in m.cx ..< cur.n { next.r[next.n] = cur.r[k]; next.n += 1 }
	cur.n = m.cx

	m.cy += 1
	m.cx = 0
	return true
}

// Appends line at+1 onto line `at` and closes the gap. The shared tail of
// Backspace-at-column-0 and Delete-at-end-of-line, which is exactly why those
// two have to be distinct operations: they join the SAME pair of lines but
// leave the cursor in different places.
//
// Returns false when the join was REFUSED, which is the F22 fix and is the
// whole reason this proc reports anything. It used to copy next.r into cur.r
// and `break` the instant cur.n reached MAX_COLS -- and then close the gap and
// decrement nlines UNCONDITIONALLY. So on a line already at the 256-rune cap,
// one Delete at end-of-line (or one Backspace at column 0) deleted an entire
// line of the document having copied NOT ONE CHARACTER of it, with no message,
// no beep and no undo, while the status bar reported "last:delete". Held down,
// the key destroyed the document one line per key repeat. Measured at 120x30
// under a pty: 260 X's pasted into line 1, End, three Deletes -> 18/17/16/15
// lines with line 1 unchanged, i.e. three whole lines erased and nothing kept.
//
// A partial join was never on the table -- there is no correct place to put the
// half that does not fit, and an editor that keeps some of your text and
// discards the rest silently is worse than one that refuses. The caller turns
// the false into Action.Line_Full, so the refusal is on screen.
@(private)
join_next :: proc(m: ^Model, at: int) -> bool {
	if at + 1 >= m.nlines { return false }
	cur  := &m.lines[at]
	next :=  m.lines[at + 1]
	if cur.n + next.n > MAX_COLS { return false }
	for k in 0 ..< next.n {
		cur.r[cur.n] = next.r[k]; cur.n += 1
	}
	for i := at + 1; i < m.nlines - 1; i += 1 { m.lines[i] = m.lines[i + 1] }
	m.nlines -= 1
	m.lines[m.nlines] = Line{}
	return true
}

// ---------------------------------------------------------------------------
// movement
// ---------------------------------------------------------------------------

// Pulls the caret back onto the current line -- Up and Down keep the COLUMN,
// which the shorter line may not have -- and onto a cluster boundary while it
// is there. The snap matters because a column carried down from another line
// can land between the two runes of one visible character, and cursor() would
// then measure a prefix that cuts a cluster in half and park the caret inside a
// glyph. is_word is ASCII-only, so word_left/word_right can stop in the same
// place; they go through here too.
@(private)
clamp_cx :: proc(m: ^Model) {
	l := m.lines[m.cy]
	if m.cx > l.n { m.cx = l.n }
	m.cx = cluster_snap(l, m.cx)
}

// How many DOCUMENT lines the text area shows, starting at m.top.
//
// IT IS NOT text_rows(m), AND THAT IS THE POINT. A view line wider than the
// window wraps onto several PHYSICAL rows, so the number of logical lines a
// fixed row budget holds depends on the content. The old code answered the
// constant VIEWPORT to this question and the frame simply overflowed: at 40
// columns every line of the sample document takes two rows, so ten of them ask
// for twenty rows of a fourteen-row screen and the renderer truncated the
// frame -- taking the status bar with it.
//
// AT LEAST ONE, always: a single line taller than the whole text area is shown
// and clipped by the renderer rather than producing an empty screen.
//
// The row strings come from row_text -- the ONE copy of that formatting, which
// view() also paints and click_target also measures -- so this cannot disagree
// with what is on screen. They are built from `alloc`, which is rt's frame
// arena, and die with the frame (arena.odin's LIFETIME CONTRACT).
@(private)
visible_count :: proc(m: Model, pal: ^Palette, alloc: mem.Allocator) -> int {
	budget := text_rows(m)
	used, n := 0, 0
	for m.top + n < m.nlines {
		r := rt.rows_for_line(row_text(m, m.top + n, pal, alloc), m.term_w)
		if n > 0 && used + r > budget { break }
		used += r
		n += 1
		if used >= budget { break }
	}
	return max(n, 1)
}

// The SMALLEST `top` for which document line `at` is still inside the text
// area -- the same walk as visible_count run backwards. Two callers, and they
// are the two clamps every scroll obeys: `top_for(m, m.cy)` is the lowest the
// window may sit and still show the caret, and `top_for(m, m.nlines - 1)` is
// the highest it may sit at all (scrolling past the last line shows blank rows
// nothing can put text in). It is monotone in `at`, so the two never fight.
@(private)
top_for :: proc(m: Model, at: int, pal: ^Palette, alloc: mem.Allocator) -> int {
	budget := text_rows(m)
	used, t := 0, min(at + 1, m.nlines)
	for t > 0 {
		r := rt.rows_for_line(row_text(m, t - 1, pal, alloc), m.term_w)
		if used > 0 && used + r > budget { break }
		used += r
		t -= 1
		if used >= budget { break }
	}
	return t
}

// Keeps the cursor inside the visible window. Called after every action, so
// no individual key handler has to remember to scroll.
//
// TAKES AN ALLOCATOR NOW, and the reason is the wrapping above: deciding
// whether the caret is visible means laying the text area out, and laying it
// out means building the row strings. update() is handed rt's frame arena and
// passes it straight through, so this costs the frame nothing that view() was
// not about to spend anyway.
@(private)
follow_cursor :: proc(m: ^Model, alloc: mem.Allocator) {
	pal := palette(m.profile, m.term_w, m.term_h)
	if m.cy < m.top { m.top = m.cy }
	if t := top_for(m^, m.cy, &pal, alloc); m.top < t { m.top = t }
	if hi := top_for(m^, m.nlines - 1, &pal, alloc); m.top > hi { m.top = hi }
	if m.top < 0 { m.top = 0 }
}

// BY GRAPHEME CLUSTER, not by rune -- see the cluster section above for what
// moving by rune cost (a Left that changed the column counter and did not move
// the caret).
@(private)
move_left :: proc(m: ^Model) {
	if m.cx > 0 { m.cx = cluster_left(m.lines[m.cy], m.cx); return }
	if m.cy > 0 { m.cy -= 1; m.cx = m.lines[m.cy].n }   // across the line boundary
}

@(private)
move_right :: proc(m: ^Model) {
	if l := m.lines[m.cy]; m.cx < l.n { m.cx = cluster_right(l, m.cx); return }
	if m.cy < m.nlines - 1 { m.cy += 1; m.cx = 0 }      // across the line boundary
}

@(private)
is_word :: proc(r: rune) -> bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_'
}

// Emacs/readline forward-word: skip whatever non-word run the cursor is in,
// then skip the word itself -- so from column 0 of "hello world" one press
// lands on 5 (end of "hello") and the next on 11.
@(private)
word_right :: proc(m: ^Model) {
	l := m.lines[m.cy]
	if m.cx >= l.n { move_right(m); return }
	for m.cx < l.n && !is_word(l.r[m.cx]) { m.cx += 1 }
	for m.cx < l.n &&  is_word(l.r[m.cx]) { m.cx += 1 }
}

@(private)
word_left :: proc(m: ^Model) {
	if m.cx == 0 { move_left(m); return }
	l := m.lines[m.cy]
	for m.cx > 0 && !is_word(l.r[m.cx - 1]) { m.cx -= 1 }
	for m.cx > 0 &&  is_word(l.r[m.cx - 1]) { m.cx -= 1 }
}

// ---------------------------------------------------------------------------
// update
// ---------------------------------------------------------------------------

// `m` is a POINTER -- mutate in place, return only the Cmd. See
// rt.Program.update (runetea/tea.odin) for why, and for what a panic partway
// through this proc now does (and no longer does) to the model.
update :: proc(m: ^Model, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	switch v in msg {
	case rt.Paste_Start_Msg:
		// Bubble Tea's PasteMsg{Content string} does not exist here -- box()
		// rejects a `string` field -- so the content is STREAMED as ordinary
		// Key_Msgs with pasted = true between these two markers (input.odin).
		// For an editor that is strictly nicer: nothing has to buffer the
		// paste, it just gets inserted as it arrives.
		m.pasting = true
		m.paste_cr = false
		m.last = .Paste
	case rt.Paste_End_Msg:
		m.pasting = false
		m.paste_cr = false
	case rt.Keyboard_Enhancements_Msg:
		m.kitty = .Disambiguate in v.flags
	case rt.Window_Size_Msg:
		// T2-C. rt's own renderer already consumed this before update() was
		// called (rt.apply keeps Renderer.term_width/term_height live from the
		// same message), so this is not the app doing the framework's job -- it
		// is the app keeping ITS copy of the width, which click_target needs to
		// account for wrapped view lines exactly the way the renderer does.
		// w == 0 is rt's "the ioctl failed" sentinel; ignore it rather than
		// clobbering a known-good width, same rule rt.apply follows.
		if v.w > 0 { m.term_w = v.w }
		if v.h > 0 { m.term_h = v.h }
	case rt.Mouse_Msg:
		return apply_mouse(m, v, alloc)
	case rt.Key_Msg:
		return apply_key(m, v, alloc)
	}
	return rt.cmd_nil()
}

// How many lines one wheel notch scrolls. Three is what most editors and
// terminals use; it is a constant rather than 1 because a one-line-per-notch
// scroll feels broken on a trackpad.
WHEEL_LINES :: 3

// T2-B/T2-C: the mouse. The wheel scrolls; a LEFT PRESS positions the caret.
//
// T2-B DECLINED TO BIND CLICK-TO-POSITION, and the reason it gave was correct
// at the time: a click carries ABSOLUTE TERMINAL COORDINATES (rt.Mouse_Msg.x/y
// are screen cells, 0-based from the top-left of the WINDOW), and turning `y`
// into a view line needs to know which screen row this frame's first line is on.
// rt's renderer was an INLINE REWIND renderer, so a frame sat wherever the
// terminal's cursor happened to be -- it had no screen origin at all, and a
// binding built on a guessed one would put the caret on the wrong line whenever
// the frame was not flush against the top of the window.
//
// T2-C REMOVED EXACTLY THAT OBSTACLE. main.odin now runs this program with
// rt.Render_Mode.Diff inside the alternate screen, and .Diff delivers exactly
// the frame .Full_Screen paints -- homed at the top-left cell, every frame -- so
// VIEW LINE 0 IS SCREEN ROW 0 by construction, with nothing to track. (T2-C used
// .Full_Screen here; T3-A swapped the delivery, not the frame, which is why this
// mapping did not have to change.) `y` is then a physical row within the frame,
// and the only remaining
// work is the one the inline renderer could not have done either: physical rows
// are not logical lines, because a view line wider than the terminal wraps onto
// several of them. click_target does that arithmetic with rt.rows_for_line --
// the SAME function the renderer itself uses to lay the frame out -- so the two
// cannot disagree about which row a line starts on. That is what makes this
// well-defined rather than merely usually-right.
//
// `.Press` only, and only the LEFT button: a release would fire a second time on
// the same spot, and a right/middle click has no meaning in this editor.
apply_mouse :: proc(m: ^Model, mo: rt.Mouse_Msg, alloc: mem.Allocator) -> rt.Cmd {
	if mo.kind == .Press && mo.button == .Left {
		if cy, cx, ok := click_target(m^, mo.x, mo.y, alloc); ok {
			m.cy, m.cx = cy, cx
			m.last = .Click
			// follow_cursor, not a bare assignment: a click can only land on a
			// visible line, so this is a no-op today -- but it is the invariant
			// every other action in this file maintains, and leaving it out would
			// make this the one code path that could ever leave the caret outside
			// the window.
			follow_cursor(m, alloc)
		}
		return rt.cmd_nil()
	}
	if mo.kind != .Wheel { return rt.cmd_nil() }
	pal := palette(m.profile, m.term_w, m.term_h)
	#partial switch mo.button {
	case .Wheel_Up:
		m.top = max(0, m.top - WHEEL_LINES)
		m.last = .Scroll_Up
	case .Wheel_Down:
		m.top = min(top_for(m^, m.nlines - 1, &pal, alloc), m.top + WHEEL_LINES)
		m.last = .Scroll_Down
	case:
		return rt.cmd_nil()   // horizontal wheel: this view does not scroll sideways
	}
	// THE WINDOW MOVED, SO THE CARET MAY NOW BE OUTSIDE IT. Pull it back to the
	// nearest visible line rather than letting cursor() (which returns the zero
	// Cursor for an off-screen caret) silently stop drawing it -- and note this
	// is the OPPOSITE direction from follow_cursor, which moves the window to
	// the caret. Scrolling is the one action where the window leads.
	m.cy = clamp(m.cy, m.top, min(m.top + visible_count(m^, &pal, alloc), m.nlines) - 1)
	clamp_cx(m)
	return rt.cmd_nil()
}

// ^Model for the same reason update() takes one: Model is ~258 KiB now, so a
// by-value in-and-out of this proc would be half a megabyte of memcpy per
// keypress on top of reintroducing exactly the codegen blowup the pointer
// signature exists to avoid.
apply_key :: proc(m: ^Model, k: rt.Key_Msg, alloc: mem.Allocator) -> rt.Cmd {
	// PASTED RUNES ARE TEXT, UNCONDITIONALLY. Checked before anything else,
	// mirroring decode_keys' own precedence: inside a paste no escape
	// sequence is decoded and no key semantics are applied, so a pasted "\n"
	// is Key_Msg{code = .Rune, r = '\n'} and a pasted "\e[A" is three literal
	// runes. An editor that dropped this branch and let a pasted 'q' hit its
	// quit binding would be the classic bracketed-paste bug.
	if k.pasted {
		// F56. CR, then LF, is ONE line break, and this branch used to treat
		// them as two -- see Model.paste_cr for the measurement. The CR does the
		// split (so a CR-only paste, which is what VTE delivers, is unchanged)
		// and the LF that follows it is swallowed.
		was_cr := m.paste_cr
		m.paste_cr = k.r == '\r'
		switch {
		case k.r == '\n' && was_cr:
			m.last = .Paste
		case k.r == '\n' || k.r == '\r':
			m.last = split_line(m) ? .Paste : .Doc_Full
		case k.r >= 0x20:
			m.last = insert_rune(m, k.r) ? .Paste : .Line_Full
		case:
			m.last = .Paste   // a C0 byte inside the payload: dropped, as before
		}
		follow_cursor(m, alloc)
		return rt.cmd_nil()
	}

	#partial switch k.code {
	case .Rune:
		if .Ctrl in k.mods {
			switch k.r {
			case 'c', 'q':
				return rt.quit_cmd()
			case 'i':
				// THE KITTY PAYOFF, and the only binding in this file that
				// cannot exist without it. On the legacy encoding Ctrl+I and
				// Tab are both the single byte 0x09 and no decoder can tell
				// them apart -- Legacy_Key_Encoding.Ctrl_I only lets an app
				// pick WHICH ONE it gets, never both. With the Kitty
				// keyboard protocol's disambiguation flag pushed (main.odin's
				// term_enter_raw(fd, {.Disambiguate})) they are different
				// byte strings: Tab is `CSI 9 u`, Ctrl+I is `CSI 105;5 u`.
				// So Tab indents and Ctrl+I toggles help, simultaneously.
				// On a terminal with no Kitty support m.kitty stays false,
				// 0x09 decodes as Tab, and this branch is simply unreachable
				// -- the graceful degradation, visible in the status line.
				m.help = !m.help
				m.last = .Toggle_Help
			}
			return rt.cmd_nil()
		}
		// F18's editor-side half. decode_keys no longer produces a control
		// Rune for Alt+Enter and friends, so the specific reported path is
		// closed in the decoder -- but a Kitty text-input report can still
		// carry one, and this file's own contract with the .Diff renderer is
		// that no C0 byte ever reaches the view (see init's sanitiser and
		// test_the_view_emits_only_sgr_printable_text_and_newlines). Dropped
		// rather than inserted, matching the paste branch exactly.
		if k.r < 0x20 || k.r == 0x7F { return rt.cmd_nil() }
		m.last = insert_rune(m, k.r) ? .Insert : .Line_Full

	case .Space:
		m.last = insert_rune(m, ' ') ? .Insert : .Line_Full

	case .Enter:
		m.last = split_line(m) ? .Newline : .Doc_Full

	case .Tab:
		// All four spaces or the refusal: a partial indent would silently
		// misalign the line against every other one in the document.
		full := false
		for _ in 0 ..< TAB_WIDTH { if !insert_rune(m, ' ') { full = true } }
		m.last = full ? .Line_Full : .Indent

	// BACKWARD delete: 0x7F on the wire. Removes the grapheme cluster BEFORE
	// the cursor -- not the rune, see the cluster section: on `e` + U+0301 the
	// rune reading removed the accent and left the letter, so one visible
	// character took two presses -- and at column 0 pulls this line onto the
	// end of the previous one, leaving the cursor at the join point.
	case .Backspace:
		if m.cx > 0 {
			l := &m.lines[m.cy]
			from := cluster_left(l^, m.cx)
			gap  := m.cx - from
			for k := m.cx; k < l.n; k += 1 { l.r[k - gap] = l.r[k] }
			l.n -= gap
			m.cx = from
			m.last = .Backspace
		} else if m.cy > 0 {
			// PEEK BEFORE MOVING. join_next can refuse (F22), and a Backspace
			// that refuses must leave the caret where it was rather than on the
			// previous line with nothing joined.
			at  := m.cy - 1
			col := m.lines[at].n
			if join_next(m, at) {
				m.cy = at
				m.cx = col
				m.last = .Backspace
			} else {
				m.last = .Line_Full
			}
		} else {
			m.last = .Backspace   // start of the document: nothing to remove
		}

	// FORWARD delete: `CSI 3~` on the wire, a completely different sequence
	// from Backspace's single 0x7F byte -- which is the point of binding them
	// separately here. Removes the cluster AT the cursor, and at end-of-line
	// pulls the NEXT line up; the cursor does not move either way.
	case .Delete:
		l := &m.lines[m.cy]
		if m.cx < l.n {
			to  := cluster_right(l^, m.cx)
			gap := to - m.cx
			for k := to; k < l.n; k += 1 { l.r[k - gap] = l.r[k] }
			l.n -= gap
			m.last = .Delete
		} else if m.cy + 1 < m.nlines {
			m.last = join_next(m, m.cy) ? .Delete : .Line_Full
		} else {
			m.last = .Delete   // end of the document: nothing to pull up
		}

	case .Left:
		// `CSI 1;5D` vs `CSI D` -- the xterm modifier parameter, decoded by
		// xterm_mods (input.odin) into k.mods.
		if .Ctrl in k.mods { word_left(m);  clamp_cx(m); m.last = .Word_Left }
		else               { move_left(m);  m.last = .Left }
	case .Right:
		if .Ctrl in k.mods { word_right(m); clamp_cx(m); m.last = .Word_Right }
		else               { move_right(m); m.last = .Right }

	case .Up:
		if m.cy > 0 { m.cy -= 1; clamp_cx(m) }
		m.last = .Up
	case .Down:
		if m.cy < m.nlines - 1 { m.cy += 1; clamp_cx(m) }
		m.last = .Down

	case .Home:
		m.cx = 0; m.last = .Home
	case .End:
		m.cx = m.lines[m.cy].n; m.last = .End

	// Scroll by a whole viewport, cursor and window together -- follow_cursor
	// alone would only ever scroll by one line.
	//
	// THE PAGE IS text_rows(m) PHYSICAL ROWS, counted as lines. On a terminal
	// where nothing wraps the two are the same number; where lines do wrap a
	// page moves slightly further than one screenful and follow_cursor's clamps
	// below pull the window back to something legal. Deriving the page from the
	// content instead would make Page_Down's distance depend on which lines
	// happen to be on screen, which is worse than moving a predictable amount.
	case .Page_Up:
		page := text_rows(m^)
		m.top = max(0, m.top - page)
		m.cy  = max(0, m.cy - page)
		clamp_cx(m); m.last = .Page_Up
	case .Page_Down:
		page := text_rows(m^)
		pal  := palette(m.profile, m.term_w, m.term_h)
		m.top = min(top_for(m^, m.nlines - 1, &pal, alloc), m.top + page)
		m.cy  = min(m.nlines - 1, m.cy + page)
		clamp_cx(m); m.last = .Page_Down

	case .Escape:
		return rt.quit_cmd()
	}

	follow_cursor(m, alloc)
	return rt.cmd_nil()
}

// ---------------------------------------------------------------------------
// view
// ---------------------------------------------------------------------------

// The two horizontal rules, as wide as the window.
//
// RULE USED TO BE A 74-DASH STRING CONSTANT, and 74 was never right for any
// terminal in particular: at 80 columns it stopped six columns short of the
// status bar it was supposed to sit above, at 40 it wrapped onto a second row
// and cost the text area a line, at 200 it drew a stub across a third of the
// screen. The status bar four lines below has been term_w wide since T3-B, so
// the editor was showing three different chrome widths at once.
//
// 74 survives only as the answer when term_w is 0 (size unknown -- no tty), for
// the same reason VIEWPORT_UNSIZED is 10: it is what this example painted
// before, so a size-less run produces the frame its golden already pins.
RULE_UNSIZED_COLS :: 74

// The help panel's width when term_w is unknown -- see palette.
HELP_UNSIZED_COLS :: 78

@(private)
rule_line :: proc(w: int, alloc: mem.Allocator) -> string {
	return strings.repeat("-", w > 0 ? w : RULE_UNSIZED_COLS, alloc)
}

// THE HEADER IS ASSEMBLED, NOT WRITTEN OUT, and it used to be a 101-column
// string constant. On an 80-column terminal -- the industry default, and the
// size this example is most likely to be looked at -- that constant WRAPPED
// onto a second row, so the first thing a new reader saw was a key-help line
// broken mid-word. At 40x14 it took three rows and pushed the status bar off
// the bottom of the screen; at 20x6 it was the only thing on screen at all,
// wrapped five ways, with the caret parked inside the word "Tab".
//
// Assembled in priority order, and the ordering is the design: the TITLE and
// the QUIT BINDING are always present -- a user who cannot read the rest still
// has to be able to get out, which is exactly what F47 found missing at small
// sizes -- and the hints in between are added only while they fit. Adding them
// in order and STOPPING at the first that does not fit (rather than skipping it
// and trying the next) keeps the line a prefix of the full one, so it never
// reads as an arbitrary subset.
//
// Truncated, not wrapped, as the last step: header_line is exactly one physical
// row at every width, which is what lets cursor() and click_target treat
// HEADER_LINES as a row count rather than a guess.
HEADER_TITLE :: "RuneTea editor"
HEADER_QUIT  :: "Ctrl+C quit"
HEADER_SEP   :: "   "

Header_Hint :: struct {
	text: string,
	// True for a binding that only exists under the Kitty keyboard protocol.
	// THE HEADER USED TO ADVERTISE "Ctrl+I help" UNCONDITIONALLY, and on a
	// terminal with no Kitty support that byte IS Tab: it decoded as .Tab,
	// indented the line, and the panel it named was unreachable -- while the
	// status bar two fields away truthfully printed `kitty:off`. A binding that
	// cannot work on this terminal is not advertised on this terminal.
	kitty: bool,
}

HEADER_HINTS := [?]Header_Hint{
	{"arrows Home End PgUp PgDn", false},
	{"Ctrl+<-/-> word",           false},
	{"Tab indent",                false},
	{"Ctrl+I help",               true},
}

@(private)
header_line :: proc(m: Model, alloc: mem.Allocator) -> string {
	// TITLE + SEPARATOR + QUIT is 28 columns, and MIN_COLS is 20 -- so there is
	// a real band of supported widths where the two cannot both be shown. The
	// TITLE is what goes: it tells the user what program this is, which they
	// already know, and the quit binding tells them how to leave, which at 20
	// columns is the only thing the header can still usefully say.
	quit_w := rt.display_width(HEADER_QUIT)
	if m.term_w > 0 && rt.display_width(HEADER_TITLE) + rt.display_width(HEADER_SEP) + quit_w > m.term_w {
		if quit_w <= m.term_w { return HEADER_QUIT }
		return rg.truncate(HEADER_QUIT, m.term_w, "…", {}, alloc)
	}

	sb := strings.builder_make(alloc)
	strings.write_string(&sb, HEADER_TITLE)

	// Reserved up front, so a hint can never crowd out the quit binding.
	tail := strings.concatenate({HEADER_SEP, HEADER_QUIT}, alloc)
	used := rt.display_width(HEADER_TITLE) + rt.display_width(tail)

	for h in HEADER_HINTS {
		if h.kitty && !m.kitty { continue }
		cost := rt.display_width(HEADER_SEP) + rt.display_width(h.text)
		if m.term_w > 0 && used + cost > m.term_w { break }
		strings.write_string(&sb, HEADER_SEP)
		strings.write_string(&sb, h.text)
		used += cost
	}
	strings.write_string(&sb, tail)

	s := strings.to_string(sb)
	// Belt and braces for the "exactly one row" claim above: the loop's own
	// budget already keeps this under term_w, so this only ever fires if
	// somebody adds a hint whose width the loop mismeasures.
	if m.term_w > 0 && rt.display_width(s) > m.term_w {
		return rg.truncate(s, m.term_w, "…", {}, alloc)
	}
	return s
}

// The view's fixed preamble: the key-help header, then RULE. Text row `row`
// (0-based, within the viewport) is therefore view line HEADER_LINES + row --
// and `cursor` below depends on that being exactly true, which is why it is a
// named constant here rather than a 2 written twice.
HEADER_LINES :: 2

// The gutter every text row starts with: "% 3d " -- three columns of
// right-aligned line number plus one space. Constant because MAX_LINES is 250,
// so the number is never wider than 3.
GUTTER_COLS :: 4

// The exact text view() paints for DOCUMENT LINE `i`, gutter included AND
// STYLED. EXTRACTED SO THERE IS ONE COPY, not two: click_target measures these
// strings to map a screen row back to a line, visible_count and top_for measure
// them to decide how many fit, and a second, hand-kept copy of the formatting
// would be a mapping that agrees with the paint right up until someone edits one
// of them.
//
// ABSOLUTE, NOT VIEWPORT-RELATIVE: it took `row` and added m.top itself, which
// top_for -- which walks BACKWARDS from the end of the document, with no
// meaningful row number -- cannot express. `i` past the end of the document is
// the "~" filler row, which is how view() pads the text area out to its full
// height.
//
// THE STYLING IS INSIDE THIS PROC, not layered on by view(), for exactly that
// reason. It costs click_target nothing to measure the styled string -- SGR
// escapes are zero width to rt.display_width (width.odin's escape pre-pass), so
// the styled and unstyled forms occupy the same cells -- and measuring the string
// that is actually painted is the only version of this that stays true when
// somebody changes the gutter.
@(private)
row_text :: proc(m: Model, i: int, pal: ^Palette, alloc: mem.Allocator) -> string {
	if i < 0 || i >= m.nlines { return rg.render(&pal.rule, "   ~", alloc) }
	sb := strings.builder_make(alloc)
	// "% 3d", not "%3d": Odin's core:fmt does NOT follow Go here. "%3d"
	// pads a number with ZEROS ("001"), and "%-3d" pads with zeros on the
	// RIGHT -- so `fmt.printf("%-3d", 1)` prints "100", which reads as one
	// hundred. Only the explicit space flag gives Go's "  1". Verified on
	// this toolchain, not assumed.
	num := fmt.aprintf("% 3d ", i + 1, allocator = alloc)
	// The caret's own line gets the accent gutter. Two styles rather than one is
	// the cheapest possible demonstration of what .Diff buys: moving the caret
	// down a line repaints eight cells -- two gutters -- and nothing else.
	strings.write_string(&sb, rg.render(i == m.cy ? &pal.gutter_cur : &pal.gutter, num, alloc))
	l := m.lines[i]
	for k in 0 ..< l.n { strings.write_rune(&sb, l.r[k]) }
	return strings.to_string(sb)
}

// T2-C. Maps an absolute screen cell to a caret position: `y` is a PHYSICAL
// screen row and `x` a physical column, both 0-based from the top-left of the
// window (rt.Mouse_Msg's coordinates). ok=false means the click was not on a
// text row at all -- the header, either rule, the status line, a "~" filler
// past the end of the document, or ANY cell of a frame that has no text area
// (the help panel covers it; the too-small frame has none) -- and the caller
// must then do nothing rather than pick a nearby line.
//
// WHY THIS IS WELL-DEFINED AND WAS NOT BEFORE: main.odin runs this program with
// rt.Render_Mode.Diff, which delivers .Full_Screen's frame -- and those start at
// the top-left cell every time, so view line 0 is screen row 0 with nothing to
// track. See apply_mouse.
//
// PHYSICAL ROWS, NOT LOGICAL LINES, and that is the whole substance of this
// proc. Every view line above the text area (and every text row above the one
// clicked) may WRAP, and rt.rows_for_line -- the renderer's own layout function,
// not a re-derivation -- says how many rows each actually took. With an unknown
// width (m.term_w == 0) rows_for_line answers 1 for everything, which is
// precisely what the renderer assumes too, so mapping and paint stay consistent
// with each other even when both are ignorant of the real terminal.
//
// The COLUMN is handled by the same arithmetic in reverse: a click on the
// SECOND physical row of a wrapped line is at display column x + term_w, on the
// third at x + 2*term_w, and so on.
@(private)
click_target :: proc(m: Model, x, y: int, alloc: mem.Allocator) -> (cy, cx: int, ok: bool) {
	// Neither of these frames has a text area to click on -- the help panel
	// occupies it, and the too-small frame is a single line.
	if m.help || too_small(m) { return 0, 0, false }

	w := m.term_w
	pal := palette(m.profile, w, m.term_h)
	// The header and the rules unstyled, while view() paints them styled -- and
	// that is exact, not an approximation: rt.display_width (and therefore
	// rows_for_line) treats SGR escapes as zero width, so
	// rg.render(&pal.header, s) is the same number of physical rows as `s`.
	// Measuring saves two rg.render calls per click for a provably identical
	// answer -- and now that both are truncated to `w` the answer is 1 apiece,
	// which is measured rather than asserted so that a future header that DID
	// wrap would move the mapping with the paint instead of desynchronising it.
	row := rt.rows_for_line(header_line(m, alloc), w) + rt.rows_for_line(rule_line(w, alloc), w)
	if y < row { return 0, 0, false }   // header or the rule under it

	// The SAME walk view() paints, bounded by the same visible_count, so a
	// click below the last visible line lands on the trailing rule or the
	// status bar and is correctly refused rather than resolving to a document
	// line the user cannot see.
	for r in 0 ..< visible_count(m, &pal, alloc) {
		i := m.top + r
		text := row_text(m, i, &pal, alloc)
		rows := rt.rows_for_line(text, w)
		if y < row + rows {
			if i >= m.nlines { return 0, 0, false }   // a "~" filler row
			col := x
			if w > 0 { col += (y - row) * w }         // which continuation row was clicked
			// A click in the GUTTER (the line number) means the start of the
			// line, not a negative column -- the same thing every editor does.
			col = max(col - GUTTER_COLS, 0)
			return i, rune_at_display_col(m.lines[i], col), true
		}
		row += rows
	}
	return 0, 0, false   // a "~" filler row, the trailing rule or the status line
}

// The inverse of `cursor`'s display_width sum: a DISPLAY column within a line's
// text, back to the RUNE INDEX the caret uses. The two must be inverses or a
// click followed by a repaint would move the caret somewhere the user did not
// click, so this walks widths the same way cursor() sums them.
//
// A click anywhere INSIDE a grapheme cluster -- the second cell of a CJK glyph,
// or either half of `e` + U+0301 -- resolves to the cluster's own start, i.e.
// the caret lands on its left edge. There is no caret position inside one
// user-perceived character, which is what every terminal editor does and what
// the cluster-granular movement in this file assumes everywhere else.
// A click past the end of the text lands at the end of the line.
@(private)
rune_at_display_col :: proc(l: Line, col: int) -> int {
	if col <= 0 { return 0 }
	w := 0
	for k in 0 ..< l.n {
		buf, n := utf8.encode_rune(l.r[k])
		rw := rt.display_width(string(buf[:n]))
		// Snapped to a cluster boundary, because a click is the ONE route into
		// m.cx that can name a position inside a grapheme cluster -- the walk
		// above steps by rune, so a defective cluster (one that opens with a
		// combining mark) would otherwise leave the caret between two runes the
		// user sees as one character, and the next Left would be a dead key.
		if col < w + rw { return cluster_snap(l, k) }
		w += rw
	}
	return l.n
}

// The Ctrl+I panel's text, hoisted out of view() because RuneGloss lays a
// MULTI-LINE block out as one call -- the border and the padding are applied to
// the whole rectangle, so this cannot be three separate render calls the way it
// used to be three separate sbprintfln calls.
//
// WRITTEN AS ONE PARAGRAPH PER LINE, not pre-broken at a column: pal.help is
// .Wrap with an exact width now (see palette), so RuneGloss reflows this to
// whatever the window is. Hard line breaks here would survive the reflow and
// leave the panel ragged at every width but the one they were chosen for.
HELP_PANEL :: `Ctrl+I toggled this panel. Tab (CSI 9 u) and Ctrl+I (CSI 105;5 u) are distinct keys ONLY because the Kitty disambiguation flag is pushed; on the legacy encoding both are the byte 0x09 and this panel is dead code.
Press Ctrl+I again to close.`

// F47. The whole frame when the window is below MIN_COLS x MIN_ROWS.
//
// ONE LINE, and it has to be: the reason the old code painted an empty screen
// at small sizes is that its first view line did not fit, and .Full_Screen /
// .Diff truncate whole logical lines -- so a "too small" banner that itself
// wraps is a banner nobody sees. It says what is needed and what there is,
// truncated (never wrapped) to whatever width exists.
@(private)
too_small_text :: proc(m: Model, alloc: mem.Allocator) -> string {
	s := fmt.aprintf("need %dx%d, have %dx%d", MIN_COLS, MIN_ROWS, m.term_w, m.term_h, allocator = alloc)
	if m.term_w > 0 && rt.display_width(s) > m.term_w {
		return rg.truncate(s, m.term_w, "…", {}, alloc)
	}
	return s
}

// EVERY STRING THIS PROC PRODUCES COMES FROM `alloc`, which rt hands it as the
// FRAME ARENA (arena.odin's LIFETIME CONTRACT) -- including the ones rg.render
// allocates. RuneGloss allocates from the allocator it is passed and from nothing
// else (runegloss/render.odin), so the whole frame, styling included, is reclaimed
// wholesale when the arena resets and there is nothing here to free by hand. That
// is what keeps tools/test.sh's leak audit clean with a styling layer in the loop.
// THE FRAME IS EXACTLY term_h PHYSICAL ROWS, and it used to be exactly 14
// logical lines whatever the terminal was. Two rows of preamble, text_rows(m)
// rows of text area, two rows of footer -- so nothing is left dead below the
// status bar on a tall terminal and nothing is pushed off the bottom of a short
// one. The text area is filled to its full height with "~" rows when the
// document is shorter, which is what keeps the status bar on the last row
// rather than floating up under the text.
view :: proc(m: Model, alloc: mem.Allocator) -> string {
	pal := palette(m.profile, m.term_w, m.term_h)

	// F47. Not a layout at all: see too_small_text.
	if too_small(m) { return rg.render(&pal.status, too_small_text(m, alloc), alloc) }

	sb := strings.builder_make(alloc)
	fmt.sbprintfln(&sb, "%s", rg.render(&pal.header, header_line(m, alloc), alloc))
	fmt.sbprintfln(&sb, "%s", rg.render(&pal.rule, rule_line(m.term_w, alloc), alloc))

	budget := text_rows(m)
	shown  := 0
	if m.help {
		// F23. THE PANEL TAKES THE TEXT AREA rather than being appended after
		// the status bar. Appending it was what made its height unbudgetable:
		// the frame was 14 logical lines plus however many the box happened to
		// be, so on an 18-row terminal it opened with a top border, three
		// content rows and no bottom border. Occupying the area it is being
		// read INSTEAD of costs the frame nothing, needs no second height
		// calculation (pal.help is already exactly text_area_rows tall), and is
		// how a modal help screen behaves everywhere else. cursor() and
		// click_target both go quiet while it is open, for the same reason.
		fmt.sbprintfln(&sb, "%s", rg.render(&pal.help, HELP_PANEL, alloc))
		shown = budget
	} else {
		n := visible_count(m, &pal, alloc)
		for r in 0 ..< n {
			text := row_text(m, m.top + r, &pal, alloc)
			rows := rt.rows_for_line(text, m.term_w)
			// ONE LINE CAN BE TALLER THAN THE WHOLE TEXT AREA -- at 20x6 the
			// area is two rows and the sample document's first line needs three
			// -- and visible_count is required to return it anyway, because the
			// alternative is a blank screen. Clipped to the rows that are left
			// rather than emitted whole: emitting it whole overflows the frame,
			// and what a .Full_Screen/.Diff frame drops when it overflows is its
			// LAST rows, i.e. the closing rule and the status bar. Losing the
			// tail of one line the window is too small to show is a fair trade;
			// losing the status bar (the only thing on screen still reporting
			// the caret position and the terminal size) is not. Fires at most
			// once per frame, on the first line, by visible_count's own shape.
			if m.term_w > 0 && shown + rows > budget {
				text = rg.truncate(text, (budget - shown) * m.term_w, "…", {}, alloc)
				rows = rt.rows_for_line(text, m.term_w)
			}
			fmt.sbprintfln(&sb, "%s", text)
			shown += rows
		}
		// The filler rows past the end of the document -- and, when the visible
		// lines wrapped to fewer than `budget` rows, the slack under them.
		for shown < budget {
			fmt.sbprintfln(&sb, "%s", rg.render(&pal.rule, "   ~", alloc))
			shown += 1
		}
	}

	fmt.sbprintfln(&sb, "%s", rg.render(&pal.rule, rule_line(m.term_w, alloc), alloc))
	// FIELDS ORDERED MOST-USEFUL-FIRST because pal.status truncates rather than
	// wrapping now (see palette): on a narrow window it is the term size and
	// the last action that fall off the end, not the caret position.
	status := fmt.aprintf("Ln %d, Col %d   %d lines   window %d-%d   term %dx%d   kitty:%s   last:%s%s",
		m.cy + 1, m.cx + 1, m.nlines, m.top + 1,
		min(m.top + visible_count(m, &pal, alloc), m.nlines),
		m.term_w, m.term_h,
		m.kitty ? "on" : "off", ACTION_NAME[m.last],
		m.pasting ? "   [PASTING]" : "", allocator = alloc)
	fmt.sbprintfln(&sb, "%s", rg.render(&pal.status, status, alloc))

	return strings.to_string(sb)
}

// The REAL terminal cursor (rt.Program.cursor, wired up in main.odin), and the
// reason there is no longer a caret glyph in the view above.
//
// THIS EXAMPLE USED TO PAINT A LITERAL '|' INTO THE TEXT, and the comment that
// used to sit on that constant explained why: rt's Renderer had no cursor
// positioning of any kind, and display_width counted an ANSI escape's bytes as
// content, so even the reverse-video alternative would have inflated the row
// count and desynchronised the next frame's rewind. Both of those are fixed
// (T2-A: width.odin skips escapes; render.odin places a real cursor), and a
// fake caret was never merely cosmetic -- it INSERTED a column, so every
// character to its right sat one column further over than the file really has
// it, which is wrong for anything that has to line up (indentation, an
// alignment guide, a second pane).
//
// TWO RULES THIS HAS TO FOLLOW, both from rt.Cursor's doc comment:
//
//  1. `line` is an index into the VIEW's logical lines, so it must be derived
//     from the same layout view() paints -- hence HEADER_LINES, and hence
//     m.cy - m.top rather than m.cy.
//  2. `col` is a DISPLAY column, so it goes through rt.display_width over the
//     exact prefix view() wrote before the caret. NOT m.cx: that is a RUNE
//     index, and a line containing CJK or an emoji would put the caret several
//     columns left of where the text actually is. GUTTER_COLS is added rather
//     than measured because "% 3d " is ASCII and fixed-width by construction.
//
// The prefix string is built with the frame allocator handed in -- it dies
// with the frame, exactly like view()'s own builder (arena.odin's LIFETIME
// CONTRACT).
cursor :: proc(m: Model, alloc: mem.Allocator) -> rt.Cursor {
	// NO TEXT ON SCREEN, NO CARET. The help panel occupies the text area and
	// the too-small frame is one line; declaring a cursor in either would park
	// the terminal's caret on top of prose the user is reading, which is
	// exactly the "caret placed in the help text" reading F47 measured at 60x2.
	if m.help || too_small(m) { return rt.Cursor{} }

	row := m.cy - m.top
	pal := palette(m.profile, m.term_w, m.term_h)
	// Defensive, not reachable in practice: follow_cursor runs after every
	// action, so the caret's line is always inside the window. If it somehow
	// is not, declare no cursor rather than point at the wrong row -- the zero
	// value costs zero bytes (render.odin's Cursor).
	if row < 0 || m.cy >= m.nlines || row >= visible_count(m, &pal, alloc) { return rt.Cursor{} }

	sb := strings.builder_make(alloc)
	l := m.lines[m.cy]
	for k in 0 ..< min(m.cx, l.n) { strings.write_rune(&sb, l.r[k]) }
	col := GUTTER_COLS + rt.display_width(strings.to_string(sb))

	// THE CARET CAN BE ON A CONTINUATION ROW THE FRAME NO LONGER HAS. view()
	// clips a line taller than the whole text area (see its own note), so on a
	// very small window the caret's own wrapped row may have been cut. Declare
	// no cursor rather than let the renderer resolve a logical position that is
	// no longer painted -- it would land on the rule below the text.
	if m.term_w > 0 && row == 0 && col / m.term_w >= text_rows(m) { return rt.Cursor{} }

	return rt.Cursor{
		line = HEADER_LINES + row,
		col  = col,
		show = true,
	}
}
