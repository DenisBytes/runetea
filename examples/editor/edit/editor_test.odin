package edit

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import rt "../../../runetea"

// The editor's tests, driven through the REAL rt.run() event loop with
// scripted input bytes -- the same instrument runetea/golden_test.odin uses,
// and the reason edit is a package at all rather than living inside
// examples/editor/main.odin (a `package main` cannot be imported, so it can
// only be validated by a human looking at a terminal).
//
// Everything below sends WIRE BYTES, not synthesised Key_Msgs: "\e[1;5C" not
// Key_Msg{code = .Right, mods = {.Ctrl}}. That is deliberate and is what makes
// these integration tests rather than a second copy of input_test.odin -- they
// exercise the reader thread, decode_keys, the mailbox, the frame arena,
// update() and view() as one stack, which is precisely the layer that unit
// tests cannot reach.
//
// Regenerate the golden with:
//   odin test examples/editor/edit -define:GOLDEN_UPDATE=true
GOLDEN_UPDATE :: #config(GOLDEN_UPDATE, false)

// Ctrl+C. Every script ends with it: input_source_from_bytes reports EOF once
// its slice is exhausted, and run() treats that as input dying rather than as
// a clean quit, so a script that never quits would exit through a different
// path than a real session does.
QUIT :: "\x03"

// The wire bytes for every key this editor binds, spelled once. Getting one of
// these wrong would make a test pass or fail for a reason that has nothing to
// do with the editor, so they are named next to what they mean.
UP        :: "\e[A"
DOWN      :: "\e[B"
RIGHT     :: "\e[C"
LEFT      :: "\e[D"
HOME      :: "\e[H"
END       :: "\e[F"
PAGE_UP   :: "\e[5~"
PAGE_DOWN :: "\e[6~"
DEL       :: "\e[3~"       // FORWARD delete -- a CSI sequence
BKSP      :: "\x7f"        // BACKWARD delete -- one byte. Not the same key.
CTRL_LEFT  :: "\e[1;5D"    // xterm modifier param: 5 == 1 + Ctrl(4)
CTRL_RIGHT :: "\e[1;5C"
KITTY_TAB    :: "\e[9u"      // Kitty: Tab
KITTY_CTRL_I :: "\e[105;5u"  // Kitty: Ctrl+I -- a DIFFERENT key. Legacy: both 0x09.
KITTY_REPLY  :: "\e[?1u"     // the terminal's answer to term_enter_raw's CSI ? u
// T2-B. SGR mouse wheel notches: Cb 64 is up, 65 is down. The coordinates are
// present because the encoding requires them and are irrelevant to a wheel
// binding -- unlike a CLICK, whose coordinates are its entire meaning, which is
// why the click tests below build their bytes with click_at() rather than
// spelling them as constants here.
WHEEL_UP     :: "\e[<64;1;1M"
WHEEL_DOWN   :: "\e[<65;1;1M"

// Runs one scripted session to completion and hands back the final model.
// `b` is the caller's so the rendered bytes stay readable after this returns
// (the golden test needs them; the behavioural tests ignore them).
@(private = "file")
drive :: proc(t: ^testing.T, start: Model, script: string, b: ^strings.Builder) -> Model {
	full := strings.concatenate({script, QUIT}); defer delete(full)
	src := rt.input_source_from_bytes(transmute([]u8)full)
	defer rt.input_close(&src)

	p: rt.Program(Model)
	rt.program_init(&p, start, update, view)
	// Exactly what main.odin does, and it has to be here too: without it these
	// tests would drive a DIFFERENT program from the one that ships -- the
	// cursor escapes would be missing from the golden, and cursor() itself
	// (which runs inside rt's guarded view call, on every frame) would never be
	// exercised at all.
	p.cursor = cursor
	// T2-C, and here for exactly the same reason p.cursor is: main.odin ships
	// this program in FULL-SCREEN mode, so a test that drove it inline would be
	// testing a different program -- the golden would hold rewind bytes the real
	// editor never emits, and the full-screen path (which is what makes
	// click_target's coordinates mean anything) would never run here at all.
	//
	// The alternate screen is NOT entered here, and that is not an omission: it
	// is term_enter_raw's job, and these tests deliberately never enter raw mode
	// (they drive run() over a byte slice, with flush_fd = -1 and no tty in
	// sight). The two opt-ins are independent by design -- see rt.term_enter_raw
	// -- so a full-screen renderer with no alt screen is a legal configuration
	// and exactly the one a test harness wants.
	p.render_mode = .Full_Screen
	err := rt.run(&p, &src, b)
	testing.expectf(t, err == nil, "run should exit cleanly, got %v", err)
	return p.model
}

@(private = "file")
run_script :: proc(t: ^testing.T, start: Model, script: string) -> Model {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	return drive(t, start, script, &b)
}

@(private = "file")
expect_line :: proc(t: ^testing.T, m: Model, i: int, want: string, what: string) {
	got := line_text(m, i, context.allocator); defer delete(got, context.allocator)
	testing.expectf(t, got == want, "%s: line %d = %q, want %q", what, i, got, want)
}

// ---------------------------------------------------------------------------

// The headline paste requirement: a bracketed paste whose payload contains a
// newline must land as TWO lines. Also pins the two things that make paste
// worth having at all -- the payload is not parsed as escape sequences, and
// its characters do not hit key bindings.
@(test)
test_paste_with_a_newline_lands_as_two_lines :: proc(t: ^testing.T) {
	m := run_script(t, init(""), "\e[200~foo\nbar\e[201~")

	testing.expectf(t, m.nlines == 2, "paste: %d lines, want 2", m.nlines)
	expect_line(t, m, 0, "foo", "paste")
	expect_line(t, m, 1, "bar", "paste")
	testing.expectf(t, m.cy == 1 && m.cx == 3, "paste: cursor (%d,%d), want (1,3)", m.cy, m.cx)
	testing.expect(t, !m.pasting, "Paste_End_Msg should have cleared `pasting`")
	testing.expectf(t, m.last == .Paste, "paste: last = %v, want .Paste", m.last)
}

// A paste containing what LOOKS like an arrow key and what looks like a quit
// binding. Neither may be acted on: inside a paste there are no key semantics
// (input.odin's decode_keys). The ESC itself is a control character this
// editor drops; "[A" and the 'q' are inserted as literal text.
@(test)
test_paste_content_is_never_interpreted_as_keys :: proc(t: ^testing.T) {
	m := run_script(t, init(""), "\e[200~a\e[Aq\e[201~z")

	testing.expectf(t, m.nlines == 1, "paste: %d lines, want 1 (no Enter, no Up)", m.nlines)
	expect_line(t, m, 0, "a[Aqz", "paste")
	testing.expect(t, !m.pasting, "paste should be closed")
}

// Ctrl+Right must move by a WORD, not by a character -- i.e. `CSI 1;5C` and
// `CSI C` must reach update() as different things. The contrast is the test:
// the same start with a plain Right lands on column 1.
@(test)
test_ctrl_right_and_ctrl_left_move_by_a_word :: proc(t: ^testing.T) {
	start := init("hello world")

	one := run_script(t, start, RIGHT)
	testing.expectf(t, one.cx == 1, "plain Right: cx = %d, want 1", one.cx)
	testing.expectf(t, one.last == .Right, "plain Right: last = %v", one.last)

	w1 := run_script(t, start, CTRL_RIGHT)
	testing.expectf(t, w1.cx == 5, "Ctrl+Right: cx = %d, want 5 (end of \"hello\")", w1.cx)
	testing.expectf(t, w1.last == .Word_Right, "Ctrl+Right: last = %v, want .Word_Right", w1.last)

	w2 := run_script(t, start, CTRL_RIGHT + CTRL_RIGHT)
	testing.expectf(t, w2.cx == 11, "Ctrl+Right x2: cx = %d, want 11 (end of \"world\")", w2.cx)

	back := run_script(t, start, END + CTRL_LEFT)
	testing.expectf(t, back.cx == 6, "End+Ctrl+Left: cx = %d, want 6 (start of \"world\")", back.cx)
	testing.expectf(t, back.last == .Word_Left, "Ctrl+Left: last = %v, want .Word_Left", back.last)
}

// Delete and Backspace are the whole reason this example exists: `CSI 3~` and
// the single byte 0x7F must survive the decoder as DIFFERENT operations. Same
// start, same cursor, opposite characters removed.
@(test)
test_delete_and_backspace_are_different_operations :: proc(t: ^testing.T) {
	start := init("abc")

	// Cursor between 'a' and 'b' for both.
	bk := run_script(t, start, RIGHT + BKSP)
	expect_line(t, bk, 0, "bc", "backspace")
	testing.expectf(t, bk.cx == 0, "backspace: cx = %d, want 0 (cursor follows the removal)", bk.cx)
	testing.expectf(t, bk.last == .Backspace, "backspace: last = %v", bk.last)

	del := run_script(t, start, RIGHT + DEL)
	expect_line(t, del, 0, "ac", "delete")
	testing.expectf(t, del.cx == 1, "delete: cx = %d, want 1 (cursor does not move)", del.cx)
	testing.expectf(t, del.last == .Delete, "delete: last = %v", del.last)

	// And at a line boundary they join the same pair of lines from opposite
	// sides: Delete at end-of-line pulls the next line up, Backspace at
	// column 0 pushes this line onto the previous one.
	two := init("ab\ncd")
	dj := run_script(t, two, END + DEL)
	testing.expectf(t, dj.nlines == 1, "delete-join: %d lines, want 1", dj.nlines)
	expect_line(t, dj, 0, "abcd", "delete-join")

	bj := run_script(t, two, DOWN + HOME + BKSP)
	testing.expectf(t, bj.nlines == 1, "backspace-join: %d lines, want 1", bj.nlines)
	expect_line(t, bj, 0, "abcd", "backspace-join")
}

@(test)
test_home_and_end :: proc(t: ^testing.T) {
	start := init("hello world")

	e := run_script(t, start, END)
	testing.expectf(t, e.cx == 11, "End: cx = %d, want 11", e.cx)
	testing.expectf(t, e.last == .End, "End: last = %v", e.last)

	h := run_script(t, start, END + HOME)
	testing.expectf(t, h.cx == 0, "End then Home: cx = %d, want 0", h.cx)
	testing.expectf(t, h.last == .Home, "Home: last = %v", h.last)
}

// Arrows must cross line boundaries in both directions.
@(test)
test_arrows_cross_line_boundaries :: proc(t: ^testing.T) {
	m := init("ab\ncd")

	fwd := run_script(t, m, RIGHT + RIGHT + RIGHT)
	testing.expectf(t, fwd.cy == 1 && fwd.cx == 0,
		"Right x3 from (0,0) over \"ab\": (%d,%d), want (1,0)", fwd.cy, fwd.cx)

	back := run_script(t, m, DOWN + HOME + LEFT)
	testing.expectf(t, back.cy == 0 && back.cx == 2,
		"Left from (1,0): (%d,%d), want (0,2) -- end of the previous line", back.cy, back.cx)

	up := run_script(t, m, DOWN + UP)
	testing.expectf(t, up.cy == 0, "Down then Up: cy = %d, want 0", up.cy)
}

@(private = "file")
long_doc :: proc() -> Model {
	sb := strings.builder_make(); defer strings.builder_destroy(&sb)
	for i in 1 ..= 30 {
		if i > 1 { strings.write_string(&sb, "\n") }
		strings.write_string(&sb, "line")
	}
	return init(strings.to_string(sb))
}

// Page_Down must scroll by a whole VIEWPORT, not by one line, and the view
// must paint only the visible window.
@(test)
test_page_down_scrolls_by_a_viewport :: proc(t: ^testing.T) {
	doc := long_doc()
	testing.expectf(t, doc.nlines == 30, "fixture: %d lines, want 30", doc.nlines)
	testing.expectf(t, doc.top == 0, "fixture: top = %d, want 0", doc.top)

	d1 := run_script(t, doc, PAGE_DOWN)
	testing.expectf(t, d1.top == VIEWPORT, "Page_Down: top = %d, want %d", d1.top, VIEWPORT)
	testing.expectf(t, d1.cy == VIEWPORT, "Page_Down: cy = %d, want %d", d1.cy, VIEWPORT)
	testing.expectf(t, d1.last == .Page_Down, "Page_Down: last = %v", d1.last)

	d2 := run_script(t, doc, PAGE_DOWN + PAGE_DOWN)
	testing.expectf(t, d2.top == 2 * VIEWPORT, "Page_Down x2: top = %d, want %d", d2.top, 2 * VIEWPORT)

	u1 := run_script(t, doc, PAGE_DOWN + PAGE_DOWN + PAGE_UP)
	testing.expectf(t, u1.top == VIEWPORT, "Page_Up: top = %d, want %d", u1.top, VIEWPORT)
	testing.expectf(t, u1.last == .Page_Up, "Page_Up: last = %v", u1.last)

	// The window is what the view actually paints: after one Page_Down the
	// last frame must contain line 11 and must NOT contain line 1.
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	drive(t, doc, PAGE_DOWN, &b)
	out := strings.to_string(b)
	last := out[strings.last_index(out, "RuneTea editor"):]
	// Every text row is now the plain form: the caret is the terminal's REAL
	// cursor (see cursor()), not a glyph inserted into the text, so line 11 --
	// the cursor's own line after one Page_Down -- reads exactly like every
	// other row. It used to read " 11 |line", and the fact that this assertion
	// had to change is the point: the old caret shifted every column after it.
	testing.expectf(t, strings.contains(last, " 11 line"),
		"view after Page_Down should show line 11; frame was:\n%s", last)
	testing.expect(t, strings.contains(last, " 12 line"), "view after Page_Down should show line 12")
	testing.expect(t, !strings.contains(last, "  1 line"), "view after Page_Down should not show line 1")
	testing.expect(t, !strings.contains(last, " 21 line"), "view after Page_Down should not show line 21")
	testing.expect(t, strings.contains(last, "window 11-20"), "status line should report the visible window")
}

// THE KITTY PAYOFF. `CSI 9 u` (Tab) and `CSI 105;5 u` (Ctrl+I) must reach
// update() as two different keys and do two different things. Under the
// legacy encoding both are the byte 0x09 and this test could not exist --
// which is exactly why it does.
@(test)
test_tab_and_ctrl_i_are_different_keys_under_kitty :: proc(t: ^testing.T) {
	start := init("x")

	tab := run_script(t, start, KITTY_TAB)
	expect_line(t, tab, 0, "    x", "Kitty Tab")
	testing.expectf(t, tab.last == .Indent, "Kitty Tab: last = %v, want .Indent", tab.last)
	testing.expect(t, !tab.help, "Kitty Tab must not toggle the help panel")

	ci := run_script(t, start, KITTY_CTRL_I)
	expect_line(t, ci, 0, "x", "Kitty Ctrl+I")
	testing.expect(t, ci.help, "Kitty Ctrl+I should toggle the help panel on")
	testing.expectf(t, ci.last == .Toggle_Help, "Kitty Ctrl+I: last = %v, want .Toggle_Help", ci.last)

	// And the legacy byte, for contrast: a bare 0x09 is Tab, never Ctrl+I.
	legacy := run_script(t, start, "\t")
	expect_line(t, legacy, 0, "    x", "legacy 0x09")
	testing.expect(t, !legacy.help, "legacy 0x09 must decode as Tab, not Ctrl+I")
}

// The terminal's `CSI ? <flags> u` reply reaches update() as a
// Keyboard_Enhancements_Msg -- which is the only way an app can honestly say
// whether the Tab/Ctrl+I split above is actually available.
@(test)
test_keyboard_enhancements_reply_reaches_update :: proc(t: ^testing.T) {
	off := run_script(t, init("x"), "")
	testing.expect(t, !off.kitty, "no reply means the legacy encoding")

	on := run_script(t, init("x"), KITTY_REPLY)
	testing.expect(t, on.kitty, "CSI ? 1 u should set kitty = true")

	b := strings.builder_make(); defer strings.builder_destroy(&b)
	drive(t, init("x"), KITTY_REPLY, &b)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "kitty:on"), "the status line should report kitty:on")
}

// The help panel is real view output, not just a bool.
@(test)
test_ctrl_i_help_panel_appears_in_the_view :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	drive(t, init("x"), KITTY_CTRL_I, &b)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "CSI 105;5 u"), "the help panel should be painted")
}

// ---------------------------------------------------------------------------
// T2-A: the real terminal cursor replaces the fake '|' caret.
// ---------------------------------------------------------------------------

// THE POINT OF THE WHOLE EXERCISE. cursor()'s column must be a DISPLAY column,
// so a line of CJK text puts the caret where the glyphs actually end -- not
// where a rune index (2 columns short here) or a byte index (2 columns long)
// would put it. The old '|' caret could not get this wrong because it was
// painted INTO the text, which is precisely why it also shifted every column
// after it.
@(test)
test_cursor_column_is_a_display_column_not_a_rune_or_byte_index :: proc(t: ^testing.T) {
	// cursor() builds its measuring prefix with the allocator it is handed --
	// normally rt's frame arena, reclaimed wholesale after each frame. Here
	// that is the temp allocator, freed below; using context.allocator would
	// leak, and tools/test.sh's leak audit would (rightly) fail the run.
	defer free_all(context.temp_allocator)

	m := init("日本x")
	m.cx = 2   // after "日本": 2 RUNES, 6 BYTES, 4 COLUMNS

	c := cursor(m, context.temp_allocator)
	testing.expect(t, c.show, "the editor always declares a cursor for a visible line")
	testing.expectf(t, c.line == HEADER_LINES, "line = %d, want %d (first text row)", c.line, HEADER_LINES)
	testing.expectf(t, c.col == GUTTER_COLS + 4,
		"col = %d, want %d -- a rune index would give %d and a byte index %d",
		c.col, GUTTER_COLS + 4, GUTTER_COLS + 2, GUTTER_COLS + 6)

	// End of the line: "日本x" is 4 + 1 = 5 columns.
	m.cx = 3
	testing.expect_value(t, cursor(m, context.temp_allocator).col, GUTTER_COLS + 5)

	// And the scroll offset, not the absolute line, is what picks the row.
	long := long_doc()
	long.cy = 12
	long.top = 10
	testing.expect_value(t, cursor(long, context.temp_allocator).line, HEADER_LINES + 2)
}

// End to end through the real loop: the last frame must END with the cursor
// placement and the DECTCEM show, and must contain no '|' caret anywhere.
@(test)
test_the_rendered_frame_places_a_real_cursor_and_paints_no_caret_glyph :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	drive(t, init(""), "hello", &b)
	out := strings.to_string(b)
	last := out[strings.last_index(out, "\e[?25l"):]

	// T2-C REBASELINED THIS ONE LINE, deliberately: the editor now ships in
	// FULL-SCREEN mode (drive() sets p.render_mode to match main.odin), so the
	// caret is placed with an ABSOLUTE CUP instead of the inline renderer's
	// relative walk. The CELL is the same one the inline expectation described,
	// and that is the point of writing it out both ways here.
	//
	// The view is 14 logical lines with no help panel (header, RULE, VIEWPORT
	// text rows, RULE, status), and these tests run with no terminal, so
	// term_width is 0 and every logical line is one physical row (width.odin's
	// rows_for_line). The caret is on view line 2 (HEADER_LINES + row 0) at
	// display column 4 + len("hello") = 9. Inline, that was "12 rows above home,
	// CHA to 1-based column 10" -- "\e[12A\e[10G". Full-screen, it is the same
	// cell named absolutely: row 3, column 10, both 1-based.
	want :: "\e[3;10H\e[?25h"
	testing.expectf(t, strings.has_suffix(last, want),
		"frame must end with the cursor placement %q; frame was:\n%q", want, last)
	// ...and the frame it ends is a full-screen frame, not a rewind: homed at the
	// top-left, no \e[1A anywhere. Pinned here rather than assumed because this is
	// the only test in this file that looks at the real bytes.
	testing.expect(t, strings.has_prefix(last, "\e[?25l\e[H"),
		"a full-screen frame must home before it paints")
	testing.expect(t, !strings.contains(last, "\e[1A"),
		"a full-screen frame must never rewind")
	testing.expect(t, strings.has_prefix(last, "\e[?25l"),
		"a cursor frame must hide the cursor before it repaints")
	testing.expect(t, !strings.contains(last, "|"),
		"the fake '|' caret must be gone -- it inserted a column and shifted everything after it")
}

// Golden bytes for a session that touches every binding at once. Same shape as
// runetea/golden_test.odin: this is the instrument that catches a view change
// nobody meant to make, including the rewind escapes the renderer emits.
@(test)
test_golden_editor_session :: proc(t: ^testing.T) {
	script := strings.concatenate({
		"hello world",              // typing
		HOME, CTRL_RIGHT,           // word jump
		DEL, DEL,                   // forward delete
		END, BKSP,                  // backward delete
		"\r",                       // Enter -- split
		KITTY_TAB,                  // indent (Kitty Tab)
		"second",
		"\e[200~x\ny\e[201~",       // multi-line paste
		PAGE_DOWN, PAGE_UP,         // scroll both ways
		KITTY_CTRL_I,               // help panel on -- Kitty only
	})
	defer delete(script)

	b := strings.builder_make(); defer strings.builder_destroy(&b)
	drive(t, init(""), script, &b)
	got := transmute([]u8)strings.to_string(b)

	path := "testdata/editor_session.golden"
	when GOLDEN_UPDATE {
		os.make_directory("testdata")
		werr := os.write_entire_file(path, got)
		testing.expect(t, werr == nil, "failed to write golden")
		return
	}

	want, rerr := os.read_entire_file(path, context.allocator)
	testing.expectf(t, rerr == nil, "missing golden %s -- regenerate with -define:GOLDEN_UPDATE=true", path)
	if rerr != nil { return }
	defer delete(want)

	testing.expectf(t, string(got) == string(want),
		"byte mismatch\n got: %q\nwant: %q", string(got), string(want))
}

// T2-B, end to end through rt.run(): a mouse wheel notch arrives as WIRE BYTES,
// is decoded by rt's SGR mouse path, crosses the mailbox as a Mouse_Msg, and
// scrolls the viewport. Same instrument as every other test in this file -- the
// point is that nothing here synthesises a Mouse_Msg; the editor sees exactly
// what a terminal sends.
//
// The document is DOC-shaped (18 lines) so there is somewhere to scroll to:
// VIEWPORT is 10, so `top` can range over 0..8.
@(test)
test_mouse_wheel_scrolls_the_viewport :: proc(t: ^testing.T) {
	doc := init(`l1
l2
l3
l4
l5
l6
l7
l8
l9
l10
l11
l12
l13
l14
l15`)

	// Three notches down: 3 lines each, clamped at nlines - VIEWPORT == 5.
	m := run_script(t, doc, WHEEL_DOWN)
	testing.expectf(t, m.top == 3, "one notch down: top = %d, want 3", m.top)
	testing.expectf(t, m.last == .Scroll_Down, "one notch down: last = %v, want scroll-down", m.last)

	m = run_script(t, doc, WHEEL_DOWN + WHEEL_DOWN + WHEEL_DOWN)
	testing.expectf(t, m.top == 5, "three notches down: top = %d, want 5 (clamped)", m.top)

	// ...and back up, clamped at 0. Two notches down is 3 then 5 (the clamp),
	// so one notch back up is 2 -- NOT 3: the clamp is not undone by scrolling
	// the other way, which is the behaviour every scrollback in every terminal
	// has and is worth pinning rather than assuming.
	m = run_script(t, doc, WHEEL_DOWN + WHEEL_DOWN + WHEEL_UP)
	testing.expectf(t, m.top == 2, "down twice then up once: top = %d, want 2", m.top)
	testing.expectf(t, m.last == .Scroll_Up, "last = %v, want scroll-up", m.last)

	m = run_script(t, doc, WHEEL_UP + WHEEL_UP)
	testing.expectf(t, m.top == 0, "up from the top: top = %d, want 0 (clamped)", m.top)

	// THE CARET FOLLOWS THE WINDOW, which is the opposite direction from every
	// other action in this editor (follow_cursor moves the window to the caret;
	// scrolling moves the caret to the window). Without it the caret would leave
	// the viewport and cursor() would return the zero Cursor -- the caret would
	// simply vanish, with nothing on screen saying why.
	m = run_script(t, doc, WHEEL_DOWN)
	testing.expectf(t, m.cy >= m.top && m.cy < m.top + VIEWPORT,
		"after scrolling, the caret must stay visible: cy = %d, window %d..%d",
		m.cy, m.top, m.top + VIEWPORT)
	testing.expectf(t, m.cy == 3, "the caret should be pulled to the top of the window, got %d", m.cy)

	// A wheel event never edits. The document must be byte-identical afterwards.
	expect_line(t, m, 0, "l1", "wheel must not modify the text")
	expect_line(t, m, 14, "l15", "wheel must not modify the text")
	testing.expectf(t, m.nlines == 15, "wheel changed nlines to %d", m.nlines)
}

// ---------------------------------------------------------------------------
// T2-C: click-to-position.
//
// The coordinates below are SCREEN CELLS, and every one of them is derived, not
// guessed, so a layout change breaks these tests loudly instead of silently
// moving what a click means:
//
//   text row r sits at screen row TEXT_ORIGIN + r, where TEXT_ORIGIN is the
//   physical height of the header plus the rule under it;
//   column c of a line sits at screen column GUTTER_COLS + <display width of
//   the runes before it>.
//
// With m.term_w == 0 (no tty behind these tests, so no width was ever learned)
// rt.rows_for_line answers 1 for every line, so TEXT_ORIGIN is HEADER_LINES --
// and the wrapping case gets its own test below, with a width set.
// ---------------------------------------------------------------------------

// SGR mouse press, left button, at 0-based screen cell (x, y). The wire encoding
// is 1-based, hence the +1s -- the same conversion rt.sgr_mouse undoes on the
// way in. Cb 0 is the left button.
@(private = "file")
click_at :: proc(x, y: int) -> string {
	return fmt.aprintf("\e[<0;%d;%dM", x + 1, y + 1)
}

@(test)
test_click_positions_the_caret_on_the_clicked_cell :: proc(t: ^testing.T) {
	doc := init(`alpha
bravo
charlie`)

	// Text row 1 ("bravo"), column 3 -- so screen cell (GUTTER_COLS + 3, 2 + 1).
	script := click_at(GUTTER_COLS + 3, HEADER_LINES + 1); defer delete(script)
	m := run_script(t, doc, script)
	testing.expectf(t, m.cy == 1 && m.cx == 3, "click: caret at (%d,%d), want (1,3)", m.cy, m.cx)
	testing.expectf(t, m.last == .Click, "click: last = %v, want click", m.last)

	// A click in the GUTTER (the line number) means column 0, not a negative
	// column and not "ignore this click".
	script2 := click_at(1, HEADER_LINES + 2); defer delete(script2)
	m = run_script(t, doc, script2)
	testing.expectf(t, m.cy == 2 && m.cx == 0, "gutter click: caret at (%d,%d), want (2,0)", m.cy, m.cx)

	// A click PAST THE END of a line lands at the end of that line, not at the
	// column the user physically clicked (there is no text there to point at).
	script3 := click_at(GUTTER_COLS + 40, HEADER_LINES + 0); defer delete(script3)
	m = run_script(t, doc, script3)
	testing.expectf(t, m.cy == 0 && m.cx == 5, "past-end click: caret at (%d,%d), want (0,5)", m.cy, m.cx)

	// A click that is not on a text row at all -- the header -- must do NOTHING.
	// Placing the caret "somewhere near" would be worse than ignoring it.
	script4 := click_at(10, 0); defer delete(script4)
	m = run_script(t, doc, script4)
	testing.expectf(t, m.cy == 0 && m.cx == 0, "header click moved the caret to (%d,%d)", m.cy, m.cx)
	testing.expectf(t, m.last == .None, "header click: last = %v, want none", m.last)

	// ...and neither must a click on a "~" filler row past the end of the
	// document (row 5 of the viewport, with only 3 lines of text).
	script5 := click_at(GUTTER_COLS, HEADER_LINES + 5); defer delete(script5)
	m = run_script(t, doc, script5)
	testing.expectf(t, m.cy == 0 && m.cx == 0, "filler click moved the caret to (%d,%d)", m.cy, m.cx)
	testing.expectf(t, m.last == .None, "filler click: last = %v, want none", m.last)
}

// THE WIDE-RUNE CASE, which is the whole reason the mapping goes through
// rt.display_width in both directions rather than counting runes. "日本語" is 3
// runes, 9 bytes and SIX COLUMNS, so the caret positions and the screen columns
// they correspond to are three different sequences of numbers.
@(test)
test_click_on_a_line_with_a_wide_rune_uses_display_columns :: proc(t: ^testing.T) {
	doc := init("日本語x")

	// Column layout of the text, 0-based within the line:
	//   cols 0-1  日   (rune 0)
	//   cols 2-3  本   (rune 1)
	//   cols 4-5  語   (rune 2)
	//   col  6    x    (rune 3)
	Case :: struct { col, want_cx: int, what: string }
	for c in ([?]Case{
		{0, 0, "left half of the first wide rune"},
		{1, 0, "RIGHT half of the first wide rune -- still that rune"},
		{2, 1, "left half of the second"},
		{3, 1, "right half of the second"},
		{4, 2, "left half of the third"},
		{6, 3, "the narrow rune after three wide ones"},
		{7, 4, "past the end of the text"},
	}) {
		script := click_at(GUTTER_COLS + c.col, HEADER_LINES); defer delete(script)
		m := run_script(t, doc, script)
		testing.expectf(t, m.cy == 0 && m.cx == c.want_cx,
			"%s: click at display column %d -> caret (%d,%d), want (0,%d)",
			c.what, c.col, m.cy, m.cx, c.want_cx)
	}

	// A rune index would have put the caret at 6 for the last case and a BYTE
	// index at 9 -- both silently wrong. Pinned so the test above cannot pass
	// for the wrong reason.
	testing.expectf(t, m_line_len(doc, 0) == 4, "the fixture line must be 4 runes")
}

@(private = "file")
m_line_len :: proc(m: Model, i: int) -> int { return m.lines[i].n }

// THE VIEW SCROLLED. `top` shifts which document line a text row shows, and the
// mapping has to follow it -- clicking the first text row after scrolling must
// select the first VISIBLE line, not line 0. Driven through a real wheel notch
// so the scroll itself comes from the same wire bytes a terminal sends.
@(test)
test_click_after_scrolling_selects_the_visible_line :: proc(t: ^testing.T) {
	doc := init(`l1
l2
l3
l4
l5
l6
l7
l8
l9
l10
l11
l12
l13
l14
l15`)

	// One wheel notch down scrolls WHEEL_LINES (3), so text row 0 now shows l4.
	click := click_at(GUTTER_COLS + 1, HEADER_LINES + 0); defer delete(click)
	script := strings.concatenate({WHEEL_DOWN, click}); defer delete(script)
	m := run_script(t, doc, script)
	testing.expectf(t, m.top == 3, "the wheel notch should have scrolled to top=3, got %d", m.top)
	testing.expectf(t, m.cy == 3 && m.cx == 1,
		"click on the first visible row after scrolling: caret (%d,%d), want (3,1)", m.cy, m.cx)

	// ...and the last visible row is top + VIEWPORT - 1, not VIEWPORT - 1.
	click2 := click_at(GUTTER_COLS, HEADER_LINES + VIEWPORT - 1); defer delete(click2)
	script2 := strings.concatenate({WHEEL_DOWN, click2}); defer delete(script2)
	m = run_script(t, doc, script2)
	testing.expectf(t, m.cy == 3 + VIEWPORT - 1,
		"click on the last visible row: cy = %d, want %d", m.cy, 3 + VIEWPORT - 1)
}

// THE CASE THAT MAKES THIS WELL-DEFINED RATHER THAN USUALLY-RIGHT: a terminal
// narrow enough to WRAP the view's own header. At 40 columns the 105-column
// header takes 3 physical rows and the 74-column rule takes 2, so the text area
// starts at screen row 5 -- not at HEADER_LINES. A mapping that counted logical
// lines would put every click three rows too high.
//
// The width reaches the model the way it does in production: main.odin seeds it
// from rt.term_size, and this test seeds the fixture directly, because these
// tests have no tty to resize.
@(test)
test_click_accounts_for_wrapped_view_lines :: proc(t: ^testing.T) {
	doc := init(`alpha
bravo
charlie`)
	doc.term_w = 40

	origin := rt.rows_for_line(HELP_LINE, 40) + rt.rows_for_line(RULE, 40)
	testing.expectf(t, origin == 5, "the wrapped preamble should be 5 rows at width 40, got %d", origin)

	// Text row 1 is now at screen row `origin + 1`, and a click there must land
	// on line 1 -- while the same click at the UNWRAPPED origin would not.
	script := click_at(GUTTER_COLS + 2, origin + 1); defer delete(script)
	m := run_script(t, doc, script)
	testing.expectf(t, m.cy == 1 && m.cx == 2,
		"wrapped-header click: caret (%d,%d), want (1,2)", m.cy, m.cx)

	// The proof that the wrap accounting is doing real work: clicking where the
	// text row WOULD be if nothing wrapped now hits the header, and is ignored.
	script2 := click_at(GUTTER_COLS + 2, HEADER_LINES + 1); defer delete(script2)
	m = run_script(t, doc, script2)
	testing.expectf(t, m.last == .None,
		"a click inside the wrapped header must be ignored, got last = %v", m.last)

	// A TEXT ROW that wraps: with the caret mapping in continuation-row terms,
	// clicking column 2 of the SECOND physical row of a long line is display
	// column 2 + 40 = 42, minus the 4-column gutter = 38.
	long := init("0123456789012345678901234567890123456789012345678901234567890123456789")
	long.term_w = 40
	script3 := click_at(2, origin + 1); defer delete(script3)
	m = run_script(t, long, script3)
	testing.expectf(t, m.cy == 0 && m.cx == 38,
		"click on a wrapped line's continuation row: caret (%d,%d), want (0,38)", m.cy, m.cx)
}

// A resize keeps the mapping live: the width arrives as a Window_Size_Msg (the
// same message rt's own renderer consumes) and click_target must use the NEW one
// immediately. Driven through update() directly rather than through run(),
// because a SIGWINCH cannot be scripted into a byte slice.
@(test)
test_window_size_msg_keeps_the_click_mapping_live :: proc(t: ^testing.T) {
	m := init(`alpha
bravo
charlie`)
	testing.expectf(t, m.term_w == 0, "a fresh model knows no width, got %d", m.term_w)

	// context.temp_allocator, not context.allocator: click_target below builds
	// one row string per viewport row it scans, and in production those come
	// from rt's FRAME arena and die with the frame (arena.odin's LIFETIME
	// CONTRACT). A test that handed them the tracking allocator instead would
	// report them as leaks -- correctly, since nothing here would ever free them.
	update(&m, rt.Window_Size_Msg{w = 40, h = 12}, context.temp_allocator)
	testing.expectf(t, m.term_w == 40 && m.term_h == 12,
		"a resize must reach the model: term %dx%d, want 40x12", m.term_w, m.term_h)

	// The failure sentinel (rt sets both to 0 when the ioctl fails) must not
	// clobber a known-good size.
	update(&m, rt.Window_Size_Msg{w = 0, h = 0}, context.temp_allocator)
	testing.expectf(t, m.term_w == 40 && m.term_h == 12,
		"a failed size lookup must not clobber a known-good one, got %dx%d", m.term_w, m.term_h)

	origin := rt.rows_for_line(HELP_LINE, 40) + rt.rows_for_line(RULE, 40)
	defer free_all(context.temp_allocator)
	cy, cx, ok := click_target(m, GUTTER_COLS + 1, origin + 2, context.temp_allocator)
	testing.expect(t, ok, "a click on a text row must resolve")
	testing.expectf(t, cy == 2 && cx == 1, "post-resize click: (%d,%d), want (2,1)", cy, cx)
}
