package runegloss

import "core:mem"
import "core:strings"
import rt "../runetea"

// THE RENDERER: a Style plus some text, out the other end as a rectangular
// block of terminal cells.
//
// EVERY MEASUREMENT IN THIS FILE GOES THROUGH rt.display_width, and that is the
// single most important sentence in the package. There is exactly ONE display-
// width implementation in this repo (runetea/width.odin), it already solves
// grapheme clustering, the four documented core:unicode defects, and
// zero-width ANSI escapes, and a styling layer that measured anything any other
// way -- bytes, runes, or "runes but skipping escapes I recognise" -- would
// produce ragged blocks on exactly the inputs that matter (CJK, VS16 emoji,
// flag pairs, already-styled text). That is what the width table pins.
//
// WHAT THIS EMITS, and why it is safe to feed straight to runetea's renderers:
// SGR escapes, printable text, and "\n". Nothing else. runetea's .Diff renderer
// models SGR per cell and treats every other escape as invisible (render.odin's
// KNOWN LIMITS: "views may contain styling, not motion"), so a styling layer
// that emitted a cursor move or an OSC would be lying to the cell model. It
// does not.
//
// NO ROW EVER ENDS WITH TERMINAL STATE STILL SET, unconditionally. A row that
// opened a style run closes it with "\e[0m"; a row that opened NO style run --
// a layout-only Style, or any coloured Style under .None -- still closes with
// "\e[0m" whenever the CONTENT carried escapes of its own that did not end in a
// reset. Both halves matter, and the second one is not theoretical: leaving one
// "\e[31m" open at the end of a row makes runetea's .Diff renderer carry that
// style into the next frame's Screen, where screen_sgr APPENDS it again --
// so 200 identical frames cost 605, 635, 640 ... 1625 bytes instead of 605 and
// then zero, growing without bound until the interned style hits
// STYLE_BYTES_MAX. That is the whole reason the .Diff mode exists, defeated by
// four missing bytes.
//
// WHY NOT JUST ALWAYS EMIT "\e[0m" AT END OF ROW: because a Style that asks for
// nothing must render its input byte for byte (the zero-cost case this package
// promises, and pins in a test), and four bytes per row on every plain-ASCII
// layout-only block is a real cost for blocks that provably cannot leave any
// state behind. So the reset is emitted exactly when the row COULD carry state,
// which is decidable without guessing: the style's own SGR is non-empty, or the
// content's last escape was not one of the two canonical resets. See
// write_reset.
//
// TRUNCATED ESCAPES IN THE CONTENT ARE DROPPED before anything is appended after
// them -- see drop_truncated_escape, which exists because a trailing "\e[3"
// eats the padding that follows it.
//
// SCOPE, stated plainly rather than discovered: no wrapping, no truncation, no
// layout joins. `width`/`height` are FLOORS. Content wider than `width` widens
// the block; silently cutting a user's text would be worse than a block that
// visibly overflows, and re-flowing it is a text-layout problem (word breaking,
// CJK line-break rules, ANSI-preserving splits) that is deliberately not in
// this package.

@(private = "file")
RESET :: "\e[0m"

@(private = "file")
ESC :: 0x1B
@(private = "file")
BEL :: 0x07

// The whole API. `alloc` is explicit and required, matching how every `view`
// proc in this codebase already works (arena.odin's LIFETIME CONTRACT): a
// runetea application hands this the frame allocator and the result dies with
// the frame. NOTHING but the returned string is allocated -- the two measuring
// passes below are subslice arithmetic and the SGR sequences live in
// fixed-size stack buffers, so this proc makes exactly one allocation family
// (the builder's) from exactly the allocator it was given.
@(require_results)
render :: proc(s: ^Style, text: string, alloc: mem.Allocator) -> string {
	opts := rt.Width_Options{ambiguous_is_wide = s.ambiguous_wide}

	// --- pass 1: measure the content -------------------------------------
	content_w, nlines := 0, 0
	{
		it := line_iter(text)
		for {
			line, ok := line_next(&it)
			if !ok { break }
			content_w = max(content_w, rt.display_width(line, opts))
			nlines += 1
		}
	}

	// The content AREA (inside the padding). `width` describes the padded box,
	// so the area it implies is width - left - right; max() with the real
	// content width is what makes `width` a floor rather than a clamp.
	inner := content_w
	if s.width > 0 { inner = max(inner, s.width - s.pad[.Left] - s.pad[.Right]) }
	box_w := s.pad[.Left] + inner + s.pad[.Right]

	rows := s.pad[.Top] + nlines + s.pad[.Bottom]
	fill := max(0, s.height - rows)
	fill_top, fill_bottom := 0, 0
	switch s.align_v {
	case .Top:    fill_top, fill_bottom = 0, fill
	case .Middle: fill_top, fill_bottom = fill / 2, fill - fill / 2
	case .Bottom: fill_top, fill_bottom = fill, 0
	}

	// --- border geometry --------------------------------------------------
	//
	// The left border COLUMN is as wide as the widest glyph that can appear in
	// it, and every glyph is padded out to that width (write_cell_padded).
	// Standard box-drawing borders are uniformly 1 column so this is a no-op
	// for them -- it exists so that a CUSTOM border whose corners and sides
	// measure differently still produces a rectangular block instead of a
	// ragged one, which is a property the width table can then assert
	// unconditionally.
	has_t := s.bordered && .Top    in s.border_sides
	has_r := s.bordered && .Right  in s.border_sides
	has_b := s.bordered && .Bottom in s.border_sides
	has_l := s.bordered && .Left   in s.border_sides

	lw, rw := 0, 0
	if has_l {
		lw = rt.display_width(cell_str(&s.border.left), opts)
		if has_t { lw = max(lw, rt.display_width(cell_str(&s.border.top_left),    opts)) }
		if has_b { lw = max(lw, rt.display_width(cell_str(&s.border.bottom_left), opts)) }
	}
	if has_r {
		rw = rt.display_width(cell_str(&s.border.right), opts)
		if has_t { rw = max(rw, rt.display_width(cell_str(&s.border.top_right),    opts)) }
		if has_b { rw = max(rw, rt.display_width(cell_str(&s.border.bottom_right), opts)) }
	}

	total_w := s.mar[.Left] + lw + box_w + rw + s.mar[.Right]

	// --- the two style runs ----------------------------------------------
	//
	// BORROWED FROM THIS FRAME, which is why the buffers are locals here and
	// sgr_str takes a pointer: building the Sgr inside a helper and returning
	// `string(local.buf[:local.len])` would hand back a pointer into the dead
	// helper's stack frame -- the exact bug msg.odin's msg_text_string
	// documents having shipped once. These two strings are valid for the whole
	// body of render and nowhere else.
	content_sgr := build_sgr(s.fg, s.bg, s.attrs, s.profile)
	border_sgr  := build_sgr(s.border_fg, s.border_bg, {}, s.profile)

	// EVERYTHING THE EMITTERS NEED, computed once. Odin has no capturing
	// closures, so the alternative is a dozen loose parameters threaded through
	// four call sites -- which is how this was first written and is exactly the
	// shape in which one of them silently gets the wrong `lw`. `g` lives in
	// this frame, and its two `string` fields borrow the two Sgr buffers above,
	// so it must not outlive render (it does not; nothing stores it).
	g := Geom{
		inner = inner, box_w = box_w, total_w = total_w,
		lw = lw, rw = rw,
		mar_l = s.mar[.Left], mar_r = s.mar[.Right],
		csgr = sgr_str(&content_sgr), bsgr = sgr_str(&border_sgr),
		opts = opts,
	}

	// --- emit -------------------------------------------------------------
	sb := strings.builder_make(alloc)
	nrow := 0

	for _ in 0 ..< s.mar[.Top] {
		row_break(&sb, &nrow)
		write_spaces(&sb, total_w)
	}

	if has_t {
		emit_border_row(&sb, &nrow, s, &g, &s.border.top_left, &s.border.top, &s.border.top_right)
	}

	emit_blank_rows(&sb, &nrow, fill_top,      s, &g)
	emit_blank_rows(&sb, &nrow, s.pad[.Top],   s, &g)

	{
		it := line_iter(text)
		for {
			line, ok := line_next(&it)
			if !ok { break }
			row_break(&sb, &nrow)
			write_row_open(&sb, s, &g)

			gap := g.inner - rt.display_width(line, opts)
			if gap < 0 { gap = 0 }   // unreachable: inner >= every line's width
			lead, trail := 0, 0
			switch s.align_h {
			case .Left:   lead, trail = 0, gap
			// Odd remainder goes RIGHT, matching Lipgloss -- an arbitrary but
			// fixed choice, and fixing it is what makes centred blocks stable
			// frame to frame.
			case .Center: lead, trail = gap / 2, gap - gap / 2
			case .Right:  lead, trail = gap, 0
			}

			write_sgr(&sb, g.csgr)
			write_spaces(&sb, s.pad[.Left] + lead)
			dirty := write_content(&sb, g.csgr, line)
			write_spaces(&sb, trail + s.pad[.Right])
			write_reset(&sb, g.csgr, dirty)

			write_row_close(&sb, s, &g)
		}
	}

	emit_blank_rows(&sb, &nrow, s.pad[.Bottom], s, &g)
	emit_blank_rows(&sb, &nrow, fill_bottom,    s, &g)

	if has_b {
		emit_border_row(&sb, &nrow, s, &g, &s.border.bottom_left, &s.border.bottom, &s.border.bottom_right)
	}

	for _ in 0 ..< s.mar[.Bottom] {
		row_break(&sb, &nrow)
		write_spaces(&sb, total_w)
	}

	return strings.to_string(sb)
}

// The laid-out block, so the emitters below take two pointers instead of a
// dozen scalars. `csgr`/`bsgr` BORROW render's Sgr locals -- see render.
@(private = "file")
Geom :: struct {
	inner, box_w, total_w: int,
	lw, rw:                int,
	mar_l, mar_r:          int,
	csgr, bsgr:            string,
	opts:                  rt.Width_Options,
}

// A full-width blank row inside the box: vertical padding and height fill are
// the same thing to the emitter, and both take the CONTENT style (they are
// inside the box, so a background colour must reach them).
@(private = "file")
emit_blank_rows :: proc(sb: ^strings.Builder, nrow: ^int, n: int, s: ^Style, g: ^Geom) {
	for _ in 0 ..< n {
		row_break(sb, nrow)
		write_row_open(sb, s, g)
		write_sgr(sb, g.csgr)
		write_spaces(sb, g.box_w)
		write_reset(sb, g.csgr)
		write_row_close(sb, s, g)
	}
}

// The top or bottom edge: ONE border style run around corner + fill + corner,
// not three. The corners are only drawn where the corresponding vertical side
// exists (lw/rw are 0 otherwise), so a border with Top but no Left starts
// straight into the fill rather than hanging a corner off nothing.
@(private = "file")
emit_border_row :: proc(sb: ^strings.Builder, nrow: ^int, s: ^Style, g: ^Geom, left, mid, right: ^Border_Cell) {
	row_break(sb, nrow)
	write_spaces(sb, g.mar_l)
	write_sgr(sb, g.bsgr)
	if g.lw > 0 { write_cell_padded(sb, left, g.lw, g.opts) }
	write_repeat_to_width(sb, mid, g.box_w, g.opts)
	if g.rw > 0 { write_cell_padded(sb, right, g.rw, g.opts) }
	write_reset(sb, g.bsgr)
	write_spaces(sb, g.mar_r)
}

// "\n" BEFORE every row except the first, never after the last. A trailing
// newline would be a fifth kind of blank row that nothing asked for, and
// runetea's renderer_render treats a trailing "\n" as a terminator rather than
// content -- so emitting one here would be invisible in a full frame and a
// silent extra row anywhere a block is concatenated into something larger.
@(private = "file")
row_break :: proc(sb: ^strings.Builder, nrow: ^int) {
	if nrow^ > 0 { strings.write_byte(sb, '\n') }
	nrow^ += 1
}

// The left margin and left border cell that open every body row. The border
// cell gets its OWN style run, closed before the content's begins -- three runs
// per bordered row rather than one, which is the price of a border colour
// independent of the content colour, and cheap: runetea's .Diff renderer
// interns each of the two spellings exactly once for the whole session.
@(private = "file")
write_row_open :: proc(sb: ^strings.Builder, s: ^Style, g: ^Geom) {
	write_spaces(sb, g.mar_l)
	if g.lw > 0 {
		write_sgr(sb, g.bsgr)
		write_cell_padded(sb, &s.border.left, g.lw, g.opts)
		write_reset(sb, g.bsgr)
	}
}

@(private = "file")
write_row_close :: proc(sb: ^strings.Builder, s: ^Style, g: ^Geom) {
	if g.rw > 0 {
		write_sgr(sb, g.bsgr)
		write_cell_padded(sb, &s.border.right, g.rw, g.opts)
		write_reset(sb, g.bsgr)
	}
	write_spaces(sb, g.mar_r)
}

// An EMPTY style run writes nothing at all. That is what keeps a Style with no
// colours and no attributes byte-for-byte transparent -- the same "write nothing
// you were not asked for" rule runetea's DECTCEM handling follows.
@(private = "file")
write_sgr :: proc(sb: ^strings.Builder, sgr: string) {
	if len(sgr) > 0 { strings.write_string(sb, sgr) }
}

// CLOSES THE ROW, and the one place the "no row ends with terminal state set"
// invariant is enforced. Two independent reasons a reset is owed:
//
//   len(sgr) > 0     this row OPENED a style run, so it must close it.
//
//   content_dirty    this row wrote CONTENT that carried its own escapes and
//                    did not end at the default SGR. That is true even when
//                    len(sgr) == 0 -- a layout-only Style (padding/width/border,
//                    no colour and no attribute) or ANY coloured Style under
//                    .None builds an empty sgr, and before this parameter
//                    existed such a row copied "\e[31mred" through and closed
//                    nothing. See the header for what that costs the .Diff
//                    renderer.
//
// The alternative -- reset every row unconditionally -- was rejected: it costs
// four bytes per row on blocks that provably cannot leak (no style run, no
// escapes in the content) and it breaks the byte-for-byte transparency of an
// unstyled Style, which is a documented promise with a test on it. The
// condition below is a strict refinement of "the row could carry state", never
// a guess: a row with an empty sgr and content ending in "\e[0m" is at the
// terminal default by construction.
@(private = "file")
write_reset :: proc(sb: ^strings.Builder, sgr: string, content_dirty := false) {
	if len(sgr) > 0 || content_dirty { strings.write_string(sb, RESET) }
}

@(private = "file")
write_spaces :: proc(sb: ^strings.Builder, n: int) {
	for _ in 0 ..< n { strings.write_byte(sb, ' ') }
}

// Writes `cell`, then spaces out to exactly `want` columns. A glyph WIDER than
// the column it was measured for cannot happen (the column is the max of the
// glyphs that can appear in it) but is handled anyway, as spaces: emitting an
// oversized glyph would push the whole row right and break rectangularity,
// which is the one property everything downstream depends on.
@(private = "file")
write_cell_padded :: proc(sb: ^strings.Builder, cell: ^Border_Cell, want: int, opts: rt.Width_Options) {
	g := cell_str(cell)
	w := rt.display_width(g, opts)
	if w > 0 && w <= want {
		strings.write_string(sb, g)
		write_spaces(sb, want - w)
		return
	}
	write_spaces(sb, want)
}

// Repeats `cell` until exactly `target` columns are covered, finishing with
// spaces when the glyph's width does not divide the target (a 2-column border
// glyph across an odd box). A ZERO-WIDTH glyph would never terminate the loop,
// so it degrades to spaces -- an empty border cell is a configuration mistake,
// not a reason to hang.
@(private = "file")
write_repeat_to_width :: proc(sb: ^strings.Builder, cell: ^Border_Cell, target: int, opts: rt.Width_Options) {
	g := cell_str(cell)
	gw := rt.display_width(g, opts)
	if gw <= 0 {
		write_spaces(sb, target)
		return
	}
	w := 0
	for w + gw <= target {
		strings.write_string(sb, g)
		w += gw
	}
	write_spaces(sb, target - w)
}

// WHAT HAPPENS WHEN THE INPUT ALREADY CONTAINS SGR -- the decision, and it is a
// decision rather than an accident.
//
// THE OUTER STYLE IS THE FLOOR. The caller's style is emitted first, the
// content's own escapes are passed through UNTOUCHED (they layer on top: bold
// content inside a purple style is bold and purple), and every time the content
// RESETS, the caller's style is immediately re-established. Then one final
// reset closes the row.
//
// The alternative -- pass the content through and let an inner reset stand --
// is what a naive `style + text + reset` wrapper does, and it is silently wrong
// in the most common case there is: `render(&purple, some_widget_output)` where
// the widget ends a highlighted word with "\e[0m" loses the purple for the rest
// of the line, and (worse) loses the BACKGROUND for the padding that follows,
// so a coloured box acquires a transparent notch. Stripping the inner escapes
// instead would silently discard styling the caller deliberately embedded.
//
// ONLY THE TWO CANONICAL RESET SPELLINGS ARE RECOGNISED, "\e[0m" and "\e[m",
// and that is not laziness: they are EXACTLY the two runetea's own cell model
// treats as a reset (screen.odin's screen_sgr: `params == "" || params == "0"`).
// Recognising a third spelling here would make RuneGloss and the renderer
// disagree about what the terminal's state is, which is a worse failure than the
// cosmetic one it would fix. Nothing this package emits uses any other spelling,
// so the disagreement is unreachable for its own output; it can only arise from
// content the caller embedded by hand.
//
// WHAT THAT COSTS, stated plainly rather than left to be discovered. A REAL
// TERMINAL resets on more spellings than those two: "\e[00m" and "\e[0;1m" are
// full resets, and "\e[22m" / "\e[39m" / "\e[49m" are partial ones. RuneGloss
// does NOT re-establish the outer style after any of them, so on a real terminal
// the outer style is silently LOST from that point to the end of the row --
// including the right-hand padding:
//
//	bold + fg #FF0000 + padding(0,2) over "a\e[00mb"
//	-> "\e[1;38;2;255;0;0m  a\e[00mb  \e[0m"
//
// and "b" plus the two trailing spaces paint UNSTYLED. Not a leak -- a loss, and
// a silent one: the "outer style is the FLOOR" contract above simply does not
// hold for those spellings. Worse, runetea's cell model does not recognise them
// either, so it still believes those cells are bold+red and a later frame will
// not repaint them; the wrong pixels persist until something else dirties the
// row.
//
// THAT IS STILL THE RIGHT TRADE, because the alternative is worse in a way that
// cannot be repaired downstream: if RuneGloss recognised "\e[00m" and the
// renderer did not, the two layers would hold DIFFERENT beliefs about the same
// cell, and a diff computed against the wrong belief mispaints cells that no
// input ever touched. Agreeing with the renderer keeps the damage confined to
// the row the caller hand-wrote an unusual reset into.
// test_a_noncanonical_reset_loses_the_outer_style_and_that_is_pinned nails the
// behaviour down so it is visible rather than surprising.
//
// SOUND ON BYTES, not just on runes: 0x1B can never occur inside a multi-byte
// UTF-8 sequence (every continuation byte is >= 0x80), so scanning for it
// cannot split a rune. Same argument width.odin's escape pre-pass makes.
//
// RETURNS whether the content may have left the terminal's SGR state non-default
// -- see write_reset, which is what does something about it.
@(private = "file")
write_content :: proc(sb: ^strings.Builder, sgr: string, line: string) -> (dirty: bool) {
	if len(sgr) == 0 {
		strings.write_string(sb, line)
		// No style run was opened, so whatever state the CONTENT set is the only
		// state there is, and it is this row's job to close it.
		return content_leaves_sgr_set(line)
	}
	i, start := 0, 0
	for i < len(line) {
		if line[i] != ESC { i += 1; continue }
		n := 0
		if strings.has_prefix(line[i:], "\e[0m") {
			n = 4
		} else if strings.has_prefix(line[i:], "\e[m") {
			n = 3
		} else {
			i += 1
			continue
		}
		strings.write_string(sb, line[start : i + n])
		strings.write_string(sb, sgr)
		i += n
		start = i
	}
	strings.write_string(sb, line[start:])
	// A style run WAS opened, and every inner reset re-established it, so the row
	// is unconditionally still styled here. write_reset closes it on len(sgr)
	// alone; the return value is about the empty-sgr case only.
	return true
}

// "Might this content have left the terminal at something other than the default
// SGR?" -- decided the same way runetea's cell model decides it, so the two
// layers cannot disagree: a reset is "\e[0m" or "\e[m" and nothing else.
//
// CONSERVATIVE BY CONSTRUCTION. Any escape that is not one of those two spellings
// counts as leaving state set, whether or not it actually does ("\e[00m" does,
// really, and is still counted as dirty here). Being wrong in that direction
// costs four redundant bytes on a row that already contained escapes; being
// wrong in the other direction is the unbounded .Diff growth in the header.
//
// Only the LAST escape is examined, because every earlier one is overridden by
// whatever came after it -- and if the last escape is a reset, the row genuinely
// ends at the default and owes nothing. Scanning bytes is sound for the reason
// write_content gives above.
@(private = "file")
content_leaves_sgr_set :: proc(line: string) -> bool {
	last := -1
	for i in 0 ..< len(line) { if line[i] == ESC { last = i } }
	if last < 0 { return false }
	rest := line[last:]
	return !strings.has_prefix(rest, "\e[0m") && !strings.has_prefix(rest, "\e[m")
}

// ---------------------------------------------------------------------------
// line iteration -- allocation-free
// ---------------------------------------------------------------------------

// strings.split_lines would do this, but it allocates a []string, and render
// walks the input TWICE (measure, then emit). Two allocations from the caller's
// allocator, freed at different times, in a proc whose entire memory contract
// is "one allocation, the result" -- against an iterator that is four lines.
//
// n newlines yield n+1 lines, so a trailing "\n" produces a trailing EMPTY
// line, which is rendered as a blank row. That is content, not a terminator:
// unlike runetea's renderer (which owns a whole frame and must not paint a
// phantom row), a block is a value the caller composes, and dropping a row the
// caller's string genuinely contained would be the surprising choice.
@(private = "file")
Line_Iter :: struct { rest: string, done: bool }

@(private = "file")
line_iter :: proc(s: string) -> Line_Iter { return Line_Iter{rest = s} }

// A TRUNCATED TRAILING ESCAPE IS DROPPED HERE, in the one place both passes go
// through, so the measuring pass and the emitting pass cannot possibly disagree
// about what a line is. See drop_truncated_escape for why it has to happen at
// all; doing it anywhere further downstream would mean pass 1 measured one
// string and pass 2 emitted another.
@(private = "file")
line_next :: proc(it: ^Line_Iter) -> (line: string, ok: bool) {
	if it.done { return "", false }
	i := strings.index_byte(it.rest, '\n')
	if i < 0 {
		it.done = true
		return drop_truncated_escape(it.rest), true
	}
	line = it.rest[:i]
	it.rest = it.rest[i + 1:]
	return drop_truncated_escape(line), true
}

// ---------------------------------------------------------------------------
// truncated escapes
// ---------------------------------------------------------------------------

// A LINE THAT ENDS INSIDE AN ESCAPE SEQUENCE SWALLOWS WHATEVER IS APPENDED TO
// IT, and this package appends to every line: alignment fill, right padding, the
// right border cell. Concretely, before this existed:
//
//	border(NORMAL); padding(1,1); width(7); render("abc\e[3")
//	rows measured 9, 9, 6, 9, 9 -- row 2 was "│ abc\e[3   │"
//
// 0x20 is inside the CSI parameter/intermediate range 0x20-0x3F, so the three
// padding spaces are consumed as parameter bytes of the unterminated CSI: they
// are not painted by a real terminal and are not counted by rt.display_width,
// which is the same measure this package pads with. The block stops being
// rectangular, which is the one property everything downstream depends on. Bare
// "\e" and "\e[" do the same thing, and the alignment mode changes how much gets
// eaten.
//
// DROPPING IT is the fix rather than closing it or emitting a reset first.
//   - CLOSING it ("\e[3" -> "\e[3m") would INVENT styling: SGR 3 is italic. A
//     layer that turns a caller's truncated byte into a real attribute change is
//     worse than one that drops it.
//   - EMITTING A RESET FIRST leaves the fragment in the output. It happens to
//     work (an ESC aborts a CSI, on a real terminal and in runetea's scanner
//     alike), but it also makes this package emit bytes that are not SGR and not
//     printable text -- breaking the "SGR escapes, printable text and \n,
//     nothing else" contract in the header, which is exactly the contract that
//     lets runetea's cell model trust a RuneGloss view.
//   - DROPPING it keeps that contract, and is width-neutral by construction:
//     rt.display_width already scores a truncated trailing escape as zero (see
//     width.odin's "UNTERMINATED ESCAPE AT END OF STRING -> ZERO WIDTH TO THE
//     END"), so the line measures the same before and after. Nothing visible is
//     lost -- the terminal was never going to paint those bytes either.
@(private = "file")
drop_truncated_escape :: proc(line: string) -> string {
	i := 0
	for i < len(line) {
		if line[i] != ESC { i += 1; continue }
		next, complete := scan_escape(line, i)
		// Runs off the end: everything from here on is unpaintable, and would
		// eat whatever the emitter appends next.
		if !complete { return line[:i] }
		i = next
	}
	return line
}

// MIRRORS runetea's skip_escape (width.odin) rule for rule -- CSI, the
// ST-terminated string family, and the nF/Fe/Fp/Fs forms -- and returns the
// extra bit that one does not: whether the sequence actually TERMINATED inside
// the string.
//
// Why a mirror rather than a call: skip_escape is @(private = "package") in
// runetea and this is a different package. Why that is acceptable here, when the
// file's opening rule is that every MEASUREMENT goes through rt.display_width:
// this is not a measurement, it is a boundary scan, and it is pinned against
// the real one from the outside. The width table renders truncated-escape inputs
// under every style variant and every profile and asserts each produced row
// measures the block width UNDER rt.display_width -- so any drift between this
// scanner and runetea's shows up there as a ragged block, not as silence.
@(private = "file")
scan_escape :: proc(s: string, start: int) -> (next: int, complete: bool) {
	i := start + 1
	if i >= len(s) { return len(s), false }   // bare trailing ESC

	switch s[i] {
	case '[':
		// CSI: ESC [ P...P I...I F. Parameter bytes 0x30-0x3F and intermediate
		// bytes 0x20-0x2F are contiguous, so one scan over 0x20-0x3F covers both;
		// the final byte is 0x40-0x7E.
		i += 1
		for i < len(s) && s[i] >= 0x20 && s[i] <= 0x3F { i += 1 }
		if i < len(s) && s[i] >= 0x40 && s[i] <= 0x7E { return i + 1, true }
		// i == len(s): truncated. i < len(s): a byte that cannot belong to a CSI
		// aborts it -- on a real terminal and in runetea's scanner alike -- so
		// measurement resumes AT that byte and nothing downstream is swallowed.
		return i, i < len(s)

	case ']', 'P', '^', '_', 'X':
		// OSC / DCS / PM / APC / SOS, closed by ST ("\e\\") or BEL.
		i += 1
		for i < len(s) {
			if s[i] == BEL { return i + 1, true }
			if s[i] == ESC {
				if i + 1 < len(s) && s[i + 1] == '\\' { return i + 2, true }
				return i, true   // bare ESC inside: this string ends here and the
				                 // loop re-dispatches on the ESC
			}
			i += 1
		}
		return len(s), false   // unterminated: eats everything appended after it

	case:
		// nF escapes (ESC + intermediates 0x20-0x2F + a final byte) and the plain
		// two-byte forms, which have no intermediates.
		for i < len(s) && s[i] >= 0x20 && s[i] <= 0x2F { i += 1 }
		if i < len(s) { return i + 1, true }
		return len(s), false
	}
}

// ---------------------------------------------------------------------------
// SGR assembly
// ---------------------------------------------------------------------------

// Longest possible run: "\e[" + "1;2;3;4;5;7;9" + ";38;2;255;255;255" +
// ";48;2;255;255;255" + "m" == 50 bytes. 64 is the round number above it, and
// sgr_put drops anything past it rather than corrupting the buffer -- which
// cannot happen, but a silent truncation of an escape sequence is the one
// failure mode this file must not have (see screen.odin on what a clipped style
// did to the diff renderer once).
@(private = "file")
SGR_CAP :: 64

@(private = "file")
Sgr :: struct {
	buf: [SGR_CAP]u8,
	len: int,
}

// BORROWS `g^` -- see render's own note on why the Sgr buffers are locals there
// and this takes a pointer.
@(private = "file")
sgr_str :: proc(g: ^Sgr) -> string { return string(g.buf[:g.len]) }

@(private = "file")
sgr_put :: proc(g: ^Sgr, b: u8) {
	if g.len >= SGR_CAP { return }
	g.buf[g.len] = b
	g.len += 1
}

@(private = "file")
sgr_puts :: proc(g: ^Sgr, s: string) {
	for i in 0 ..< len(s) { sgr_put(g, s[i]) }
}

@(private = "file")
sgr_int :: proc(g: ^Sgr, v: int) {
	if v >= 100 { sgr_put(g, u8('0' + (v / 100) % 10)) }
	if v >= 10  { sgr_put(g, u8('0' + (v / 10)  % 10)) }
	sgr_put(g, u8('0' + v % 10))
}

// SGR parameter numbers, in Attr's declaration order. Note 7 and 9, not 6 and
// 8: SGR 6 is "rapid blink" (unsupported almost everywhere) and SGR 8 is
// "conceal", neither of which this package exposes.
@(private = "file")
ATTR_CODE := [Attr]int{
	.Bold = 1, .Faint = 2, .Italic = 3, .Underline = 4,
	.Blink = 5, .Reverse = 7, .Strike = 9,
}

// ONE SGR SEQUENCE PER STYLE, with every parameter in a fixed order
// (attributes in enum order, then foreground, then background). Emitting
// "\e[1m\e[38;2;...m" instead would render identically and cost runetea's
// .Diff renderer a distinct Style_Table entry for every spelling it ever saw
// -- and, more to the point, a style whose byte spelling varied run to run
// would make an unchanged cell compare unequal and repaint forever. Fixed
// order, one sequence.
//
// ATTRIBUTES ARE NOT PROFILE-DEGRADED. $NO_COLOR and TERM=dumb are about
// COLOUR; bold, italic and underline are not colour, and stripping them under
// .None would leave a no-colour terminal with no emphasis at all -- strictly
// worse than what the user asked for. Only the two Colors go through convert().
@(private = "file")
build_sgr :: proc(fgc, bgc: Color, attrs: Attrs, p: Profile) -> Sgr {
	g: Sgr
	f := convert(fgc, p)
	b := convert(bgc, p)
	if attrs == {} && f.kind == .None && b.kind == .None { return g }

	sgr_puts(&g, "\e[")
	n := 0
	for a in Attr {
		if a not_in attrs { continue }
		if n > 0 { sgr_put(&g, ';') }
		sgr_int(&g, ATTR_CODE[a])
		n += 1
	}
	if f.kind != .None {
		if n > 0 { sgr_put(&g, ';') }
		sgr_color(&g, f, false)
		n += 1
	}
	if b.kind != .None {
		if n > 0 { sgr_put(&g, ';') }
		sgr_color(&g, b, true)
		n += 1
	}
	sgr_put(&g, 'm')
	return g
}

// The four encodings, and the reason the 16 have their own two rather than
// going through 38;5;n: a genuinely 16-colour terminal does not understand
// 38;5 at all, and "\e[38;5;4m" on one is either ignored or, on the worst of
// them, partially printed. The 30-37/90-97 (and 40-47/100-107) forms are the
// only ones a .ANSI profile may emit.
@(private = "file")
sgr_color :: proc(g: ^Sgr, c: Color, is_bg: bool) {
	base := 30 if !is_bg else 40
	switch c.kind {
	case .None:
		return
	case .ANSI:
		switch {
		case c.idx < 8:
			sgr_int(g, base + int(c.idx))
		case c.idx < 16:
			// The "bright" range: 90-97 / 100-107.
			sgr_int(g, base + 60 + int(c.idx) - 8)
		case:
			sgr_int(g, base + 8)   // 38 / 48
			sgr_puts(g, ";5;")
			sgr_int(g, int(c.idx))
		}
	case .RGB:
		sgr_int(g, base + 8)       // 38 / 48
		sgr_puts(g, ";2;")
		sgr_int(g, int(c.r)); sgr_put(g, ';')
		sgr_int(g, int(c.g)); sgr_put(g, ';')
		sgr_int(g, int(c.b))
	}
}
