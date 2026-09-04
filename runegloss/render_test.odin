#+private
// ^ Every declaration in this file is package-private, so that `odin doc
//   runetea` / `odin doc runegloss` -- the command README.md and docs/API.md
//   hand a newcomer for symbol discovery -- lists the library rather than the
//   test fixtures. Pinned by tools/doccheck/run.sh's `apidoc` check, which is
//   also where the argument for it is written out.
package runegloss

import "core:mem"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
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
	// width(7) is now the width of the WHOLE BLOCK including its border, so this
	// is a 7-column box: 2 border + 2 padding + 3 content, and "abc" fills the
	// content area exactly. It used to be a 9-column box (border added on top of
	// a 7-column padded box), which is the lipgloss-v1-vs-v2 divergence F48 is
	// about; the fragment-swallowing claim being pinned here is unaffected by
	// which of the two it is.
	for text in ([]string{"abc\e[3", "abc\e[", "abc\e"}) {
		s := new_style_profile(.True_Color)
		border(&s, NORMAL); padding(&s, 1, 1); width(&s, 7)
		one(t, &s, text,
			"┌─────┐\n" +
			"│     │\n" +
			"│ abc │\n" +
			"│     │\n" +
			"└─────┘")
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

// ---------------------------------------------------------------------------
// the box model: width CLAMPS
// ---------------------------------------------------------------------------

@(test)
test_width_clamps_instead_of_flooring :: proc(t: ^testing.T) {
	// THE REVERSAL. This test used to be called
	// test_width_is_a_floor_never_a_truncation and asserted
	// render(width(3), "abcdef") == "abcdef" -- a 6-column block from a Style
	// that asked for 3. Nothing downstream could do anything with that: a
	// `width` that only ever grows cannot be used to fit a viewport, a column or
	// a panel, which is the only thing a width is for.
	//
	// It is not a truncation either, which is what the old name assumed the only
	// alternative was. .Wrap is the default and loses no byte.
	s := new_style_profile(.True_Color)
	width(&s, 3)
	one(t, &s, "abcdef", "abc\ndef")

	// And the old behaviour, still reachable, now spelled out loud.
	g := new_style_profile(.True_Color)
	width(&g, 3); overflow(&g, .Grow)
	one(t, &g, "abcdef", "abcdef")
}

@(test)
test_one_long_line_cannot_widen_a_bordered_block :: proc(t: ^testing.T) {
	// F06/F21, reduced to its smallest form. Under the floor semantics this
	// produced a 53-column box out of a Style that asked for 20 -- and the
	// damage did not stop at the box: the over-wide rows run past the terminal
	// margin, DECAWM wraps each of them onto a second physical row, and every
	// row of the frame BELOW this block is displaced. One long path in one panel
	// sheared layouts it had nothing to do with.
	s := new_style_profile(.True_Color)
	border(&s, NORMAL); padding(&s, 0, 1); width(&s, 20)

	long := "/home/user/dev/some/deeply/nested/project/file.odin"
	out := render(&s, long, context.allocator)
	defer delete(out, context.allocator)

	lines := strings.split_lines(out, context.allocator)
	defer delete(lines, context.allocator)
	testing.expect(t, len(lines) > 3, "expected the content to wrap onto several rows")
	for line, i in lines {
		if w := rt.display_width(line); w != 20 {
			testing.expectf(t, false, "row %d measures %d, want 20: %q", i, w, line)
		}
	}

	// NOTHING WAS DELETED: every character of the path is still in the block, in
	// order. That is the half of the claim that distinguishes wrapping from the
	// truncation the old comment feared, and it is why an exact `width` could be
	// made the default at all.
	joined := strings.concatenate(lines, context.allocator)
	defer delete(joined, context.allocator)
	kept, _ := strings.remove_all(joined, " ", context.allocator)
	defer delete(kept, context.allocator)
	bare, _ := strings.remove_all(kept, "│", context.allocator)
	defer delete(bare, context.allocator)
	testing.expect(t, strings.contains(bare, long), "wrapping lost or reordered content")
}

@(test)
test_width_includes_the_border_and_frame_size_reports_the_cost :: proc(t: ^testing.T) {
	// F48. `width` is the OUTER width (border + padding + content), matching
	// lipgloss v2, which is the version RuneTea names as its target. Before this
	// the border was added on top and a ported layout came out 2 columns wider
	// per box, with no getter anywhere to notice it with.
	s := new_style_profile(.True_Color)
	border(&s, ROUNDED); padding(&s, 1, 2); margin(&s, 0, 3); width(&s, 20); height(&s, 7)

	hw, vh := frame_size(s)
	testing.expect_value(t, hw, 12)   // margin 3+3, padding 2+2, border 1+1
	testing.expect_value(t, vh, 4)    // margin 0+0, padding 1+1, border 1+1
	bw, bh := border_size(s)
	testing.expect_value(t, bw, 2)
	testing.expect_value(t, bh, 2)
	testing.expect_value(t, horizontal_frame_size(s), 12)
	testing.expect_value(t, vertical_frame_size(s), 4)

	out := render(s, "hello world this is long enough to wrap", context.allocator)
	defer delete(out, context.allocator)
	w, h := measure(out)
	testing.expect_value(t, w, 20 + 3 + 3)
	testing.expect_value(t, h, 7)

	// A CUSTOM 2-COLUMN BORDER, which is the case an application cannot compute
	// for itself and the reason border_size is exported rather than assumed to
	// be 2 whenever `bordered` is set.
	c := new_style_profile(.True_Color)
	b := NORMAL
	b.left, b.right = border_cell("<<"), border_cell(">>")
	border(&c, b); width(&c, 12)
	cbw, _ := border_size(c)
	testing.expect_value(t, cbw, 4)
	cout := render(c, "abcdefgh", context.allocator)
	defer delete(cout, context.allocator)
	testing.expect_value(t, measure_width(cout), 12)
}

@(test)
test_a_width_smaller_than_its_own_frame_yields_a_frame_wide_block :: proc(t: ^testing.T) {
	// The degenerate case, pinned so it is a documented answer rather than a
	// discovered one: 2 border columns plus 4 padding columns cannot fit in 4,
	// so the content area goes to zero and the frame wins. Nothing asks the
	// builder for a negative run of spaces on the way, and nothing tries to wrap
	// to zero columns (which cannot terminate).
	s := new_style_profile(.True_Color)
	border(&s, NORMAL); padding(&s, 0, 2); width(&s, 4)
	one(t, &s, "abcdef", "┌────┐\n│    │\n└────┘")
}

@(test)
test_height_clamps_and_align_v_chooses_which_rows_survive :: proc(t: ^testing.T) {
	// There is no reflow for rows, so an over-tall block loses some. WHICH ones
	// follows from align_v: the alignment already says which end the content is
	// anchored to, so the rows nearest that anchor are the ones kept.
	body := "1\n2\n3\n4\n5"

	top := new_style_profile(.True_Color); height(&top, 2); valign(&top, .Top)
	one(t, &top, body, "1\n2")
	bot := new_style_profile(.True_Color); height(&bot, 2); valign(&bot, .Bottom)
	one(t, &bot, body, "4\n5")
	mid := new_style_profile(.True_Color); height(&mid, 3); valign(&mid, .Middle)
	one(t, &mid, body, "2\n3\n4")

	// .Grow keeps the old floor semantics on the vertical axis too.
	g := new_style_profile(.True_Color); height(&g, 2); overflow(&g, .Grow)
	one(t, &g, body, body)

	// A dropped line must not widen the block it is no longer in.
	w := new_style_profile(.True_Color); height(&w, 1); valign(&w, .Top)
	one(t, &w, "ab\nlonger", "ab")
}

// ---------------------------------------------------------------------------
// wrap / truncate
// ---------------------------------------------------------------------------

@(test)
test_wrap_breaks_at_words_and_drops_the_break_spaces :: proc(t: ^testing.T) {
	got := wrap("the quick brown fox", 10, {}, context.allocator)
	defer delete(got, context.allocator)
	testing.expect_value(t, got, "the quick\nbrown fox")

	// The spaces AT a break are dropped -- left in, they would sit at the head of
	// the next row and shift it right by however many there were.
	many := wrap("aaa     bbb", 5, {}, context.allocator)
	defer delete(many, context.allocator)
	testing.expect_value(t, many, "aaa\nbbb")

	// Multi-line input stays multi-line, and a line that fits is untouched.
	ml := wrap("fits\nthis one does not fit", 8, {}, context.allocator)
	defer delete(ml, context.allocator)
	testing.expect_value(t, ml, "fits\nthis one\ndoes not\nfit")
}

@(test)
test_wrap_hard_breaks_a_word_with_nowhere_to_break :: proc(t: ^testing.T) {
	// A 200-character URL in a 40-column panel is the case that has to work, and
	// there is no space anywhere in it to break at.
	got := wrap("abcdefghij", 4, {}, context.allocator)
	defer delete(got, context.allocator)
	testing.expect_value(t, got, "abcd\nefgh\nij")

	// The break lands on a CLUSTER boundary, not a byte or a rune one: "日本語"
	// is 3 clusters of 2 columns each, so a 3-column limit fits exactly one per
	// row and never splits one in half.
	cjk := wrap("日本語", 3, {}, context.allocator)
	defer delete(cjk, context.allocator)
	testing.expect_value(t, cjk, "日\n本\n語")

	// A cluster wider than the whole box overflows by a column rather than being
	// split (unpaintable bytes) or dropped (a deleted character).
	narrow := wrap("日本", 1, {}, context.allocator)
	defer delete(narrow, context.allocator)
	testing.expect_value(t, narrow, "日\n本")
}

@(test)
test_wrap_reestablishes_the_active_style_on_every_row :: proc(t: ^testing.T) {
	// The failure a naive implementation ships and nobody notices until a
	// coloured paragraph loses its colour halfway down: "\e[31mhello world\e[0m"
	// wrapped at 5 must not become "\e[31mhello" / "world\e[0m", where the second
	// row paints in the terminal default.
	got := wrap("\e[31mhello world\e[0m", 5, {}, context.allocator)
	defer delete(got, context.allocator)
	testing.expect_value(t, got, "\e[31mhello\e[0m\n\e[31mworld\e[0m")

	// Every produced row independently ends at the terminal default, which is
	// the invariant runetea's .Diff renderer needs from every row this package
	// emits (see this file's header on unbounded style growth).
	lines := strings.split_lines(got, context.allocator)
	defer delete(lines, context.allocator)
	for line, i in lines {
		testing.expectf(t, strings.has_suffix(line, "\e[0m"), "row %d does not close: %q", i, line)
	}

	// A canonical reset inside the line CLEARS the carry, so rows after it are
	// not re-opened in a style the content already closed.
	after := wrap("\e[31maa\e[0m bb cc", 2, {}, context.allocator)
	defer delete(after, context.allocator)
	testing.expect_value(t, after, "\e[31maa\e[0m\nbb\ncc")
}

@(test)
test_truncate_budgets_its_tail_inside_the_width :: proc(t: ^testing.T) {
	// A truncate whose output could exceed the width it was given would be
	// useless to the box model that calls it.
	for n in 1 ..= 12 {
		got := truncate("abcdefghijkl", n, "…", {}, context.allocator)
		defer delete(got, context.allocator)
		testing.expectf(t, rt.display_width(got) <= n, "truncate to %d gave %q (%d cols)", n, got, rt.display_width(got))
	}
	four := truncate("abcdefghijkl", 4, "…", {}, context.allocator)
	defer delete(four, context.allocator)
	testing.expect_value(t, four, "abc…")

	// A line that already fits is copied byte for byte -- no tail, no reset.
	fits := truncate("abc", 8, "…", {}, context.allocator)
	defer delete(fits, context.allocator)
	testing.expect_value(t, fits, "abc")

	// A tail wider than the whole budget is dropped rather than the content: a
	// row consisting only of ellipsis carries no information at all.
	tiny := truncate("abcdef", 2, "...", {}, context.allocator)
	defer delete(tiny, context.allocator)
	testing.expect_value(t, tiny, "ab")

	// Multi-line stays multi-line, and a line that fits is left alone.
	ml := truncate("abcdef\nxy", 3, "", {}, context.allocator)
	defer delete(ml, context.allocator)
	testing.expect_value(t, ml, "abc\nxy")
}

@(test)
test_truncate_closes_a_style_run_it_cut_through :: proc(t: ^testing.T) {
	// A cut that lands mid-run leaves the run open, which costs runetea's .Diff
	// renderer unbounded per-frame growth (this file's header) and floods the
	// next row's background on a real terminal. The reset goes AFTER the tail so
	// the ellipsis is painted in the style of the text it replaced.
	got := truncate("\e[31mabcdef", 4, "…", {}, context.allocator)
	defer delete(got, context.allocator)
	testing.expect_value(t, got, "\e[31mabc…\e[0m")

	// Escapes AFTER the cut are dropped: they style nothing that is still there.
	// Escapes before it are kept, because they style what survived.
	mixed := truncate("ab\e[32mcd\e[0mef", 3, "", {}, context.allocator)
	defer delete(mixed, context.allocator)
	testing.expect_value(t, mixed, "ab\e[32mc\e[0m")
}

@(test)
test_truncation_never_splits_a_grapheme_cluster :: proc(t: ^testing.T) {
	// F25's mechanical half. Cutting between a base rune and its combining mark,
	// or inside a ZWJ sequence, puts bytes on the wire that no terminal can paint
	// back into what the caller wrote -- and then the row is padded to a width
	// derived from the un-split string, so it is ragged as well as corrupt.
	for input in ([]string{"éx", "❤️x", "\U0001F1EF\U0001F1F5x", "👨‍💻x", "日本x"}) {
		for n in 0 ..= 8 {
			got := truncate(input, n, "", {}, context.allocator)
			defer delete(got, context.allocator)
			testing.expectf(t, rt.display_width(got) <= n, "%q -> %d cols for a %d-col budget", input, rt.display_width(got), n)
			testing.expectf(t, utf8.valid_string(got), "%q truncated to %d is not valid UTF-8: %q", input, n, got)
			testing.expectf(t, strings.has_prefix(input, got), "%q truncated to %d is not a prefix: %q", input, n, got)
		}
	}
}

@(test)
test_per_cluster_widths_sum_to_the_whole_strings_display_width :: proc(t: ^testing.T) {
	// THE EQUIVALENCE prefix_fitting is built on, pinned from the outside. It
	// walks cluster boundaries locally (core:unicode) and asks rt.display_width
	// for every width, one cluster at a time; that is only sound if measuring the
	// clusters separately gives the same answer as measuring the whole string.
	//
	// It is also the assertion that catches the mistake this area is full of:
	// summing PER-RUNE widths instead of per-cluster ones scores "👨‍💻" as 4 (or 6,
	// depending on the table) against the 2 columns it advances, so a truncation
	// built on it cuts in the wrong place AND pads to the wrong width.
	for input in ([]string{"hello", "日本語", "é", "❤️", "\U0001F1EF\U0001F1F5", "👨‍💻", "a日❤️b", "👨‍👩‍👧‍👦"}) {
		sum, rest := 0, input
		for len(rest) > 0 {
			n := clip_prefix_len(rest)
			sum += rt.display_width(rest[:n])
			rest = rest[n:]
		}
		testing.expectf(t, sum == rt.display_width(input),
			"%q: per-cluster sum %d != display_width %d", input, sum, rt.display_width(input))
	}
}

// Byte length of the first grapheme cluster of `s`. Written out here rather than
// made non-file-private in render.odin: a test that called the implementation's
// own helper would pass even if that helper walked runes instead of clusters,
// which is exactly the defect the test above exists to catch.
@(private = "file")
clip_prefix_len :: proc(s: string) -> int {
	it := utf8.decode_grapheme_iterator_make(s)
	seen := 0
	for {
		_, g, more := utf8.decode_grapheme_iterate(&it)
		if !more { break }
		seen += 1
		if seen == 2 { return g.byte_index }
	}
	return len(s)
}

@(test)
test_measure_reports_the_number_render_pads_to :: proc(t: ^testing.T) {
	// F25's other half. RuneGloss pads every row to runetea's opinion of how many
	// columns a cluster occupies, and terminals disagree with that opinion on
	// emoji (VTE paints "👨‍💻" as 4 and "❤️" as 1, where the UCD rules say 2 and 2).
	// That disagreement cannot be settled from in here -- only the terminal knows
	// -- but it USED TO BE UNDETECTABLE from outside, because there was no way to
	// ask RuneGloss what number it was about to pad to. There is now, and it is
	// the same measure render uses, which is the part worth pinning.
	for input in ([]string{"hello", "日本語", "❤️", "👨‍💻", "\U0001F1EF\U0001F1F5", "a\nbb\nccc"}) {
		s := new_style_profile(.True_Color)
		out := render(s, input, context.allocator)
		defer delete(out, context.allocator)
		w, h := measure(input)
		ow, oh := measure(out)
		testing.expectf(t, w == ow && h == oh, "%q: measure said %dx%d, render produced %dx%d", input, w, h, ow, oh)
	}

	// And the POLICY is reachable, which it was not: `wopts` is the whole
	// rt.Width_Options value rather than one hand-copied bool, so every present
	// and future width knob is exposed by construction. Box-drawing characters
	// are East_Asian_Width=Ambiguous, which is the knob that exists today.
	a := new_style_profile(.True_Color)
	b := new_style_profile(.True_Color); ambiguous_wide(&b, true)
	testing.expect_value(t, measure_width("┌─┐", a.wopts), 3)
	testing.expect_value(t, measure_width("┌─┐", b.wopts), 6)
}

// The OTHER width policy, and the one F25 was actually about. A live VTE 2.91
// advances 4 columns for "👨‍💻" and 1 for "❤️" where the UCD emoji-presentation
// rules -- and therefore this package's default padding -- say 2 and 2. That
// cannot be settled from in here (kitty and WezTerm advance 2 and 2, so
// switching the numbers would only move the raggedness), but it can be SAID,
// and this pins that saying it reaches the renderer and not merely the measure.
@(test)
test_emoji_width_policy_squares_a_box_on_a_per_character_terminal :: proc(t: ^testing.T) {
	dev    :: "\U0001F468\u200D\U0001F4BB"
	legacy := rt.Width_Options{emoji_width = .Legacy_Wcwidth}

	cluster_style := new_style_profile(.True_Color)
	legacy_style  := new_style_profile(.True_Color); emoji_width(&legacy_style, .Legacy_Wcwidth)
	border(&cluster_style, NORMAL)
	border(&legacy_style,  NORMAL)

	// The knob reaches the measure...
	testing.expect_value(t, measure_width(dev, cluster_style.wopts), 2)
	testing.expect_value(t, measure_width(dev, legacy_style.wopts),  4)

	// ...and it reaches the BOX, which is the half an application could not
	// reach before: the border rows are sized from the same measure the content
	// row is padded to, so selecting the policy squares the frame under it.
	for st, i in ([]Style{cluster_style, legacy_style}) {
		st := st
		opts := st.wopts
		out  := render(&st, dev, context.allocator)
		defer delete(out, context.allocator)
		lines := strings.split_lines(out, context.allocator)
		defer delete(lines, context.allocator)
		testing.expect_value(t, len(lines), 3)
		want := rt.display_width(lines[0], opts)
		testing.expect_value(t, want, i == 0 ? 4 : 6)   // 2 or 4 columns of emoji + 2 of border
		for line, row in lines {
			testing.expectf(t, rt.display_width(line, opts) == want,
				"policy %v row %d measures %d, want %d: %q",
				opts.emoji_width, row, rt.display_width(line, opts), want, line)
		}
	}

	// AND THE DEFECT ITSELF, pinned rather than described: the block rendered
	// under the default policy is NOT rectangular when measured the way a
	// VTE-based terminal (GNOME Terminal, Tilix, Terminator, xfce4) measures
	// it. 4-6-4 is the right border hanging two columns outside the frame.
	ragged := render(&cluster_style, dev, context.allocator)
	defer delete(ragged, context.allocator)
	rows := strings.split_lines(ragged, context.allocator)
	defer delete(rows, context.allocator)
	testing.expect_value(t, rt.display_width(rows[0], legacy), 4)
	testing.expect_value(t, rt.display_width(rows[1], legacy), 6)
	testing.expect_value(t, rt.display_width(rows[2], legacy), 4)
}

// ---------------------------------------------------------------------------
// joins
// ---------------------------------------------------------------------------

@(test)
test_join_horizontal_keeps_every_column_aligned :: proc(t: ^testing.T) {
	left  := "aaa\nbbb\nccc"
	right := "XX\nYY"

	top := join_horizontal(.Top, {left, right}, {}, context.allocator)
	defer delete(top, context.allocator)
	testing.expect_value(t, top, "aaaXX\nbbbYY\nccc  ")

	bot := join_horizontal(.Bottom, {left, right}, {}, context.allocator)
	defer delete(bot, context.allocator)
	testing.expect_value(t, bot, "aaa  \nbbbXX\ncccYY")

	mid := join_horizontal(.Middle, {left, right}, {}, context.allocator)
	defer delete(mid, context.allocator)
	testing.expect_value(t, mid, "aaaXX\nbbbYY\nccc  ")

	// Ragged blocks: each block is padded to ITS OWN width, so column offsets
	// stay fixed down the whole join. This is only well-defined now that `width`
	// clamps -- under the old floor semantics one long line widened one block's
	// rows and not the others, and everything below the join sheared.
	ragged := join_horizontal(.Top, {"a\nlonger", "1\n2"}, {}, context.allocator)
	defer delete(ragged, context.allocator)
	testing.expect_value(t, ragged, "a     1\nlonger2")
}

@(test)
test_join_closes_a_styled_row_before_padding_it :: proc(t: ^testing.T) {
	// Without this, the padding of a red row paints red and the join grows a
	// coloured notch exactly where the blocks meet.
	got := join_horizontal(.Top, {"\e[41mred", "x"}, {}, context.allocator)
	defer delete(got, context.allocator)
	testing.expect_value(t, got, "\e[41mred\e[0mx")

	// A row that already closed itself -- which every row this package emits does
	// -- gets no second reset.
	clean := join_horizontal(.Top, {"\e[41mred\e[0m", "x"}, {}, context.allocator)
	defer delete(clean, context.allocator)
	testing.expect_value(t, clean, "\e[41mred\e[0mx")
}

@(test)
test_join_vertical_aligns_narrow_blocks_against_the_widest :: proc(t: ^testing.T) {
	l := join_vertical(.Left, {"aaaa", "b"}, {}, context.allocator)
	defer delete(l, context.allocator)
	testing.expect_value(t, l, "aaaa\nb   ")

	r := join_vertical(.Right, {"aaaa", "b"}, {}, context.allocator)
	defer delete(r, context.allocator)
	testing.expect_value(t, r, "aaaa\n   b")

	// Odd remainder goes RIGHT, the same fixed choice render's own centring
	// makes, so a centred block and a centred join cannot disagree by a column.
	c := join_vertical(.Center, {"aaaa", "b"}, {}, context.allocator)
	defer delete(c, context.allocator)
	testing.expect_value(t, c, "aaaa\n b  ")

	testing.expect_value(t, join_vertical(.Left, {}, {}, context.allocator), "")
	testing.expect_value(t, join_horizontal(.Top, {}, {}, context.allocator), "")
}

// ---------------------------------------------------------------------------
// the ^Style / by-value friction
// ---------------------------------------------------------------------------

@(private = "file")
Themed :: struct { title: Style }

// SHAPED EXACTLY LIKE A RUNETEA VIEW -- model by value, allocator second -- so
// that if the proc group ever stops resolving, this file stops compiling rather
// than this test starting to fail in some subtler way.
@(private = "file")
themed_view :: proc(m: Themed, alloc: mem.Allocator) -> string {
	return render(m.title, "X", alloc)   // by value: `&m.title` cannot compile
}

@(test)
test_render_takes_a_style_by_pointer_or_by_value :: proc(t: ^testing.T) {
	// F49/F52. runetea's view contract passes the model BY VALUE, and an Odin
	// procedure parameter is not addressable, so `rg.render(&m.title, ...)` --
	// the pattern docs/API.md §12 recommends -- was a compile error pointing at
	// Odin addressability rather than at anything the caller did wrong. The proc
	// group makes both spellings legal without forcing the 184-byte copy on the
	// call sites that already hold a local and pay nothing today.
	m := Themed{title = new_style_profile(.True_Color)}
	bold(&m.title, true)

	by_value := themed_view(m, context.allocator)
	defer delete(by_value, context.allocator)

	local := m.title
	by_ptr := render(&local, "X", context.allocator)
	defer delete(by_ptr, context.allocator)

	testing.expect_value(t, by_value, "\e[1mX\e[0m")
	testing.expect_value(t, by_value, by_ptr)
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

@(test)
test_a_tab_is_measured_from_the_column_it_actually_lands_in :: proc(t: ^testing.T) {
	// prefix_fitting threads opts.start_col through runetea's cluster iterator,
	// and this is what that buys. A TAB's width is next_tab_stop(col) - col, so
	// the same "\t" is 8 columns at column 0 and 1 column at column 7. Measuring
	// each escape-free run from column 0 -- which is what a per-cluster
	// display_width call over an isolated span does -- scores every tab after the
	// first one wrong, and the cut lands somewhere the terminal does not agree is
	// that many columns in.
	//
	// The assertion is the additivity law runetea's Width_Options states: a
	// truncation of `s` to n columns must itself measure at most n columns WHEN
	// MEASURED THE SAME WAY.
	for input in ([]string{"a\tb\tc", "\t\t", "ab\tcd", "日\t本"}) {
		for n in 0 ..= 20 {
			got := truncate(input, n, "", {}, context.allocator)
			defer delete(got, context.allocator)
			testing.expectf(t, rt.display_width(got) <= n,
				"truncate(%q, %d) = %q measures %d", input, n, got, rt.display_width(got))
			testing.expectf(t, strings.has_prefix(input, got), "%q is not a prefix of %q", got, input)
		}
	}

	// And the whole string survives once the budget reaches its real width, which
	// is the direction a from-column-zero measure gets wrong (it over-counts the
	// later tabs and cuts a string that fits).
	full := rt.display_width("a\tb\tc")
	got := truncate("a\tb\tc", full, "", {}, context.allocator)
	defer delete(got, context.allocator)
	testing.expect_value(t, got, "a\tb\tc")
}
