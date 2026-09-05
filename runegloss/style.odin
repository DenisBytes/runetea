package runegloss

import rt "../runetea"

// RuneGloss's own limitations -- non-canonical SGR resets that silently lose the
// outer style, the colour-conversion caps -- are consolidated with RuneTea's in
// ../docs/LIMITATIONS.md, section 7. Read it before assuming this is Lipgloss
// with different spelling; it is deliberately a subset.
//
// THREE ITEMS ON THAT LIST ARE GONE, and the reason is worth stating here rather
// than only in the changelog, because the old behaviour was the package's single
// largest design mistake. `width`/`height` USED TO BE FLOORS: content wider than
// `width` widened the box and dragged the right border with it. That is not an
// overflow, it is a SHEAR -- the widened box pushes past the terminal margin,
// DECAWM wraps it, and every row below it in the frame is displaced. One long
// file path in one panel destroyed the layout of panels it had nothing to do
// with. `width` is now EXACT (see below), and `wrap`, `truncate`,
// `join_horizontal` and `join_vertical` exist so that clamping has somewhere to
// put the text it no longer lets overflow.
//
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

	// EXACT, NOT A FLOOR, and INCLUSIVE OF THE BORDER. `width` is the total
	// number of columns the block occupies excluding margin -- left border +
	// left padding + content + right padding + right border -- and `height` is
	// the same for rows. 0 means "unconstrained": the block is whatever its
	// content makes it, which is the zero-value-does-nothing rule this package
	// keeps everywhere else.
	//
	// TWO CHANGES FROM THE ORIGINAL DESIGN, both deliberate, both breaking.
	//
	// (1) EXACT RATHER THAN A FLOOR. The old `width` was a minimum: content
	// wider than it widened the box. That makes `width` useless for the only
	// thing a width is for. A layout primitive whose output width is not a
	// function of its declared width is not a layout primitive -- you cannot
	// build a column, a panel or a join out of it, because the row you compute
	// on paper is not the row that reaches the terminal. Worse, the failure is
	// NOT confined to the offending box: the widened box runs past the terminal
	// margin, DECAWM wraps it, and every subsequent row of the whole frame is
	// displaced (and, under .Full_Screen/.Diff, the doubled row cost is charged
	// against term_height and the bottom of the frame is silently deleted).
	//
	// The old comment defended flooring as "silently cutting a user's text would
	// be worse than a block that visibly overflows". That premise was right and
	// the conclusion did not follow, because cutting is not the only way to fit:
	// the DEFAULT overflow policy is .Wrap, which loses no byte at all, it just
	// moves it. Cutting is available (.Truncate) for the places an app knows one
	// row is what it wants -- a status bar, a table cell -- and the old floor
	// behaviour is still reachable, spelled out loud, as .Grow.
	//
	// (2) INCLUSIVE OF THE BORDER, which lipgloss v2 also does (style.go:408,
	// `width -= horizontalBorderSize`) and lipgloss v0/v1 did not. RuneTea names
	// v2 as its target, so matching v1 here was a silent 2-column-per-box error
	// for anyone porting. But the decisive argument is local: if `width`
	// excluded the border, then `rg.width(&s, 40)` could not be written at all
	// without first knowing the border's own column cost, so `border()` would
	// have to be called BEFORE `width()` and setter order would become
	// load-bearing -- exactly the trap the border()/border_sides() note below
	// exists to avoid. With the border included, `rg.width(&s, 40)` means "40
	// columns" no matter what order anything is set in.
	//
	// MARGIN IS OUTSIDE, matching lipgloss: a margin is space BETWEEN blocks,
	// not part of one. Total rendered columns are width + mar[.Left] +
	// mar[.Right]. frame_size() reports the whole non-content cost including
	// margin, the way lipgloss's GetHorizontalFrameSize does.
	//
	// A width smaller than the frame it must contain clamps the content area to
	// zero rather than going negative; the block is then exactly as wide as its
	// own border and padding, which is the least surprising floor there is.
	width, height: int,

	// What happens to content that does not fit `width`/`height`. Inert while
	// both are 0, which is why .Wrap can be the zero value without violating
	// "a fresh Style renders its input byte for byte".
	overflow: Overflow,

	// The tail .Truncate appends when it cuts, e.g. "…". A Border_Cell for
	// exactly the reason border.odin gives -- Style must stay POD, and a
	// `string` field here would be a dangling read the first time someone built
	// one out of a heap buffer and stored the Style in their model.
	//
	// THE ZERO VALUE IS NO TAIL AT ALL, not "…". A truncation that silently ate
	// one more column for a glyph the caller never asked for is precisely the
	// kind of surprise the zero-value rule exists to prevent. The standalone
	// truncate() defaults to "…" instead, because there the caller is asking for
	// a truncation by name and a visible cut mark is what they want.
	ellipsis: Border_Cell,

	align_h: Align_H,
	align_v: Align_V,

	// `bordered` and not "is Border the zero value": HIDDEN is a border made
	// entirely of spaces, and it must still occupy its columns.
	bordered:     bool,
	border:       Border,
	border_sides: Sides,
	border_fg:    Color,
	border_bg:    Color,

	// THE WHOLE Width_Options VALUE, not a hand-copied bool per knob. Passed
	// through verbatim to every rt.display_width call this package makes.
	//
	// It used to be `ambiguous_wide: bool`, unpacked into a fresh
	// rt.Width_Options at the top of render. That shape has a standing bug in
	// it: every knob runetea's width layer grows has to be re-declared here, a
	// setter written for it, and the unpack extended -- and until someone does,
	// the knob is UNREACHABLE from a Style even though the width layer supports
	// it. That is the shape the emoji complaint had: how many columns a terminal
	// paints for a skin-tone modifier, a ZWJ sequence or a keycap is a matter on
	// which real terminals disagree violently (VTE paints "👨‍💻" as 4 columns and
	// "❤️" as 1, where the UCD emoji-presentation rules say 2 and 2), RuneGloss
	// pads every row to runetea's number, and an application that KNEW its
	// terminal had no way to say so. It does now -- rt.Width_Options.emoji_width
	// is that policy, and it arrived here for free, without a line changing in
	// this struct, which is the property embedding the options value buys.
	// `emoji_width` below is a convenience over it, not the mechanism.
	//
	// rt.Width_Options is POD, so Style stays POD -- asserted in the tests.
	wopts: rt.Width_Options,
}

// What render does with content that does not fit `width`/`height`.
//
// .Wrap IS THE ZERO VALUE and the default. It is the only policy that loses
// nothing: a long line is reflowed at word boundaries (and hard-broken at
// grapheme-cluster boundaries when a single word is wider than the box), so
// every byte the caller passed in is still on screen. That is what makes an
// exact `width` safe to have made the default -- see Style.width.
Overflow :: enum u8 {
	// Reflow to fit. Horizontally: greedy word wrap, hard-breaking words that
	// cannot fit on a line of their own. Vertically: excess rows are dropped
	// (there is no "reflow" for rows), from the end under .Top, the start under
	// .Bottom, and both ends under .Middle -- i.e. the rows kept are the ones
	// the vertical alignment says are nearest the anchor.
	Wrap,
	// Cut each line at `width` and append Style.ellipsis. Rows beyond `height`
	// are dropped exactly as under .Wrap.
	Truncate,
	// The pre-clamp behaviour, kept and named rather than deleted: `width` and
	// `height` become floors again and over-budget content widens or lengthens
	// the block. Correct when the caller has already guaranteed the fit and
	// wants to pay nothing for a re-measure, and the only honest way to render
	// content that must not be altered at any cost. Read Style.width for what
	// it does to a frame when that guarantee turns out to be false.
	Grow,
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
// DO NOT USE THIS. It is exported for completeness of the SGR set and for
// nothing else, and it is the only proc in this package with a warning on it.
//
// SGR 5 is a WCAG 2.3.1 (Three Flashes or Below Threshold) concern at LEVEL A
// -- the strictest tier -- and blinking text is a documented migraine and
// vestibular trigger. It also carries no information: anything you would blink
// can be said with a word, a glyph, reverse video or bold, all of which every
// reader can perceive and none of which can hurt one.
//
// What it costs even when it does no harm: many terminal emulators ignore SGR 5
// outright, so the attribute mostly buys you bytes on the wire and reaches only
// the subset of users whose terminal honours it -- which is exactly the subset
// it can harm. There is no configuration in which it is the best available
// choice.
//
// It is REMOVED under Profile.None ($NO_COLOR, TERM=dumb) -- see build_sgr in
// render.odin for why blink is the one attribute the profile degrades. On a
// capable terminal with colour enabled, nothing downstream will save a user
// from this call, so gate it on your own setting if you make it at all.
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

// EXACT COLUMNS AND ROWS, border included, margin excluded. See Style.width for
// the full argument; the short version is that a `width` that only ever made a
// block wider could not be used to build a layout, and that including the border
// is what keeps `rg.width(&s, 40)` independent of the order the other setters
// are called in.
//
// 0 restores "unconstrained". Negative is clamped to 0 for the same reason a
// negative padding is: it has no meaning, and letting one through would make
// every downstream width assertion off by it.
width  :: proc(s: ^Style, w: int) { s.width  = max(w, 0) }
height :: proc(s: ^Style, h: int) { s.height = max(h, 0) }

// What to do when the content does not fit. See Overflow.
overflow :: proc(s: ^Style, o: Overflow) { s.overflow = o }

// The tail .Truncate appends when it cuts -- "…", "...", ">" or "". Longer than
// BORDER_CELL_CAP yields an EMPTY tail rather than a clipped one, because a
// clipped multi-byte glyph is invalid UTF-8 on the wire; same contract as
// border_cell, which is the proc this calls.
ellipsis :: proc(s: ^Style, tail: string) { s.ellipsis = border_cell(tail) }

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

// The width knobs: two named policies and one total. `ambiguous_wide` and
// `emoji_width` are the two an application actually reaches for, because they
// are the two questions the terminal answers differently and never reports --
// East_Asian_Width=Ambiguous runes (curly quotes, box-drawing, Greek, Cyrillic)
// are 1 or 2 columns depending on the terminal, and a multi-rune emoji cluster
// is one advance or one per rune depending on it too. `width_options` exists so
// that no future knob runetea adds needs a new setter here to be reachable. See
// Style.wopts.
//
// WHAT emoji_width IS FOR, concretely: a box drawn around "👨‍💻" pads its content
// row to rt.display_width's number, which under the default .Grapheme_Cluster
// is 2. A VTE-based terminal (GNOME Terminal, Tilix, Terminator, xfce4) paints
// that cluster 4 columns wide, so the row runs 2 columns long and the right
// border lands outside the frame; "❤️" and "1️⃣" go the other way and pull it 1
// column inside. `emoji_width(&s, .Legacy_Wcwidth)` makes every measurement in
// this package -- padding, wrapping, truncation, join alignment and `measure`
// -- agree with that family of terminals instead. rt.Emoji_Width carries the
// measured table of which terminals want which, and there is no autodetect:
// nothing in the terminal protocol reports it.
ambiguous_wide :: proc(s: ^Style, on: bool) { s.wopts.ambiguous_is_wide = on }
emoji_width    :: proc(s: ^Style, p: rt.Emoji_Width) { s.wopts.emoji_width = p }
width_options  :: proc(s: ^Style, o: rt.Width_Options) { s.wopts = o }

// ---------------------------------------------------------------------------
// frame geometry
// ---------------------------------------------------------------------------

// THE COLUMNS AND ROWS THAT ARE NOT CONTENT: margin + border + padding. This is
// lipgloss's GetHorizontalFrameSize/GetVerticalFrameSize, and it is here because
// without it an application cannot compute a layout AT ALL. The border's own
// column cost is not a constant an app can assume: it is the display width of
// the widest glyph that can appear in each vertical edge (a custom border may be
// 2 columns, or fullwidth CJK), computed from the same rt.display_width the
// renderer pads with, and there was previously no way to reach it from outside.
//
// NOTE THE ASYMMETRY WITH Style.width, which is deliberate and is lipgloss's:
// `width` includes border and padding but NOT margin, while frame_size includes
// all three. So the total columns a block occupies are
//
//	width + mar[.Left] + mar[.Right]           when width > 0
//	content_width + horizontal_frame_size(s)   when width == 0
//
// and the content area inside a constrained block is
//
//	width - (horizontal_frame_size(s) - mar[.Left] - mar[.Right])
//
// which is what render computes. An app laying out two panels across `cols`
// columns wants the first form: `rg.width(&panel, cols/2 - panel.mar[.Left] -
// panel.mar[.Right])`.
@(require_results)
frame_size :: proc(s: Style) -> (w, h: int) {
	return horizontal_frame_size(s), vertical_frame_size(s)
}

@(require_results)
horizontal_frame_size :: proc(s: Style) -> int {
	bw, _ := border_size(s)
	return s.mar[.Left] + s.mar[.Right] + s.pad[.Left] + s.pad[.Right] + bw
}

@(require_results)
vertical_frame_size :: proc(s: Style) -> int {
	_, bh := border_size(s)
	return s.mar[.Top] + s.mar[.Bottom] + s.pad[.Top] + s.pad[.Bottom] + bh
}

// The border's own cost, in columns and rows. Split out from frame_size because
// it is the piece an application genuinely CANNOT recompute: `bw` is not "2 if
// bordered", it is the max display width of the glyphs that can land in each
// vertical edge, under this Style's own width options, and a partial
// border_sides may contribute only one side or none.
//
// Rows are 0 or 1 per horizontal edge unconditionally -- a border row is one row
// however wide its glyph is.
@(require_results)
border_size :: proc(s: Style) -> (w, h: int) {
	if !s.bordered { return 0, 0 }
	sc := s   // cell_str borrows a ^Border_Cell; `s` is a parameter and not addressable
	lw, rw := edge_widths(&sc)
	if .Top    in s.border_sides { h += 1 }
	if .Bottom in s.border_sides { h += 1 }
	return lw + rw, h
}
