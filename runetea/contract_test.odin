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
	// whose position the cell model does not track, so every cell after it is
	// somewhere the diff does not think it is. examples/editor expands tabs to
	// spaces for exactly this reason.
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
// The loud path.
// ---------------------------------------------------------------------------
//
// DIFF_STRICT defaults to ODIN_DEBUG, which `odin test` does not set, so the
// assertion is not live on the gate. That is the right default -- it is a
// development check, not a production cost -- but it means the gate would never
// notice the assertion rotting. These call diff_contract_assert DIRECTLY,
// through the package's own panic recovery, so the loud path is exercised in
// every build regardless of how DIFF_STRICT is set.

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
