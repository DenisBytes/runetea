package runetea

// THE CELL GRID (T3-A). A model of what is actually on the terminal's screen:
// cols x rows of cells, plus the terminal state that decides where the next
// write lands (cursor, SGR, pending wrap). Nothing here emits a byte -- this is
// the data structure the diff renderer compares against, and the one the test
// oracle replays a byte stream into.
//
// WHY A MODEL AT ALL, rather than diffing view strings. Two frames can be
// textually different and produce the same screen (a line that grew past the
// right margin and wrapped), and textually identical and produce different
// screens (the same view painted at a different width). Only a cell grid
// answers "what would the user see", and only "what would the user see" is
// what the diff must preserve. The spec's warning about this code failing
// silently (§10, §13.1) is really a warning about diffing the wrong thing.
//
// THE SEMANTICS MODELLED HERE ARE THE TERMINAL'S, NOT RUNETEA'S. Every proc
// below is a primitive a VT100 already has -- write a cluster, wrap, index,
// erase in line, erase in display, position the cursor -- and each one is
// deliberately a faithful copy of what a terminal does with the corresponding
// byte, including the parts that look like bugs:
//
//   * DECAWM PENDING WRAP. `x` is allowed to equal `cols`. A terminal that has
//     just filled the last column does NOT move to the next row -- it parks in
//     a "pending wrap" state, and only the NEXT printable character wraps.
//     Collapsing that into "x = 0, y += 1" eagerly is the classic off-by-one:
//     it turns a trailing \e[K into an erase of the WRONG row.
//   * A WIDE CLUSTER AT THE LAST COLUMN IS WRITTEN THERE, with no continuation
//     cell (there is no column left to hold one), and the cursor clamps to
//     `cols` rather than spilling onto the next row. This is what pyte does,
//     and width.odin's measure_line now MEASURES it -- it walks the placement
//     with this exact rule.
//
//     THAT IS A CORRECTION TO WHAT THIS PARAGRAPH USED TO SAY, and the
//     correction is the point. It used to claim width.odin "already assumes"
//     this, when in fact rows_for_line divided display_width by cols and
//     render.odin's line_fills_its_rows took display_width modulo cols --
//     neither of which knows a wide cluster straddled the margin. The three
//     were therefore NOT consistent, only consistently derived from the wrong
//     quantity: the modulo could call a row flush with the right margin when
//     placement had left it a column short, the trailing \e[K was skipped, and
//     the tail of that row kept the previous frame's characters forever under
//     .Diff (the model agreed with the omission, so nothing repainted it).
//     line_fills_its_rows is gone; measure_line answers all three questions
//     from one placement walk.
//
//     xterm-family terminals instead leave the last cell blank and wrap the
//     whole cluster (alacritty inserts a leading-wide-char spacer and wraps;
//     foot pads with spacers and forces a line wrap). THIS IS A KNOWN,
//     DELIBERATE DIVERGENCE from real hardware, kept because pyte -- the
//     independent oracle tools/difftest scores this package against -- takes
//     this side, and because the divergence is invisible to .Diff and
//     .Full_Screen: both address every row absolutely, so a model that agrees
//     with itself paints a correct screen either way. It is NOT invisible to
//     .Inline, which has no cell model and is painted by the real terminal:
//     there a line whose last cluster is wide and starts on the last column
//     occupies two rows on real hardware and one here, so the rewind is one row
//     short. See docs/LIMITATIONS.md 3.8.
//   * ERASE PAINTS THE CURRENT SGR. \e[K and \e[J fill with the ACTIVE
//     background, not with "default blank". A cell erased under a background
//     colour is a coloured cell. Modelling erase as "style 0" would make the
//     diff think a coloured gap already matched and skip it.
//   * NO WIDE-PAIR REPAIR. Overwriting half a wide cluster leaves the model in
//     the same half-broken state a terminal is left in, transiently. It is only
//     transient because the full-screen repaint this model mirrors writes or
//     erases EVERY cell of every painted row, left to right -- so a stub whose
//     head was just overwritten is always covered before the row is done. The
//     diff EMITTER is where the wide-cell invariant is enforced (see
//     emit_row_diff); repairing pairs here would make the model disagree with
//     the terminal instead.

// One screen cell.
//
// POD (T3-A checked this deliberately, per arena.odin's MESSAGE OWNERSHIP
// CONTRACT): every field is an integer, so `is_pod_type(Cell)` is true and a
// Cell could legally cross a Msg boundary. It never does -- a Renderer is
// owned by one event loop and never leaves it -- and it MUST NOT, because
// `off`/`len` are only meaningful against the Screen.text buffer they were
// filled from. That is a lifetime coupling POD-ness does not express, which is
// exactly why it is stated here instead of relied upon.
//
// WHY off/len INTO A SIDE BUFFER rather than inline bytes. A grapheme cluster
// has no useful upper bound: a ZWJ family emoji is 25 bytes, a tag-sequence
// flag 28, and an adversarial combining sequence is unbounded. An inline
// [N]u8 either wastes ~30 bytes per cell (69 KB per 80x24 grid, doubled for
// prev/cur) or silently truncates a cluster, which corrupts the bytes written
// back to the terminal. A byte offset costs 4 bytes and truncates nothing.
@(private = "package")
Cell :: struct {
	off:   u32,   // byte offset into Screen.text
	len:   u16,   // 0 => blank; the cell renders as a single space
	// 1 = a narrow cluster, 2 = the HEAD of a wide cluster, 0 = the
	// CONTINUATION cell that a wide cluster's second column holds. A blank is
	// width 1. The distinction is what makes "overwriting half a wide cell
	// repaints the whole cell" expressible at all.
	width: u8,
	style: u16,   // index into the shared STYLE table (Style_Table); 0 == default SGR
	// Index into the shared LINK table -- a second Style_Table instance, see
	// Screen.links. 0 == "this cell is not part of a hyperlink".
	//
	// Structurally identical to `style` and for exactly the same reason: an
	// OSC 8 hyperlink is terminal STATE that applies to every cell written
	// while it is open, precisely like an SGR attribute. A cell model that
	// tracks styles but not links reproduces the glyphs and loses the links,
	// which is silent data loss -- see render.odin's .Diff section.
	//
	// FREE, in the literal sense: Cell carried 9 bytes of payload padded to 12,
	// so this field consumes padding that already existed.
	link:  u16,
}

// A cell's cluster bytes. Empty for a blank -- callers that need to PAINT a
// blank write a space, which is not the same thing (a blank is "nothing was
// ever put here", a space is "a space was put here"); on screen they are
// indistinguishable, which is the whole reason a blank can be painted with one.
@(private = "package")
cell_bytes :: proc(s: ^Screen, c: Cell) -> string {
	if c.len == 0 { return "" }
	return string(s.text[c.off:][:c.len])
}

// Cell equality AS THE USER WOULD SEE IT: same cluster bytes, same width class,
// same SGR. Two cells that differ only in `off` are equal -- `off` is storage
// bookkeeping, and comparing it would make every frame differ.
@(private = "package")
cell_eq :: proc(sa: ^Screen, ca: Cell, sb: ^Screen, cb: Cell) -> bool {
	if ca.width != cb.width || ca.style != cb.style || ca.len != cb.len { return false }
	// `link` participates for the same reason `style` does: two cells with the
	// same glyph but different hyperlinks are two different things the user can
	// interact with, and a comparison that ignored it would leave a stale link
	// on screen forever (the cell "did not change", so it is never repainted).
	if ca.link != cb.link { return false }
	if ca.len == 0 { return true }
	return cell_bytes(sa, ca) == cell_bytes(sb, cb)
}

// The SGR strings any cell may point at, interned so a style comparison is an
// integer compare instead of a string compare -- and, more importantly, so a
// style index means the same thing in the PREVIOUS frame's screen and the
// CURRENT one. That is why the table lives beside the two Screens (on the
// Renderer) rather than inside either of them.
//
// A style is stored as the RAW ACCUMULATED SGR BYTES since the last reset --
// "\e[1m\e[31m", not a parsed {bold, fg} struct. Deliberate, and the trade is
// worth stating: raw accumulation handles 256-colour, truecolour, underline
// styles, and any SGR this package has never heard of, with no table to keep in
// sync with reality; the cost is that "\e[1m\e[31m" and "\e[31;1m" intern as
// two different styles even though they render identically, so a view that
// alternates between the two spellings would repaint cells that did not change.
// No real view does that; every real view emits one fixed spelling per style.
//
// RE-EMISSION IS ALWAYS CORRECT because the bytes are accumulated from a known
// reset point: writing style s onto a terminal known to be at default
// reproduces s exactly. See emit_style.
//
// TWO INSTANCES EXIST, not one (T3-C). The type is a content-addressed intern
// table for ESCAPE PAYLOADS, and the renderer keeps one for SGR strings and a
// second for OSC 8 hyperlink payloads (Screen.styles and Screen.links). They
// are deliberately separate tables rather than one shared namespace: index 0
// means "the default" in both, and the two vocabularies have nothing to say to
// each other, so sharing would only make an overflow in one drop the other.
@(private = "package")
Style_Table :: struct {
	spans: [dynamic]Style_Span,
	bytes: [dynamic]u8,
}

@(private = "package")
Style_Span :: struct {
	off: u32,
	len: u32,
}

// Beyond this many distinct styles the table is dropped and the screen force-
// repainted (see renderer's style_overflow handling). A TUI has a handful of
// styles; a view that manufactures unbounded distinct SGR strings (a colour
// gradient recomputed per frame) would otherwise grow this without limit for
// the lifetime of the process. Dropping and repainting is O(one frame) and
// bounded; leaking is not.
@(private = "package")
STYLE_TABLE_MAX :: 4096

@(private = "package")
style_table_init :: proc(st: ^Style_Table) {
	clear(&st.spans)
	clear(&st.bytes)
	// Index 0 is ALWAYS the default (empty) style, reserved before anything
	// can be interned. Every blank cell, every fresh Screen and every
	// "terminal is at default" claim in the emitter is spelled `0`, so this
	// entry existing is load-bearing, not a convenience.
	append(&st.spans, Style_Span{0, 0})
}

@(private = "package")
style_table_destroy :: proc(st: ^Style_Table) {
	delete(st.spans)
	delete(st.bytes)
	st.spans = nil
	st.bytes = nil
}

@(private = "package")
style_bytes :: proc(st: ^Style_Table, idx: u16) -> string {
	sp := st.spans[idx]
	if sp.len == 0 { return "" }
	return string(st.bytes[sp.off:][:sp.len])
}

// Interns `s`, returning its index. ok=false means the table is full -- the
// caller must force a repaint and reset it rather than silently aliasing two
// different styles onto one index.
@(private = "package")
style_intern :: proc(st: ^Style_Table, s: string) -> (idx: u16, ok: bool) {
	if len(s) == 0 { return 0, true }
	// Linear scan. The table holds single digits of entries in any real
	// program, and a hash map here would cost an allocation per frame to save
	// nothing measurable.
	for sp, i in st.spans {
		if int(sp.len) == len(s) && string(st.bytes[sp.off:][:sp.len]) == s {
			return u16(i), true
		}
	}
	// TWO CAPS, both of which mean "stop interning and force a repaint" rather
	// than "store something approximate". Truncating or aliasing a style is the
	// one failure this whole design cannot tolerate: it makes two visibly
	// different cells compare equal, which is a silently wrong screen -- and it
	// is exactly the defect the pyte cross-check caught in the first version of
	// this file, where an accumulated style was silently clipped at 256 bytes
	// and the diff painted an earlier colour than the repaint did.
	if len(st.spans) >= STYLE_TABLE_MAX { return 0, false }
	if len(st.bytes) + len(s) > STYLE_BYTES_MAX { return 0, false }
	off := u32(len(st.bytes))
	append(&st.bytes, s)
	append(&st.spans, Style_Span{off, u32(len(s))})
	return u16(len(st.spans) - 1), true
}

// The modelled screen. `cells` is row-major, len == cols*rows.
@(private = "package")
Screen :: struct {
	cols, rows: int,
	cells:      [dynamic]Cell,
	text:       [dynamic]u8,
	styles:     ^Style_Table,   // SHARED with the other Screen; not owned
	links:      ^Style_Table,   // ditto, for OSC 8 hyperlink payloads

	// --- modelled terminal state ---
	// x is in [0, cols]: cols means DECAWM PENDING WRAP -- the last column has
	// been filled and the next printable cluster starts the next row. See this
	// file's header for why that state is kept rather than collapsed.
	x, y:   int,
	style:  u16,
	// The hyperlink currently OPEN, i.e. the one every cell written from here on
	// belongs to. Structurally identical to `style` above, and reset alongside
	// it at the top of every frame.
	//
	// BOTH USED TO CARRY ACROSS FRAMES, on the reasoning that "the repaint
	// stream this models never resets them between frames either". That was
	// true of the stream and it was the bug: a view leaving either open made
	// screen_ed0 blank the rows below the frame with the leaked state, made
	// screen_sgr re-accumulate the view's own escape onto last frame's copy of
	// it (so an idle screen's diff grew by 16 bytes a frame until the 1 MiB
	// style budget blew), and made .Diff and .Full_Screen render the same view
	// differently for the first frame after any resize -- .Diff's forced
	// repaint reset both planes, .Full_Screen carried them. render.odin's
	// paint_frame now resets both in the model AND emits the matching bytes,
	// together, so the stream and the model still agree; see its frame-head
	// reset and Renderer.pen_open.
	link:   u16,
	hidden: bool,
}

@(private = "package")
screen_init :: proc(s: ^Screen, cols, rows: int, styles: ^Style_Table, links: ^Style_Table) {
	s.cols, s.rows = cols, rows
	s.styles = styles
	s.links  = links
	resize(&s.cells, cols * rows)
	clear(&s.text)
	screen_blank(s)
}

@(private = "package")
screen_destroy :: proc(s: ^Screen) {
	delete(s.cells)
	delete(s.text)
	s.cells = nil
	s.text  = nil
}

// Resets to "nothing has ever been on this screen": every cell blank at the
// DEFAULT style, cursor home, SGR default. Used for the first frame and after a
// resize, where the emitter pairs it with a real \e[2J so the terminal and the
// model agree again.
@(private = "package")
screen_blank :: proc(s: ^Screen) {
	clear(&s.text)
	for i in 0 ..< len(s.cells) { s.cells[i] = Cell{off = 0, len = 0, width = 1, style = 0, link = 0} }
	s.x, s.y = 0, 0
	s.style  = 0
	s.link   = 0
	s.hidden = false
}

// dst := src, with dst.text REBUILT COMPACTLY from the live cells.
//
// The compaction is not an optimisation, it is what bounds memory: `text` is
// append-only within a frame (a cell that is overwritten leaves its old bytes
// behind), so without a rebuild it would grow by one frame's worth of cluster
// bytes forever. Copying prev <- cur once per frame is O(cells) and gives the
// rebuild for free, so there is no separate compaction pass to forget to run.
@(private = "package")
screen_copy :: proc(dst, src: ^Screen) {
	dst.cols, dst.rows = src.cols, src.rows
	dst.styles = src.styles
	dst.links  = src.links
	resize(&dst.cells, len(src.cells))
	clear(&dst.text)
	for c, i in src.cells {
		d := c
		if c.len > 0 {
			d.off = u32(len(dst.text))
			append(&dst.text, cell_bytes(src, c))
		} else {
			d.off = 0
		}
		dst.cells[i] = d
	}
	dst.x, dst.y  = src.x, src.y
	dst.style     = src.style
	dst.link      = src.link
	dst.hidden    = src.hidden
}

@(private = "package")
screen_at :: proc(s: ^Screen, x, y: int) -> Cell {
	return s.cells[y * s.cols + x]
}

// Writes a cluster into cell (x, y). The bytes are appended to s.text -- see
// screen_copy for why that is safe to do unboundedly within a frame.
@(private = "file")
put_cell :: proc(s: ^Screen, x, y: int, span: string, width: u8, style: u16, link: u16) {
	// A WRITTEN SPACE AND AN ERASED CELL ARE THE SAME THING ON SCREEN, and are
	// normalised to the same representation here (len == 0) so that they compare
	// equal. Without this the diff would repaint a cell every time a view
	// replaced an erased gap with a literal space or vice versa -- and, worse,
	// the emitter (which paints a blank AS a space) would leave the model
	// describing something the terminal is not.
	// A SPACE WRITTEN INSIDE A HYPERLINK IS STILL INSIDE IT (`link` survives the
	// normalisation below), which is what makes "Click here" one link rather
	// than two. An ERASED cell is the opposite case and is handled by
	// blank_cell, which clears the link.
	if span == " " {
		s.cells[y * s.cols + x] = Cell{off = 0, len = 0, width = width, style = style, link = link}
		return
	}
	// A cluster longer than 64 KiB cannot be addressed by `len` (u16). Nothing
	// real produces one; store it as a blank rather than truncating to a corrupt
	// prefix, which would put invalid UTF-8 on the wire.
	if len(span) > int(max(u16)) {
		s.cells[y * s.cols + x] = Cell{off = 0, len = 0, width = width, style = style, link = link}
		return
	}
	c := Cell{off = 0, len = u16(len(span)), width = width, style = style, link = link}
	if len(span) > 0 {
		c.off = u32(len(s.text))
		append(&s.text, span)
	}
	s.cells[y * s.cols + x] = c
}

// AN ERASED CELL CARRIES NO HYPERLINK -- link = 0, unconditionally, even when a
// link is open at the moment of the erase. Two reasons, and the second is the
// load-bearing one:
//
//   * It is what a terminal does. xterm-family terminals keep the hyperlink id
//     in the cell, and erasing the cell erases it along with the glyph.
//   * IT IS TRUE ON EVERY TERMINAL FOR THE STREAM THE DIFF RENDERER EMITS,
//     because that emitter closes the link before every \e[K it writes (see
//     emit_row) -- so nothing is open when the erase runs and no terminal can
//     record one. The model does not have to be right about a debatable case,
//     because the emitter never puts the terminal in it.
//
// The .Full_Screen repaint, which blasts the view's own bytes, can still put
// the terminal in it for a PER-LINE \e[K -- a view whose line opens a hyperlink
// and never closes it before the end of that line. That much remains a
// view-side contract (close your hyperlinks), because closing the link there
// would break a link that legitimately spans a wrapped line.
//
// The TRAILING \e[J is no longer in that category: render.odin's paint_frame
// closes the link before it (and before the frame-head paint), in the byte
// stream and in the model together, so the rows below a frame are erased with
// nothing open on any terminal. That used to be the case where "the repaint
// cannot" was said flatly, and it was the case that mattered most -- it is the
// erase that covers the whole rest of the screen.
@(private = "file")
blank_cell :: proc(s: ^Screen, x, y: int, style: u16) {
	s.cells[y * s.cols + x] = Cell{off = 0, len = 0, width = 1, style = style, link = 0}
}

// LF / IND: down one row, scrolling the whole screen up if already on the last.
//
// The scrolled-in bottom row is blanked at the DEFAULT style, not the current
// one -- that is what a terminal does (the new line is fresh, not "erased under
// the current background") and what pyte does.
@(private = "package")
screen_index :: proc(s: ^Screen) {
	if s.y < s.rows - 1 { s.y += 1; return }
	if s.rows <= 0 { return }
	// Overlapping copy, downward: `copy` on a slice of itself is a memmove in
	// Odin, and the destination starts BELOW the source, so a forward copy is
	// correct here regardless.
	copy(s.cells[:], s.cells[s.cols:])
	for x in 0 ..< s.cols { blank_cell(s, x, s.rows - 1, 0) }
}

@(private = "package")
screen_cr :: proc(s: ^Screen) { s.x = 0 }

// CUP / CHA / VPA all land here. Both coordinates are 0-BASED and clamped the
// way a terminal clamps them (pyte's ensure_hbounds/ensure_vbounds): x is
// pulled into [0, cols-1], so an absolute move can never leave the cursor in
// the pending-wrap state that only a WRITE can produce.
@(private = "package")
screen_goto :: proc(s: ^Screen, x, y: int) {
	s.x = clamp(x, 0, s.cols - 1)
	s.y = clamp(y, 0, s.rows - 1)
}

// EL 0 -- erase from the cursor to the end of the row, INCLUSIVE of the cursor
// cell, painting the CURRENT SGR. With x == cols (pending wrap) there is
// nothing to erase, which is why the loop is written over a possibly-empty
// range rather than guarded by a "the cursor is on the row" assertion.
@(private = "package")
screen_el0 :: proc(s: ^Screen) {
	for x in s.x ..< s.cols { blank_cell(s, x, s.y, s.style) }
}

// EL 1 / EL 2 -- neither renderer emits these (the inline mode's \e[2K never
// reaches a cell model), but the oracle's byte replay must not silently ignore
// an escape it does not implement, so both exist rather than being a hole.
@(private = "package")
screen_el1 :: proc(s: ^Screen) {
	for x in 0 ..= min(s.x, s.cols - 1) { blank_cell(s, x, s.y, s.style) }
}

@(private = "package")
screen_el2 :: proc(s: ^Screen) {
	for x in 0 ..< s.cols { blank_cell(s, x, s.y, s.style) }
}

// ED 0 -- erase from the cursor to the end of the SCREEN. Note the tail: a
// terminal's ED 0 also erases the rest of the CURRENT row (it is "to the end of
// the display", and the display starts at the cursor, not at the next row).
// Missing that is a classic one-row stale-content bug.
@(private = "package")
screen_ed0 :: proc(s: ^Screen) {
	for y in s.y + 1 ..< s.rows {
		for x in 0 ..< s.cols { blank_cell(s, x, y, s.style) }
	}
	screen_el0(s)
}

// ED 2 -- erase the whole display, cursor unmoved.
@(private = "package")
screen_ed2 :: proc(s: ^Screen) {
	for y in 0 ..< s.rows {
		for x in 0 ..< s.cols { blank_cell(s, x, y, s.style) }
	}
}

// Writes one grapheme cluster of corrected display width `w` at the cursor,
// advancing it. THE ONE PLACE wrapping and wide-cell placement happen.
@(private = "package")
screen_put :: proc(s: ^Screen, span: string, w: int) {
	if s.cols <= 0 || s.rows <= 0 { return }

	if w == 0 {
		// A ZERO-WIDTH CLUSTER (a combining mark that opened its own cluster --
		// width.odin's defect 4; reachable when an escape splits a cluster, or
		// when a line begins mid-cluster). A terminal folds it into the cell to
		// its LEFT rather than giving it a cell. Fold into the HEAD of that
		// cell, never into a continuation half: appending bytes to a
		// continuation would make a zero-width cell carry text, and the emitter
		// has no way to paint that.
		tx, ty := s.x, s.y
		if tx >= s.cols { tx = s.cols - 1 }
		if tx == 0 {
			if ty == 0 { return }   // nothing to the left at all: drop it
			ty -= 1
			tx  = s.cols - 1
		} else {
			tx -= 1
		}
		if screen_at(s, tx, ty).width == 0 && tx > 0 { tx -= 1 }
		old := cell_bytes(s, screen_at(s, tx, ty))
		c   := screen_at(s, tx, ty)
		// Re-append base + mark contiguously; the old bytes stay in `text` as
		// garbage until the next screen_copy compacts them away.
		off := u32(len(s.text))
		append(&s.text, old)
		append(&s.text, span)
		c.off = off
		c.len = u16(len(old) + len(span))
		s.cells[ty * s.cols + tx] = c
		return
	}

	// DECAWM: the pending wrap resolves HERE, on the next printable cluster,
	// not when the last column was filled.
	if s.x >= s.cols {
		s.x = 0
		screen_index(s)
	}

	put_cell(s, s.x, s.y, span, u8(w), s.style, s.link)
	if w == 2 && s.x + 1 < s.cols {
		// The continuation half. Blank bytes, width 0 -- see Cell.width. It
		// takes the head's link as well as its style: the two halves are one
		// glyph and must never differ in any attribute, or emit_row's wide-pair
		// reasoning stops holding.
		s.cells[s.y * s.cols + s.x + 1] = Cell{off = 0, len = 0, width = 0, style = s.style, link = s.link}
	}
	// min(): a wide cluster written in the LAST column advances to `cols`
	// (pending wrap), it does not spill into the next row. See this file's
	// header on why that -- rather than xterm's blank-and-wrap -- is the rule
	// the whole package already assumes.
	s.x = min(s.x + w, s.cols)
}

// Applies one SGR sequence to the modelled style. `seq` is the full escape,
// ESC included.
//
// ACCUMULATE, DO NOT INTERPRET (see Style_Table). "\e[0m" and "\e[m" reset to
// index 0; anything else ending in 'm' is appended to whatever is already
// active. A NON-SGR escape that is not an OSC 8 hyperlink (cursor movement,
// DCS, other OSCs) is IGNORED here -- stated as a limitation rather than
// hidden: a view that embeds its own cursor motion is lying to the renderer
// about where its text lands, and no cell model can survive that. Views contain
// styling and hyperlinks; they must not contain motion. view_diff_safe
// (contract.odin) is the checkable form of that sentence.
//
// ok=false means the style table overflowed; the caller forces a repaint.
@(private = "package")
screen_sgr :: proc(s: ^Screen, seq: string, scratch: ^[dynamic]u8) -> (ok: bool) {
	if len(seq) < 3 || seq[0] != ESC || seq[1] != '[' { return true }
	if seq[len(seq) - 1] != 'm' { return true }

	params := seq[2:len(seq) - 1]
	if params == "" || params == "0" {
		s.style = 0
		return true
	}

	clear(scratch)
	append(scratch, style_bytes(s.styles, s.style))
	// NEVER TRUNCATED. An earlier version clipped this at 256 bytes to bound
	// growth, and the pyte cross-check caught the consequence within one run: a
	// line with enough SGRs to reach the cap had its LATER attributes dropped,
	// so the diff painted the colour set at the start of the run while the
	// repaint painted the one set at the end. Both harnesses that share this
	// package's model were blind to it -- the truncation happened identically on
	// both sides of their comparison -- which is the single best argument for
	// keeping a second oracle with no shared code.
	//
	// Growth is bounded instead where it can be bounded without lying: by the
	// style table's own byte budget (STYLE_BYTES_MAX), whose overflow forces a
	// repaint rather than corrupting a style.
	append(scratch, seq)
	idx, iok := style_intern(s.styles, string(scratch[:]))
	if !iok { return false }
	s.style = idx
	return true
}

// Total bytes the interned style strings may occupy before the table is dropped
// and the screen repainted. 1 MiB is several orders of magnitude past any real
// view; it exists so that an adversarial one cannot grow this without limit for
// the lifetime of the process, not as a working constraint.
@(private = "package")
STYLE_BYTES_MAX :: 1 << 20

// The bytes an OSC 8 hyperlink escape opens with, and the two ways it can end.
// Both terminators are accepted on the way IN (xterm's BEL convention is as
// common in the wild as the standard ST) and only ST is ever written on the way
// OUT -- one spelling on the wire means one spelling to reason about, and ST is
// the one the OSC 8 specification itself uses.
@(private = "package")
OSC8_OPEN :: "\e]8;"
@(private = "package")
ST :: "\e\\"

// Applies one OSC 8 hyperlink escape to the modelled link state. `seq` is the
// full escape, ESC included, exactly as skip_escape delimited it.
//
// THE WIRE FORM is  OSC 8 ; <params> ; <URI> ST|BEL , where <params> is a
// (usually empty) ':'-separated key=value list -- `id=` is the only one anyone
// uses, and it exists so two non-adjacent runs can be marked as ONE link. An
// EMPTY URI is the protocol's "close the current link", which is why the close
// sequence is the slightly odd-looking "\e]8;;\e\\".
//
// WHAT IS INTERNED IS `<params>;<URI>` -- everything between the "8;" and the
// terminator, verbatim. Not the URI alone, and that is deliberate: `id=1;u` and
// `id=2;u` are two DIFFERENT links to the terminal even though the destination
// matches, and folding them together would make the diff skip a cell whose link
// identity genuinely changed. Same "accumulate, do not interpret" rule
// screen_sgr follows, and it buys the same thing: any OSC 8 parameter invented
// after this was written travels through untouched.
//
// AN UNTERMINATED OSC 8 CHANGES NOTHING. skip_escape returns the end of the
// string for one, so the payload is a fragment whose real tail is whatever bytes
// the application writes next; acting on half a URI would open a link to
// somewhere nobody asked for. Dropped instead -- the same answer width.odin
// gives a truncated escape, for the same reason.
//
// ok=false means the link table overflowed; the caller forces a repaint,
// exactly as it does for the style table.
@(private = "package")
screen_osc8 :: proc(s: ^Screen, seq: string) -> (ok: bool) {
	if len(seq) < len(OSC8_OPEN) || seq[:len(OSC8_OPEN)] != OSC8_OPEN { return true }

	body := seq[len(OSC8_OPEN):]
	switch {
	case len(body) >= len(ST) && body[len(body) - len(ST):] == ST:
		body = body[:len(body) - len(ST)]
	case len(body) >= 1 && body[len(body) - 1] == BEL:
		body = body[:len(body) - 1]
	case:
		return true   // unterminated: not a link yet, so not a link change
	}

	// Split at the FIRST ';' -- params first, URI (which may itself contain ';')
	// second. No ';' at all is malformed; ignore it rather than guessing which
	// half is missing.
	semi := -1
	for i in 0 ..< len(body) {
		if body[i] == ';' { semi = i; break }
	}
	if semi < 0 { return true }

	if semi + 1 >= len(body) {
		s.link = 0   // empty URI: close
		return true
	}
	idx, iok := style_intern(s.links, body)
	if !iok { return false }
	s.link = idx
	return true
}

// Writes a run of view text -- clusters AND embedded escapes -- at the cursor.
//
// THE ESCAPE SPLIT IS display_width's, BYTE FOR BYTE (same ESC scan, same
// skip_escape, same segment boundaries). It has to be: rows_for_line is built
// on display_width, the full-screen repaint's truncation and EL decisions are
// built on rows_for_line, and this model exists to reproduce that repaint. A
// second, subtly different scanner here would desynchronise the two in exactly
// the cases -- styled lines -- that T2-A already had to fix once.
@(private = "package")
screen_write :: proc(s: ^Screen, text: string, scratch: ^[dynamic]u8, opts := Width_Options{}) -> (ok: bool) {
	ok = true
	seg := 0
	i   := 0
	for i < len(text) {
		if text[i] != ESC { i += 1; continue }
		screen_write_plain(s, text[seg:i], opts)
		j := skip_escape(text, i)   // always > i, so this loop always advances
		if !screen_escape(s, text[i:j], scratch) { ok = false }
		i   = j
		seg = i
	}
	screen_write_plain(s, text[seg:], opts)
	return
}

// THE ONE PLACE an escape found in a view is routed to the state it changes.
// Exactly two escapes change cell state -- SGR and OSC 8 -- and everything else
// is consumed for width and dropped, which is the .Diff contract stated in
// render.odin and checkable via view_diff_safe (contract.odin).
//
// Written as a router rather than as two calls at the call site because
// vt_replay (diff_oracle_test.odin) has to make exactly the same routing
// decision from the byte stream, and one shared entry point is one decision
// instead of two that can drift.
@(private = "package")
screen_escape :: proc(s: ^Screen, seq: string, scratch: ^[dynamic]u8) -> (ok: bool) {
	if len(seq) >= 2 && seq[1] == ']' { return screen_osc8(s, seq) }
	return screen_sgr(s, seq, scratch)
}

// THE CLUSTER LOOP, with the iterator's column kept in step with the CURSOR.
//
// WHAT THIS USED TO DO AND WHAT IT COST. It made one Cluster_Iter per plain
// SEGMENT and never touched ci.col, so the iterator measured every cluster from
// the segment's own start (0, since screen_write passes no start_col) while
// screen_put placed it at s.x. For every cluster but one that is harmless --
// widths are position-independent -- but a TAB's width is defined as
// next_tab_stop(col) - col, so a tab arriving at s.x = 3 in the second segment
// of a styled line was measured from 0 and came back 8. screen_put would then
// have written ONE cell claiming width 8: not memory-unsafe (put_cell writes a
// single cell), but a cell grid that says a glyph occupies eight columns is a
// model that no longer describes any terminal, and .Diff emits from the model.
//
// ci.col is assigned per cluster rather than once at iterator construction
// because screen_put MOVES the cursor in ways the iterator cannot see: it
// resolves a pending wrap to column 0 of the next row, and it clamps a wide
// cluster written in the last column to `cols`. Seeding start_col once would
// have been right only until the first wrap. The assignment is what
// Cluster_Iter.col's own comment ("WRITABLE ON PURPOSE ... a caller that DOES
// wrap assigns col = 0 after each wrap") exists for.
//
// A TAB IS A MOVE, NOT A CELL, which is why it does not reach screen_put at
// all. HT advances the cursor to the next tab stop and paints nothing; the
// cells it passes over keep whatever this frame had already put in them. That
// is what a VT100 does, what pyte does, and -- since the emitter paints from
// the model rather than forwarding the tab byte -- it is also self-consistent
// for .Diff: cells this frame skipped are cells this frame did not write.
//
// STILL UNREACHABLE THROUGH THE SUPPORTED PATH, and deliberately fixed anyway.
// A tab in a .Diff view is a Control_Byte violation of the view contract, and
// DIFF_STRICT now catches it in a plain `odin build` (contract.odin), so no
// application that passes the checker gets here. The guard is a compile-mode
// assertion, though, not a type: -o:speed drops it, an embedder can drive
// Screen directly (diff_oracle_test.odin does), and "the caller was supposed to
// have checked" is exactly the argument that leaves a model quietly describing
// something no terminal can show. Two lines of column bookkeeping is a cheaper
// answer than a documented divergence.
@(private = "file")
screen_write_plain :: proc(s: ^Screen, text: string, opts: Width_Options) {
	if len(text) == 0 { return }
	ci := cluster_iter_make(text, opts)
	for {
		// The column the NEXT cluster will be placed at -- which is what
		// Cluster_Iter.col means, and is not always s.x: s.x == cols is the
		// pending-wrap state, and the next printable cluster resolves it to
		// column 0 of the following row (screen_put's DECAWM branch).
		ci.col = s.x < s.cols ? s.x : 0
		span, w, more := cluster_next(&ci)
		if !more { break }
		if is_tab_span(span) { screen_tab(s, w); continue }
		screen_put(s, span, w)
	}
}

// A tab is a cluster of its own by construction: HT is GCB=Control, so GB4/GB5
// forbid it from being absorbed into a neighbour or carrying a combining mark.
// A byte compare is therefore sufficient and there is nothing to decode.
// (width.odin's is_tab says the same thing and is private to that file; one
// line duplicated is cheaper here than widening that file's surface for a case
// the view contract already forbids.)
@(private = "file")
is_tab_span :: proc(span: string) -> bool {
	return len(span) == 1 && span[0] == '\t'
}

// HT: advance the cursor by the width cluster_next already computed from the
// column this tab is at, and paint nothing.
//
// The pending wrap is resolved the SAME way screen_put resolves it, rather than
// being left standing. Real terminals differ on whether a control that prints
// nothing clears the deferred-wrap flag, and nothing in this tree can measure
// which -- but screen_write_plain has already MEASURED this tab from column 0
// of the next row on that assumption, so resolving here is what keeps the width
// and the placement describing the same cell. One rule in this file beats
// fidelity to an unobservable corner of a case the view contract forbids.
@(private = "file")
screen_tab :: proc(s: ^Screen, w: int) {
	if s.cols <= 0 || s.rows <= 0 { return }
	if s.x >= s.cols {
		s.x = 0
		screen_index(s)
	}
	s.x = min(s.x + w, s.cols)
}
