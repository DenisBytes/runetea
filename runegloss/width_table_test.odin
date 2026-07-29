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
@(private = "file")
expected_block_width :: proc(s: ^Style, text: string) -> int {
	inner := max_line_width(text)
	if s.width > 0 { inner = max(inner, s.width - s.pad[.Left] - s.pad[.Right]) }
	box := s.pad[.Left] + inner + s.pad[.Right]
	lw, rw := 0, 0
	if s.bordered {
		// Every border this package ships is one column per side (box-drawing
		// characters are East_Asian_Width=Ambiguous, which the width layer folds
		// to 1 by default).
		if .Left  in s.border_sides { lw = 1 }
		if .Right in s.border_sides { rw = 1 }
	}
	return s.mar[.Left] + lw + box + rw + s.mar[.Right]
}

@(private = "file")
expected_block_height :: proc(s: ^Style, text: string) -> int {
	rows := s.pad[.Top] + line_count(text) + s.pad[.Bottom]
	if s.height > rows { rows = s.height }
	if s.bordered {
		if .Top    in s.border_sides { rows += 1 }
		if .Bottom in s.border_sides { rows += 1 }
	}
	return s.mar[.Top] + rows + s.mar[.Bottom]
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
