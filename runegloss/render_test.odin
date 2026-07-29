package runegloss

import "core:strings"
import "core:testing"
import rt "../runetea"

// ---------------------------------------------------------------------------
// Style is a PLAIN VALUE TYPE
// ---------------------------------------------------------------------------

@(test)
test_style_is_pod_and_therefore_freely_copyable :: proc(t: ^testing.T) {
	// rt.is_pod_type is runetea's own structural check for "contains no
	// string/pointer/slice/map/any anywhere in its field tree" (arena.odin).
	// Reusing it here is the strongest available statement of the requirement
	// that an app may store a Style in its model and copy it around: a Style
	// that failed this could alias its source's storage on copy.
	testing.expect(t, rt.is_pod_type(Style), "Style must be POD")
	testing.expect(t, rt.is_pod_type(Border), "Border must be POD")
	testing.expect(t, rt.is_pod_type(Color), "Color must be POD")
}

@(test)
test_copying_a_style_shares_nothing_with_the_original :: proc(t: ^testing.T) {
	a := new_style_profile(.True_Color)
	fg(&a, color("#FF0000"))
	border(&a, ROUNDED)
	padding(&a, 1, 1)

	b := a
	fg(&b, color("#00FF00"))
	border(&b, DOUBLE)
	padding(&b, 0, 0)

	testing.expect_value(t, a.fg, color("#FF0000"))
	testing.expect_value(t, a.pad[.Left], 1)
	testing.expect_value(t, cell_str(&a.border.left), "│")   // still ROUNDED's
}

// ---------------------------------------------------------------------------
// byte-exact canonical renders
// ---------------------------------------------------------------------------

@(private = "file")
one :: proc(t: ^testing.T, s: ^Style, text, want: string, loc := #caller_location) {
	got := render(s, text, context.allocator)
	defer delete(got, context.allocator)
	if got != want {
		testing.expectf(t, false, "got  %q\nwant %q", got, want, loc = loc)
	}
}

@(test)
test_unstyled_render_is_the_input_byte_for_byte :: proc(t: ^testing.T) {
	// The zero-cost case. A Style that asks for nothing must not write a single
	// escape -- same opt-in discipline runetea's renderer follows for DECTCEM.
	s := new_style_profile(.True_Color)
	one(t, &s, "Hello", "Hello")
	one(t, &s, "", "")
	one(t, &s, "a\nb", "a\nb")
}

@(test)
test_fg_only :: proc(t: ^testing.T) {
	s := new_style_profile(.True_Color)
	fg(&s, color("#7D56F4"))
	one(t, &s, "Hello", "\e[38;2;125;86;244mHello\e[0m")
}

@(test)
test_attributes_are_one_sgr_in_enum_order :: proc(t: ^testing.T) {
	s := new_style_profile(.True_Color)
	bold(&s, true); italic(&s, true); underline(&s, true); strikethrough(&s, true)
	one(t, &s, "x", "\e[1;3;4;9mx\e[0m")
}

@(test)
test_padding_is_inside_the_style_run_and_margin_is_outside :: proc(t: ^testing.T) {
	// The visible difference between the two, and the reason they are separate
	// concepts at all: padding is part of the box (it takes the background),
	// margin is the gap around it (it does not).
	a := new_style_profile(.True_Color); bg(&a, color("#FF0000")); padding(&a, 0, 2)
	one(t, &a, "Hi", "\e[48;2;255;0;0m  Hi  \e[0m")

	b := new_style_profile(.True_Color); bg(&b, color("#FF0000")); margin(&b, 0, 2)
	one(t, &b, "Hi", "  \e[48;2;255;0;0mHi\e[0m  ")
}

@(test)
test_vertical_padding_paints_full_width_rows :: proc(t: ^testing.T) {
	s := new_style_profile(.True_Color)
	padding(&s, 1, 2)
	one(t, &s, "Hi", "      \n  Hi  \n      ")
}

@(test)
test_width_and_alignment :: proc(t: ^testing.T) {
	l := new_style_profile(.True_Color); width(&l, 10); align(&l, .Left)
	one(t, &l, "Hi", "Hi        ")
	c := new_style_profile(.True_Color); width(&c, 10); align(&c, .Center)
	one(t, &c, "Hi", "    Hi    ")
	r := new_style_profile(.True_Color); width(&r, 10); align(&r, .Right)
	one(t, &r, "Hi", "        Hi")
	// Odd remainder goes to the RIGHT, matching Lipgloss.
	c9 := new_style_profile(.True_Color); width(&c9, 9); align(&c9, .Center)
	one(t, &c9, "Hi", "   Hi    ")
}

@(test)
test_height_and_vertical_alignment :: proc(t: ^testing.T) {
	top := new_style_profile(.True_Color); height(&top, 3); valign(&top, .Top)
	one(t, &top, "X", "X\n \n ")
	mid := new_style_profile(.True_Color); height(&mid, 3); valign(&mid, .Middle)
	one(t, &mid, "X", " \nX\n ")
	bot := new_style_profile(.True_Color); height(&bot, 3); valign(&bot, .Bottom)
	one(t, &bot, "X", " \n \nX")
}

@(test)
test_border_wraps_the_whole_block_not_each_line :: proc(t: ^testing.T) {
	s := new_style_profile(.True_Color)
	border(&s, NORMAL)
	one(t, &s, "Hi", "┌──┐\n│Hi│\n└──┘")
	// Ragged multi-line input: every line is padded to the BLOCK width first,
	// then one border goes around the lot.
	one(t, &s, "ab\nc", "┌──┐\n│ab│\n│c │\n└──┘")
}

@(test)
test_border_colour_is_independent_of_content_colour :: proc(t: ^testing.T) {
	s := new_style_profile(.True_Color)
	fg(&s, color("#FF0000"))
	border(&s, NORMAL)
	border_fg(&s, color("#00FF00"))
	G :: "\e[38;2;0;255;0m"
	R :: "\e[38;2;255;0;0m"
	one(t, &s, "X",
		G + "┌─┐" + "\e[0m" + "\n" +
		G + "│" + "\e[0m" + R + "X" + "\e[0m" + G + "│" + "\e[0m" + "\n" +
		G + "└─┘" + "\e[0m")
}

@(test)
test_hidden_border_reserves_columns_without_drawing :: proc(t: ^testing.T) {
	s := new_style_profile(.True_Color)
	border(&s, HIDDEN)
	one(t, &s, "Hi", "    \n Hi \n    ")
}

@(test)
test_border_sides_can_be_dropped :: proc(t: ^testing.T) {
	s := new_style_profile(.True_Color)
	border(&s, NORMAL)
	border_sides(&s, {.Top, .Bottom})
	one(t, &s, "Hi", "──\n" + "Hi\n" + "──")

	v := new_style_profile(.True_Color)
	border(&v, NORMAL)
	border_sides(&v, {.Left, .Right})
	one(t, &v, "Hi", "│Hi│")
}

// ---------------------------------------------------------------------------
// input that ALREADY contains SGR
// ---------------------------------------------------------------------------

@(test)
test_inner_reset_restores_the_outer_style_rather_than_the_terminal_default :: proc(t: ^testing.T) {
	// THE DOCUMENTED RULE (see write_content): the outer style is the FLOOR.
	// Inner SGR layers on top of it, and an inner reset drops back to the outer
	// style, not to the terminal's default -- otherwise everything after a
	// nested reset would silently lose the caller's styling for the rest of the
	// line, which is the classic Lipgloss-shaped bug.
	s := new_style_profile(.True_Color)
	bold(&s, true)
	one(t, &s, "a\e[31mb\e[0mc", "\e[1ma\e[31mb\e[0m\e[1mc\e[0m")
	// The short spelling "\e[m" is a reset too, and is recognised for exactly
	// the same reason runetea's own screen_sgr recognises it.
	one(t, &s, "a\e[mb", "\e[1ma\e[m\e[1mb\e[0m")
}

@(test)
test_padding_after_an_inner_reset_is_still_styled :: proc(t: ^testing.T) {
	s := new_style_profile(.True_Color)
	bg(&s, color("#FF0000"))
	padding(&s, 0, 1)
	one(t, &s, "a\e[0mb", "\e[48;2;255;0;0m a\e[0m\e[48;2;255;0;0mb \e[0m")
}

@(test)
test_already_styled_input_is_measured_by_columns_not_bytes :: proc(t: ^testing.T) {
	// "\e[1;31mred\e[0m" is 15 bytes and 3 columns. A width-8 block must add 5
	// columns of padding, not -7.
	s := new_style_profile(.True_Color)
	width(&s, 8)
	one(t, &s, "\e[1;31mred\e[0m", "\e[1;31mred\e[0m     ")
}

// ---------------------------------------------------------------------------
// reset discipline, and composition with the .Diff renderer
// ---------------------------------------------------------------------------

// True iff `line` leaves the terminal at the default SGR: either it contains no
// escape at all, or the LAST escape in it is a reset.
@(private = "file")
ends_at_default_sgr :: proc(line: string) -> bool {
	last := -1
	for i in 0 ..< len(line) { if line[i] == 0x1b { last = i } }
	if last < 0 { return true }
	rest := line[last:]
	return strings.has_prefix(rest, "\e[0m") || strings.has_prefix(rest, "\e[m")
}

@(test)
test_every_emitted_line_terminates_its_style_run :: proc(t: ^testing.T) {
	// CONTENT WHOSE LAST ESCAPE IS NOT A RESET, deliberately. The earlier
	// version of this test used "a\e[33mb\e[0mc\n日本", which ends every line at
	// the default SGR all by itself -- so it could not distinguish a renderer
	// that closes its rows from one that never closes anything. The "\e[36m!"
	// tail is what makes the assertion bite.
	CONTENT :: "a\e[33mb\e[0mc\n日本\e[36m!"

	for p in Profile {
		for v in ([]proc(s: ^Style){
			proc(s: ^Style) { fg(s, color("#7D56F4")); padding(s, 1, 2) },
			proc(s: ^Style) { bg(s, color("#04B575")); border(s, ROUNDED); width(s, 12) },
			proc(s: ^Style) { bold(s, true); border(s, DOUBLE); border_fg(s, color(200)); margin(s, 1, 1) },
			proc(s: ^Style) { reverse(s, true); height(s, 4); valign(s, .Middle) },

			// LAYOUT ONLY -- no colour, no attribute, so build_sgr returns an
			// EMPTY sequence under EVERY profile and the row opens no style run
			// of its own. Three of the four variants above set an attribute, and
			// attributes survive .None, so before this line the "sgr is empty"
			// path was never reached by this test at all.
			proc(s: ^Style) { width(s, 12); border(s, NORMAL); padding(s, 1, 1) },
			proc(s: ^Style) { padding(s, 0, 2); align(s, .Center); width(s, 16) },

			// COLOUR ONLY -- non-empty sgr under the three colour profiles, and
			// empty under .None, which is the $NO_COLOR / TERM=dumb case. Same
			// unclosed row as the layout-only styles, reached by a Style that
			// looks styled.
			proc(s: ^Style) { fg(s, color("#FF0000")); bg(s, color(240)); padding(s, 1, 2) },
		}) {
			s := new_style_profile(p)
			v(&s)
			out := render(&s, CONTENT, context.allocator)
			defer delete(out, context.allocator)
			lines := strings.split_lines(out, context.allocator)
			defer delete(lines, context.allocator)
			for line, i in lines {
				if !ends_at_default_sgr(line) {
					testing.expectf(t, false, "[%v] row %d leaks its style: %q", p, i, line)
				}
			}
		}
	}
}

@(test)
test_a_layout_only_style_still_composes_with_the_diff_renderer :: proc(t: ^testing.T) {
	// THE REGRESSION THIS FILE EXISTS FOR, and the reason a "does the row end in
	// \e[0m" assertion is not enough on its own: this one goes through runetea's
	// actual cell model rather than restating RuneGloss's own rule.
	//
	// A layout-only Style (width + border, no colour, no attribute) builds an
	// EMPTY sgr. When the row's reset was gated on len(sgr) > 0, such a row
	// copied "\e[31mred" through and closed nothing -- and because screen_copy
	// carries Screen.style across frames while screen_sgr APPENDS, the interned
	// style accreted one "\e[31m" per frame. 200 IDENTICAL frames cost
	// 605, 635, 640, 645 ... 880 (f50) ... 1625 (f199) bytes, growing +5 per
	// frame without bound, heading for STYLE_BYTES_MAX and a forced table drop.
	//
	// 200 frames rather than 2, because the two-frame version of this test
	// passes on a renderer that grows by five bytes a frame forever.
	s := new_style_profile(.True_Color)
	width(&s, 12)
	border(&s, NORMAL)

	// Content whose LAST escape is not a reset. That is the whole input: an
	// application concatenating widget output has no idea whether it ends at the
	// default SGR, which is precisely why the row must close itself.
	view := render(&s, "\e[31mred", context.allocator)
	defer delete(view, context.allocator)

	b := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&b)
	r: rt.Renderer
	rt.renderer_init(&r, &b, 40, 12, .Diff)
	defer rt.renderer_destroy(&r)

	rt.renderer_render(&r, view)
	testing.expect(t, len(strings.to_string(b)) > 0, "first frame must paint something")

	for f in 1 ..< 200 {
		strings.builder_reset(&b)
		rt.renderer_render(&r, view)
		if n := len(strings.to_string(b)); n != 0 {
			testing.expectf(t, false, "identical frame %d cost %d bytes, want 0", f, n)
			return
		}
	}
}

@(test)
test_a_colour_only_style_under_profile_none_still_closes_its_rows :: proc(t: ^testing.T) {
	// The other way to reach an empty sgr, and the one that looks least like a
	// bug from the call site: the Style IS coloured, but $NO_COLOR or TERM=dumb
	// degraded it to nothing. Attributes survive .None (they are not colour), so
	// only a Style with colour and NO attribute lands here.
	s := new_style_profile(.None)
	fg(&s, color("#FF0000"))
	one(t, &s, "a\e[31mb", "a\e[31mb\e[0m")

	// ... and the zero-cost promise is not collateral damage: content with no
	// escapes at all still comes back byte for byte.
	one(t, &s, "ab", "ab")
}

@(test)
test_a_truncated_trailing_escape_does_not_swallow_the_padding :: proc(t: ^testing.T) {
	// 0x20 is inside the CSI parameter/intermediate range 0x20-0x3F, so the
	// padding spaces appended after an unterminated "\e[3" were consumed as
	// parameter bytes of that CSI -- painted by no terminal and counted by
	// rt.display_width, the same measure this package pads with. The block
	// measured 9, 9, 6, 9, 9.
	//
	// Byte-exact rather than width-only, because "the fragment is gone" and "the
	// row happens to measure right" are different claims and only the first one
	// keeps the header's "SGR escapes, printable text and \n, nothing else"
	// promise true.
	for text in ([]string{"abc\e[3", "abc\e[", "abc\e"}) {
		s := new_style_profile(.True_Color)
		border(&s, NORMAL); padding(&s, 1, 1); width(&s, 7)
		one(t, &s, text,
			"┌───────┐\n" +
			"│       │\n" +
			"│ abc   │\n" +
			"│       │\n" +
			"└───────┘")
	}

	// A COMPLETE escape at the end of a line is NOT dropped -- only truncated
	// ones are. "\e[3m" is a real (if pointless) italic; it stays, and the row
	// closes itself because its last escape is not a reset.
	c := new_style_profile(.True_Color)
	width(&c, 6)
	one(t, &c, "abc\e[3m", "abc\e[3m   \e[0m")
}

@(test)
test_a_noncanonical_reset_loses_the_outer_style_and_that_is_pinned :: proc(t: ^testing.T) {
	// PINS A KNOWN COST, not a desired behaviour. RuneGloss re-establishes the
	// outer style after "\e[0m" and "\e[m" only, because those are exactly the
	// two runetea's cell model treats as a reset (screen.odin's screen_sgr) and
	// the two layers disagreeing about a cell is worse than the cosmetic bug it
	// would fix -- see write_content.
	//
	// The cost, which the comment there now states outright: on a REAL terminal
	// "\e[00m" IS a full reset, so "b" and the trailing padding below paint
	// UNSTYLED even though the model believes they are bold+red -- and being a
	// LOSS rather than a leak, no later frame repaints them. Same for "\e[0;1m"
	// (a full reset that then sets bold) and for the partial resets "\e[22m" and
	// "\e[39m".
	s := new_style_profile(.True_Color)
	bold(&s, true); fg(&s, color("#FF0000")); padding(&s, 0, 2)

	// Note what is NOT here: a second "\e[1;38;2;255;0;0m" after the "\e[00m".
	one(t, &s, "a\e[00mb", "\e[1;38;2;255;0;0m  a\e[00mb  \e[0m")
	one(t, &s, "a\e[22mb", "\e[1;38;2;255;0;0m  a\e[22mb  \e[0m")

	// The canonical spellings, for contrast: these DO restore the outer style,
	// which is what makes the two cases above a deliberate boundary rather than
	// a renderer that never restores anything.
	one(t, &s, "a\e[0mb", "\e[1;38;2;255;0;0m  a\e[0m\e[1;38;2;255;0;0mb  \e[0m")
	one(t, &s, "a\e[mb",  "\e[1;38;2;255;0;0m  a\e[m\e[1;38;2;255;0;0mb  \e[0m")
}

@(test)
test_output_contains_no_c0_controls_and_no_motion_escapes :: proc(t: ^testing.T) {
	// runetea's .Diff renderer models SGR per cell and nothing else -- a view
	// containing cursor motion is "lying to the model" (render.odin's KNOWN
	// LIMITS). RuneGloss must therefore emit SGR and printable text only, with
	// "\n" as the sole control byte (which the renderer splits on before the
	// cell model ever sees it).
	s := new_style_profile(.True_Color)
	fg(&s, color("#7D56F4")); bg(&s, color(240)); bold(&s, true)
	padding(&s, 1, 2); margin(&s, 1, 1); border(&s, ROUNDED); border_fg(&s, color("#04B575"))
	width(&s, 20); height(&s, 6); align(&s, .Center); valign(&s, .Middle)
	out := render(&s, "日本語\n\e[7mx\e[0m", context.allocator)
	defer delete(out, context.allocator)

	i := 0
	for i < len(out) {
		c := out[i]
		if c == 0x1b {
			// Only CSI ... m is allowed.
			j := i + 1
			if j >= len(out) || out[j] != '[' {
				testing.expectf(t, false, "non-CSI escape at %d in %q", i, out); return
			}
			j += 1
			for j < len(out) && out[j] >= 0x30 && out[j] <= 0x3F { j += 1 }
			if j >= len(out) || out[j] != 'm' {
				testing.expectf(t, false, "non-SGR escape at %d in %q", i, out); return
			}
			i = j + 1
			continue
		}
		if c < 0x20 && c != '\n' {
			testing.expectf(t, false, "C0 control 0x%02X at %d in %q", c, i, out); return
		}
		i += 1
	}
}

@(test)
test_composes_with_the_diff_renderer_second_identical_frame_is_zero_bytes :: proc(t: ^testing.T) {
	// The end-to-end contract: RuneGloss's output feeds runetea's .Diff
	// renderer, which interns raw SGR per cell. If RuneGloss left the terminal
	// styled at the end of the view, the next frame's Screen would start from
	// that carried-over style and an IDENTICAL second frame would not come out
	// as zero bytes -- which is the property that mode exists for.
	//
	// WHAT THIS ACTUALLY CHECKS, stated narrowly: END-OF-FRAME RESET DISCIPLINE,
	// and nothing else. Verified non-vacuous by stripping every "\e[0m" from the
	// view, which turns frame 2 from 0 bytes into 7303.
	//
	// It does NOT check that a style has a stable BYTE SPELLING. Re-splitting the
	// single 34-byte SGR this style emits into "\e[1m\e[38;2;...m\e[48;2;...m"
	// still gives 0 bytes on frame 2 -- spelling only affects how many
	// Style_Table entries a session interns, never whether an unchanged cell
	// compares equal, so identical-frame cost cannot see it. The stable-order
	// argument lives in build_sgr's own comment, where it is a cost claim rather
	// than a correctness one; do not read it into this test.
	s := new_style_profile(.True_Color)
	fg(&s, color("#7D56F4")); bg(&s, color("#1A1A1A")); bold(&s, true)
	padding(&s, 1, 2); border(&s, ROUNDED); border_fg(&s, color("#04B575"))
	width(&s, 20); align(&s, .Center)

	view := render(&s, "日本語\nhello", context.allocator)
	defer delete(view, context.allocator)

	b := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&b)
	r: rt.Renderer
	rt.renderer_init(&r, &b, 40, 12, .Diff)
	defer rt.renderer_destroy(&r)

	rt.renderer_render(&r, view)
	first := strings.to_string(b)
	testing.expect(t, len(first) > 0, "first frame must paint something")

	strings.builder_reset(&b)
	rt.renderer_render(&r, view)
	testing.expect_value(t, strings.to_string(b), "")
}

@(test)
test_diff_renderer_agrees_with_the_full_screen_repaint_on_a_styled_block :: proc(t: ^testing.T) {
	// Weaker than runetea's own oracle, but it is the specific claim this
	// package makes: a RuneGloss block is a view the two renderers model
	// identically. A styled block that confused the cell model would show up as
	// a diff frame that never converges to zero bytes across a CHANGE.
	s := new_style_profile(.ANSI256)
	fg(&s, color(212)); border(&s, THICK); padding(&s, 1, 2)

	v1 := render(&s, "one", context.allocator);  defer delete(v1, context.allocator)
	v2 := render(&s, "two", context.allocator);  defer delete(v2, context.allocator)

	b := strings.builder_make(context.allocator); defer strings.builder_destroy(&b)
	r: rt.Renderer
	rt.renderer_init(&r, &b, 30, 10, .Diff)
	defer rt.renderer_destroy(&r)

	rt.renderer_render(&r, v1)
	strings.builder_reset(&b)
	rt.renderer_render(&r, v2)
	changed := strings.to_string(b)
	testing.expect(t, len(changed) > 0, "a changed frame must paint")

	strings.builder_reset(&b)
	rt.renderer_render(&r, v2)
	testing.expect_value(t, strings.to_string(b), "")
}

// ---------------------------------------------------------------------------
// misc
// ---------------------------------------------------------------------------

@(test)
test_width_is_a_floor_never_a_truncation :: proc(t: ^testing.T) {
	// Stated scope: RuneGloss does not wrap or truncate. Content wider than
	// `width` widens the block rather than being cut -- silently losing a
	// user's text is worse than a block that overflows visibly.
	s := new_style_profile(.True_Color)
	width(&s, 3)
	one(t, &s, "abcdef", "abcdef")
}

@(test)
test_render_allocates_only_from_the_supplied_allocator :: proc(t: ^testing.T) {
	// A frame-arena caller (every runetea `view` proc) depends on this: nothing
	// render touches may outlive the frame, and nothing may land on the heap
	// behind the caller's back. Exercised by the leak audit in tools/test.sh --
	// this test simply makes the intent explicit and gives the audit a
	// worst-case shape to chew on.
	s := new_style_profile(.True_Color)
	fg(&s, color("#7D56F4")); padding(&s, 2, 4); border(&s, DOUBLE)
	width(&s, 30); height(&s, 8); margin(&s, 1, 2)
	out := render(&s, "日本語\n\e[1mx\e[0m\n", context.allocator)
	defer delete(out, context.allocator)
	testing.expect(t, len(out) > 0)
}
