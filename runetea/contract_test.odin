#+private
// ^ Every declaration in this file is package-private, so that `odin doc
//   runetea` / `odin doc runegloss` -- the command README.md and docs/API.md
//   hand a newcomer for symbol discovery -- lists the library rather than the
//   test fixtures. Pinned by tools/doccheck/run.sh's `apidoc` check, which is
//   also where the argument for it is written out.
package runetea

import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------
// view_diff_safe: the .Diff view contract, as a predicate.
// ---------------------------------------------------------------------------

@(test)
test_view_diff_safe_accepts_plain_text_styling_and_hyperlinks :: proc(t: ^testing.T) {
	OK := []string{
		"",
		"hello",
		"line one\nline two\n",
		"\e[31mred\e[0m",
		"\e[1m\e[38;5;120m\e[4mstacked\e[0m",
		"\e[mreset with no parameter\e[0m",
		"\e]8;;https://example.com\e\\link\e]8;;\e\\",
		"\e]8;id=1;https://example.com\e\\link\e]8;;\e\\",
		"\e]8;;https://example.com\aBEL terminated\e]8;;\a",
		"界 wide runes and é combining marks",
		"\e[7m❤️\e[0m 🇯🇵",
	}
	for v in OK {
		ok, at, why := view_diff_safe(v)
		testing.expectf(t, ok, "expected %q to be diff-safe, got %v at byte %d", v, why, at)
	}
}

@(test)
test_view_diff_safe_rejects_control_bytes :: proc(t: ^testing.T) {
	// \t is the one that bites in practice: it is a MOVE to the next tab stop,
	// and a cell grid can record what is IN a cell but not a jump between them,
	// so every cell after it is somewhere the diff does not think it is.
	// examples/editor expands tabs to spaces for exactly this reason. Note it is
	// rejected HERE and accepted by view_render_safe -- see
	// test_view_render_safe_accepts_the_one_control_byte_the_row_count_models.
	cases := []struct{ v: string, at: int }{
		{"a\tb",    1},
		{"a\rb",    1},
		{"a\x08b",  1},
		{"bell\a",  4},
		{"a\x00b",  1},
		{"a\x7Fb",  1},
		{"\e[31mred\e[0m\tmore", 12},
	}
	for c in cases {
		ok, at, why := view_diff_safe(c.v)
		testing.expectf(t, !ok, "expected %q to be rejected", c.v)
		testing.expect_value(t, why, Diff_Contract.Control_Byte)
		testing.expect_value(t, at, c.at)
	}
	// \n is the ONE control byte that is legal: renderer_render splits the view
	// on it before a line ever reaches the cell model, so rejecting it would
	// fail every multi-line view, i.e. every real one.
	ok, _, _ := view_diff_safe("a\nb")
	testing.expect(t, ok, "\\n must be legal -- the renderer splits on it")
}

@(test)
test_view_diff_safe_rejects_motion_escapes :: proc(t: ^testing.T) {
	// Everything here renders identically under .Full_Screen (which passes the
	// bytes through) and wrongly under .Diff (whose model did not perform the
	// move). That divergence is exactly what the checker exists to name.
	MOTION := []string{
		"a\e[2Ab",       // CUU
		"a\e[3Cb",       // CUF
		"a\e[5;1Hb",     // CUP
		"a\e[10Gb",      // CHA
		"a\e[Kb",        // EL
		"a\e[2Jb",       // ED
		"a\e[?25lb",     // DECTCEM
		"a\e[1;5rb",     // DECSTBM
	}
	for v in MOTION {
		ok, at, why := view_diff_safe(v)
		testing.expectf(t, !ok, "expected %q to be rejected", v)
		testing.expect_value(t, why, Diff_Contract.Motion_Escape)
		testing.expect_value(t, at, 1)
	}
}

@(test)
test_view_diff_safe_rejects_non_hyperlink_string_escapes :: proc(t: ^testing.T) {
	// Zero width, so the LAYOUT survives -- which is precisely why this is worth
	// diagnosing: the frame looks right and the payload is gone.
	OTHER := []string{
		"a\e]0;window title\e\\b",   // OSC 0
		"a\e]52;c;Zm9v\e\\b",        // OSC 52 clipboard
		"a\e]80;not eight\e\\b",     // an OSC whose code merely STARTS with 8
		"a\ePq#0;2;0;0;0\e\\b",      // DCS / sixel
		"a\e_Gf=100\e\\b",           // APC / Kitty graphics
	}
	for v in OTHER {
		ok, at, why := view_diff_safe(v)
		testing.expectf(t, !ok, "expected %q to be rejected", v)
		testing.expect_value(t, why, Diff_Contract.Other_String_Escape)
		testing.expect_value(t, at, 1)
	}
}

@(test)
test_view_diff_safe_rejects_other_and_truncated_escapes :: proc(t: ^testing.T) {
	other := []string{
		"a\e(Bb",   // nF: select ASCII into G0
		"a\eMb",    // RI (reverse index)
		"a\e7b",    // DECSC
	}
	for v in other {
		ok, _, why := view_diff_safe(v)
		testing.expectf(t, !ok, "expected %q to be rejected", v)
		testing.expect_value(t, why, Diff_Contract.Other_Escape)
	}

	// A truncated escape does not merely vanish. The terminal consumes its
	// missing tail from whatever bytes arrive next -- in .Diff mode, the NEXT
	// FRAME's cursor move -- so it eats the beginning of the following frame.
	truncated := []string{
		"text\e",             // bare trailing ESC
		"text\e[",            // CSI with no final byte
		"text\e[3",           // CSI with a parameter and no final byte
		"text\e]8;;https:/",  // OSC with no ST or BEL
		"text\e(",            // nF with an intermediate and no final byte
	}
	for v in truncated {
		ok, at, why := view_diff_safe(v)
		testing.expectf(t, !ok, "expected %q to be rejected", v)
		testing.expect_value(t, why, Diff_Contract.Truncated_Escape)
		testing.expect_value(t, at, 4)
	}
}

// THE COUPLING TEST, and the one that keeps this file honest.
//
// view_diff_safe answering "safe" for an escape screen_escape does not model is
// silent data loss with a green test suite on top -- the two lists have to be
// the same list. Rather than assert that by reading both, this drives every
// escape through the REAL model and checks that "the model's state changed"
// and "the checker approved" agree, escape for escape.
@(test)
test_view_diff_safe_accepts_exactly_what_the_cell_model_tracks :: proc(t: ^testing.T) {
	ESCAPES := []string{
		// tracked
		"\e[31m", "\e[0m", "\e[m", "\e[1;4;38;5;120m",
		"\e]8;;https://example.com\e\\", "\e]8;id=3;https://example.com\e\\", "\e]8;;\e\\",
		"\e]8;;https://example.com\a",
		// not tracked
		"\e[2A", "\e[H", "\e[K", "\e[2J", "\e[?25l", "\e[6n",
		"\e]0;title\e\\", "\e]52;c;Zm9v\e\\", "\eP0;1|\e\\", "\e_Gx=1\e\\",
		"\e(B", "\eM", "\e7", "\e8",
	}

	st, lt: Style_Table
	style_table_init(&st); defer style_table_destroy(&st)
	style_table_init(&lt); defer style_table_destroy(&lt)
	scratch: [dynamic]u8; defer delete(scratch)

	s: Screen
	screen_init(&s, 4, 2, &st, &lt); defer screen_destroy(&s)

	for esc in ESCAPES {
		// A known, non-default starting state, so that an escape which RESETS
		// counts as a change just as much as one that sets.
		s.style, s.link = 0, 0
		screen_escape(&s, "\e[31m", &scratch)
		screen_escape(&s, "\e]8;;https://start\e\\", &scratch)
		before_style, before_link := s.style, s.link

		screen_escape(&s, esc, &scratch)
		modelled := s.style != before_style || s.link != before_link

		approved, _, why := view_diff_safe(esc)
		testing.expectf(t, approved == modelled,
			"%q: view_diff_safe says %v (%v) but the cell model %s it -- these two lists must be the same list",
			esc, approved, why, modelled ? "TRACKS" : "IGNORES")
	}
}

// ---------------------------------------------------------------------------
// The mode-general tier.
// ---------------------------------------------------------------------------

@(test)
test_view_render_safe_accepts_the_one_control_byte_the_row_count_models :: proc(t: ^testing.T) {
	// THE F04 CONSEQUENCE, as a predicate. A tab is legal under .Inline and
	// .Full_Screen because width.odin now MODELS it (HT advances to the next tab
	// stop, clamped at the margin), so rows_for_line counts a tabbed line's rows
	// correctly and .Inline's rewind stays in step. It stays illegal under .Diff,
	// which has to name the cells a glyph landed in and a tab lands in none.
	ok, _, _ := view_render_safe("id\tname\tstatus")
	testing.expect(t, ok, "a tab is legal in the render tier -- width.odin models it")
	dok, dat, dwhy := view_diff_safe("id\tname\tstatus")
	testing.expect(t, !dok, "a tab is still illegal in the diff tier")
	testing.expect_value(t, dwhy, Diff_Contract.Control_Byte)
	testing.expect_value(t, dat, 2)
}

@(test)
test_view_render_safe_rejects_everything_that_breaks_a_row_count :: proc(t: ^testing.T) {
	// The tab is the ONLY byte the two tiers disagree about. Everything else
	// here moves the cursor, erases, or eats the next frame's bytes, and every
	// mode counts the physical rows it painted and acts on that count -- so all
	// of it is fatal to .Inline's rewind and .Full_Screen's truncation too, not
	// only to the cell model.
	BAD := []struct{ v: string, why: Diff_Contract }{
		{"a\rb",            .Control_Byte},          // CR: back to column 0
		{"a\x08b",          .Control_Byte},          // BS
		{"bell\a",          .Control_Byte},
		{"a\x7Fb",          .Control_Byte},
		{"a\e[2Ab",         .Motion_Escape},         // CUU: the .Inline rewind's own escape
		{"a\e[5;1Hb",       .Motion_Escape},         // CUP
		{"a\e[2Jb",         .Motion_Escape},         // ED
		{"a\e]0;title\e\\b", .Other_String_Escape},
		{"a\eMb",           .Other_Escape},          // RI: scrolls at the top margin
		{"text\e[3",        .Truncated_Escape},
	}
	for c in BAD {
		ok, _, why := view_render_safe(c.v)
		testing.expectf(t, !ok, "expected %q to be rejected by the render tier", c.v)
		testing.expect_value(t, why, c.why)
	}
	// And the two tiers agree on all of it, byte offset included.
	for c in BAD {
		rok, rat, rwhy := view_render_safe(c.v)
		dok, dat, dwhy := view_diff_safe(c.v)
		testing.expectf(t, rok == dok && rat == dat && rwhy == dwhy,
			"%q: the tiers must differ only on \\t", c.v)
	}
	// The accepting side agrees too.
	GOOD := []string{"", "hello", "\e[31mred\e[0m", "\e]8;;https://x\e\\l\e]8;;\e\\", "a\nb"}
	for v in GOOD {
		rok, _, _ := view_render_safe(v)
		dok, _, _ := view_diff_safe(v)
		testing.expectf(t, rok && dok, "%q must be legal in both tiers", v)
	}
}

// ---------------------------------------------------------------------------
// The loud path.
// ---------------------------------------------------------------------------
//
// These call the assertions DIRECTLY, through the package's own panic recovery,
// so the loud path is exercised whatever VIEW_STRICT/DIFF_STRICT are set to.
// That mattered more than it does now: the comment here used to say "DIFF_STRICT
// defaults to ODIN_DEBUG, which `odin test` does not set, so the assertion is
// not live on the gate", and that was the whole finding -- the default was also
// off for the plain `odin build` the README publishes, so the check existed only
// for a build nobody was told to make. VIEW_STRICT is now on for anything short
// of -o:speed, `odin test` included, so the renderer really does assert on every
// frame of this suite. These tests stay direct anyway: they pin the MESSAGE,
// which no amount of ambient assertion does.

@(private = "file")
Assert_Case :: struct {
	view:      string,
	recovered: bool,
	message:   string,
}

@(private = "file")
run_assert :: proc(ud: rawptr) {
	c := (^Assert_Case)(ud)
	diff_contract_assert(c.view)
}

@(private = "file")
check_assert :: proc(view: string) -> Panic_Info {
	c := Assert_Case{view = view}
	return guarded(run_assert, &c)
}

@(private = "file")
run_render_assert :: proc(ud: rawptr) {
	c := (^Assert_Case)(ud)
	render_contract_assert(c.view)
}

@(private = "file")
check_render_assert :: proc(view: string) -> Panic_Info {
	c := Assert_Case{view = view}
	return guarded(run_render_assert, &c)
}

@(test)
test_diff_contract_assert_is_silent_on_a_legal_view :: proc(t: ^testing.T) {
	info := check_assert("\e[31mred\e[0m \e]8;;https://example.com\e\\link\e]8;;\e\\")
	defer delete(info.message)
	testing.expect(t, !info.recovered, "a legal view must not trip the contract assertion")
}

@(test)
test_diff_contract_assert_panics_and_says_where :: proc(t: ^testing.T) {
	info := check_assert("status\tbar")
	defer delete(info.message)
	// NON-VACUITY: if this proc ever stopped panicking, `recovered` would be
	// false and this test would fail -- which is the whole point of routing it
	// through guarded() rather than trusting a comment.
	testing.expect(t, info.recovered, "an illegal view must panic under DIFF_STRICT")
	testing.expect(t, strings.contains(info.message, "Control_Byte"),
		"the panic must name WHAT is wrong")
	testing.expect(t, strings.contains(info.message, "byte 6"),
		"the panic must name WHERE it is wrong")
	testing.expect(t, strings.contains(info.message, "view_diff_safe"),
		"the panic must name the predicate the caller can run themselves")
}

@(test)
test_diff_contract_assert_excerpt_is_bounded :: proc(t: ^testing.T) {
	// A 100 KB view must not become a 100 KB panic message.
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	for _ in 0 ..< 100_000 { strings.write_byte(&b, 'x') }
	strings.write_byte(&b, '\t')
	info := check_assert(strings.to_string(b))
	defer delete(info.message)
	testing.expect(t, info.recovered, "an illegal view must panic")
	testing.expectf(t, len(info.message) < 1024,
		"the diagnostic must be bounded, got %d bytes", len(info.message))
}

// ---------------------------------------------------------------------------
// F27: the switch itself.
// ---------------------------------------------------------------------------

@(test)
test_view_strict_is_on_in_any_build_that_is_not_optimised :: proc(t: ^testing.T) {
	// THE FINDING, AS AN ASSERTION. The default used to be plain ODIN_DEBUG,
	// which `odin test` does not set and which the README's own build command
	// (`odin build . -collection:rune=vendor/runetea`) does not set either -- so
	// the only checkable contract in the package was compiled out of every build
	// the project actually publishes, and a tab in a .Diff view produced
	// permanently wrong output with no diagnostic of any kind. This test failed
	// before the default moved and is the reason it is a `when`-free runtime
	// assertion: a compile-time `#assert` would have been just as invisible.
	testing.expect(t, VIEW_STRICT,
		"VIEW_STRICT must be on for `odin test` -- it is on for anything but -o:speed")
	testing.expect(t, DIFF_STRICT,
		"DIFF_STRICT defaults to VIEW_STRICT, so it inherits the corrected default")
	// It is still compiled out where it must be. Stated rather than asserted --
	// this build is not an optimised one, so there is nothing here to measure --
	// but the expression is pinned so a future edit that drops the guard fails
	// to compile rather than silently costing a scan per frame in production.
	#assert(VIEW_STRICT == #config(RUNETEA_VIEW_STRICT, ODIN_DEBUG || ODIN_OPTIMIZATION_MODE < .Speed))
}

@(test)
test_render_contract_assert_is_silent_on_a_tab_and_loud_on_a_move :: proc(t: ^testing.T) {
	// The tab passes the render tier -- the assertion that fires for .Diff must
	// NOT fire for .Inline, or the fix to rows_for_line would be unreachable.
	tabbed := check_render_assert("id\tname\tstatus")
	defer delete(tabbed.message)
	testing.expect(t, !tabbed.recovered, "a tab is legal under .Inline and .Full_Screen")

	// A cursor move is not. This is the byte that makes Renderer.last_rows a lie.
	moved := check_render_assert("row\e[2Aoops")
	defer delete(moved.message)
	testing.expect(t, moved.recovered, "a motion escape must panic under VIEW_STRICT")
	testing.expect(t, strings.contains(moved.message, "Motion_Escape"),
		"the panic must name WHAT is wrong")
	testing.expect(t, strings.contains(moved.message, "byte 3"),
		"the panic must name WHERE it is wrong")
	testing.expect(t, strings.contains(moved.message, "view_render_safe"),
		"the panic must name the predicate the caller can run themselves")
	testing.expect(t, strings.contains(moved.message, "RUNETEA_VIEW_STRICT"),
		"the panic must name the escape hatch")
}

@(test)
test_diff_contract_assert_points_a_tab_at_the_modes_that_model_it :: proc(t: ^testing.T) {
	// A developer who hits this is one sentence away from a fix, and the
	// sentence changed: expanding tabs is no longer the ONLY answer, because
	// .Inline and .Full_Screen now measure them.
	info := check_assert("status\tbar")
	defer delete(info.message)
	testing.expect(t, info.recovered, "a tab is still illegal under .Diff")
	testing.expect(t, strings.contains(info.message, "tab is a move"),
		"the panic must say WHY a tab is different from a styled byte")
	testing.expect(t, strings.contains(info.message, ".Inline"),
		"the panic must name the modes that do model a tab")
}
