#+private
// ^ Every declaration in this file is package-private, so that `odin doc
//   runetea` / `odin doc runegloss` -- the command README.md and docs/API.md
//   hand a newcomer for symbol discovery -- lists the library rather than the
//   test fixtures. Pinned by tools/doccheck/run.sh's `apidoc` check, which is
//   also where the argument for it is written out.
package runegloss

import "core:strings"
import "core:testing"
import rt "../runetea"

// THE WIDTH-CORRECTNESS TABLE. The single most valuable test in this package:
// a styling layer that produces RAGGED blocks is broken, and raggedness is
// exactly what every plausible implementation mistake produces -- padding by
// byte count (CJK collapses), by rune count (emoji/flags/combining marks
// collapse), or by counting escape bytes as content (already-styled input
// blows out).
//
// The assertion is deliberately made with rt.display_width -- the SAME measure
// the implementation pads with. That is not circular for the defects it exists
// to catch: it pins "every line of the block measures the same, and measures
// what the style asked for", which is false the instant padding is computed
// with any other measure.
//
// PROVEN NON-VACUOUS, not assumed: swapping render's two rt.display_width calls
// for utf8.rune_count_in_string produced 426 failures here -- the ascii cases
// still passed, and cjk / combining / vs16-emoji / flag-pair / already-ansi all
// came out ragged, under every profile and every variant. Left in the report
// rather than in the tree; re-run it by hand if this file is ever rewritten.

// The inputs, and what rt.display_width says each one measures. The widths are
// spelled out rather than computed so that a regression in the WIDTH layer
// shows up here as a failure too, instead of both sides moving together.
@(private = "file")
Input :: struct { text: string, w: int, label: string }

@(private = "file")
INPUTS := []Input{
	{"hello",                    5, "ascii"},
	{"",                         0, "empty"},
	{"日本語",                    6, "cjk"},
	{"é",                  1, "combining"},
	{"❤️",             2, "vs16-emoji"},
	{"\U0001F1EF\U0001F1F5",     2, "flag-pair"},
	{"\e[1;31mred\e[0m",         3, "already-ansi"},
	{"a日❤️b",          6, "mixed"},
	{"ab\n日本語\nc",             6, "multiline-ragged"},
	{"\e[7mx\e[0m\n日本",         4, "multiline-ansi-cjk"},

	// TRUNCATED ESCAPES. A line that ends INSIDE an escape swallows whatever is
	// appended to it, and this package appends to every line -- alignment fill,
	// right padding, the right border cell. These four inputs used to produce
	// rows measuring 6 or 7 in a block whose other rows measured 9, because
	// 0x20 is inside the CSI parameter/intermediate range 0x20-0x3F and the
	// padding spaces were consumed as parameters of the unterminated CSI.
	//
	// The widths below are what rt.display_width says, and it says a truncated
	// trailing escape is ZERO width (width.odin: "UNTERMINATED ESCAPE AT END OF
	// STRING -> ZERO WIDTH TO THE END"). That is also why dropping the fragment
	// is width-neutral: 3 before, 3 after.
	{"abc\e[3",                  3, "truncated-csi-param"},
	{"abc\e[",                   3, "truncated-csi-bare"},
	{"abc\e",                    3, "truncated-esc"},
	// Not an SGR, and not on the last line either: the fragment ends a line in
	// the MIDDLE of the block, where it eats that row's fill and nothing else --
	// a raggedness that only shows up when the block has more than one row.
	{"a\e]8;;http://x\nbb",      2, "truncated-osc-midblock"},
}

@(test)
test_input_table_widths_are_what_the_width_layer_says :: proc(t: ^testing.T) {
	// Guards the table itself: if any literal above is mis-typed (an emoji
	// pasted without its VS16, say) every later assertion silently tests the
	// wrong string.
	for in_ in INPUTS {
		got := max_line_width(in_.text)
		if got != in_.w {
			testing.expectf(t, false, "%s: display_width = %d, table says %d", in_.label, got, in_.w)
		}
	}
}

// The style variants the inputs are crossed with. Each is a proc rather than a
// Style value because a Style must be built through the setters -- that is the
// API under test.
@(private = "file")
Variant :: struct { name: string, build: proc(s: ^Style) }

@(private = "file")
VARIANTS := []Variant{
	{"plain",        proc(s: ^Style) {}},
	{"pad-1-2",      proc(s: ^Style) { padding(s, 1, 2) }},
	{"pad-trbl",     proc(s: ^Style) { padding(s, 0, 3, 2, 1) }},
	{"w20-left",     proc(s: ^Style) { width(s, 20); align(s, .Left) }},
	{"w20-center",   proc(s: ^Style) { width(s, 20); align(s, .Center) }},
	{"w20-right",    proc(s: ^Style) { width(s, 20); align(s, .Right) }},
	{"w20-pad",      proc(s: ^Style) { width(s, 20); padding(s, 1, 2); align(s, .Center) }},
	{"b-normal",     proc(s: ^Style) { border(s, NORMAL) }},
	{"b-rounded",    proc(s: ^Style) { border(s, ROUNDED) }},
	{"b-thick",      proc(s: ^Style) { border(s, THICK) }},
	{"b-double",     proc(s: ^Style) { border(s, DOUBLE) }},
	{"b-hidden",     proc(s: ^Style) { border(s, HIDDEN) }},
	{"b-sides-tb",   proc(s: ^Style) { border(s, NORMAL); border_sides(s, {.Top, .Bottom}) }},
	{"b-sides-lr",   proc(s: ^Style) { border(s, NORMAL); border_sides(s, {.Left, .Right}) }},
	{"margin",       proc(s: ^Style) { margin(s, 1, 3) }},
	{"h5-top",       proc(s: ^Style) { height(s, 5); valign(s, .Top) }},
	{"h5-middle",    proc(s: ^Style) { height(s, 5); valign(s, .Middle) }},
	{"h5-bottom",    proc(s: ^Style) { height(s, 5); valign(s, .Bottom) }},
	{"everything",   proc(s: ^Style) {
		fg(s, color("#7D56F4")); bg(s, color("#1A1A1A"))
		bold(s, true); underline(s, true)
		padding(s, 1, 2); margin(s, 1, 3)
		width(s, 24); height(s, 6)
		align(s, .Center); valign(s, .Middle)
		border(s, ROUNDED); border_fg(s, color("#04B575"))
	}},

	// THE CLAMPING VARIANTS. Everything above this line describes a block big
	// enough for its content; these five are the ones where the content does NOT
	// fit, which is the case the box model used to answer by widening the block
	// and shearing the frame. Every input in the table is pushed through wrap,
	// truncate, the vertical clamp and the degenerate zero-content-column case
	// under every profile -- which is what makes "the block is exactly `width`
	// columns wide, whatever you feed it" an assertion rather than a hope.
	//
	// width 4 is deliberately narrower than the CJK, mixed and already-ansi
	// inputs, so wrap and truncate both do real work rather than passing the
	// line through.
	{"w4-wrap",      proc(s: ^Style) { width(s, 4) }},
	{"w4-truncate",  proc(s: ^Style) { width(s, 4); overflow(s, .Truncate); ellipsis(s, "…") }},
	{"w4-border",    proc(s: ^Style) { width(s, 4); border(s, ROUNDED) }},
	{"w4-grow",      proc(s: ^Style) { width(s, 4); overflow(s, .Grow) }},
	// Frame wider than `width`: 2 border columns plus 4 padding columns against a
	// width of 4 leaves NEGATIVE room for content. The block must still come out
	// exactly 4 columns and never ask the builder for a negative run of spaces.
	{"w4-overfull",  proc(s: ^Style) { width(s, 4); padding(s, 0, 2); border(s, NORMAL) }},
	// Vertical clamp: 2 border rows out of 3 leaves ONE content row, so every
	// multi-line input loses rows.
	{"w6-h3",        proc(s: ^Style) { width(s, 6); height(s, 3); border(s, NORMAL) }},
}

@(test)
test_width_table_every_produced_line_is_the_block_width :: proc(t: ^testing.T) {
	// Every profile, because a profile change changes the BYTES emitted around
	// every cell of padding -- and a padding routine that measured its own
	// escapes as content would come out ragged under truecolor and clean under
	// .None, which is precisely the bug that is easy to ship.
	for p in Profile {
		for v in VARIANTS {
			for in_ in INPUTS {
				s := new_style_profile(p)
				v.build(&s)
				out := render(&s, in_.text, context.allocator)
				defer delete(out, context.allocator)

				want_w := expected_block_width(&s, in_.text)
				want_h := expected_block_height(&s, in_.text)
				check_block(t, out, want_w, want_h, v.name, in_.label, p)
			}
		}
	}
}

// The whole point of the table, made separately assertable: the same style over
// CJK and over ASCII of the same DISPLAY width must produce byte-different but
// column-identical blocks.
@(test)
test_cjk_and_ascii_of_equal_display_width_produce_equal_column_blocks :: proc(t: ^testing.T) {
	s := new_style_profile(.True_Color)
	padding(&s, 1, 2)
	border(&s, ROUNDED)
	width(&s, 20)
	align(&s, .Center)

	a := render(&s, "日本語", context.allocator)   // 6 columns, 9 bytes
	defer delete(a, context.allocator)
	b := render(&s, "abcdef", context.allocator)  // 6 columns, 6 bytes
	defer delete(b, context.allocator)

	testing.expect(t, len(a) != len(b), "expected different byte lengths")
	la := strings.split_lines(a, context.allocator); defer delete(la, context.allocator)
	lb := strings.split_lines(b, context.allocator); defer delete(lb, context.allocator)
	testing.expect_value(t, len(la), len(lb))
	for i in 0 ..< min(len(la), len(lb)) {
		testing.expect_value(t, rt.display_width(la[i]), rt.display_width(lb[i]))
	}
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

@(private = "file")
max_line_width :: proc(text: string) -> int {
	w := 0
	rest := text
	for {
		i := strings.index_byte(rest, '\n')
		line := rest if i < 0 else rest[:i]
		w = max(w, rt.display_width(line))
		if i < 0 { break }
		rest = rest[i + 1:]
	}
	return w
}

@(private = "file")
line_count :: proc(text: string) -> int {
	n := 1
	for c in transmute([]u8)text { if c == '\n' { n += 1 } }
	return n
}

// The block width RE-DERIVED FROM THE STYLE FIELDS, independently of render's
// own arithmetic. Both agree on the formula (they must -- it is the definition
// of the box model), but this one never touches a single character of content,
// so a render that mismeasures content comes out unequal here.
//
// THE CONSTRAINED BRANCH IS THE WHOLE POINT AND IT IS A ONE-LINER: a block with
// a `width` is exactly `width` columns wide plus its margins, WHATEVER THE
// CONTENT IS. That single line is the property the old box model did not have --
// it computed max(content, width - padding), so one long string moved the answer
// and there was no width you could rely on downstream. Deriving it from the
// content here would be re-implementing render rather than checking it.
//
// The old formula also excluded the border from `width` and this one includes
// it; that is the lipgloss-v2 alignment (F48), and it is why "everything" is now
// a 30-column block where it used to be 32.
//
// UNCONSTRAINED (`width == 0`) AND .Grow still derive from the content, because
// there the content genuinely is what decides.
@(private = "file")
expected_block_width :: proc(s: ^Style, text: string) -> int {
	lw, rw := 0, 0
	if s.bordered {
		// Every border this package ships is one column per side (box-drawing
		// characters are East_Asian_Width=Ambiguous, which the width layer folds
		// to 1 by default).
		if .Left  in s.border_sides { lw = 1 }
		if .Right in s.border_sides { rw = 1 }
	}
	frame := lw + rw + s.pad[.Left] + s.pad[.Right]
	if s.width > 0 && s.overflow != .Grow {
		// max() with the frame, not plain `width`: a width too small to hold its
		// own border and padding cannot be honoured, and the documented answer is
		// that the frame wins and the content area goes to zero (Style.width).
		// The "w4-overfull" variant exists to keep that case asserted rather than
		// discovered by an app that set width(4) on a padding(0,2)+border Style.
		return s.mar[.Left] + max(s.width, frame) + s.mar[.Right]
	}
	inner := max_line_width(text)
	if s.width > 0 { inner = max(inner, s.width - frame) }
	return s.mar[.Left] + frame + inner + s.mar[.Right]
}

// Same shape: a `height` is exact, everything else is the content's row count
// plus the frame. Note that a wrapped block's row count is NOT line_count(text)
// -- wrapping adds rows -- which is another reason the constrained branch cannot
// be derived from the input text and must be the flat answer.
@(private = "file")
expected_block_height :: proc(s: ^Style, text: string) -> int {
	frame := s.pad[.Top] + s.pad[.Bottom]
	if s.bordered {
		if .Top    in s.border_sides { frame += 1 }
		if .Bottom in s.border_sides { frame += 1 }
	}
	if s.height > 0 && s.overflow != .Grow {
		return s.mar[.Top] + max(s.height, frame) + s.mar[.Bottom]
	}
	rows := s.pad[.Top] + wrapped_line_count(s, text) + s.pad[.Bottom]
	if s.height > rows { rows = s.height }
	if s.bordered {
		if .Top    in s.border_sides { rows += 1 }
		if .Bottom in s.border_sides { rows += 1 }
	}
	return s.mar[.Top] + rows + s.mar[.Bottom]
}

// How many rows the content occupies once wrapping has run.
//
// THE ONE PLACE THIS FILE IS NOT INDEPENDENT OF THE IMPLEMENTATION, stated
// outright rather than hidden: for a width-constrained .Wrap block with no
// explicit `height`, the row count is whatever the wrap algorithm decided, and
// re-deriving it here would be re-implementing greedy word wrap with hard breaks
// at cluster boundaries -- a second implementation that would drift from the
// first and then be "fixed" to match it, which is worse than delegating.
//
// WHAT STAYS INDEPENDENT is the assertion that actually matters, and it is the
// one this table exists for: EVERY row measures the same, and measures exactly
// the width the Style asked for. That is derived from the Style fields alone
// (expected_block_width) and is not weakened by taking the row count from wrap.
// A wrap that produced the wrong number of rows but rectangular ones would slip
// through here; a wrap that produced a ragged block could not.
//
// Truncation never adds a row, and a zero-width content area is rendered by the
// truncate path, so both answer line_count directly.
@(private = "file")
wrapped_line_count :: proc(s: ^Style, text: string) -> int {
	if s.width <= 0 || s.overflow != .Wrap { return line_count(text) }
	inner := s.width - (horizontal_frame_size(s^) - s.mar[.Left] - s.mar[.Right])
	if inner <= 0 { return line_count(text) }
	w := wrap(text, inner, s.wopts, context.allocator)
	defer delete(w, context.allocator)
	return line_count(w)
}

@(private = "file")
check_block :: proc(t: ^testing.T, out: string, want_w, want_h: int, variant, label: string, p: Profile) {
	lines := strings.split_lines(out, context.allocator)
	defer delete(lines, context.allocator)

	if len(lines) != want_h {
		testing.expectf(t, false, "[%v/%s/%s] %d rows, want %d\n%q", p, variant, label, len(lines), want_h, out)
		return
	}
	for line, i in lines {
		got := rt.display_width(line)
		if got != want_w {
			testing.expectf(t, false, "[%v/%s/%s] row %d measures %d, want %d\nrow=%q\nblock=%q",
				p, variant, label, i, got, want_w, line, out)
			return
		}
	}
}
