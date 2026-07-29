package runegloss

// Border character sets.
//
// FIXED-CAPACITY BYTES, NOT `string`, and that is the same decision msg.odin's
// Msg_Text made for the same reason: Style must be a PLAIN VALUE TYPE that an
// application can drop into its model and copy freely. A `string` field would
// make Border a {ptr, len} pair -- fine while it points at a literal, a
// dangling read the first time someone builds a custom border out of a
// heap-allocated or stack-local string and stores the Style. A byte array
// cannot alias anything, so `b := a` is the whole truth.
//
// THE CAP IS 8 BYTES PER GLYPH, which is not arbitrary: a border cell is ONE
// grapheme cluster, and every box-drawing character is 3 UTF-8 bytes. 8 leaves
// room for a base rune plus a combining mark, or a 4-byte astral rune plus a
// variation selector. Anything longer is silently truncated by border_cell --
// same contract as msg_text_from, and for the same reason (this has to be
// usable in a one-line composite literal, so it cannot be fallible). A
// truncated cell would be invalid UTF-8, so it is REJECTED rather than clipped:
// see border_cell.
BORDER_CELL_CAP :: 8

Border_Cell :: struct {
	buf: [BORDER_CELL_CAP]u8,
	len: u8,
}

// The eight glyphs a box needs. Sides and corners are separate so that a
// partial border (border_sides) can drop a side without leaving a corner
// pointing at nothing.
Border :: struct {
	top, bottom, left, right:                       Border_Cell,
	top_left, top_right, bottom_left, bottom_right:  Border_Cell,
}

// `contextless` IS LOAD-BEARING, not decoration: the NORMAL/ROUNDED/... globals
// below are initialised by calling this at package scope, and Odin rejects a
// call to a context-requiring procedure there ("Procedures requiring a
// 'context' cannot be called at the global scope"). Nothing in here needs a
// context anyway -- `copy` on two byte slices is a memmove.
//
// A glyph longer than BORDER_CELL_CAP yields an EMPTY cell rather than a
// truncated one. Clipping mid-cluster would put invalid UTF-8 on the wire, and
// an empty cell degrades visibly (a gap) instead of corrupting the terminal's
// decoder for the rest of the line.
@(require_results)
border_cell :: proc "contextless" (s: string) -> Border_Cell {
	c: Border_Cell
	if len(s) > BORDER_CELL_CAP { return c }
	n := copy(c.buf[:], s)
	c.len = u8(n)
	return c
}

// BORROWS `c^`, exactly like msg_text_string borrows its Msg_Text -- and takes
// a POINTER for exactly the same reason that one learned the hard way: taking
// the cell by value and slicing the local copy would return a string pointing
// into this procedure's own dead stack frame.
@(require_results)
cell_str :: proc(c: ^Border_Cell) -> string {
	return string(c.buf[:c.len])
}

// The shipped border sets.
//
// PACKAGE VARIABLES, NOT CONSTANTS, because border_cell is a procedure call and
// Odin has no way to fold one into a compile-time constant (the same limitation
// arena.odin's is_pod_type ran into with `when`). Treat them as read-only: to
// customise, COPY one and modify the copy -- which is free, since Border is a
// plain value type.
//
// EVERY GLYPH BELOW IS ONE COLUMN WIDE. Box-drawing characters are
// East_Asian_Width=Ambiguous (they sit inside width.odin's own
// ambiguous_width_ranges: 0x24EB-0x254B and 0x2550-0x2573 cover all of them),
// and the width layer folds Ambiguous to 1 by default. An application that sets
// ambiguous_wide(&s, true) -- because its terminal really does render Ambiguous
// double-width -- gets a border measured at 2 columns per side, and the block
// stays rectangular because render measures the glyphs with the SAME options it
// pads with. That is checked, not assumed: see the width table.
NORMAL := Border{
	top          = border_cell("─"), bottom       = border_cell("─"),
	left         = border_cell("│"), right        = border_cell("│"),
	top_left     = border_cell("┌"), top_right    = border_cell("┐"),
	bottom_left  = border_cell("└"), bottom_right = border_cell("┘"),
}

ROUNDED := Border{
	top          = border_cell("─"), bottom       = border_cell("─"),
	left         = border_cell("│"), right        = border_cell("│"),
	top_left     = border_cell("╭"), top_right    = border_cell("╮"),
	bottom_left  = border_cell("╰"), bottom_right = border_cell("╯"),
}

THICK := Border{
	top          = border_cell("━"), bottom       = border_cell("━"),
	left         = border_cell("┃"), right        = border_cell("┃"),
	top_left     = border_cell("┏"), top_right    = border_cell("┓"),
	bottom_left  = border_cell("┗"), bottom_right = border_cell("┛"),
}

DOUBLE := Border{
	top          = border_cell("═"), bottom       = border_cell("═"),
	left         = border_cell("║"), right        = border_cell("║"),
	top_left     = border_cell("╔"), top_right    = border_cell("╗"),
	bottom_left  = border_cell("╚"), bottom_right = border_cell("╝"),
}

// SPACES, not nothing. A hidden border still OCCUPIES its columns and rows --
// that is the entire point of it, and what makes it useful for aligning a
// bordered box against an unbordered one. To have no border at all, simply
// never call border().
HIDDEN := Border{
	top          = border_cell(" "), bottom       = border_cell(" "),
	left         = border_cell(" "), right        = border_cell(" "),
	top_left     = border_cell(" "), top_right    = border_cell(" "),
	bottom_left  = border_cell(" "), bottom_right = border_cell(" "),
}
