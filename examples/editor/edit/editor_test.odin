package edit

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
	// Line 11 is the CURSOR line after one Page_Down, so its row reads
	// " 11 |line" -- the caret sits at column 0. Line 12 is the plain form.
	testing.expectf(t, strings.contains(last, " 11 |line"),
		"view after Page_Down should show line 11 with the caret; frame was:\n%s", last)
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
