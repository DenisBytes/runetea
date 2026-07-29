package runegloss

import "core:testing"

// ---------------------------------------------------------------------------
// hex parsing
// ---------------------------------------------------------------------------

@(test)
test_color_hex_parses_six_digit_form :: proc(t: ^testing.T) {
	c := color("#7D56F4")
	testing.expect_value(t, c.kind, Color_Kind.RGB)
	testing.expect_value(t, c.r, u8(0x7D))
	testing.expect_value(t, c.g, u8(0x56))
	testing.expect_value(t, c.b, u8(0xF4))
}

@(test)
test_color_hex_parses_three_digit_form_by_nybble_doubling :: proc(t: ^testing.T) {
	// "#F0A" is "#FF00AA", not "#0F000A" -- each nybble is doubled, which is
	// the CSS rule and the only one that keeps "#FFF" white.
	c := color("#F0A")
	testing.expect_value(t, c.r, u8(0xFF))
	testing.expect_value(t, c.g, u8(0x00))
	testing.expect_value(t, c.b, u8(0xAA))
}

@(test)
test_color_hex_is_case_insensitive_and_hash_optional :: proc(t: ^testing.T) {
	a := color("#7d56f4")
	b := color("7D56F4")
	testing.expect_value(t, a, b)
}

@(test)
test_color_hex_rejects_garbage_as_no_color :: proc(t: ^testing.T) {
	// A bad literal must degrade to "no colour", never to a wrong colour: a
	// typo'd hex that silently rendered as black would be far harder to spot
	// than one that renders unstyled.
	for bad in ([]string{"", "#", "#12", "#12345", "#GGGGGG", "#1234567", "nope"}) {
		testing.expect_value(t, color(bad).kind, Color_Kind.None)
	}
}

@(test)
test_color_ansi_index_and_out_of_range :: proc(t: ^testing.T) {
	c := color(212)
	testing.expect_value(t, c.kind, Color_Kind.ANSI)
	testing.expect_value(t, c.idx, u8(212))
	// Out of range is "no colour" for the same reason a bad hex is.
	testing.expect_value(t, color(-1).kind, Color_Kind.None)
	testing.expect_value(t, color(256).kind, Color_Kind.None)
}

// ---------------------------------------------------------------------------
// profile detection -- PURE, over explicit env values, never the ambient
// environment (see detect_profile_env's own comment)
// ---------------------------------------------------------------------------

@(test)
test_no_color_forces_none_regardless_of_everything_else :: proc(t: ^testing.T) {
	// https://no-color.org: "when present and not an empty string (regardless
	// of its value)". So "0" and "false" both DISABLE colour -- the classic
	// misreading is to treat NO_COLOR=0 as "colour on".
	for v in ([]string{"1", "0", "false", "yes", " "}) {
		testing.expect_value(t, detect_profile_env(v, "truecolor", "xterm-256color"), Profile.None)
	}
	// Empty is absent, and must NOT disable colour.
	testing.expect_value(t, detect_profile_env("", "truecolor", "xterm-256color"), Profile.True_Color)
}

@(test)
test_profile_detection_table :: proc(t: ^testing.T) {
	Case :: struct { no_color, colorterm, term: string, want: Profile }
	cases := []Case{
		{"", "truecolor", "xterm-256color", .True_Color},
		{"", "24bit",     "xterm",          .True_Color},
		{"", "TrueColor", "xterm",          .True_Color},   // case-insensitive
		{"", "",          "xterm-256color", .ANSI256},
		{"", "",          "screen-256color", .ANSI256},
		{"", "",          "xterm",          .ANSI},
		{"", "",          "screen",         .ANSI},
		{"", "",          "linux",          .ANSI},
		{"", "",          "dumb",           .None},
		{"", "",          "",               .None},
		// COLORTERM set to something meaningless must not promote anything.
		{"", "yes",       "xterm",          .ANSI},
		{"", "yes",       "",               .None},
	}
	for c in cases {
		got := detect_profile_env(c.no_color, c.colorterm, c.term)
		if got != c.want {
			testing.expectf(t, false, "detect_profile_env(%q,%q,%q) = %v, want %v",
				c.no_color, c.colorterm, c.term, got, c.want)
		}
	}
}

// ---------------------------------------------------------------------------
// down-conversion. Expected indices were computed INDEPENDENTLY (a throwaway
// Python script over the same xterm palette and the same CIE76 formula) before
// this implementation existed, so these numbers are not a transcription of
// whatever the Odin code happened to produce.
// ---------------------------------------------------------------------------

@(test)
test_truecolor_passes_through_unconverted :: proc(t: ^testing.T) {
	c := color("#7D56F4")
	testing.expect_value(t, convert(c, .True_Color), c)
}

@(test)
test_rgb_down_converts_to_256_by_lab_distance :: proc(t: ^testing.T) {
	Case :: struct { hex: string, want256, want16: u8 }
	cases := []Case{
		{"#7D56F4",  99,  4},
		{"#FF0000", 196,  9},
		{"#00FF00",  46, 10},
		{"#808080", 244,  8},
		{"#FAFAFA", 231, 15},
		{"#04B575",  35,  2},
	}
	for c in cases {
		got256 := convert(color(c.hex), .ANSI256)
		testing.expect_value(t, got256.kind, Color_Kind.ANSI)
		if got256.idx != c.want256 {
			testing.expectf(t, false, "convert(%s, .ANSI256).idx = %d, want %d", c.hex, got256.idx, c.want256)
		}
		got16 := convert(color(c.hex), .ANSI)
		if got16.idx != c.want16 {
			testing.expectf(t, false, "convert(%s, .ANSI).idx = %d, want %d", c.hex, got16.idx, c.want16)
		}
	}
}

@(test)
test_256_index_down_converts_to_16 :: proc(t: ^testing.T) {
	Case :: struct { idx, want: u8 }
	for c in ([]Case{{33, 4}, {196, 9}, {231, 15}, {244, 8}, {21, 12}}) {
		got := convert(color(int(c.idx)), .ANSI)
		if got.idx != c.want {
			testing.expectf(t, false, "convert(ansi %d, .ANSI).idx = %d, want %d", c.idx, got.idx, c.want)
		}
	}
}

@(test)
test_index_under_16_is_already_representable_everywhere :: proc(t: ^testing.T) {
	for i in 0 ..< 16 {
		c := color(i)
		testing.expect_value(t, convert(c, .ANSI), c)
		testing.expect_value(t, convert(c, .ANSI256), c)
		testing.expect_value(t, convert(c, .True_Color), c)
	}
}

@(test)
test_profile_none_erases_every_colour :: proc(t: ^testing.T) {
	testing.expect_value(t, convert(color("#7D56F4"), .None).kind, Color_Kind.None)
	testing.expect_value(t, convert(color(212), .None).kind, Color_Kind.None)
	testing.expect_value(t, convert(color(1), .None).kind, Color_Kind.None)
}

@(test)
test_two_step_degradation_agrees_on_these_six_samples_but_not_in_general :: proc(t: ^testing.T) {
	// truecolor -> 256 -> 16 lands where truecolor -> 16 does ON THESE SIX
	// SAMPLES. That is the whole claim. It is NOT a property of convert and is
	// NOT checked across the palette: the 256 cube is a lossy waypoint, so
	// rounding to it first can move a colour into a different nearest-16
	// neighbourhood, and nothing prevents that.
	for hex in ([]string{"#7D56F4", "#FF0000", "#00FF00", "#808080", "#FAFAFA", "#04B575"}) {
		c := color(hex)
		direct := convert(c, .ANSI)
		stepped := convert(convert(c, .ANSI256), .ANSI)
		if direct != stepped {
			testing.expectf(t, false, "%s: direct %v != stepped %v", hex, direct, stepped)
		}
	}

	// THE KNOWN COUNTEREXAMPLE, asserted so the limit is pinned rather than
	// implied by the samples above. #123456 is a dark desaturated blue: direct
	// CIE76 to the 16 puts it at 0 (black), while the 256 cube rounds it to 24
	// (a distinctly teal-blue) and 24's own nearest-16 is 6 (cyan). Both hops are
	// what CIE76 says; neither is a convert defect. If this ever starts agreeing,
	// the colour maths changed and the six samples above stopped proving anything
	// they were not already proving by luck.
	odd := color("#123456")
	testing.expect_value(t, convert(odd, .ANSI).idx, u8(0))
	testing.expect_value(t, convert(odd, .ANSI256).idx, u8(24))
	testing.expect_value(t, convert(convert(odd, .ANSI256), .ANSI).idx, u8(6))
}

// ---------------------------------------------------------------------------
// SGR bytes -- the same #RRGGBB under each of the four profiles
// ---------------------------------------------------------------------------

@(test)
test_same_hex_under_each_profile_emits_expected_sgr :: proc(t: ^testing.T) {
	Case :: struct { p: Profile, want: string }
	cases := []Case{
		{.True_Color, "\e[38;2;125;86;244mX\e[0m"},
		{.ANSI256,    "\e[38;5;99mX\e[0m"},
		{.ANSI,       "\e[34mX\e[0m"},     // index 4 -> 30+4
		{.None,       "X"},
	}
	for c in cases {
		s := new_style_profile(c.p)
		fg(&s, color("#7D56F4"))
		got := render(&s, "X", context.allocator)
		defer delete(got, context.allocator)
		testing.expect_value(t, got, c.want)
	}
}

@(test)
test_bright_ansi_index_uses_the_90s_range_not_38_5 :: proc(t: ^testing.T) {
	s := new_style_profile(.ANSI)
	fg(&s, color(12))
	bg(&s, color(3))
	got := render(&s, "X", context.allocator)
	defer delete(got, context.allocator)
	testing.expect_value(t, got, "\e[94;43mX\e[0m")
}

@(test)
test_attributes_survive_profile_none :: proc(t: ^testing.T) {
	// NO_COLOR is about COLOUR. Bold/italic/underline are not colour, and
	// stripping them would make a $NO_COLOR terminal lose emphasis entirely.
	s := new_style_profile(.None)
	fg(&s, color("#FF0000"))
	bold(&s, true)
	underline(&s, true)
	got := render(&s, "X", context.allocator)
	defer delete(got, context.allocator)
	testing.expect_value(t, got, "\e[1;4mX\e[0m")
}
