package runetea

import "core:strings"

// A DETERMINISTIC FRAME-SEQUENCE GENERATOR for the diff renderer's oracle.
//
// TESTING SUPPORT, NOT PART OF THE RENDERING API -- but exported rather than
// tucked into a _test file, and deliberately so: the same corpus has to be
// driven from TWO harnesses that cannot share code any other way.
//
//   runetea/diff_oracle_test.odin  replays both byte streams through an
//                                  independent in-package VT emulator and
//                                  asserts the screens match. On the gate
//                                  (`./tools/test.sh`), no external deps.
//   tools/difftest                 emits the same two byte streams for the same
//                                  seeds and hands them to pyte -- a
//                                  third-party VT100 emulator with no shared
//                                  ancestry with anything in this package.
//
// Splitting it that way is the point. The in-package emulator shares this
// package's TERMINAL PRIMITIVES with the renderer's model (screen.odin), so a
// misconception about what a terminal does with a byte would be invisible to
// it -- it would be baked into both sides of the comparison. pyte has no such
// blind spot and no such shared code; what it cannot do is run on the gate
// (python + pyte would become a hard build dependency) or reach the width
// corrections width.odin exists to apply (pyte measures per code point with
// wcwidth, so VS16 emoji and flags are simply a different model). Neither
// harness alone is enough. Together they cover both failure modes, and both
// consume THIS generator so a seed that fails in one can be replayed in the
// other.
//
// EVERY CASE IS A PURE FUNCTION OF ITS SEED -- geometry, frame count, content,
// mutations, cursor. A failure is reproduced by rerunning the seed, and the
// seed is what the failing test prints.

// The mutation alphabet. Kept as compile-time constants so generating a frame
// allocates nothing but the view string itself.
//
// Each entry is one "token": a unit the generator places, moves and replaces.
// A token is either one grapheme cluster or one SGR escape -- never a partial
// cluster, because a view that splits a cluster is not something an application
// produces and the width layer documents its own behaviour there separately.
@(private = "file")
TOK_ASCII := []string{"a", "b", "c", "X", "Y", "0", "7", " ", ".", "#", "|", "~"}

// CJK: the wide-cell case, which is where the spec's "wide-cell invariants"
// warning lives.
@(private = "file")
TOK_WIDE := []string{"界", "日", "本", "語"}

// Base + combining mark: one cluster, width 1, THREE bytes. Exercises the "a
// cell holds a cluster's bytes, not a rune" path -- the reason a Cell stores an
// offset and a length rather than a rune.
//
// NOT pyte-safe, and the reason is worth recording because the pyte harness
// found it: pyte resolves DECAWM's pending wrap BEFORE it looks at a character's
// width, so a zero-width combining mark arriving with the cursor parked at the
// right margin makes pyte wrap (and, on the bottom row, SCROLL THE SCREEN)
// before merging the mark into the preceding cell. No real terminal scrolls on
// a combining mark, and RuneTea does not either -- it never splits the cluster
// in the first place. Excluded from the pyte alphabet as a disagreement the
// harness was built to have, not as a bug being hidden.
@(private = "file")
TOK_COMBINING := []string{"é", "ä", "ñ"}

// The pyte-safe stand-ins: the SAME characters precomposed into one code point
// each. Still multi-byte (2 bytes), so a cell still has to hold bytes rather
// than a rune, but with no separate combining mark for pyte to trip over.
@(private = "file")
TOK_PRECOMPOSED := []string{"é", "ä", "ñ"}

// VS16 emoji and a regional-indicator flag pair: width.odin's defects 2 and 3,
// where this package deliberately disagrees with per-code-point wcwidth. NOT
// pyte-safe -- see diff_fuzz_init's `pyte_safe`.
@(private = "file")
TOK_EMOJI := []string{"❤️", "\U0001F1EF\U0001F1F5", "\U0001F600"}

// SGR only. A view may contain styling; it must not contain motion (see
// render.odin's .Diff limits), so nothing here moves the cursor.
@(private = "file")
TOK_STYLE := []string{"\e[31m", "\e[1m", "\e[0m", "\e[4m", "\e[42m", "\e[38;5;120m"}

// OSC 8 HYPERLINKS (T3-C). Zero width, like TOK_STYLE, and like TOK_STYLE they
// are STATE: whatever is written after an open belongs to that link until the
// next open or the close. Placed by the same mutator as every other token, so
// the generator freely produces opens with no close, closes with no open,
// links that straddle a wrap, links that fall off the bottom of the viewport,
// and links whose run is later overwritten -- which is the point.
//
// Four entries, and each one earns its place:
//   * two DIFFERENT URIs, so "the glyph is the same but the destination
//     changed" is reachable -- the case a cell model that stored only styles
//     cannot see at all.
//   * one with an `id=` parameter, so "same URI, different link identity" is
//     reachable. That is why screen_osc8 interns params AND URI rather than the
//     URI alone.
//   * the close.
//
// PYTE-SAFE. pyte's OSC parser consumes an ST- or BEL-terminated string whole
// and dispatches only codes 0/1/2, so an OSC 8 is swallowed silently and
// identically on both sides of its comparison. It has no link model, so it
// cannot CHECK the links -- what it checks is that emitting them corrupted
// nothing else, which is exactly the half the in-package oracle is weakest on.
@(private = "file")
TOK_LINK := []string{
	"\e]8;;https://example.com\e\\",
	"\e]8;;https://runetea.invalid/b\e\\",
	"\e]8;id=7;https://example.com\e\\",
	"\e]8;;\e\\",
}

// A running fuzz case: geometry, a document of tokenised lines, and the PRNG
// state that drives the next mutation.
Diff_Fuzz :: struct {
	rng:       u64,
	cols:      int,
	rows:      int,
	frames:    int,   // how many frames this seed's case should run
	seed:      u64,
	pyte_safe: bool,
	lines:     [dynamic][dynamic]string,
	// Set once the first frame has been produced; the first frame is emitted
	// unmutated so that a case always has a baseline to diff against.
	started:   bool,
}

@(private = "file")
fuzz_u64 :: proc(s: ^u64) -> u64 {
	// splitmix64. Chosen over core:math/rand purely for pinning: this must
	// produce the same corpus from `odin test` and from tools/difftest for as
	// long as both exist, and a hand-written generator cannot be changed out
	// from under either by a core library revision.
	s^ += 0x9E3779B97F4A7C15
	z := s^
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

@(private = "file")
fuzz_n :: proc(f: ^Diff_Fuzz, n: int) -> int {
	if n <= 1 { return 0 }
	return int(fuzz_u64(&f.rng) % u64(n))
}

// `pyte_safe` restricts the alphabet to what pyte's per-code-point model agrees
// with this package about: ASCII, CJK and PRECOMPOSED accented letters. Two
// exclusions, both disagreements the harnesses were built to have rather than
// bugs being hidden -- see TOK_COMBINING and TOK_EMOJI for each one in full.
// The in-package oracle runs the FULL alphabet.
diff_fuzz_init :: proc(f: ^Diff_Fuzz, seed: u64, pyte_safe := false) {
	f.rng       = seed * 0x2545F4914F6CDD1D + 0x9E3779B97F4A7C15
	f.seed      = seed
	f.pyte_safe = pyte_safe
	f.started   = false

	// Small geometries on purpose. Wrapping, truncation and the right margin
	// are where the invariants live, and a 4-column screen reaches all three in
	// two tokens; an 80x24 screen mostly exercises "there was plenty of room".
	f.cols   = 4 + fuzz_n(f, 37)    // 4 .. 40
	f.rows   = 2 + fuzz_n(f, 11)    // 2 .. 12
	f.frames = 2 + fuzz_n(f, 13)    // 2 .. 14

	clear(&f.lines)
	// Start somewhere between "empty view" and "taller than the viewport", so
	// growth and truncation are both reachable from the initial state.
	n := fuzz_n(f, f.rows + 3)
	for _ in 0 ..< n { fuzz_add_line(f, fuzz_n(f, len(f.lines) + 1)) }
}

diff_fuzz_destroy :: proc(f: ^Diff_Fuzz) {
	for &l in f.lines { delete(l) }
	delete(f.lines)
	f.lines = nil
}

@(private = "file")
fuzz_token :: proc(f: ^Diff_Fuzz) -> string {
	roll := fuzz_n(f, 100)
	switch {
	case roll < 50: return TOK_ASCII[fuzz_n(f, len(TOK_ASCII))]
	case roll < 70: return TOK_WIDE[fuzz_n(f, len(TOK_WIDE))]
	case roll < 80:
		if f.pyte_safe { return TOK_PRECOMPOSED[fuzz_n(f, len(TOK_PRECOMPOSED))] }
		return TOK_COMBINING[fuzz_n(f, len(TOK_COMBINING))]
	case roll < 88: return TOK_STYLE[fuzz_n(f, len(TOK_STYLE))]
	// No pyte_safe branch: an OSC 8 is swallowed identically by both models.
	// See TOK_LINK.
	case roll < 95: return TOK_LINK[fuzz_n(f, len(TOK_LINK))]
	case:
		if f.pyte_safe { return TOK_ASCII[fuzz_n(f, len(TOK_ASCII))] }
		return TOK_EMOJI[fuzz_n(f, len(TOK_EMOJI))]
	}
}

@(private = "file")
fuzz_add_line :: proc(f: ^Diff_Fuzz, at: int) {
	line: [dynamic]string
	// 0 tokens is a real case (a blank line), and so is a line 1.5x wider than
	// the screen (two wrapped rows plus a partial third).
	n := fuzz_n(f, f.cols * 3 / 2 + 2)
	for _ in 0 ..< n { append(&line, fuzz_token(f)) }
	idx := clamp(at, 0, len(f.lines))
	inject_at(&f.lines, idx, line)
}

// Produces the next frame's view (into `b`, which it resets) and cursor.
//
// The FIRST call returns the document as initialised, unmutated: a case needs a
// baseline before "the same frame again" and "one cell different" mean
// anything. Every later call applies exactly one mutation, drawn so that
// "nothing changed" is a common outcome -- an identical consecutive frame is
// the single most important case the diff renderer has to get right (it is the
// one that must cost zero bytes) and a generator that never produced one would
// never test it.
diff_fuzz_frame :: proc(f: ^Diff_Fuzz, b: ^strings.Builder) -> (view: string, cur: Cursor) {
	if f.started { fuzz_mutate(f) }
	f.started = true

	strings.builder_reset(b)
	for line, i in f.lines {
		if i > 0 { strings.write_byte(b, '\n') }
		for tok in line { strings.write_string(b, tok) }
	}
	view = strings.to_string(b^)

	// A declared cursor about half the time, at coordinates that are frequently
	// out of range on purpose -- clamping is shared with the full-screen path
	// (cursor_cell) and must therefore land in the same place in both.
	if fuzz_n(f, 2) == 0 && len(f.lines) > 0 {
		cur.show = true
		cur.line = fuzz_n(f, len(f.lines) + 2)
		cur.col  = fuzz_n(f, f.cols + 3)
	}
	return
}

@(private = "file")
fuzz_mutate :: proc(f: ^Diff_Fuzz) {
	roll := fuzz_n(f, 100)
	switch {
	case roll < 18:
		// NOTHING. The zero-byte case.
		return
	case roll < 45:
		// One token: the one-changed-cell case (or a few, if the token's width
		// differs from what it replaced and the rest of the line shifts).
		if len(f.lines) == 0 { return }
		li := fuzz_n(f, len(f.lines))
		if len(f.lines[li]) == 0 { append(&f.lines[li], fuzz_token(f)); return }
		f.lines[li][fuzz_n(f, len(f.lines[li]))] = fuzz_token(f)
	case roll < 58:
		// Several tokens on ONE line.
		if len(f.lines) == 0 { return }
		li := fuzz_n(f, len(f.lines))
		if len(f.lines[li]) == 0 { return }
		for _ in 0 ..< 1 + fuzz_n(f, 5) {
			f.lines[li][fuzz_n(f, len(f.lines[li]))] = fuzz_token(f)
		}
	case roll < 68:
		// A line GROWS.
		if len(f.lines) == 0 { fuzz_add_line(f, 0); return }
		li := fuzz_n(f, len(f.lines))
		for _ in 0 ..< 1 + fuzz_n(f, 4) { append(&f.lines[li], fuzz_token(f)) }
	case roll < 78:
		// A line SHRINKS (including all the way to empty).
		if len(f.lines) == 0 { return }
		li := fuzz_n(f, len(f.lines))
		l  := &f.lines[li]
		k  := fuzz_n(f, len(l) + 1)
		resize(l, len(l) - k)
	case roll < 86:
		fuzz_add_line(f, fuzz_n(f, len(f.lines) + 1))
	case roll < 94:
		if len(f.lines) == 0 { return }
		li := fuzz_n(f, len(f.lines))
		delete(f.lines[li])
		ordered_remove(&f.lines, li)
	case:
		// Wholesale replacement: the many-changed-cells case, and the one that
		// swings the view from taller than the viewport to shorter and back.
		for &l in f.lines { delete(l) }
		clear(&f.lines)
		n := fuzz_n(f, f.rows + 3)
		for _ in 0 ..< n { fuzz_add_line(f, len(f.lines)) }
	}
}
