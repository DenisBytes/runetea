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
	// T2-B. APPENDED, like every other member added to an enum in this repo --
	// ACTION_NAME below is an [Action]string, so an inserted member would
	// silently shift every existing label.
	Scroll_Up, Scroll_Down,
	// T2-C. Appended for the same reason.
	Click,
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
	// T2-C. The terminal's size, as this app last knew it. NEEDED FOR
	// CLICK-TO-POSITION, not for layout: turning a Mouse_Msg's absolute screen
	// row into a view line means knowing how many PHYSICAL rows each view line
	// above it occupies, and that is a function of the width (rt.rows_for_line).
	// Without it, a header line wider than the terminal -- and this view's header
	// is 105 columns, so on an 80-column terminal it is exactly that -- would
	// wrap, push everything below it down a row, and every click would land one
	// line too high.
	//
	// SEEDED BY main.odin from rt.term_size at startup and kept live here from
	// Window_Size_Msg; 0 means "unknown", which rt.rows_for_line reads as "assume
	// one row per line". That is the same assumption the RENDERER makes with an
	// unknown width, which is the property that matters: the mapping and the
	// paint are wrong together or right together, never inconsistent with each
	// other. `term_h` is not used for anything but the status line -- this
	// editor's viewport is a fixed VIEWPORT rows, not the screen's height -- and
	// is kept so a resize is visible in the UI rather than silently absorbed.
	term_w:  int,
	term_h:  int,
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
		return apply_key(m, v)
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
// rt.Render_Mode.Full_Screen inside the alternate screen, and that renderer
// homes to the top-left cell every frame (render.odin's render_full_screen), so
// VIEW LINE 0 IS SCREEN ROW 0 -- by construction, every frame, with nothing to
// track. `y` is then a physical row within the frame, and the only remaining
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
			follow_cursor(m)
		}
		return rt.cmd_nil()
	}
	if mo.kind != .Wheel { return rt.cmd_nil() }
	#partial switch mo.button {
	case .Wheel_Up:
		m.top = max(0, m.top - WHEEL_LINES)
		m.last = .Scroll_Up
	case .Wheel_Down:
		m.top = min(max(0, m.nlines - VIEWPORT), m.top + WHEEL_LINES)
		m.last = .Scroll_Down
	case:
		return rt.cmd_nil()   // horizontal wheel: this view does not scroll sideways
	}
	// THE WINDOW MOVED, SO THE CARET MAY NOW BE OUTSIDE IT. Pull it back to the
	// nearest visible line rather than letting cursor() (which returns the zero
	// Cursor for an off-screen caret) silently stop drawing it -- and note this
	// is the OPPOSITE direction from follow_cursor, which moves the window to
	// the caret. Scrolling is the one action where the window leads.
	m.cy = clamp(m.cy, m.top, min(m.top + VIEWPORT, m.nlines) - 1)
	clamp_cx(m)
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

// The header, hoisted out of view()'s first sbprintfln by T2-C. It is a named
// constant now because click_target has to MEASURE it (105 columns -- wider than
// an 80-column terminal, so it really does wrap in practice) to know which
// screen row the text area starts on. A literal written twice would be a layout
// that can silently drift out of agreement with the click mapping.
HELP_LINE :: "RuneTea editor   arrows Home End PgUp PgDn   Ctrl+<-/-> word   Tab indent   Ctrl+I help   Ctrl+C quit"

// The view's fixed preamble: the key-help header, then RULE. Text row `row`
// (0-based, within the viewport) is therefore view line HEADER_LINES + row --
// and `cursor` below depends on that being exactly true, which is why it is a
// named constant here rather than a 2 written twice.
HEADER_LINES :: 2

// The gutter every text row starts with: "% 3d " -- three columns of
// right-aligned line number plus one space. Constant because MAX_LINES is 250,
// so the number is never wider than 3.
GUTTER_COLS :: 4

// The exact text view() paints for viewport row `row`, gutter included.
// EXTRACTED SO THERE IS ONE COPY, not two: click_target measures these strings
// to map a screen row back to a line, and a second, hand-kept copy of the
// formatting would be a mapping that agrees with the paint right up until
// someone edits one of them.
@(private)
view_row_text :: proc(m: Model, row: int, alloc: mem.Allocator) -> string {
	i := m.top + row
	if i < 0 || i >= m.nlines { return "   ~" }
	sb := strings.builder_make(alloc)
	// "% 3d", not "%3d": Odin's core:fmt does NOT follow Go here. "%3d"
	// pads a number with ZEROS ("001"), and "%-3d" pads with zeros on the
	// RIGHT -- so `fmt.printf("%-3d", 1)` prints "100", which reads as one
	// hundred. Only the explicit space flag gives Go's "  1". Verified on
	// this toolchain, not assumed.
	fmt.sbprintf(&sb, "% 3d ", i + 1)
	l := m.lines[i]
	for k in 0 ..< l.n { strings.write_rune(&sb, l.r[k]) }
	return strings.to_string(sb)
}

// T2-C. Maps an absolute screen cell to a caret position: `y` is a PHYSICAL
// screen row and `x` a physical column, both 0-based from the top-left of the
// window (rt.Mouse_Msg's coordinates). ok=false means the click was not on a
// text row at all -- the header, either rule, the status line, the help panel,
// or a "~" filler past the end of the document -- and the caller must then do
// nothing rather than pick a nearby line.
//
// WHY THIS IS WELL-DEFINED AND WAS NOT BEFORE: main.odin runs this program with
// rt.Render_Mode.Full_Screen, whose frames start at the top-left cell every
// time, so view line 0 is screen row 0 with nothing to track. See apply_mouse.
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
	w := m.term_w
	row := rt.rows_for_line(HELP_LINE, w) + rt.rows_for_line(RULE, w)
	if y < row { return 0, 0, false }   // header or the rule under it

	for r in 0 ..< VIEWPORT {
		text := view_row_text(m, r, alloc)
		rows := rt.rows_for_line(text, w)
		if y < row + rows {
			i := m.top + r
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
	return 0, 0, false   // the trailing rule, the status line or the help panel
}

// The inverse of `cursor`'s display_width sum: a DISPLAY column within a line's
// text, back to the RUNE INDEX the caret uses. The two must be inverses or a
// click followed by a repaint would move the caret somewhere the user did not
// click, so this walks widths the same way cursor() sums them.
//
// A click anywhere INSIDE a wide rune (the second cell of a CJK glyph, say)
// resolves to that rune's own index, i.e. the caret lands on its left edge.
// That is what a rune-granular editor can offer -- there is no position between
// the two halves of one rune -- and it is what every terminal editor does.
// A click past the end of the text lands at the end of the line.
@(private)
rune_at_display_col :: proc(l: Line, col: int) -> int {
	if col <= 0 { return 0 }
	w := 0
	for k in 0 ..< l.n {
		buf, n := utf8.encode_rune(l.r[k])
		rw := rt.display_width(string(buf[:n]))
		if col < w + rw { return k }
		w += rw
	}
	return l.n
}

view :: proc(m: Model, alloc: mem.Allocator) -> string {
	sb := strings.builder_make(alloc)

	fmt.sbprintfln(&sb, HELP_LINE)
	fmt.sbprintfln(&sb, RULE)

	for row in 0 ..< VIEWPORT {
		fmt.sbprintfln(&sb, "%s", view_row_text(m, row, alloc))
	}

	fmt.sbprintfln(&sb, RULE)
	fmt.sbprintfln(&sb, "Ln %d, Col %d   %d lines   window %d-%d   term %dx%d   kitty:%s   last:%s%s",
		m.cy + 1, m.cx + 1, m.nlines, m.top + 1, min(m.top + VIEWPORT, m.nlines),
		m.term_w, m.term_h,
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
