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
VIEWPORT  :: 10   // text rows the view paints -- content taller than this scrolls
TAB_WIDTH :: 4

// Runes, not bytes: the cursor is then a rune index and every movement,
// insert and delete is plain integer arithmetic that cannot land in the
// middle of a UTF-8 sequence. Storing bytes would mean re-deriving rune
// boundaries in Left/Right/Backspace/Delete/word-jump -- six places to get
// wrong in a file whose entire point is that the key handling is correct.
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
}

ACTION_NAME := [Action]string{
	.None = "-", .Insert = "insert", .Newline = "newline",
	.Backspace = "backspace", .Delete = "delete",
	.Left = "left", .Right = "right", .Up = "up", .Down = "down",
	.Word_Left = "word-left", .Word_Right = "word-right",
	.Home = "home", .End = "end", .Page_Up = "page-up", .Page_Down = "page-down",
	.Indent = "indent", .Toggle_Help = "help", .Paste = "paste",
}

Model :: struct {
	lines:   [MAX_LINES]Line,
	nlines:  int,
	cy, cx:  int,    // cursor: line index, rune index within that line
	top:     int,    // first visible line -- the scroll offset
	pasting: bool,   // between Paste_Start_Msg and Paste_End_Msg
	help:    bool,   // toggled by Ctrl+I -- see apply_key
	// What the terminal actually answered to term_enter_raw's `CSI ? u`
	// query. false means no reply came back, i.e. the legacy encoding, i.e.
	// Tab and Ctrl+I below are the same byte and only one of them can win.
	// The view prints this so the Tab-vs-Ctrl+I demonstration is visibly
	// conditional rather than silently so.
	kitty:   bool,
	last:    Action,
}

// ---------------------------------------------------------------------------
// text primitives
// ---------------------------------------------------------------------------

init :: proc(text: string) -> Model {
	m: Model
	m.nlines = 1
	for r in text {
		if r == '\n' {
			if m.nlines >= MAX_LINES { break }
			m.nlines += 1
			continue
		}
		l := &m.lines[m.nlines - 1]
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

@(private)
insert_rune :: proc(m: ^Model, r: rune) {
	l := &m.lines[m.cy]
	if l.n >= MAX_COLS { return }
	for k := l.n; k > m.cx; k -= 1 { l.r[k] = l.r[k - 1] }
	l.r[m.cx] = r
	l.n += 1
	m.cx += 1
}

// Splits the current line at the cursor -- Enter, and every '\n' inside a
// paste (see apply_key: inside a paste there are no key semantics, so a
// newline arrives as Key_Msg{code = .Rune, r = '\n'}, not as .Enter).
@(private)
split_line :: proc(m: ^Model) {
	if m.nlines >= MAX_LINES { return }
	for i := m.nlines; i > m.cy + 1; i -= 1 { m.lines[i] = m.lines[i - 1] }
	m.nlines += 1

	cur  := &m.lines[m.cy]
	next := &m.lines[m.cy + 1]
	next^ = Line{}
	for k in m.cx ..< cur.n { next.r[next.n] = cur.r[k]; next.n += 1 }
	cur.n = m.cx

	m.cy += 1
	m.cx = 0
}

// Appends line cy+1 onto line cy and closes the gap. The shared tail of
// Backspace-at-column-0 and Delete-at-end-of-line, which is exactly why those
// two have to be distinct operations: they join the SAME pair of lines but
// leave the cursor in different places.
@(private)
join_next :: proc(m: ^Model, at: int) {
	if at + 1 >= m.nlines { return }
	cur  := &m.lines[at]
	next :=  m.lines[at + 1]
	for k in 0 ..< next.n {
		if cur.n >= MAX_COLS { break }
		cur.r[cur.n] = next.r[k]; cur.n += 1
	}
	for i := at + 1; i < m.nlines - 1; i += 1 { m.lines[i] = m.lines[i + 1] }
	m.nlines -= 1
	m.lines[m.nlines] = Line{}
}

// ---------------------------------------------------------------------------
// movement
// ---------------------------------------------------------------------------

@(private)
clamp_cx :: proc(m: ^Model) { if m.cx > m.lines[m.cy].n { m.cx = m.lines[m.cy].n } }

// Keeps the cursor inside the visible window. Called after every action, so
// no individual key handler has to remember to scroll.
@(private)
follow_cursor :: proc(m: ^Model) {
	if m.cy < m.top { m.top = m.cy }
	if m.cy >= m.top + VIEWPORT { m.top = m.cy - VIEWPORT + 1 }
	if m.top < 0 { m.top = 0 }
	if hi := max(0, m.nlines - VIEWPORT); m.top > hi { m.top = hi }
}

@(private)
move_left :: proc(m: ^Model) {
	if m.cx > 0 { m.cx -= 1; return }
	if m.cy > 0 { m.cy -= 1; m.cx = m.lines[m.cy].n }   // across the line boundary
}

@(private)
move_right :: proc(m: ^Model) {
	if m.cx < m.lines[m.cy].n { m.cx += 1; return }
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
		m.last = .Paste
	case rt.Paste_End_Msg:
		m.pasting = false
	case rt.Keyboard_Enhancements_Msg:
		m.kitty = .Disambiguate in v.flags
	case rt.Key_Msg:
		return apply_key(m, v)
	}
	return rt.cmd_nil()
}

// ^Model for the same reason update() takes one: Model is ~258 KiB now, so a
// by-value in-and-out of this proc would be half a megabyte of memcpy per
// keypress on top of reintroducing exactly the codegen blowup the pointer
// signature exists to avoid.
apply_key :: proc(m: ^Model, k: rt.Key_Msg) -> rt.Cmd {
	// PASTED RUNES ARE TEXT, UNCONDITIONALLY. Checked before anything else,
	// mirroring decode_keys' own precedence: inside a paste no escape
	// sequence is decoded and no key semantics are applied, so a pasted "\n"
	// is Key_Msg{code = .Rune, r = '\n'} and a pasted "\e[A" is three literal
	// runes. An editor that dropped this branch and let a pasted 'q' hit its
	// quit binding would be the classic bracketed-paste bug.
	if k.pasted {
		switch {
		case k.r == '\n' || k.r == '\r': split_line(m)
		case k.r >= 0x20:                insert_rune(m, k.r)
		}
		m.last = .Paste
		follow_cursor(m)
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
		insert_rune(m, k.r)
		m.last = .Insert

	case .Space:
		insert_rune(m, ' '); m.last = .Insert

	case .Enter:
		split_line(m); m.last = .Newline

	case .Tab:
		for _ in 0 ..< TAB_WIDTH { insert_rune(m, ' ') }
		m.last = .Indent

	// BACKWARD delete: 0x7F on the wire. Removes the rune BEFORE the cursor,
	// and at column 0 pulls this line onto the end of the previous one --
	// the cursor ends up at the join point.
	case .Backspace:
		if m.cx > 0 {
			l := &m.lines[m.cy]
			for k := m.cx; k < l.n; k += 1 { l.r[k - 1] = l.r[k] }
			l.n -= 1
			m.cx -= 1
		} else if m.cy > 0 {
			m.cy -= 1
			m.cx = m.lines[m.cy].n
			join_next(m, m.cy)
		}
		m.last = .Backspace

	// FORWARD delete: `CSI 3~` on the wire, a completely different sequence
	// from Backspace's single 0x7F byte -- which is the point of binding them
	// separately here. Removes the rune AT the cursor, and at end-of-line
	// pulls the NEXT line up; the cursor does not move either way.
	case .Delete:
		l := &m.lines[m.cy]
		if m.cx < l.n {
			for k := m.cx; k < l.n - 1; k += 1 { l.r[k] = l.r[k + 1] }
			l.n -= 1
		} else {
			join_next(m, m.cy)
		}
		m.last = .Delete

	case .Left:
		// `CSI 1;5D` vs `CSI D` -- the xterm modifier parameter, decoded by
		// xterm_mods (input.odin) into k.mods.
		if .Ctrl in k.mods { word_left(m);  m.last = .Word_Left }
		else               { move_left(m);  m.last = .Left }
	case .Right:
		if .Ctrl in k.mods { word_right(m); m.last = .Word_Right }
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
	case .Page_Up:
		m.top = max(0, m.top - VIEWPORT)
		m.cy  = max(0, m.cy - VIEWPORT)
		clamp_cx(m); m.last = .Page_Up
	case .Page_Down:
		m.top = min(max(0, m.nlines - VIEWPORT), m.top + VIEWPORT)
		m.cy  = min(m.nlines - 1, m.cy + VIEWPORT)
		clamp_cx(m); m.last = .Page_Down

	case .Escape:
		return rt.quit_cmd()
	}

	follow_cursor(m)
	return rt.cmd_nil()
}

// ---------------------------------------------------------------------------
// view
// ---------------------------------------------------------------------------

RULE :: "--------------------------------------------------------------------------"

// The view's fixed preamble: the key-help header, then RULE. Text row `row`
// (0-based, within the viewport) is therefore view line HEADER_LINES + row --
// and `cursor` below depends on that being exactly true, which is why it is a
// named constant here rather than a 2 written twice.
HEADER_LINES :: 2

// The gutter every text row starts with: "% 3d " -- three columns of
// right-aligned line number plus one space. Constant because MAX_LINES is 250,
// so the number is never wider than 3.
GUTTER_COLS :: 4

view :: proc(m: Model, alloc: mem.Allocator) -> string {
	sb := strings.builder_make(alloc)

	fmt.sbprintfln(&sb, "RuneTea editor   arrows Home End PgUp PgDn   Ctrl+<-/-> word   Tab indent   Ctrl+I help   Ctrl+C quit")
	fmt.sbprintfln(&sb, RULE)

	for row in 0 ..< VIEWPORT {
		i := m.top + row
		if i >= m.nlines {
			fmt.sbprintfln(&sb, "   ~")
			continue
		}
		// "% 3d", not "%3d": Odin's core:fmt does NOT follow Go here. "%3d"
		// pads a number with ZEROS ("001"), and "%-3d" pads with zeros on the
		// RIGHT -- so `fmt.printf("%-3d", 1)` prints "100", which reads as one
		// hundred. Only the explicit space flag gives Go's "  1". Verified on
		// this toolchain, not assumed.
		fmt.sbprintf(&sb, "% 3d ", i + 1)
		l := m.lines[i]
		for k in 0 ..< l.n { strings.write_rune(&sb, l.r[k]) }
		strings.write_string(&sb, "\n")
	}

	fmt.sbprintfln(&sb, RULE)
	fmt.sbprintfln(&sb, "Ln %d, Col %d   %d lines   window %d-%d   kitty:%s   last:%s%s",
		m.cy + 1, m.cx + 1, m.nlines, m.top + 1, min(m.top + VIEWPORT, m.nlines),
		m.kitty ? "on" : "off", ACTION_NAME[m.last],
		m.pasting ? "   [PASTING]" : "")

	if m.help {
		fmt.sbprintfln(&sb, RULE)
		fmt.sbprintfln(&sb, "Ctrl+I toggled this panel. Tab (CSI 9 u) and Ctrl+I (CSI 105;5 u) are")
		fmt.sbprintfln(&sb, "distinct keys ONLY because the Kitty disambiguation flag is pushed;")
		fmt.sbprintfln(&sb, "on the legacy encoding both are the byte 0x09 and this panel is dead code.")
	}

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
	row := m.cy - m.top
	// Defensive, not reachable in practice: follow_cursor runs after every
	// action, so the caret's line is always inside the window. If it somehow
	// is not, declare no cursor rather than point at the wrong row -- the zero
	// value costs zero bytes (render.odin's Cursor).
	if row < 0 || row >= VIEWPORT || m.cy >= m.nlines { return rt.Cursor{} }

	sb := strings.builder_make(alloc)
	l := m.lines[m.cy]
	for k in 0 ..< min(m.cx, l.n) { strings.write_rune(&sb, l.r[k]) }

	return rt.Cursor{
		line = HEADER_LINES + row,
		col  = GUTTER_COLS + rt.display_width(strings.to_string(sb)),
		show = true,
	}
}
