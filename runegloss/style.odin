package runegloss

// The Style value and its setters.
//
// ODIN HAS NO METHOD CHAINING AND NO CAPTURING CLOSURES, so Lipgloss's fluent
// `NewStyle().Bold(true).Foreground(c)` has no honest translation. Faking one
// (setters that return a Style by value, called as
// `s = bold(fg(new_style(), c), true)`) reads inside-out and copies the whole
// struct at every step. A mutable value plus `^Style` setters is the shape the
// language actually has:
//
//	s := rg.new_style()
//	rg.fg(&s, rg.color("#7D56F4"))
//	rg.bold(&s, true)
//	rg.padding(&s, 1, 2)
//	rg.border(&s, rg.ROUNDED)
//	out := rg.render(&s, "Hello", alloc)
//
// STYLE IS A PLAIN VALUE TYPE -- rt.is_pod_type(Style) is true and is asserted
// in the tests. No field is a string, pointer, slice or map, so an application
// may store a Style in its model, copy it, and hand copies around without any
// aliasing. That is why Border holds fixed-capacity byte cells rather than
// strings (border.odin) and why there is no "parent style" pointer for
// inheritance.

Attr :: enum u8 {
	Bold, Faint, Italic, Underline, Blink, Reverse, Strike,
}

// A bit_set, so attributes cost one byte and compose without ordering
// questions. The SGR emitter walks this in ENUM ORDER, which is why the
// declaration order above is also the order the parameters come out in --
// stable output is what lets runetea's .Diff renderer intern a style once and
// never repaint a cell that did not change (screen.odin's Style_Table: two
// spellings of the same style intern as two entries).
Attrs :: bit_set[Attr; u8]

Align_H :: enum u8 { Left, Center, Right }
Align_V :: enum u8 { Top,  Middle, Bottom }

Side  :: enum u8 { Top, Right, Bottom, Left }
Sides :: bit_set[Side; u8]

ALL_SIDES :: Sides{.Top, .Right, .Bottom, .Left}

Style :: struct {
	// A COPY taken at construction, never re-read from the process-wide
	// default. A render is then a pure function of (Style, text): two Styles
	// built at different times cannot silently disagree because something
	// called set_default_profile in between.
	profile: Profile,

	fg, bg: Color,
	attrs:  Attrs,

	// [Side]int rather than four named ints: the render path indexes these
	// with the same Side enum it uses for border_sides, so "the left one" is
	// spelled the same way everywhere.
	pad: [Side]int,
	mar: [Side]int,

	// A FLOOR, NOT A CLAMP. `width` is the width of the PADDED box (content
	// area + horizontal padding), excluding border and margin; `height` is that
	// box's row count. Content wider or taller than the request widens the box
	// -- RuneGloss never wraps and never truncates. See render's own note.
	width, height: int,

	align_h: Align_H,
	align_v: Align_V,

	// `bordered` and not "is Border the zero value": HIDDEN is a border made
	// entirely of spaces, and it must still occupy its columns.
	bordered:     bool,
	border:       Border,
	border_sides: Sides,
	border_fg:    Color,
	border_bg:    Color,

	// Passed through to every rt.display_width call this package makes. See
	// runetea's Width_Options: East_Asian_Width=Ambiguous runes (including
	// every box-drawing character) are 1 or 2 columns depending on the
	// terminal, and there is no universally correct answer. Leave false unless
	// the target terminal is known to render them double-wide.
	ambiguous_wide: bool,
}

// A Style with the process-wide detected profile (see default_profile) and
// nothing else set. The zero value of every other field is "do nothing", so a
// fresh Style renders its input byte for byte.
@(require_results)
new_style :: proc() -> Style {
	return Style{profile = default_profile()}
}

// The same, with the profile stated outright. EVERY TEST IN THIS PACKAGE USES
// THIS ONE: a styling test that reads $TERM is a test that passes on the
// author's terminal and fails in CI.
@(require_results)
new_style_profile :: proc(p: Profile) -> Style {
	return Style{profile = p}
}

profile :: proc(s: ^Style, p: Profile) { s.profile = p }

fg :: proc(s: ^Style, c: Color) { s.fg = c }
bg :: proc(s: ^Style, c: Color) { s.bg = c }

// One setter per attribute, plus the generic one they are all built on. The
// named procs exist because `rg.bold(&s, true)` is what an application wants to
// write; `attr` exists because a widget that toggles a caller-chosen attribute
// otherwise needs a seven-way switch.
attr :: proc(s: ^Style, a: Attr, on: bool) {
	if on { s.attrs += {a} } else { s.attrs -= {a} }
}

bold          :: proc(s: ^Style, on: bool) { attr(s, .Bold,      on) }
faint         :: proc(s: ^Style, on: bool) { attr(s, .Faint,     on) }
italic        :: proc(s: ^Style, on: bool) { attr(s, .Italic,    on) }
underline     :: proc(s: ^Style, on: bool) { attr(s, .Underline, on) }
blink         :: proc(s: ^Style, on: bool) { attr(s, .Blink,     on) }
reverse       :: proc(s: ^Style, on: bool) { attr(s, .Reverse,   on) }
strikethrough :: proc(s: ^Style, on: bool) { attr(s, .Strike,    on) }

// CSS's argument counts, because they are the ones everybody already knows:
// one value is all four sides, two is (vertical, horizontal), four is
// (top, right, bottom, left) clockwise from the top. An Odin proc group
// dispatches on arity, so all three spellings are literally `rg.padding(...)`.
//
// Negative values are clamped to 0 -- a negative padding has no meaning, and
// letting one through would produce a block narrower than its own content and
// every downstream width assertion would be off by it.
padding :: proc{padding_all, padding_vh, padding_trbl}
margin  :: proc{margin_all,  margin_vh,  margin_trbl}

padding_all  :: proc(s: ^Style, all: int)          { padding_trbl(s, all, all, all, all) }
padding_vh   :: proc(s: ^Style, v, h: int)         { padding_trbl(s, v, h, v, h) }
padding_trbl :: proc(s: ^Style, t, r, b, l: int) {
	s.pad[.Top], s.pad[.Right], s.pad[.Bottom], s.pad[.Left] = max(t, 0), max(r, 0), max(b, 0), max(l, 0)
}

margin_all  :: proc(s: ^Style, all: int)          { margin_trbl(s, all, all, all, all) }
margin_vh   :: proc(s: ^Style, v, h: int)         { margin_trbl(s, v, h, v, h) }
margin_trbl :: proc(s: ^Style, t, r, b, l: int) {
	s.mar[.Top], s.mar[.Right], s.mar[.Bottom], s.mar[.Left] = max(t, 0), max(r, 0), max(b, 0), max(l, 0)
}

width  :: proc(s: ^Style, w: int) { s.width  = max(w, 0) }
height :: proc(s: ^Style, h: int) { s.height = max(h, 0) }

align  :: proc(s: ^Style, a: Align_H) { s.align_h = a }
valign :: proc(s: ^Style, a: Align_V) { s.align_v = a }

// Turns the border on with all four sides. Call border_sides afterwards to drop
// some -- not before, since this resets them (a border() call after a
// border_sides() call would otherwise silently re-enable what was dropped, and
// setter order would become load-bearing in a way nothing signals).
border :: proc(s: ^Style, b: Border) {
	s.bordered     = true
	s.border       = b
	s.border_sides = ALL_SIDES
}

border_sides :: proc(s: ^Style, sides: Sides) { s.border_sides = sides }

// A border colour distinct from the content colour, which is the common case:
// a dim frame around bright content. Left at "no colour" the border inherits
// nothing -- it is painted unstyled, NOT in the content's colour, because a
// border that silently picked up the content's foreground could not be told
// apart from one that was deliberately set to it.
border_fg :: proc(s: ^Style, c: Color) { s.border_fg = c }
border_bg :: proc(s: ^Style, c: Color) { s.border_bg = c }

ambiguous_wide :: proc(s: ^Style, on: bool) { s.ambiguous_wide = on }
