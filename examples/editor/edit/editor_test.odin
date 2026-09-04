#+private
package edit

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import rg "../../../runegloss"
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

// THE COLOUR PROFILE EVERY TEST IN THIS FILE FORCES, and the reason it is a
// constant here rather than whatever the machine happens to have.
//
// rg.new_style() reads $NO_COLOR/$TERM/$COLORTERM. A view built on it renders
// truecolour SGR under `COLORTERM=truecolor`, 256-colour SGR under
// `TERM=xterm-256color`, and NO ESCAPES AT ALL under `TERM=dumb` or in a CI job
// that sets NO_COLOR -- three different byte streams for one model, which would
// make testdata/editor_session.golden a record of the author's terminal rather
// than a test. package edit never calls new_style() for exactly this reason (see
// its `palette`), and this is the value the tests pin.
//
// .True_Color specifically: it is the profile that emits the MOST bytes and the
// most distinguishable ones ("\e[38;2;125;86;244m" -- the accent is legible in
// the golden by eye), so a down-conversion bug shows up here as a diff rather
// than as two colours that happen to quantise to the same palette index.
TEST_PROFILE :: rg.Profile.True_Color

// Runs one scripted session to completion and hands back the final model.
// `b` is the caller's so the rendered bytes stay readable after this returns
// (the golden test needs them; the behavioural tests ignore them).
@(private = "file")
drive :: proc(t: ^testing.T, start: Model, script: string, b: ^strings.Builder) -> Model {
	full := strings.concatenate({script, QUIT}); defer delete(full)
	src := rt.input_source_from_bytes(transmute([]u8)full)
	defer rt.input_close(&src)

	start := start
	// T3-B, and the same rule as p.cursor and p.render_mode below: main.odin
	// passes rg.default_profile() into ed.init, so a test that left this at the
	// zero value (.None -- no colour escapes at all) would be driving an
	// UNSTYLED program while the shipping binary is styled, and the golden would
	// pin bytes nothing ever emits. Forced rather than detected -- see
	// TEST_PROFILE.
	start.profile = TEST_PROFILE

	p: rt.Program(Model)
	rt.program_init(&p, start, update, view)
	// Exactly what main.odin does, and it has to be here too: without it these
	// tests would drive a DIFFERENT program from the one that ships -- the
	// cursor escapes would be missing from the golden, and cursor() itself
	// (which runs inside rt's guarded view call, on every frame) would never be
	// exercised at all.
	p.cursor = cursor
	// T2-C/T3-A, and here for exactly the same reason p.cursor is: main.odin
	// ships this program in .Diff mode, so a test that drove it inline -- or
	// full-screen -- would be testing a different program.
	//
	// AND HERE IS THE HONEST LIMIT OF DOING THAT, because it would otherwise be
	// invisible: THESE TESTS HAVE NO TTY. run() is called with flush_fd = -1, so
	// rt.term_size is never consulted and the Renderer's width and height stay 0
	// == unknown. .Diff models a viewport and refuses to guess at one, so with an
	// unknown size EVERY frame below degrades to .Full_Screen's exact byte stream
	// (render.odin's render_diff). The line above is therefore necessary but not
	// sufficient: it makes the CONFIGURATION match the shipping binary, and the
	// golden is genuinely the styled full-screen frame the editor falls back to
	// on a terminal whose size it cannot learn -- but the cell-diff emitter
	// itself does not run here.
	//
	// What covers that gap is test_diff_mode_* below, which drives a SIZED
	// rt.Renderer over this editor's real view() and cursor() output directly.
	// Injecting a size into run() was tried first and rejected: the only channel
	// is a Window_Size_Msg, which can only reach the loop from a SIGWINCH or from
	// a Cmd running on a pool thread, and a Cmd racing the reader thread's
	// scripted keys would make the golden non-deterministic.
	//
	// The alternate screen is NOT entered here, and that is not an omission: it
	// is term_enter_raw's job, and these tests deliberately never enter raw mode.
	// The two opt-ins are independent by design -- see rt.term_enter_raw -- so a
	// diff renderer with no alt screen is a legal configuration and exactly the
	// one a test harness wants.
	p.render_mode = .Diff
	err := rt.run(&p, &src, b)
	testing.expectf(t, err == nil, "run should exit cleanly, got %v", err)
	return p.model
}

@(private = "file")
run_script :: proc(t: ^testing.T, start: Model, script: string) -> Model {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	return drive(t, start, script, &b)
}

// A frame with every escape sequence removed, so an assertion about what the
// user SEES does not have to know where the styling happens to start and stop.
//
// THIS IS NOT COSMETIC. Before T3-B a text row was the single string " 11 line";
// it is now "\e[38;5;244m 11 \e[0mline", and `strings.contains(frame, " 11 line")`
// went from true to false without anything about what is on screen changing.
// Rewriting those assertions to spell the escapes inline would pin the STYLE in a
// test about SCROLLING -- so the style lives in the golden (which pins bytes on
// purpose) and the behavioural assertions read the plain text.
//
// The scanner is this file's own (rt's is @(private="package")) and that turns
// out to be the better arrangement anyway: test_the_view_satisfies_the_diff_
// renderers_contract below uses the SAME walk to decide whether an escape is an
// SGR, so the check on what the view is allowed to emit is independent of the
// implementation whose output it is checking.
//
// Returns the index one past the CSI beginning at s[i], and whether that CSI was
// a well-formed SGR ("\e[" params ";" ... "m"). A non-CSI escape, or a CSI that
// ends in anything but 'm', is reported not-SGR -- which is a contract violation
// for a .Diff view, not merely a curiosity.
@(private = "file")
scan_csi :: proc(s: string, i: int) -> (next: int, sgr: bool) {
	if i + 1 >= len(s) || s[i] != 0x1B { return min(i + 1, len(s)), false }
	if s[i + 1] != '[' { return i + 2, false }   // ESC + something else: not a CSI at all
	k := i + 2
	for k < len(s) && ((s[k] >= '0' && s[k] <= '?') || (s[k] >= ' ' && s[k] <= '/')) { k += 1 }
	if k >= len(s) { return len(s), false }      // truncated
	return k + 1, s[k] == 'm'
}

@(private = "file")
plain :: proc(s: string, alloc := context.temp_allocator) -> string {
	sb := strings.builder_make(alloc)
	i := 0
	for i < len(s) {
		if s[i] == 0x1B {
			i, _ = scan_csi(s, i)   // always > i, so this loop always advances
			continue
		}
		strings.write_byte(&sb, s[i])
		i += 1
	}
	return strings.to_string(sb)
}

// A document long enough that no text area in this file can hold all of it, so
// a layout test measures the layout rather than how much text happened to exist.
@(private = "file")
LONG_DOC :: `alpha bravo charlie delta echo
foxtrot golf hotel india juliett
kilo lima mike november oscar
papa quebec romeo sierra tango
uniform victor whiskey xray yankee
zulu one two three four five
six seven eight nine ten eleven
twelve thirteen fourteen fifteen
sixteen seventeen eighteen
nineteen twenty twenty-one
twenty-two twenty-three
twenty-four twenty-five
twenty-six twenty-seven
twenty-eight twenty-nine
thirty thirty-one thirty-two
thirty-three thirty-four
thirty-five thirty-six
thirty-seven thirty-eight
thirty-nine forty forty-one
forty-two forty-three forty-four
forty-five forty-six forty-seven
forty-eight forty-nine fifty
fifty-one fifty-two fifty-three
fifty-four fifty-five fifty-six
fifty-seven fifty-eight fifty-nine
sixty sixty-one sixty-two`

// The shipping document's opening lines, verbatim from examples/editor's DOC.
// Its first line is 44 columns and the gutter adds 4, so at 20 columns it needs
// THREE physical rows -- one more than the whole text area has at 20x6. That is
// the case the layout has to clip rather than overflow, and it is the size the
// task's own screenshot matrix starts at, so it is worth pinning against the
// real text rather than a fixture chosen to be easy.
@(private = "file")
TALL_DOC :: `The quick brown fox jumps over the lazy dog.
Type anything. Arrow keys move the caret, and Left at column 1
wraps to the end of the previous line.
Ctrl+Left and Ctrl+Right jump whole words -- that is CSI 1;5D
and CSI 1;5C, the xterm modifier encoding.
Backspace deletes backwards (0x7F). Delete deletes FORWARD
(CSI 3~). They are different sequences and different actions.
Home and End go to the ends of this line.
PageUp and PageDown scroll by a whole viewport, which is why
this document is deliberately longer than the ten rows the
view paints.`

// How many PHYSICAL rows a frame occupies at width `w`, counted exactly the way
// render.odin's paint_frame counts them -- split on "\n", drop the single
// trailing empty element a terminating newline produces (render.odin:522-534),
// and sum rows_for_line. Written out rather than approximated because every
// layout assertion in this file is ultimately a claim about this number, and a
// count that was off by the terminator would make all of them wrong together.
@(private = "file")
frame_rows :: proc(v: string, w: int) -> int {
	lines := strings.split_lines(v, context.temp_allocator)
	if len(lines) > 1 && lines[len(lines) - 1] == "" { lines = lines[:len(lines) - 1] }
	rows := 0
	for line in lines { rows += rt.rows_for_line(line, w) }
	return rows
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

// Page_Down must scroll by a whole VIEWPORT_UNSIZED, not by one line, and the view
// must paint only the visible window.
@(test)
test_page_down_scrolls_by_a_viewport :: proc(t: ^testing.T) {
	doc := long_doc()
	testing.expectf(t, doc.nlines == 30, "fixture: %d lines, want 30", doc.nlines)
	testing.expectf(t, doc.top == 0, "fixture: top = %d, want 0", doc.top)

	d1 := run_script(t, doc, PAGE_DOWN)
	testing.expectf(t, d1.top == VIEWPORT_UNSIZED, "Page_Down: top = %d, want %d", d1.top, VIEWPORT_UNSIZED)
	testing.expectf(t, d1.cy == VIEWPORT_UNSIZED, "Page_Down: cy = %d, want %d", d1.cy, VIEWPORT_UNSIZED)
	testing.expectf(t, d1.last == .Page_Down, "Page_Down: last = %v", d1.last)

	d2 := run_script(t, doc, PAGE_DOWN + PAGE_DOWN)
	testing.expectf(t, d2.top == 2 * VIEWPORT_UNSIZED, "Page_Down x2: top = %d, want %d", d2.top, 2 * VIEWPORT_UNSIZED)

	u1 := run_script(t, doc, PAGE_DOWN + PAGE_DOWN + PAGE_UP)
	testing.expectf(t, u1.top == VIEWPORT_UNSIZED, "Page_Up: top = %d, want %d", u1.top, VIEWPORT_UNSIZED)
	testing.expectf(t, u1.last == .Page_Up, "Page_Up: last = %v", u1.last)

	// The window is what the view actually paints: after one Page_Down the
	// last frame must contain line 11 and must NOT contain line 1.
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	defer free_all(context.temp_allocator)
	drive(t, doc, PAGE_DOWN, &b)
	out := strings.to_string(b)
	// T3-B: `plain`, because the gutter is styled now and " 11 line" is no longer
	// contiguous in the bytes -- see plain's own comment for why that is the right
	// fix here and the golden is the right place to pin the escapes.
	full := plain(out)
	last := full[strings.last_index(full, "RuneTea editor"):]
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
	// The view is 14 logical lines with no help panel (header, rule,
	// VIEWPORT_UNSIZED text rows, rule, status), and these tests run with no
	// terminal, so term_width is 0 -- which is this app's "size unknown", so
	// the text area falls back to VIEWPORT_UNSIZED -- and every logical line is
	// one physical row (width.odin's rows_for_line). The caret is on view line
	// 2 (HEADER_LINES + row 0) at
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

	// RESOLVED AGAINST THIS SOURCE FILE, NOT THE PROCESS'S CWD -- the same fix
	// runetea/golden_test.odin took, for the same reason. The bare relative
	// path made the test a function of where the shell happened to be:
	// `odin test examples/editor/edit` from the repository root (the spelling
	// in this project's own scripts) did not find the file and reported
	// "missing golden -- regenerate with -define:GOLDEN_UPDATE=true", which is
	// the worst possible diagnostic: that command, run from that same cwd,
	// writes a NEW golden into the wrong directory and turns a byte mismatch
	// into a green run.
	dir  := filepath.dir(#location().file_path)   // a slice of the literal; no allocation
	path := strings.concatenate({dir, "/testdata/editor_session.golden"}, context.temp_allocator)
	when GOLDEN_UPDATE {
		os.make_directory(strings.concatenate({dir, "/testdata"}, context.temp_allocator))
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
// VIEWPORT_UNSIZED is 10, so `top` can range over 0..8.
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

	// Three notches down: 3 lines each, clamped at nlines - VIEWPORT_UNSIZED == 5.
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
	testing.expectf(t, m.cy >= m.top && m.cy < m.top + VIEWPORT_UNSIZED,
		"after scrolling, the caret must stay visible: cy = %d, window %d..%d",
		m.cy, m.top, m.top + VIEWPORT_UNSIZED)
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

	// ...and the last visible row is top + VIEWPORT_UNSIZED - 1, not VIEWPORT_UNSIZED - 1.
	click2 := click_at(GUTTER_COLS, HEADER_LINES + VIEWPORT_UNSIZED - 1); defer delete(click2)
	script2 := strings.concatenate({WHEEL_DOWN, click2}); defer delete(script2)
	m = run_script(t, doc, script2)
	testing.expectf(t, m.cy == 3 + VIEWPORT_UNSIZED - 1,
		"click on the last visible row: cy = %d, want %d", m.cy, 3 + VIEWPORT_UNSIZED - 1)
}

// The screen row the text area starts on, derived the way click_target derives
// it rather than written as `2`. Both preamble lines are TRUNCATED to term_w
// now, so the answer is HEADER_LINES at every width -- but if a future header
// went back to wrapping, this would move with it and the click tests below
// would keep testing what they mean to test instead of failing for a reason
// three screens away.
@(private = "file")
text_origin :: proc(m: Model) -> int {
	return rt.rows_for_line(header_line(m, context.temp_allocator), m.term_w) +
	       rt.rows_for_line(rule_line(m.term_w, context.temp_allocator), m.term_w)
}

// THE FIX FOR THE HEADER THAT USED TO WRAP. This test used to assert the
// OPPOSITE: that at 40 columns the 101-column header took 3 rows and the
// 74-column rule took 2, so the text area started at screen row 5. That was a
// true description of a broken layout -- at 40x14 those five rows plus ten text
// rows plus two more left no room for the status bar at all, and at 80x24, the
// industry default, the header broke across two rows mid-word. Both lines are
// now built from term_w, so the preamble is exactly HEADER_LINES rows at every
// width and every click lands where the user aimed it.
//
// The width reaches the model the way it does in production: main.odin seeds it
// from rt.term_size, and this test seeds the fixture directly, because these
// tests have no tty to resize.
@(test)
test_the_preamble_is_two_rows_at_every_width :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	for w in ([?]int{20, 40, 60, 80, 100, 200}) {
		m := init("alpha")
		m.term_w, m.term_h = w, 24
		testing.expectf(t, text_origin(m) == HEADER_LINES,
			"at %d columns the preamble is %d rows, want %d -- header %q, rule %q",
			w, text_origin(m), HEADER_LINES,
			header_line(m, context.temp_allocator), rule_line(w, context.temp_allocator))
		// ...and the rule really does span the window, rather than stopping at
		// a constant 74 the way it did.
		testing.expectf(t, rt.display_width(rule_line(w, context.temp_allocator)) == w,
			"the rule is %d columns wide at width %d",
			rt.display_width(rule_line(w, context.temp_allocator)), w)
	}
}

// A click still has to account for a TEXT row that wraps -- the document's own
// lines are not truncated, because truncating them would hide text an editor
// with no horizontal scrolling could never show again.
@(test)
test_click_accounts_for_wrapped_text_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	doc := init(`alpha
bravo
charlie`)
	doc.term_w, doc.term_h = 40, 24
	origin := text_origin(doc)

	script := click_at(GUTTER_COLS + 2, origin + 1); defer delete(script)
	m := run_script(t, doc, script)
	testing.expectf(t, m.cy == 1 && m.cx == 2,
		"click on text row 1 at width 40: caret (%d,%d), want (1,2)", m.cy, m.cx)

	// A click on the header must still be ignored rather than resolving to a
	// nearby line.
	script2 := click_at(GUTTER_COLS + 2, 0); defer delete(script2)
	m = run_script(t, doc, script2)
	testing.expectf(t, m.last == .None,
		"a click on the header must be ignored, got last = %v", m.last)

	// A TEXT ROW that wraps: with the caret mapping in continuation-row terms,
	// clicking column 2 of the SECOND physical row of a long line is display
	// column 2 + 40 = 42, minus the 4-column gutter = 38.
	long := init("0123456789012345678901234567890123456789012345678901234567890123456789")
	long.term_w, long.term_h = 40, 24
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

	defer free_all(context.temp_allocator)
	cy, cx, ok := click_target(m, GUTTER_COLS + 1, text_origin(m) + 2, context.temp_allocator)
	testing.expect(t, ok, "a click on a text row must resolve")
	testing.expectf(t, cy == 2 && cx == 1, "post-resize click: (%d,%d), want (2,1)", cy, cx)
}

// ---------------------------------------------------------------------------
// T3-B: RuneGloss styling, and T3-A's .Diff renderer -- the two things
// main.odin now ships that nothing used to exercise.
//
// Everything above this line drives run() with flush_fd = -1, which means no
// tty, which means the Renderer's width and height are 0 == unknown, which means
// .Diff degrades to .Full_Screen's exact bytes (see drive's own comment). These
// tests close that gap by driving a SIZED rt.Renderer over this editor's real
// view() and cursor() output -- the same technique tools/difftest/main.odin uses
// for its measurements, and the only one available without a tty.
// ---------------------------------------------------------------------------

// A realistic window. Wide enough that the header keeps every hint it has, and
// tall enough (DIFF_ROWS - CHROME_ROWS = 26 text rows) that the sample
// documents below fit without scrolling -- the point of these tests is the diff
// emitter, not the layout.
DIFF_COLS :: 100
DIFF_ROWS :: 30

// Renders one frame through both renderers and returns what each wrote. Nested
// procs cannot capture in Odin, so everything is a parameter -- which is also
// what makes the two renderers provably fed the SAME view string, rather than two
// separately-built ones that could drift.
@(private = "file")
paint_both :: proc(m: Model, r_ref, r_dif: ^rt.Renderer, rb, db: ^strings.Builder) -> (ref, dif: int) {
	strings.builder_reset(rb)
	strings.builder_reset(db)
	// context.temp_allocator stands in for rt's frame arena: view() and cursor()
	// allocate from whatever they are handed (including everything rg.render
	// allocates), and the caller free_all's it. Using context.allocator would leak
	// and tools/test.sh's leak audit would fail the run -- which is precisely the
	// property this test is here to keep true now that a styling layer allocates
	// inside view().
	v := view(m, context.temp_allocator)
	c := cursor(m, context.temp_allocator)
	rt.renderer_render(r_ref, v, c)
	rt.renderer_render(r_dif, v, c)
	return len(strings.to_string(rb^)), len(strings.to_string(db^))
}

// THE WHOLE REASON THE EDITOR MOVED TO .Diff: an idle frame is free, and a
// keystroke costs a fraction of a repaint.
@(test)
test_diff_mode_costs_zero_for_an_idle_frame_and_a_fraction_for_a_keystroke :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	m := init("The quick brown fox jumps over the lazy dog.\nSecond line of text.\nThird line.", TEST_PROFILE)
	m.term_w, m.term_h = DIFF_COLS, DIFF_ROWS

	rb := strings.builder_make(); defer strings.builder_destroy(&rb)
	db := strings.builder_make(); defer strings.builder_destroy(&db)
	r_ref: rt.Renderer
	rt.renderer_init(&r_ref, &rb, DIFF_COLS, DIFF_ROWS, .Full_Screen)
	defer rt.renderer_destroy(&r_ref)
	r_dif: rt.Renderer
	rt.renderer_init(&r_dif, &db, DIFF_COLS, DIFF_ROWS, .Diff)
	defer rt.renderer_destroy(&r_dif)

	// Frame 1 is a full paint in BOTH modes by definition -- there is nothing on
	// screen yet to diff against.
	first_ref, first_dif := paint_both(m, &r_ref, &r_dif, &rb, &db)
	testing.expectf(t, first_ref > 500, "the initial repaint should be a real frame, got %d B", first_ref)
	testing.expectf(t, first_dif > 500, "the initial diff frame is a full paint too, got %d B", first_dif)

	// AN IDENTICAL CONSECUTIVE FRAME COSTS ZERO BYTES, and an editor spends most
	// of its life exactly here -- rt repaints on every message, including ones
	// that change nothing on screen.
	for i in 0 ..< 10 {
		ref, dif := paint_both(m, &r_ref, &r_dif, &rb, &db)
		testing.expectf(t, dif == 0, "idle frame %d: the diff wrote %d bytes, want 0", i, dif)
		testing.expectf(t, ref > 500, "idle frame %d: the repaint still wrote %d bytes", i, ref)
	}

	// ONE KEYSTROKE. Three regions of the frame change -- the inserted character,
	// the caret's own gutter is already accented, and the Ln/Col + last: fields of
	// the status bar -- and nothing else does. The bound is deliberately loose
	// (a quarter of a repaint); the measured figure is ~15%, and pinning the exact
	// number here would make every future layout tweak a test failure.
	apply_key(&m, rt.Key_Msg{code = .Rune, r = 'X'}, context.temp_allocator)
	ref, dif := paint_both(m, &r_ref, &r_dif, &rb, &db)
	testing.expectf(t, dif > 0, "a keystroke must actually repaint something, got %d B", dif)
	testing.expectf(t, dif * 4 < ref,
		"a keystroke: diff %d B against repaint %d B -- the diff should be a small fraction", dif, ref)

	// AND MOVING THE CARET REPAINTS THE TWO GUTTERS. The accented gutter follows
	// m.cy, so Down is the cheapest possible non-trivial frame: two four-cell runs
	// plus the status bar.
	apply_key(&m, rt.Key_Msg{code = .Down}, context.temp_allocator)
	_, down := paint_both(m, &r_ref, &r_dif, &rb, &db)
	testing.expectf(t, down > 0, "moving the caret must repaint the gutters, got %d B", down)
	testing.expectf(t, down < ref, "a caret move (%d B) should cost less than a full repaint (%d B)", down, ref)
}

// A resize is the one thing that invalidates .Diff's cell model, and it must
// resettle: the frame after a resize is a full paint, and the frame after THAT is
// free again. Worth pinning here rather than trusting, because this editor keeps
// its OWN copy of the width too (m.term_w, for click_target) and a mismatch
// between the two would show up as a frame that never stops repainting.
@(test)
test_diff_mode_resettles_after_a_resize :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	m := init("alpha\nbravo\ncharlie", TEST_PROFILE)
	m.term_w, m.term_h = DIFF_COLS, DIFF_ROWS

	rb := strings.builder_make(); defer strings.builder_destroy(&rb)
	db := strings.builder_make(); defer strings.builder_destroy(&db)
	r_ref: rt.Renderer
	rt.renderer_init(&r_ref, &rb, DIFF_COLS, DIFF_ROWS, .Full_Screen)
	defer rt.renderer_destroy(&r_ref)
	r_dif: rt.Renderer
	rt.renderer_init(&r_dif, &db, DIFF_COLS, DIFF_ROWS, .Diff)
	defer rt.renderer_destroy(&r_dif)

	paint_both(m, &r_ref, &r_dif, &rb, &db)
	_, idle := paint_both(m, &r_ref, &r_dif, &rb, &db)
	testing.expectf(t, idle == 0, "before the resize an idle frame should be free, got %d B", idle)

	// The renderer's size and the app's own copy move together, exactly as
	// rt.apply and update() move them on one Window_Size_Msg.
	rt.renderer_set_width(&r_dif, 60)
	rt.renderer_set_height(&r_dif, 20)
	rt.renderer_set_width(&r_ref, 60)
	rt.renderer_set_height(&r_ref, 20)
	update(&m, rt.Window_Size_Msg{w = 60, h = 20}, context.temp_allocator)

	_, after := paint_both(m, &r_ref, &r_dif, &rb, &db)
	testing.expectf(t, after > 0, "the frame after a resize must be a full repaint, got %d B", after)

	_, settled := paint_both(m, &r_ref, &r_dif, &rb, &db)
	testing.expectf(t, settled == 0, "the frame after that should be free again, got %d B", settled)
}

// .Diff'S CONTRACT, ASSERTED RATHER THAN ASSUMED: "SGR escapes, printable text
// and \n only" (render.odin's KNOWN LIMITS). The diff renderer models SGR per
// cell and treats every other escape as invisible, so a view that emitted a
// cursor move, an OSC, or a bare tab would be lying to the cell model -- and the
// failure would be a corrupted screen on somebody's terminal, not a test failure,
// because .Full_Screen tolerates all three.
//
// This editor has three places it could go wrong and all three are covered by the
// fixtures below: RuneGloss's own output (which promises SGR only), the document
// text (a pasted 0x09 or 0x1B must never reach the view), and the status line.
@(test)
test_the_view_emits_only_sgr_printable_text_and_newlines :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// A paste carrying a tab, an ESC and a carriage return -- the three bytes that
	// would break the cell model -- driven through the real decoder.
	pasted := run_script(t, init(""), "\e[200~a\tb\e[Ac\rd\e[201~")

	scrolled := run_script(t, long_doc(), PAGE_DOWN)

	helped := init("日本語 wide runes and an emoji: \U0001F600", TEST_PROFILE)
	helped.help = true
	helped.kitty = true
	helped.term_w, helped.term_h = DIFF_COLS, DIFF_ROWS

	// The two frames the responsive-layout work added, at the sizes where they
	// are reached: the panel now sizes itself to the window (so RuneGloss wraps
	// and clamps inside it, which is new output nothing else here covers) and
	// the too-small frame is a shape the view never used to produce at all.
	tiny := init(LONG_DOC, TEST_PROFILE)
	tiny.term_w, tiny.term_h = 8, 3

	narrow_help := init("日本語 wide runes and an emoji: \U0001F600", TEST_PROFILE)
	narrow_help.help, narrow_help.kitty = true, true
	narrow_help.term_w, narrow_help.term_h = 22, 7

	Case :: struct { m: Model, what: string }
	for c in ([?]Case{
		{init(""),                                    "an empty document"},
		{init("alpha\nbravo", TEST_PROFILE),          "a plain document"},
		{pasted,                                      "a document built from a paste containing 0x09/0x1B/0x0D"},
		{scrolled,                                    "a scrolled viewport"},
		{helped,                                      "the help panel, wide runes and a known width"},
		{narrow_help,                                 "the help panel wrapped and clamped into a 22x7 window"},
		{tiny,                                        "the too-small frame"},
	}) {
		v := view(c.m, context.temp_allocator)
		i := 0
		for i < len(v) {
			b := v[i]
			if b == 0x1B {
				next, sgr := scan_csi(v, i)
				testing.expectf(t, sgr,
					"%s: the view emitted a non-SGR escape at byte %d (%q) -- .Diff models SGR only",
					c.what, i, v[i:min(next, len(v))])
				i = next
				continue
			}
			// C0 controls, tab and carriage return included. "\n" is the ONE
			// exception: it is the view's own line separator.
			testing.expectf(t, b >= 0x20 || b == '\n',
				"%s: the view emitted the control byte 0x%02X at %d -- .Diff models printable cells and \\n only",
				c.what, b, i)
			i += 1
		}
	}
}

// THE COLOUR PROFILE IS THE ONLY THING THAT VARIES BETWEEN MACHINES, and it is
// threaded through the Model rather than read from the environment -- so a frame
// is a pure function of the Model, which is what makes the golden a test.
//
// Also pins the property every layout proc in this file silently depends on: the
// profile changes the BYTES and never the CELLS. cursor()'s column and
// click_target's row mapping both go through rt.display_width, which measures SGR
// as zero width; if that stopped being true, a coloured build would put the caret
// somewhere a monochrome build did not.
@(test)
test_styled_output_is_a_pure_function_of_the_profile :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	base := init("alpha\nbravo\ncharlie")
	base.term_w, base.term_h = DIFF_COLS, DIFF_ROWS
	base.cy = 1
	base.help = true

	frame :: proc(m: Model, p: rg.Profile) -> string {
		m := m
		m.profile = p
		return view(m, context.temp_allocator)
	}

	none  := frame(base, .None)
	ansi  := frame(base, .ANSI)
	c256  := frame(base, .ANSI256)
	truec := frame(base, .True_Color)

	// SAME MODEL, SAME PROFILE, SAME BYTES -- twice, with allocations in between.
	testing.expect(t, frame(base, .True_Color) == truec, "view must be deterministic for one profile")

	// .None EMITS NO COLOUR -- and, deliberately, still emits ATTRIBUTES.
	//
	// This assertion was written the obvious way first ("under .None the view
	// contains no escape at all") and it FAILED, correctly: runegloss/render.odin's
	// build_sgr degrades the two Colors through convert() and passes the Attrs
	// straight through, on the stated grounds that $NO_COLOR and TERM=dumb are
	// about colour and that stripping bold/faint would leave a monochrome terminal
	// with no emphasis at all. So the honest assertion is the one below: every
	// escape this view emits under .None is an attribute or a reset, and not one
	// of them names a colour.
	testing.expect(t, len(none) > 0, "the .None view must still be a frame")
	{
		i, seen := 0, 0
		for i < len(none) {
			if none[i] != 0x1B { i += 1; continue }
			next, sgr := scan_csi(none, i)
			esc := none[i:next]
			testing.expectf(t, sgr && (esc == "\e[0m" || esc == "\e[1m" || esc == "\e[2m"),
				"under .None the view emitted %q at byte %d -- only attributes and resets are allowed", esc, i)
			seen += 1
			i = next
		}
		// Non-vacuity for the loop itself: .None must not accidentally emit nothing
		// at all, or the check above would pass on an empty set.
		testing.expectf(t, seen > 0, "the .None view emitted no SGR at all -- bold/faint should survive")
	}

	// ...and every richer profile does emit escapes, in its own encoding. Pinned
	// per-profile so a down-conversion that silently fell back to 16 colours
	// everywhere would be a failure rather than a shrug.
	testing.expect(t, strings.contains(truec, "\e[38;2;125;86;244m") ||
	                  strings.contains(truec, "\e[1;38;2;125;86;244m"),
		"under .True_Color the accent must be emitted as 24-bit RGB")
	testing.expect(t, strings.contains(c256, "38;5;"), "under .ANSI256 the accent must be a palette index")
	testing.expect(t, !strings.contains(c256, "38;2;"), "under .ANSI256 nothing may be 24-bit")
	testing.expect(t, !strings.contains(ansi, "38;5;") && !strings.contains(ansi, "38;2;"),
		"under .ANSI everything must be one of the 16 SGR colours")

	// THE CELLS ARE IDENTICAL ACROSS ALL FOUR. Same plain text, same display width
	// per line, whatever the profile.
	for got, i in ([?]string{none, ansi, c256, truec}) {
		testing.expectf(t, plain(got) == plain(none),
			"profile %d changed the visible text, not just the escapes", i)
		testing.expectf(t, rt.display_width(got) == rt.display_width(none),
			"profile %d changed the display width: %d vs %d", i, rt.display_width(got), rt.display_width(none))
	}

	// And the two layout procs agree with that, end to end: the same click on the
	// same document resolves to the same caret whether the build is coloured or
	// not.
	for p in ([?]rg.Profile{.None, .ANSI, .ANSI256, .True_Color}) {
		m := base
		m.profile = p
		// help = false for this half: the panel OCCUPIES the text area (see
		// view), so with it open there is deliberately nothing to click on and
		// no caret to place. That is asserted on its own below.
		m.help = false
		cy, cx, ok := click_target(m, GUTTER_COLS + 3, text_origin(m) + 2, context.temp_allocator)
		testing.expectf(t, ok && cy == 2 && cx == 3,
			"profile %v moved where a click lands: (%d,%d) ok=%v, want (2,3) ok=true", p, cy, cx, ok)
		testing.expectf(t, cursor(m, context.temp_allocator).col == GUTTER_COLS,
			"profile %v moved the caret's display column", p)
	}
}

// THE HEADER IS NEVER WIDER THAN THE WINDOW, AND ALWAYS SAYS HOW TO GET OUT.
//
// This test replaces one that pinned the old constant's width at 101 columns
// and asserted that it WRAPPED at 80. Both facts were true and the layout they
// described was the defect: the first thing a reader saw on a default-size
// terminal was a key-help line broken mid-word. What is worth pinning is the
// property the assembly exists to guarantee -- it fits, and the quit binding
// survives every width, including ones too narrow for the title.
@(test)
test_the_header_fits_the_window_and_always_names_the_quit_key :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	for w in ([?]int{6, 12, 20, 26, 40, 60, 80, 100, 200}) {
		m := init("x")
		m.term_w, m.term_h = w, 24
		h := header_line(m, context.temp_allocator)
		testing.expectf(t, rt.display_width(h) <= w,
			"at %d columns the header is %d wide: %q", w, rt.display_width(h), h)
		testing.expectf(t, rt.rows_for_line(h, w) == 1,
			"at %d columns the header takes %d rows: %q", w, rt.rows_for_line(h, w), h)
		// Below the width of "Ctrl+C quit" itself there is nothing left to
		// promise; at or above it, the binding must be intact rather than the
		// first casualty of the trim -- the TITLE is what gets dropped in the
		// band between 11 and 28 columns, not this.
		if w >= 11 {
			testing.expectf(t, strings.contains(h, HEADER_QUIT),
				"at %d columns the header lost the quit binding: %q", w, h)
		}
	}

	// AND THE KITTY-ONLY BINDING IS NOT ADVERTISED WHERE IT CANNOT WORK. On the
	// legacy encoding Ctrl+I *is* the byte 0x09, so it decodes as Tab and the
	// panel the old header advertised was unreachable -- while the status bar
	// two fields away truthfully printed `kitty:off`.
	off := init("x"); off.term_w, off.term_h = 200, 24
	on  := off; on.kitty = true
	testing.expect(t, !strings.contains(header_line(off, context.temp_allocator), "Ctrl+I"),
		"with kitty:off the header must not advertise Ctrl+I -- that byte is Tab")
	testing.expect(t, strings.contains(header_line(on, context.temp_allocator), "Ctrl+I help"),
		"with kitty:on the header must advertise Ctrl+I")
}

// F47 / the responsive-layout group, asserted where it actually bites: the
// FRAME. At every realistic size the frame must be exactly term_h physical rows
// -- no more (the status bar would be pushed off the bottom, which is what
// happened at 40x14) and no fewer (rows left dead below it, which is what
// happened at 100x30, where seventeen of thirty rows painted nothing).
@(test)
test_the_frame_is_exactly_as_tall_as_the_terminal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	Size :: struct { w, h: int }
	for s in ([?]Size{{20, 6}, {40, 14}, {60, 20}, {80, 24}, {100, 30}, {200, 50}}) {
		for help in ([?]bool{false, true}) {
			// TALL_DOC, not LONG_DOC: its first line needs three physical rows
			// at 20 columns while the text area there has two, which is the one
			// case where view() has to CLIP a line rather than emit it whole.
			// A frame-height test that never hit it would be testing the easy
			// half of the layout.
			m := init(TALL_DOC, TEST_PROFILE)
			m.term_w, m.term_h = s.w, s.h
			m.help = help
			rows := frame_rows(view(m, context.temp_allocator), s.w)
			testing.expectf(t, rows == s.h,
				"%dx%d (help=%v): the frame is %d physical rows, want %d",
				s.w, s.h, help, rows, s.h)
		}
	}
}

// ...and the status bar is genuinely the last row, with the caret position
// still legible on it, at the narrowest supported window. This is the assertion
// that would have failed on the shipped editor at 80x24: the status bar was
// there, but ten rows above the bottom of the screen with the text area ending
// early.
@(test)
test_the_status_bar_is_the_last_row_and_keeps_the_caret_position :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	m := init(LONG_DOC, TEST_PROFILE)
	m.term_w, m.term_h = MIN_COLS, MIN_ROWS
	v := view(m, context.temp_allocator)
	lines := strings.split_lines(v, context.temp_allocator)
	// split_lines leaves a trailing "" because every row ends with \n.
	last := plain(lines[len(lines) - 2])
	testing.expectf(t, strings.has_prefix(last, "Ln 1, Col 1"),
		"the last row should be the status bar, got %q", last)
	testing.expectf(t, rt.display_width(last) == MIN_COLS,
		"the status bar should span the window exactly: %d columns of %d (%q)",
		rt.display_width(last), MIN_COLS, last)
}

// F47's degraded state. Below the minimum the editor says so in one line
// instead of painting a layout whose first row does not fit -- which is what it
// used to do, and why at 60x2 the screen showed nothing but a wrapped fragment
// of the help header with the caret parked inside the word "Tab".
@(test)
test_a_window_below_the_minimum_paints_one_line_saying_so :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	Size :: struct { w, h: int }
	for s in ([?]Size{{80, 1}, {80, 2}, {80, 5}, {19, 24}, {8, 24}, {4, 4}}) {
		m := init(LONG_DOC, TEST_PROFILE)
		m.term_w, m.term_h = s.w, s.h
		testing.expectf(t, too_small(m), "%dx%d should be below the minimum", s.w, s.h)

		v := view(m, context.temp_allocator)
		testing.expectf(t, rt.rows_for_line(v, s.w) == 1,
			"%dx%d: the too-small frame is %d rows, want 1: %q", s.w, s.h, rt.rows_for_line(v, s.w), v)
		testing.expectf(t, !strings.contains(v, "\n"),
			"%dx%d: the too-small frame must be one logical line: %q", s.w, s.h, v)
		if s.w >= 9 {
			testing.expectf(t, strings.contains(plain(v), "need 20x6"),
				"%dx%d: the frame should say what size is needed, got %q", s.w, s.h, plain(v))
		}
		// The caret must not be declared over it -- there is no text to point at.
		testing.expect(t, !cursor(m, context.temp_allocator).show,
			"no cursor may be declared on the too-small frame")
	}

	// ...and the size UNKNOWN (0, this app's no-tty / failed-ioctl sentinel) is
	// not "too small". Every test in this file runs that way.
	unknown := init(LONG_DOC, TEST_PROFILE)
	testing.expect(t, !too_small(unknown), "an unknown size must not trip the minimum")
}

// The text area grows with the terminal -- the half of the responsive group
// that is invisible in a width-only test. VIEWPORT was a compile-time 10, so a
// 50-row terminal painted ten rows of text and thirty-four rows of nothing.
@(test)
test_the_text_area_grows_with_the_terminal_height :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	Case :: struct { h, want: int }
	for c in ([?]Case{{6, 2}, {14, 10}, {20, 16}, {24, 20}, {30, 26}, {50, 46}}) {
		m := init(LONG_DOC, TEST_PROFILE)
		m.term_w, m.term_h = 200, c.h
		testing.expectf(t, text_rows(m) == c.want,
			"at %d rows the text area is %d rows, want %d", c.h, text_rows(m), c.want)
		// And the window really shows that many document lines: LONG_DOC is
		// longer than any of these and 200 columns wraps none of it.
		pal := palette(m.profile, m.term_w, m.term_h)
		// LONG_DOC is 26 lines, so a text area taller than the document shows
		// the document and pads the rest with "~" -- min(), not c.want.
		want_lines := min(c.want, m.nlines)
		testing.expectf(t, visible_count(m, &pal, context.temp_allocator) == want_lines,
			"at %d rows the window shows %d lines, want %d",
			c.h, visible_count(m, &pal, context.temp_allocator), want_lines)
	}

	// An unknown height still means VIEWPORT_UNSIZED, which is what keeps every
	// no-tty test in this file (and the golden) describing one fixed layout.
	unknown := init(LONG_DOC, TEST_PROFILE)
	testing.expect_value(t, text_rows(unknown), VIEWPORT_UNSIZED)
}

// A WRAPPING TEXT LINE COSTS THE WINDOW A ROW, which is the whole reason
// visible_count walks the rows instead of answering text_rows. Document lines
// are deliberately not truncated -- this editor has no horizontal scrolling, so
// a truncated line would be text the user can never see again -- so a narrow
// window shows fewer of them, and the status bar stays where it is.
@(test)
test_a_wrapping_line_costs_the_window_a_row_rather_than_the_status_bar :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Six lines of 60 columns of text: at width 40 (36 columns after the
	// gutter) every one of them takes two physical rows.
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 6 {
		if i > 0 { strings.write_string(&sb, "\n") }
		for _ in 0 ..< 60 { strings.write_byte(&sb, 'x') }
	}
	m := init(strings.to_string(sb), TEST_PROFILE)
	m.term_w, m.term_h = 40, 14   // 10 rows of text area

	pal := palette(m.profile, m.term_w, m.term_h)
	testing.expect_value(t, text_rows(m), 10)
	testing.expectf(t, visible_count(m, &pal, context.temp_allocator) == 5,
		"five two-row lines fill a ten-row area, got %d",
		visible_count(m, &pal, context.temp_allocator))

	// ...and the frame is still exactly 14 rows, with the status bar last.
	testing.expect_value(t, frame_rows(view(m, context.temp_allocator), 40), 14)
}

// THE CONTRACT CHECKER, POINTED AT A REAL VIEW.
//
// runetea/contract_test.odin proves view_diff_safe classifies escapes
// correctly; this proves the classification is USEFUL -- that the one non-toy
// view in this repository actually satisfies the contract, across every colour
// profile and with the caret in the awkward places.
//
// It also turns two of this editor's own design decisions into checked
// properties instead of comments: that Tab indents with spaces rather than a
// literal 0x09 (TAB_WIDTH), and that a pasted C0 byte is dropped rather than
// inserted. Either one regressing would put a control byte in the view, which
// under rt.Render_Mode.Diff is a screen the renderer models wrongly and never
// notices -- see examples/editor/main.odin's own note on why it cares.
@(test)
test_the_editors_view_satisfies_the_diff_renderers_contract :: proc(t: ^testing.T) {
	Size :: struct { w, h: int }
	for size in ([?]Size{{DIFF_COLS, 30}, {80, 24}, {40, 14}, {20, 6}, {12, 4}}) {
	for p in ([?]rg.Profile{.None, .ANSI, .ANSI256, .True_Color}) {
		m := init("The quick brown fox\nSecond line\n\tliteral tab in the SOURCE\nfourth", p)
		// EVERY SIZE, not just the design one. The layout is derived from the
		// terminal now -- truncation, wrapping, the panel's clamp and the
		// too-small frame are all new output -- so a contract check pinned to a
		// single 100x30 window would no longer see most of what this view can
		// emit. rg.truncate's ellipsis and RuneGloss's own wrap both have to
		// come out as SGR and printable text like everything else.
		m.term_w, m.term_h = size.w, size.h

		// A spread of states: fresh, help toggled, caret moved, text edited,
		// and a paste containing exactly the bytes that would break it.
		mutate := [?]proc(m: ^Model){
			proc(m: ^Model) {},
			proc(m: ^Model) { m.help = !m.help },
			proc(m: ^Model) { apply_key(m, rt.Key_Msg{code = .Down}, context.temp_allocator); apply_key(m, rt.Key_Msg{code = .End}, context.temp_allocator) },
			proc(m: ^Model) { apply_key(m, rt.Key_Msg{code = .Tab}, context.temp_allocator) },
			proc(m: ^Model) {
				update(m, rt.Paste_Start_Msg{}, context.temp_allocator)
				for r in "pa\tsted\ttabs" { apply_key(m, rt.Key_Msg{code = .Rune, r = r, pasted = true}, context.temp_allocator) }
				update(m, rt.Paste_End_Msg{}, context.temp_allocator)
			},
			proc(m: ^Model) { apply_key(m, rt.Key_Msg{code = .Page_Down}, context.temp_allocator) },
		}
		for mut in mutate {
			mut(&m)
			v := view(m, context.temp_allocator)
			ok, at, why := rt.view_diff_safe(v)
			lo := max(at - 20, 0)
			hi := min(at + 20, len(v))
			testing.expectf(t, ok,
				"profile %v at %dx%d: the editor's view violates the .Diff contract (%v) at byte %d: %q",
				p, size.w, size.h, why, at, v[lo:hi])
		}
	}
	}
	free_all(context.temp_allocator)
}

// The loader's own half of the contract above, pinned directly so a regression
// names the cause rather than only the symptom.
//
// This was a LIVE BUG until rt.view_diff_safe was pointed at the editor's view:
// every other route into the document refused C0 bytes (apply_key's paste
// branch takes only k.r >= 0x20; the Tab key inserts spaces) but init let a
// literal 0x09 straight through -- so opening a tab-indented file, the single
// most ordinary thing to do with an editor, put a cursor-moving control byte in
// the view.
@(test)
test_loading_a_document_sanitises_control_characters :: proc(t: ^testing.T) {
	m := init("\tindented\nbell\ahere\nnul\x00byte\ndel\x7Fbyte")

	// A tab becomes exactly the TAB_WIDTH spaces the Tab KEY inserts, so a
	// loaded document and a typed one indent identically.
	testing.expect_value(t, line_text(m, 0, context.temp_allocator), "    indented")
	// Every other C0 (and DEL) is dropped, matching the paste branch.
	testing.expect_value(t, line_text(m, 1, context.temp_allocator), "bellhere")
	testing.expect_value(t, line_text(m, 2, context.temp_allocator), "nulbyte")
	testing.expect_value(t, line_text(m, 3, context.temp_allocator), "delbyte")

	// And the property that actually matters, stated as itself.
	v := view(m, context.temp_allocator)
	ok, at, why := rt.view_diff_safe(v)
	testing.expectf(t, ok, "a loaded document must not put %v in the view (byte %d)", why, at)

	free_all(context.temp_allocator)
}

// ---------------------------------------------------------------------------
// F22 -- the join that used to annihilate a line.
// ---------------------------------------------------------------------------

// A 256-rune line plus anything is more than MAX_COLS, and the old join_next
// copied what fit (nothing) and then deleted the source line and decremented
// nlines ANYWAY. Verified live at 120x30 before the fix: paste 260 X's into
// line 1, End, three Deletes -> 18/17/16/15 lines with line 1 unchanged, i.e.
// three whole lines of the document erased with not one character preserved,
// while the status bar said "last:delete". Held down, the key ate the document.
@(test)
test_delete_refuses_a_join_that_would_not_fit_and_says_so :: proc(t: ^testing.T) {
	full := strings.repeat("X", MAX_COLS, context.temp_allocator)
	defer free_all(context.temp_allocator)

	doc := strings.concatenate({full, "\nsecond line\nthird line"}, context.temp_allocator)
	m := run_script(t, init(doc), END + DEL + DEL + DEL)

	// NOTHING WAS DESTROYED. Three Deletes at the end of a full line are three
	// no-ops, not three erased lines.
	testing.expectf(t, m.nlines == 3, "the document lost lines: %d, want 3", m.nlines)
	expect_line(t, m, 0, full, "the full line must be untouched")
	expect_line(t, m, 1, "second line", "the next line must survive the refused join")
	expect_line(t, m, 2, "third line", "line 3 must survive too")

	// AND THE REFUSAL IS VISIBLE. A silent no-op is indistinguishable from a
	// keystroke the terminal never delivered, which is why this is an Action
	// and not just an early return.
	testing.expectf(t, m.last == .Line_Full, "last = %v, want line-full", m.last)

	b := strings.builder_make(); defer strings.builder_destroy(&b)
	drive(t, init(doc), END + DEL, &b)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "last:LINE FULL"),
		"the status bar must name the refusal")
}

// Backspace at column 0 is the same join from the other side, and it must not
// move the caret when it refuses -- a Backspace that "did nothing" has to
// really do nothing.
@(test)
test_backspace_refuses_the_same_join_and_leaves_the_caret_alone :: proc(t: ^testing.T) {
	full := strings.repeat("X", MAX_COLS, context.temp_allocator)
	defer free_all(context.temp_allocator)

	doc := strings.concatenate({full, "\nsecond"}, context.temp_allocator)
	m := run_script(t, init(doc), DOWN + HOME + BKSP)

	testing.expectf(t, m.nlines == 2, "the document lost a line: %d, want 2", m.nlines)
	expect_line(t, m, 0, full, "line 1 must be untouched")
	expect_line(t, m, 1, "second", "line 2 must survive")
	testing.expectf(t, m.cy == 1 && m.cx == 0,
		"a refused Backspace must leave the caret at (1,0), got (%d,%d)", m.cy, m.cx)
	testing.expectf(t, m.last == .Line_Full, "last = %v, want line-full", m.last)

	// ...and a join that DOES fit still works, so the guard is a cap and not a
	// blanket refusal.
	ok := run_script(t, init("ab\ncd"), DOWN + HOME + BKSP)
	testing.expectf(t, ok.nlines == 1, "a joinable pair must still join, got %d lines", ok.nlines)
	expect_line(t, ok, 0, "abcd", "join")
	testing.expectf(t, ok.last == .Backspace, "a successful join: last = %v", ok.last)
}

// The same silence, on the other two caps: a rune typed into a full line, and a
// split in a full document. Both used to return with nothing done and the
// status bar reporting the action as if it had happened.
@(test)
test_a_refused_insert_and_a_refused_split_are_reported :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	full := strings.repeat("X", MAX_COLS, context.temp_allocator)
	m := run_script(t, init(full), END + "z")
	testing.expectf(t, m.lines[0].n == MAX_COLS, "the line grew past its cap: %d", m.lines[0].n)
	testing.expectf(t, m.last == .Line_Full, "insert into a full line: last = %v", m.last)

	// A full DOCUMENT: MAX_LINES lines, then Enter.
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< MAX_LINES { if i > 0 { strings.write_string(&sb, "\n") }; strings.write_string(&sb, "x") }
	d := run_script(t, init(strings.to_string(sb)), "\r")
	testing.expectf(t, d.nlines == MAX_LINES, "the document grew past its cap: %d", d.nlines)
	testing.expectf(t, d.last == .Doc_Full, "Enter in a full document: last = %v", d.last)
}

// ---------------------------------------------------------------------------
// F56 -- CRLF.
// ---------------------------------------------------------------------------

// A pasted CRLF is ONE line break. It used to be two: decode_keys delivers the
// paste payload verbatim (which is correct, and is the same contract Bubble
// Tea's stack has), and this editor's paste branch split on '\r' and then again
// on '\n', so every source line of a CRLF document gained a blank line after
// it. Reproduced over a real pty before the fix: 18 lines in, 22 out, "alpha /
// <blank> / beta / <blank> / gamma".
@(test)
test_a_crlf_paste_is_one_line_break_per_line :: proc(t: ^testing.T) {
	m := run_script(t, init(""), "\e[200~alpha\r\nbeta\r\ngamma\e[201~")

	testing.expectf(t, m.nlines == 3, "CRLF paste: %d lines, want 3", m.nlines)
	expect_line(t, m, 0, "alpha", "CRLF paste")
	expect_line(t, m, 1, "beta", "CRLF paste")
	expect_line(t, m, 2, "gamma", "CRLF paste")

	// The two single-terminator forms are unchanged -- CR-only is what VTE and
	// gnome-terminal deliver, LF-only is what everything else does.
	lf := run_script(t, init(""), "\e[200~alpha\nbeta\e[201~")
	testing.expectf(t, lf.nlines == 2, "LF paste: %d lines, want 2", lf.nlines)
	cr := run_script(t, init(""), "\e[200~alpha\rbeta\e[201~")
	testing.expectf(t, cr.nlines == 2, "CR paste: %d lines, want 2", cr.nlines)

	// An LF that is NOT the second half of a CRLF still splits, even right
	// after a line that ended in one -- i.e. a blank line in a CRLF document
	// survives as a blank line rather than being swallowed.
	blank := run_script(t, init(""), "\e[200~a\r\n\r\nb\e[201~")
	testing.expectf(t, blank.nlines == 3, "CRLF with a blank line: %d lines, want 3", blank.nlines)
	expect_line(t, blank, 1, "", "the blank line must survive")

	// ...and the CR state does not leak past the end of one paste into the next.
	two := run_script(t, init(""), "\e[200~a\r\e[201~\e[200~\nb\e[201~")
	testing.expectf(t, two.nlines == 3, "a fresh paste starting with LF: %d lines, want 3", two.nlines)
}

// ---------------------------------------------------------------------------
// Grapheme clusters -- the caret moves by what the user sees.
// ---------------------------------------------------------------------------

// `e` + U+0301 COMBINING ACUTE is ONE visible character in ONE cell and TWO
// runes. Pressing Left used to be a DEAD KEYSTROKE: m.cx went 2 -> 1, the
// status bar's Col counter changed, and the caret did not move, because
// cursor() measures the display width of the prefix and U+0301 is zero-width.
@(test)
test_the_caret_moves_by_grapheme_cluster_not_by_rune :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// "x" + "e" + U+0301 + "y" -- three visible characters, FOUR runes, three
	// columns. The combining mark is spelled as an escape rather than typed: a
	// literal one is invisible in the source and could silently be the
	// PRECOMPOSED U+00E9, which is ONE rune and would make this test vacuous.
	doc := init("xe\u0301y")
	testing.expect_value(t, doc.lines[0].n, 4)
	testing.expect_value(t, rt.display_width(line_text(doc, 0, context.temp_allocator)), 3)

	// End, then Left three times, must visit exactly the three cluster
	// boundaries -- and every press must move the CARET, which is the display
	// column, not just the rune index.
	Step :: struct { script: string, want_cx, want_col: int }
	for s in ([?]Step{
		{END,                             4, 3},
		{END + LEFT,                      3, 2},
		{END + LEFT + LEFT,               1, 1},   // past BOTH runes of the cluster
		{END + LEFT + LEFT + LEFT,        0, 0},
	}) {
		m := run_script(t, doc, s.script)
		testing.expectf(t, m.cx == s.want_cx, "%q: cx = %d, want %d", s.script, m.cx, s.want_cx)
		testing.expectf(t, cursor(m, context.temp_allocator).col == GUTTER_COLS + s.want_col,
			"%q: caret column = %d, want %d -- a keystroke that does not move the caret is a dead key",
			s.script, cursor(m, context.temp_allocator).col, GUTTER_COLS + s.want_col)
	}

	// Right is the mirror image, from column 0.
	r1 := run_script(t, doc, RIGHT)
	testing.expect_value(t, r1.cx, 1)
	r2 := run_script(t, doc, RIGHT + RIGHT)
	testing.expectf(t, r2.cx == 3, "Right x2 must clear the whole cluster: cx = %d, want 3", r2.cx)

	// AND A COLUMN CARRIED DOWN FROM ANOTHER LINE IS SNAPPED. Up/Down keep the
	// rune index, which on the destination line can fall between the two runes
	// of one visible character -- and cursor() would then measure a prefix that
	// cuts the cluster in half and park the caret inside a glyph. Line 1 here
	// is four ASCII runes, line 2 is "ae\u0301z" (four runes, three columns), so column
	// 2 on line 1 is the middle of line 2's cluster.
	two := init("abcd\nae\u0301z")
	d := run_script(t, two, RIGHT + RIGHT + DOWN)
	testing.expectf(t, d.cy == 1 && d.cx == 1,
		"Down onto a cluster: caret (%d,%d), want (1,1) -- the start of the cluster", d.cy, d.cx)
	testing.expectf(t, cursor(d, context.temp_allocator).col == GUTTER_COLS + 1,
		"Down onto a cluster put the caret at column %d, want %d",
		cursor(d, context.temp_allocator).col, GUTTER_COLS + 1)
}

// Backspace and Delete remove the whole cluster too -- removing the combining
// mark alone left the base letter behind, so one visible character took two
// presses and `é` silently became `e`.
@(test)
test_backspace_and_delete_remove_a_whole_cluster :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	bk := run_script(t, init("xe\u0301y"), END + LEFT + BKSP)
	expect_line(t, bk, 0, "xy", "Backspace over a combining cluster")
	testing.expectf(t, bk.cx == 1, "Backspace: cx = %d, want 1", bk.cx)

	del := run_script(t, init("xe\u0301y"), RIGHT + DEL)
	expect_line(t, del, 0, "xy", "Delete over a combining cluster")
	testing.expectf(t, del.cx == 1, "Delete must not move the caret: cx = %d, want 1", del.cx)

	// An ASCII line is unaffected -- every cluster there is one rune, which is
	// what keeps every other test in this file describing the same behaviour.
	a := run_script(t, init("abc"), RIGHT + BKSP)
	expect_line(t, a, 0, "bc", "ASCII backspace")
}

// ---------------------------------------------------------------------------
// F23 -- the help panel.
// ---------------------------------------------------------------------------

// The panel used to be a fixed 78-column bordered box appended after a fixed
// 14-row layout, with no reference to either terminal dimension: below 78
// columns the terminal wrapped it (top border across two rows, right `│`
// mid-sentence, closing `╯` alone on its own line) and below 19 rows it opened
// with a top border, three content rows and NO BOTTOM BORDER.
@(test)
test_the_help_panel_fits_the_window_at_every_size :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	Size :: struct { w, h: int }
	for s in ([?]Size{{20, 6}, {40, 14}, {60, 20}, {80, 24}, {100, 30}, {200, 50}}) {
		m := init(LONG_DOC, TEST_PROFILE)
		m.term_w, m.term_h, m.help, m.kitty = s.w, s.h, true, true
		v := view(m, context.temp_allocator)

		testing.expectf(t, frame_rows(v, s.w) == s.h,
			"%dx%d: the frame with the panel open is %d rows, want %d", s.w, s.h, frame_rows(v, s.w), s.h)

		// The help TEXT is on screen at every size...
		p := plain(v)
		testing.expectf(t, strings.contains(p, "Ctrl+I"),
			"%dx%d: the panel must show its text: %q", s.w, s.h, p)
		// ...and where a border fits at all, the box is CLOSED -- both corners
		// present. Below three text rows the border is dropped entirely rather
		// than drawn around nothing (see palette): a two-row area minus two
		// border rows is an empty box, which is what 20x6 used to paint.
		m2 := m
		if text_rows(m2) >= 3 {
			testing.expectf(t, strings.contains(p, "╭") && strings.contains(p, "╯"),
				"%dx%d: the panel must be a closed box: %q", s.w, s.h, p)
		} else {
			testing.expectf(t, !strings.contains(p, "╭"),
				"%dx%d: a text area too short for content inside a border must not draw one: %q",
				s.w, s.h, p)
		}
		lines := strings.split_lines(v, context.temp_allocator)
		for line in lines {
			testing.expectf(t, rt.display_width(line) <= s.w,
				"%dx%d: a frame line is %d columns wide: %q",
				s.w, s.h, rt.display_width(line), plain(line))
		}
	}
}

// The panel is MODAL: it takes the text area, so while it is open there is no
// text to click on and no caret to place. Appending it below the status bar --
// which is what made its height unbudgetable -- is what this replaces.
@(test)
test_the_help_panel_takes_the_text_area_and_silences_the_caret :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	m := init(LONG_DOC, TEST_PROFILE)
	m.term_w, m.term_h, m.kitty = 80, 24, true

	open := m; open.help = true
	testing.expect(t, !strings.contains(plain(view(open, context.temp_allocator)), "alpha bravo"),
		"the panel must replace the text, not sit under it")
	testing.expect(t, !cursor(open, context.temp_allocator).show,
		"no caret may be declared while the panel covers the text")
	_, _, ok := click_target(open, GUTTER_COLS, HEADER_LINES, context.temp_allocator)
	testing.expect(t, !ok, "a click must not resolve to a line the panel is covering")

	// ...and closing it brings both back.
	shut := m
	testing.expect(t, strings.contains(plain(view(shut, context.temp_allocator)), "alpha bravo"),
		"closing the panel must bring the text back")
	testing.expect(t, cursor(shut, context.temp_allocator).show, "and the caret with it")
}

// F18's EDITOR-SIDE HALF, pinned so it cannot silently regress.
//
// The decoder half is fixed -- decode_keys no longer manufactures a control
// Rune for Alt+Enter and friends (runetea/input.odin) -- so the specific
// reported path is closed upstream. This asserts the editor's own refusal,
// which is not redundant: `case .Rune` is reachable from sources the decoder
// does not shape, most concretely a Kitty text-input report, whose associated
// codepoints are whatever the terminal chose to send. Before the filter,
// apply_key inserted them, and this file's standing contract with the .Diff
// renderer is that no C0 byte ever reaches the view -- a contract
// test_the_editors_view_satisfies_the_diff_renderers_contract enforces on the
// PASTE path and on the loader, and enforced nowhere on this one.
//
// The refusal is a DROP, not an insert-as-something-else, matching the paste
// branch at the top of apply_key exactly. Deliberately checked against the
// document rather than the view: a view assertion would pass just as well if
// the byte were inserted and then filtered on the way out, which would leave
// the model holding text the user can never see or delete.
@(test)
test_a_non_pasted_control_rune_is_dropped_rather_than_inserted :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Every C0 byte, plus DEL. 0x09 and 0x0A are included on purpose: Tab and
	// Enter reach apply_key as .Tab and .Enter (their own cases, which insert
	// spaces and split the line), so a .Rune carrying the raw byte is never
	// the legitimate route to either and must be refused like the rest.
	for r in rune(0) ..= rune(0x1F) {
		m := init("ab", TEST_PROFILE)
		m.term_w, m.term_h = 80, 24
		m.cx = 1
		apply_key(&m, rt.Key_Msg{code = .Rune, r = r}, context.temp_allocator)
		expect_line(t, m, 0, "ab", fmt.tprintf("control rune U+%04X", r))
		testing.expectf(t, m.cx == 1, "U+%04X moved the caret to %d; a refused key must not move it", r, m.cx)
	}

	m := init("ab", TEST_PROFILE)
	m.term_w, m.term_h = 80, 24
	m.cx = 1
	apply_key(&m, rt.Key_Msg{code = .Rune, r = 0x7F}, context.temp_allocator)
	expect_line(t, m, 0, "ab", "DEL as a .Rune")
	testing.expect_value(t, m.cx, 1)

	// The control is that an ORDINARY rune at the same call site still lands:
	// a filter that refused everything would pass every assertion above.
	ok := init("ab", TEST_PROFILE)
	ok.term_w, ok.term_h = 80, 24
	ok.cx = 1
	apply_key(&ok, rt.Key_Msg{code = .Rune, r = 'X'}, context.temp_allocator)
	expect_line(t, ok, 0, "aXb", "an ordinary rune")
}
