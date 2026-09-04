#+private
// ^ Every declaration in this file is package-private, so that `odin doc
//   runetea` / `odin doc runegloss` -- the command README.md and docs/API.md
//   hand a newcomer for symbol discovery -- lists the library rather than the
//   test fixtures. Pinned by tools/doccheck/run.sh's `apidoc` check, which is
//   also where the argument for it is written out.
package runetea

import "core:fmt"
import "core:strings"
import "core:testing"

// ============================================================================
// THE DIFF RENDERER'S ORACLE
// ============================================================================
//
// THE INVARIANT, and it is the only one worth checking:
//
//   Replaying the DIFF renderer's bytes through a VT100 must produce exactly
//   the same screen -- every cell's glyph, width class and SGR -- and the same
//   cursor position as replaying the FULL-SCREEN REPAINT renderer's bytes for
//   the same frame sequence.
//
// Byte-matching against a transcribed corpus (what the spec proposes, §10)
// answers a different and weaker question: "did we make the same ENCODING
// choices as some other implementation". That is a proxy. This is the actual
// property, it holds over arbitrary frame sequences rather than a fixed table,
// and no amount of subtle wrongness can pass it.
//
// WHAT IS INDEPENDENT AND WHAT IS SHARED, stated precisely, because an oracle
// whose independence is overstated is worse than no oracle:
//
//   INDEPENDENT. vt_replay below is a BYTE-STREAM PARSER. It reads \e[H, \e[K,
//   \e[J, \e[<n>G, \e[<r>;<c>H, \r, \n, SGR and text, and applies them. The
//   renderer's own model is driven by paint_frame calling terminal primitives
//   directly, from the view, with no bytes involved. The two derivations have
//   nothing in common, so EVERY defect in the diff EMITTER -- a skipped cell, a
//   mis-costed cursor hop, a dropped SGR, half a wide cluster -- shows up here
//   as a screen mismatch. That is the bulk of the risk and it is fully covered.
//
//   SHARED. Both sides use screen.odin's terminal primitives (what \e[K does to
//   a row, what \n does at the bottom of the screen, where a wide cluster
//   lands). A misconception THERE would be baked into both sides and invisible
//   to this test. That gap is exactly what tools/difftest closes: it replays
//   the same two streams through pyte, which shares no code with this package.
//
// Both harnesses drive the same generator (difffuzz.odin), so a seed that fails
// in one can be replayed in the other.

// ---------------------------------------------------------------------------
// An independent VT100 replay: bytes in, cell grid out.
// ---------------------------------------------------------------------------
//
// Deliberately understands ONLY the repertoire the two renderers can emit, and
// deliberately ignores everything else rather than guessing. If a renderer ever
// starts emitting something new, this stops modelling it and the equivalence
// assertion fails -- which is the correct outcome: an escape the oracle does
// not understand is an escape the oracle cannot vouch for.
@(private = "file")
vt_replay :: proc(s: ^Screen, data: string, scratch: ^[dynamic]u8) {
	i   := 0
	seg := 0
	for i < len(data) {
		b := data[i]
		if b != ESC && b != '\r' && b != '\n' { i += 1; continue }
		if i > seg { screen_write(s, data[seg:i], scratch) }
		switch b {
		case '\r':
			screen_cr(s)
			i += 1
		case '\n':
			screen_index(s)
			i += 1
		case ESC:
			// skip_escape is width.odin's, i.e. the same scanner display_width
			// uses to decide what is zero width. Reusing it here is not a
			// shortcut: an oracle that disagreed with the width layer about
			// where an escape ENDS would mis-attribute the following bytes and
			// report differences that are its own.
			j := skip_escape(data, i)
			vt_escape(s, data[i:j], scratch)
			i = j
		}
		seg = i
	}
	if len(data) > seg { screen_write(s, data[seg:], scratch) }
}

@(private = "file")
vt_escape :: proc(s: ^Screen, seq: string, scratch: ^[dynamic]u8) {
	// OSC 8 -- a hyperlink open or close. Routed through the SAME entry point
	// screen_write uses (screen_escape), for the reason that proc's comment
	// gives: a replay that decided differently from the model about what an
	// escape means would report differences that are its own.
	//
	// Note this is the one escape family the replay understands that is not a
	// CSI, which is why it is tested before the seq[1] == '[' gate rather than
	// inside the switch below.
	if len(seq) >= 2 && seq[1] == ']' {
		screen_osc8(s, seq)
		return
	}
	if len(seq) < 3 || seq[1] != '[' { return }
	final := seq[len(seq) - 1]
	body  := seq[2:len(seq) - 1]
	priv  := len(body) > 0 && body[0] == '?'
	if priv { body = body[1:] }

	p1, p2, n := vt_params(body)

	switch final {
	case 'H', 'f':
		row := n >= 1 ? p1 : 1
		col := n >= 2 ? p2 : 1
		screen_goto(s, col - 1, row - 1)
	case 'G':
		col := n >= 1 ? p1 : 1
		screen_goto(s, col - 1, s.y)
	case 'd':
		row := n >= 1 ? p1 : 1
		screen_goto(s, s.x, row - 1)
	case 'A': screen_goto(s, s.x, s.y - max(n >= 1 ? p1 : 1, 1))
	case 'B': screen_goto(s, s.x, s.y + max(n >= 1 ? p1 : 1, 1))
	case 'C': screen_goto(s, s.x + max(n >= 1 ? p1 : 1, 1), s.y)
	case 'D': screen_goto(s, s.x - max(n >= 1 ? p1 : 1, 1), s.y)
	case 'K':
		how := n >= 1 ? p1 : 0
		switch how {
		case 0: screen_el0(s)
		case 1: screen_el1(s)
		case 2: screen_el2(s)
		}
	case 'J':
		how := n >= 1 ? p1 : 0
		switch how {
		case 0: screen_ed0(s)
		case:   screen_ed2(s)
		}
	case 'm':
		screen_sgr(s, seq, scratch)
	case 'h': if priv && p1 == 25 { s.hidden = false }
	case 'l': if priv && p1 == 25 { s.hidden = true }
	}
}

// Up to two numeric parameters out of a CSI body ("1;5", "", "25"). `n` is how
// many were actually present, which is what distinguishes "\e[H" (home) from
// "\e[1;1H" even though both land in the same place, and "\e[K" (mode 0) from
// "\e[2K".
@(private = "file")
vt_params :: proc(body: string) -> (p1, p2, n: int) {
	if len(body) == 0 { return 0, 0, 0 }
	cur   := 0
	seen  := false
	idx   := 0
	for i in 0 ..< len(body) {
		c := body[i]
		if c >= '0' && c <= '9' {
			cur = cur * 10 + int(c - '0')
			seen = true
			continue
		}
		if c == ';' {
			if idx == 0 { p1 = cur } else if idx == 1 { p2 = cur }
			idx += 1
			n = idx
			cur = 0
			seen = false
		}
	}
	if seen || idx == 0 {
		if idx == 0 { p1 = cur } else if idx == 1 { p2 = cur }
		n = idx + 1
	}
	return
}

// ---------------------------------------------------------------------------
// The equivalence assertion.
// ---------------------------------------------------------------------------

// The glyph the absolute oracle paints every cell with before a repaint, chosen
// so it cannot collide with anything the generator emits: TOK_ASCII, TOK_WIDE,
// TOK_COMBINING, TOK_PRECOMPOSED and TOK_EMOJI contain no U+00A7. One byte
// short of two, i.e. narrow, so painting it everywhere is a legal screen state
// rather than a grid of half-clusters the replay would then have to survive.
@(private = "file")
ORACLE_MARKER :: "§"

@(private = "file")
mark_every_cell :: proc(s: ^Screen) {
	// Appended once per frame and left in `text` as garbage; this Screen is
	// never screen_copy'd, so nothing compacts it -- bounded by frames x cells x
	// 2 bytes for the life of one case, which is kilobytes.
	off := u32(len(s.text))
	append(&s.text, ORACLE_MARKER)
	for i in 0 ..< len(s.cells) {
		s.cells[i] = Cell{off = off, len = u16(len(ORACLE_MARKER)), width = 1, style = 0, link = 0}
	}
}

@(private = "file")
first_marked_cell :: proc(s: ^Screen) -> (x, y: int, found: bool) {
	for i in 0 ..< len(s.cells) {
		if cell_bytes(s, s.cells[i]) == ORACLE_MARKER {
			return i % s.cols, i / s.cols, true
		}
	}
	return 0, 0, false
}

@(private = "file")
Oracle_Fail :: struct {
	seed:  u64,
	frame: int,
	row:   int,
	col:   int,
	what:  string,
	ref:   string,
	got:   string,
}

// Runs one generated case: the SAME frame sequence through .Full_Screen and
// through .Diff, replaying each renderer's bytes into its own screen AFTER
// EVERY FRAME and comparing there. Per-frame rather than only at the end,
// because a divergence that a later full repaint happens to heal is still a
// frame the user saw wrong.
@(private = "file")
oracle_case :: proc(seed: u64, pyte_safe := false, resizes := true) -> (ok: bool, fail: Oracle_Fail) {
	f: Diff_Fuzz
	// resizes: THIS harness opts in (see Diff_Fuzz.resizes for the contract).
	// It is the reason the loop below re-sizes both renderers and all three
	// replay screens on every frame. tools/difftest does not opt in, because
	// check.py has no RESIZE record and would compare against a pyte screen
	// still at the old size.
	diff_fuzz_init(&f, seed, pyte_safe, resizes)
	defer diff_fuzz_destroy(&f)

	vb := strings.builder_make();  defer strings.builder_destroy(&vb)
	rb := strings.builder_make();  defer strings.builder_destroy(&rb)
	db := strings.builder_make();  defer strings.builder_destroy(&db)

	r_ref: Renderer
	renderer_init(&r_ref, &rb, f.cols, f.rows, .Full_Screen)
	defer renderer_destroy(&r_ref)

	r_dif: Renderer
	renderer_init(&r_dif, &db, f.cols, f.rows, .Diff)
	defer renderer_destroy(&r_dif)

	// ONE style table for both screens, so a style index means the same thing on
	// both sides and the comparison is an integer compare. Legitimate: interning
	// is content-addressed (style_intern scans by bytes), so two identical SGR
	// strings arriving from two different streams collapse onto one index by
	// construction, and two different ones cannot.
	st: Style_Table
	style_table_init(&st)
	defer style_table_destroy(&st)

	// The LINK table, on exactly the same terms and legitimate for exactly the
	// same reason: interning is content-addressed, so one OSC 8 payload arriving
	// from two different streams collapses onto one index by construction.
	lt: Style_Table
	style_table_init(&lt)
	defer style_table_destroy(&lt)

	s_ref, s_dif: Screen
	screen_init(&s_ref, f.cols, f.rows, &st, &lt)
	screen_init(&s_dif, f.cols, f.rows, &st, &lt)
	defer screen_destroy(&s_ref)
	defer screen_destroy(&s_dif)

	// THE ABSOLUTE ORACLE, and the only one here that is not a comparison
	// between two renderers.
	//
	// Everything else in this file checks that .Diff reproduces .Full_Screen.
	// That is the invariant worth having, but it is blind by construction to any
	// defect in the frame's SHAPE -- which lines fit, where the \r\n goes,
	// whether the trailing \e[K is emitted -- because both modes get that shape
	// from the SAME paint_frame call and would be wrong together. F14 lived
	// exactly there: a line whose last cluster was wide and straddled the right
	// margin measured as flush with it, the \e[K was skipped, and the tail of
	// that row kept the previous frame's characters. Both oracles were green.
	//
	// So: a third screen, fed ONLY the repaint stream, whose every cell is
	// overwritten with a marker glyph before each frame. .Full_Screen writes or
	// erases every cell of every row it owns, every frame -- that is what
	// "absolute repaint" means -- so no marker may survive. One that does is a
	// cell the repaint believes it covered and did not.
	s_abs: Screen
	screen_init(&s_abs, f.cols, f.rows, &st, &lt)
	defer screen_destroy(&s_abs)

	scratch: [dynamic]u8
	defer delete(scratch)

	for frame in 0 ..< f.frames {
		view, cur := diff_fuzz_frame(&f, &vb)

		// The harness half of the resize contract. renderer_set_width/height are
		// no-ops when the value is unchanged, so this is unconditional rather
		// than gated on f.resized. The replay screens are re-created, which
		// blanks them -- sound because a resized frame is fully determined by
		// its own bytes in BOTH modes: .Diff forces a repaint (\e[0m\e[H\e[2J
		// then every cell), and .Full_Screen homes, writes every painted row and
		// \e[J's everything below.
		renderer_set_width(&r_ref, f.cols);  renderer_set_height(&r_ref, f.rows)
		renderer_set_width(&r_dif, f.cols);  renderer_set_height(&r_dif, f.rows)
		if s_ref.cols != f.cols || s_ref.rows != f.rows {
			screen_init(&s_ref, f.cols, f.rows, &st, &lt)
			screen_init(&s_dif, f.cols, f.rows, &st, &lt)
			screen_init(&s_abs, f.cols, f.rows, &st, &lt)
		}

		strings.builder_reset(&rb)
		strings.builder_reset(&db)
		renderer_render(&r_ref, view, cur)
		renderer_render(&r_dif, view, cur)

		vt_replay(&s_ref, strings.to_string(rb), &scratch)
		vt_replay(&s_dif, strings.to_string(db), &scratch)

		mark_every_cell(&s_abs)
		vt_replay(&s_abs, strings.to_string(rb), &scratch)
		if mx, my, marked := first_marked_cell(&s_abs); marked {
			return false, Oracle_Fail{
				seed = seed, frame = frame, row = my, col = mx,
				what = "stale cell (the repaint did not cover it)",
				ref  = fmt.aprintf("%q", ORACLE_MARKER),
				got  = fmt.aprintf("%dx%d view=%q", f.cols, f.rows, view),
			}
		}

		for y in 0 ..< f.rows {
			for x in 0 ..< f.cols {
				ca := screen_at(&s_ref, x, y)
				cb := screen_at(&s_dif, x, y)
				if cell_eq(&s_ref, ca, &s_dif, cb) { continue }
				return false, Oracle_Fail{
					seed = seed, frame = frame, row = y, col = x,
					what = "cell",
					ref  = fmt.aprintf("%q w=%d sgr=%q link=%q", cell_bytes(&s_ref, ca), ca.width, style_bytes(&st, ca.style), style_bytes(&lt, ca.link)),
					got  = fmt.aprintf("%q w=%d sgr=%q link=%q", cell_bytes(&s_dif, cb), cb.width, style_bytes(&st, cb.style), style_bytes(&lt, cb.link)),
				}
			}
		}

		// CURSOR, clamped into the screen on both sides. The model allows
		// x == cols (DECAWM pending wrap), a state no absolute move can
		// reproduce and none needs to: every frame that writes anything issues
		// its own absolute move first, so the distinction cannot survive into
		// the next frame's output. Everything else about the cursor -- row,
		// column, visibility -- is compared exactly.
		rx := min(s_ref.x, f.cols - 1)
		dx := min(s_dif.x, f.cols - 1)
		if rx != dx || s_ref.y != s_dif.y || s_ref.hidden != s_dif.hidden {
			return false, Oracle_Fail{
				seed = seed, frame = frame, row = s_ref.y, col = rx,
				what = "cursor",
				ref  = fmt.aprintf("(%d,%d) hidden=%v", rx, s_ref.y, s_ref.hidden),
				got  = fmt.aprintf("(%d,%d) hidden=%v", dx, s_dif.y, s_dif.hidden),
			}
		}
	}
	return true, Oracle_Fail{}
}

@(private = "file")
oracle_fail_free :: proc(f: Oracle_Fail) {
	delete(f.ref)
	delete(f.got)
}

// THE PRIMARY GATE. 500 generated frame sequences -- every one a pure function
// of its seed, so a failure reproduces by rerunning that seed and the seed is
// printed.
//
// THE EXPECTATION INVERTS UNDER AN INJECTED FAULT (render.odin's DIFF_FAULT).
// With no fault, or with the "repaint" control (a "diff" that is really a full
// repaint -- the case that proves the harness works BEFORE it has to catch
// anything), every case must pass. With any real fault injected, at least one
// case must FAIL, and this test fails if none does: an oracle that cannot catch
// a deliberately broken renderer is worthless, so "the oracle is non-vacuous"
// is itself a test rather than a claim in a report.
@(test)
test_diff_output_replays_to_the_same_screen_as_a_full_repaint :: proc(t: ^testing.T) {
	CASES :: 500

	failures  := 0
	first     : Oracle_Fail
	have_first := false
	for seed in u64(0) ..< u64(CASES) {
		ok, fail := oracle_case(seed)
		if ok { continue }
		failures += 1
		if !have_first {
			first      = fail
			have_first = true
		} else {
			oracle_fail_free(fail)
		}
	}
	defer if have_first { oracle_fail_free(first) }

	// no_pair_expand belongs with the clean builds, not with the faults: it
	// removes a guard that is provably inert against this model (see emit_row),
	// so "no divergence" is the CORRECT answer and asserting it here is what
	// pins that finding in place. If a future change to screen.odin ever breaks
	// the invariant that keeps a wide cluster's two halves changing together,
	// this build starts diverging and says so.
	when DIFF_FAULT == "" || DIFF_FAULT == "repaint" || DIFF_FAULT == "no_pair_expand" {
		if failures != 0 {
			testing.expectf(t, false,
				"%d/%d fuzz cases diverged.\n  first: seed=%d frame=%d %s at (row %d, col %d)\n    repaint: %s\n       diff: %s",
				failures, CASES, first.seed, first.frame, first.what, first.row, first.col, first.ref, first.got)
		}
	} else {
		testing.expectf(t, failures > 0,
			"INJECTED FAULT %q produced NO divergence in %d cases -- the oracle is vacuous",
			DIFF_FAULT, CASES)
		if failures > 0 {
			fmt.printfln(
				"[oracle non-vacuity] fault %q caught: %d/%d cases diverged; first seed=%d frame=%d %s at (row %d, col %d) repaint=%s diff=%s",
				DIFF_FAULT, failures, CASES, first.seed, first.frame, first.what, first.row, first.col, first.ref, first.got)
		}
	}
}

// The pyte-safe subset, run on the gate too. tools/difftest replays exactly
// these seeds through pyte; running them here as well means a failure there can
// always be bisected against a failure (or a pass) here, which is what tells
// you whether the bug is in the renderer or in this package's disagreement with
// pyte about how wide something is.
@(test)
test_diff_oracle_pyte_safe_subset :: proc(t: ^testing.T) {
	CASES :: 200
	failures := 0
	first: Oracle_Fail
	have_first := false
	for seed in u64(0) ..< u64(CASES) {
		ok, fail := oracle_case(seed, pyte_safe = true)
		if ok { continue }
		failures += 1
		if !have_first { first = fail; have_first = true } else { oracle_fail_free(fail) }
	}
	defer if have_first { oracle_fail_free(first) }

	when DIFF_FAULT == "" || DIFF_FAULT == "repaint" || DIFF_FAULT == "no_pair_expand" {
		if failures != 0 {
			testing.expectf(t, false,
				"%d/%d pyte-safe cases diverged; first seed=%d frame=%d %s at (row %d, col %d) repaint=%s diff=%s",
				failures, CASES, first.seed, first.frame, first.what, first.row, first.col, first.ref, first.got)
		}
	}
}

// ---------------------------------------------------------------------------
// Byte counts -- the numbers the mode exists to move.
// ---------------------------------------------------------------------------

@(private = "file")
Diff_Harness :: struct {
	b: strings.Builder,
	r: Renderer,
}

@(private = "file")
harness_make :: proc(cols, rows: int) -> ^Diff_Harness {
	h := new(Diff_Harness)
	h.b = strings.builder_make()
	renderer_init(&h.r, &h.b, cols, rows, .Diff)
	return h
}

@(private = "file")
harness_free :: proc(h: ^Diff_Harness) {
	renderer_destroy(&h.r)
	strings.builder_destroy(&h.b)
	free(h)
}

// Renders one frame and returns its bytes (valid until the next call).
@(private = "file")
frame :: proc(h: ^Diff_Harness, view: string, cur := Cursor{}) -> string {
	strings.builder_reset(&h.b)
	renderer_render(&h.r, view, cur)
	return strings.to_string(h.b)
}

@(test)
test_diff_identical_frame_costs_zero_bytes :: proc(t: ^testing.T) {
	// THE HEADLINE. render_test.odin's
	// test_identical_frame_costs_a_full_repaint pins the inline renderer's 14
	// bytes for exactly this frame and says "T3's diff renderer must reduce
	// this to 0 bytes, and this test is what will prove it changed". This is
	// the other half of that sentence. Neither test replaces the other: the
	// inline renderer is unchanged and still costs 14.
	h := harness_make(20, 5); defer harness_free(h)

	frame(h, "same")
	testing.expect_value(t, len(frame(h, "same")), 0)
	testing.expect_value(t, len(frame(h, "same")), 0)

	// With a declared cursor too -- the DECTCEM pair is 12 bytes and must not
	// be emitted around a frame that paints nothing.
	frame(h, "same", Cursor{line = 0, col = 2, show = true})
	testing.expect_value(t, len(frame(h, "same", Cursor{line = 0, col = 2, show = true})), 0)
}

@(test)
test_diff_one_changed_cell_costs_a_move_and_that_cell :: proc(t: ^testing.T) {
	h := harness_make(20, 5); defer harness_free(h)
	frame(h, "hello world\nsecond line")
	got := frame(h, "hellX world\nsecond line")
	// CUP to (row 1, col 5) + "X", then the frame's trailing cursor park.
	//
	// THE TRAILING \e[3;1H IS NOT OVERHEAD THIS MODE INVENTED. The full-screen
	// repaint leaves the terminal's cursor on the row below the frame (its
	// \r\n\e[J does), and "the same screen" is not the same screen if the caret
	// the user can see is somewhere else. An app that DECLARES a cursor pays
	// nothing for it -- the park IS the placement (see
	// test_diff_cursor_placement_is_absolute_and_free_when_it_does_not_move).
	testing.expect_value(t, got, "\e[1;5HX\e[3;1H")
	testing.expect_value(t, len(got), 13)

	// The same edit with a declared cursor: the move is the caret placement, so
	// one changed cell really does cost a move plus that cell.
	h2 := harness_make(20, 5); defer harness_free(h2)
	cur := Cursor{line = 0, col = 4, show = true}
	frame(h2, "hello world\nsecond line", cur)
	got2 := frame(h2, "hellX world\nsecond line", cur)
	// Not even a move for the X: the previous frame parked the caret at exactly
	// the cell that changed, so the whole edit is one byte plus the DECTCEM pair.
	testing.expect_value(t, got2, "\e[?25lX\e[5G\e[?25h")
}

@(test)
test_diff_five_changed_cells_on_one_line :: proc(t: ^testing.T) {
	h := harness_make(20, 5); defer harness_free(h)
	frame(h, "abcdefghij\nunchanged")
	got := frame(h, "abcdeFGHIJ\nunchanged")
	testing.expect_value(t, got, "\e[1;6HFGHIJ\e[3;1H")
	testing.expect_value(t, len(got), 17)
}

@(test)
test_diff_five_scattered_cells_hop_or_rewrite_by_cost :: proc(t: ^testing.T) {
	h := harness_make(20, 5); defer harness_free(h)
	frame(h, "aaaaaaaaaaaaaaaaaaaa")
	// Changes at columns 0, 2, 3, 8, 9, 10, 19. The unchanged gaps are 1 cell
	// (columns 1), 4 cells (4-7) and 8 cells (11-18). GAP_MERGE_MAX is 4, so the
	// first two are REWRITTEN -- a CHA costs 5 bytes and rewriting 4 unchanged
	// narrow cells costs 4 -- and the 8-cell gap is hopped.
	got := frame(h, "bab aaaabb aaaaaaaab")
	testing.expect_value(t, got, "\e[1;1Hbab aaaabb \e[20Gb\e[2;1H")
}

@(test)
test_diff_full_screen_change_costs_about_one_repaint :: proc(t: ^testing.T) {
	h := harness_make(20, 5); defer harness_free(h)
	a := "aaaaaaaaaaaaaaaaaaaa\naaaaaaaaaaaaaaaaaaaa\naaaaaaaaaaaaaaaaaaaa\naaaaaaaaaaaaaaaaaaaa\naaaaaaaaaaaaaaaaaaaa"
	b := "bbbbbbbbbbbbbbbbbbbb\nbbbbbbbbbbbbbbbbbbbb\nbbbbbbbbbbbbbbbbbbbb\nbbbbbbbbbbbbbbbbbbbb\nbbbbbbbbbbbbbbbbbbbb"
	frame(h, a)
	got := frame(h, b)
	// 5 rows x (CUP + 20 cells) + a final cursor move. Within a handful of bytes
	// of the repaint's own cost -- a full-screen change is where a diff renderer
	// has nothing to save, and it must not COST anything meaningful either.
	testing.expectf(t, len(got) <= 140, "full-screen change cost %d bytes", len(got))
	testing.expectf(t, len(got) >= 100, "suspiciously cheap full-screen change: %d bytes", len(got))
}

@(test)
test_diff_first_frame_paints_from_a_known_blank_screen :: proc(t: ^testing.T) {
	h := harness_make(10, 3); defer harness_free(h)
	got := frame(h, "hi")
	// \e[?25l first: this mode owns the viewport and hides the caret for as long
	// as it does -- see render_test.odin's test_full_screen_hides_the_caret_it
	// _owns, whose rule this is deliberately identical to (the oracle compares
	// cursor VISIBILITY between the two modes, so a difference here would be a
	// divergence of this file's own invention).
	// Then \e[0m: \e[2J erases with the ACTIVE background, and on the very
	// first frame this process has no idea what that is.
	testing.expect_value(t, got, "\e[?25l" + "\e[0m\e[H\e[2J" + "hi" + "\e[2;1H")
}

@(test)
test_diff_clearing_a_tail_uses_el_when_it_beats_writing_spaces :: proc(t: ^testing.T) {
	h := harness_make(20, 3); defer harness_free(h)
	frame(h, "aaaaaaaaaaaaaaaaaaaa")
	got := frame(h, "aaaa")
	// 16 cells become blank: a move plus \e[K, not 16 spaces.
	testing.expect_value(t, got, "\e[1;5H\e[K\e[2;1H")
}

@(test)
test_diff_short_tail_writes_spaces_rather_than_el :: proc(t: ^testing.T) {
	h := harness_make(20, 3); defer harness_free(h)
	frame(h, "aaaa")
	got := frame(h, "aa")
	// Only 2 cells change; \e[K would cost 3 bytes to save 2.
	testing.expect_value(t, got, "\e[1;3H  \e[2;1H")
}

// ---------------------------------------------------------------------------
// Wide cells.
// ---------------------------------------------------------------------------

@(test)
test_diff_overwriting_the_left_half_of_a_wide_cell_repaints_both_columns :: proc(t: ^testing.T) {
	h := harness_make(10, 2); defer harness_free(h)
	frame(h, "界界界")
	// Column 0 becomes "a"; column 1 was the continuation half of the first 界
	// and MUST be repainted too -- writing "a" over the left half leaves the
	// right half in a terminal-defined state.
	got := frame(h, "a界界")
	// Column 5 too: it was the continuation half of the last 界, and the frame
	// now ends one column earlier.
	testing.expect_value(t, got, "\e[1;1Ha界界 \e[2;1H")
}

@(test)
test_diff_overwriting_the_right_half_of_a_wide_cell_repaints_the_head :: proc(t: ^testing.T) {
	h := harness_make(10, 2); defer harness_free(h)
	frame(h, "ab界cd")
	// The 界 sits at columns 2-3. Replacing it with "xy" changes column 2 and
	// column 3; column 2 held the head, so both are dirty and both are written.
	got := frame(h, "abxycd")
	testing.expect_value(t, got, "\e[1;3Hxy\e[2;1H")
}

@(test)
test_diff_wide_replaced_by_narrow_leaves_no_half_glyph :: proc(t: ^testing.T) {
	h := harness_make(10, 2); defer harness_free(h)
	frame(h, "界abc")
	got := frame(h, "xabc")
	// The wide cluster occupied columns 0-1. "x" takes column 0; column 1 now
	// holds the "a" that used to be at column 2, and so on -- every cell to the
	// right shifted, so the whole prefix is rewritten and the tail cleared.
	// Only one trailing cell frees up, so it is written as a space -- \e[K would
	// cost 3 bytes to save 1.
	testing.expect_value(t, got, "\e[1;1Hxabc \e[2;1H")
}

@(test)
test_diff_narrow_replaced_by_wide_claims_both_columns :: proc(t: ^testing.T) {
	h := harness_make(10, 2); defer harness_free(h)
	frame(h, "xabc")
	got := frame(h, "界abc")
	testing.expect_value(t, got, "\e[1;1H界abc\e[2;1H")
}

@(test)
test_diff_wide_cell_untouched_when_only_its_neighbour_changed :: proc(t: ^testing.T) {
	h := harness_make(10, 2); defer harness_free(h)
	frame(h, "界ab")
	got := frame(h, "界aX")
	// The wide cluster is NOT repainted -- the expansion drags in a pair's other
	// half only when one half actually changed.
	testing.expect_value(t, got, "\e[1;4HX\e[2;1H")
}

@(test)
test_diff_wide_cluster_wrapping_at_the_margin :: proc(t: ^testing.T) {
	h := harness_make(5, 3); defer harness_free(h)
	// 界界 fills columns 0-3; the third 界 lands on column 4, the last one.
	frame(h, "界界界")
	got := frame(h, "界界日")
	testing.expect_value(t, got, "\e[1;5H日\e[2;1H")
}

// ---------------------------------------------------------------------------
// Styling.
// ---------------------------------------------------------------------------

@(test)
test_diff_style_run_that_grows :: proc(t: ^testing.T) {
	h := harness_make(20, 2); defer harness_free(h)
	frame(h, "\e[31mab\e[0mcdef")
	got := frame(h, "\e[31mabc\e[0mdef")
	// Only "c" changed -- from default to red. The style must travel with it,
	// and the frame closes it: see render_diff's frame-closing reset for why a
	// frame may never end with the terminal still styled.
	testing.expect_value(t, got, "\e[1;3H\e[31mc\e[0m\e[2;1H")
}

@(test)
test_diff_style_run_that_shrinks :: proc(t: ^testing.T) {
	h := harness_make(20, 2); defer harness_free(h)
	frame(h, "\e[31mabc\e[0mdef")
	got := frame(h, "\e[31mab\e[0mcdef")
	// "c" goes back to default. The emitter is sitting at the default already
	// (nothing styled has been written this frame), so no \e[0m is needed --
	// only the cell.
	testing.expect_value(t, got, "\e[1;3Hc\e[2;1H")
}

@(test)
test_diff_style_run_that_moves :: proc(t: ^testing.T) {
	h := harness_make(20, 2); defer harness_free(h)
	frame(h, "\e[31mab\e[0mcdef")
	got := frame(h, "ab\e[31mcd\e[0mef")
	// "ab" loses red, "cd" gains it. Two style transitions, and the second one
	// goes through \e[0m first because the emitter is mid-style. The trailing
	// \e[0m is the frame-closing reset, not a third transition.
	testing.expect_value(t, got, "\e[1;1Hab\e[31mcd\e[0m\e[2;1H")
}

@(test)
test_diff_style_is_not_re_emitted_between_cells_that_share_it :: proc(t: ^testing.T) {
	h := harness_make(20, 2); defer harness_free(h)
	frame(h, "\e[31maaaa\e[0m")
	got := frame(h, "\e[31mbbbb\e[0m")
	// ONE \e[31m for all four cells: within a frame, cells that share a style
	// do not re-emit it. That is what this test is about, and it still holds.
	//
	// What changed: the emitter's SGR state no longer persists ACROSS frames.
	// It used to, and this expectation used to have no \e[31m at all because
	// the previous frame left the terminal red. render_diff now closes every
	// frame with a reset -- a frame whose last cell is styled would otherwise
	// leave the terminal (and the user's shell after exit) in that style -- so
	// the first styled cell of each frame re-establishes it. That costs these
	// few bytes on frames which already change cells, and buys back nothing on
	// idle frames, which still cost exactly 0.
	testing.expect_value(t, got, "\e[1;1H\e[31mbbbb\e[0m\e[2;1H")
}

@(test)
test_diff_el_is_not_used_to_clear_a_styled_tail :: proc(t: ^testing.T) {
	h := harness_make(12, 2); defer harness_free(h)
	// The line's own \e[K runs with red still active, so the erased tail of THAT
	// ROW is RED blanks. \e[K cannot be used to produce them -- whether an erase
	// records anything but the background is terminal-dependent -- so they are
	// written as real spaces.
	frame(h, "abcdefgh")
	got := frame(h, "\e[41mab")
	// ROW 1 IS NOT TOUCHED, and that is the behaviour change worth reading.
	//
	// It used to be twelve red spaces plus a \r, because the trailing \e[J ran
	// with the view's leftover red still active and the model recorded a screen
	// whose every unwritten row was red. That is the whole of finding F03/F05/
	// F33 in one frame: one unclosed SGR at the end of a view flooded every row
	// BELOW the frame, .Diff wrote the flood out as literal spaces (so it needed
	// no BCE support and happened on every terminal), the leaked style was baked
	// into the cell model and carried into the next frame by screen_copy, and
	// screen_sgr then re-accumulated onto it -- +16 emitted bytes per frame,
	// forever, until the 1 MiB style budget blew and forced a full repaint.
	//
	// paint_frame now closes the pen before the trailing ED, in the byte stream
	// and in the model together (frame_state_reset), so the rows below a frame are
	// erased at the DEFAULT background. Row 1 was already default blanks, so it
	// costs nothing at all here. The per-line \e[K deliberately still carries the
	// view's pen -- that is how a view paints a bar out to the margin, and both
	// modes model it identically.
	//
	// The trailing \e[0m is the frame-closing reset: this frame ends with red
	// still active on the wire, and leaving it set would tint whatever is
	// written next.
	testing.expect_value(t, got,
		"\e[1;1H\e[41mab" + "          " + "\e[0m" + "\e[2;1H")
	testing.expect(t, !strings.contains(got, "\e[K"), "a styled tail must not be cleared with EL")
}

@(test)
test_diff_a_styled_cell_survives_an_unrelated_change_elsewhere :: proc(t: ^testing.T) {
	h := harness_make(20, 3); defer harness_free(h)
	frame(h, "\e[31mred\e[0m plain\nsecond")
	got := frame(h, "\e[31mred\e[0m plain\nsecoXd")
	testing.expect_value(t, got, "\e[2;5HX\e[3;1H")
}

// ---------------------------------------------------------------------------
// OSC 8 hyperlinks (T3-C).
// ---------------------------------------------------------------------------
//
// THE BUG THESE CLOSE, stated once here rather than in each test: before T3-C
// the cell model tracked SGR and nothing else, so the diff renderer consumed an
// OSC 8 hyperlink for width and dropped it. A view containing a link rendered as
// unlinked text, and -- worse -- a frame in which ONLY the destination changed
// produced zero bytes, because every cell compared equal. Silent data loss on
// both counts.
//
// test_diff_a_link_whose_url_changes_repaints_the_run is the one that fails
// loudest against the old code: it asserts a non-empty frame where the old
// renderer emitted nothing at all.

@(private = "file")
LINK_A :: "\e]8;;https://example.com/a\e\\"
@(private = "file")
LINK_B :: "\e]8;;https://example.com/b\e\\"
@(private = "file")
LINK_OFF :: "\e]8;;\e\\"

@(test)
test_diff_a_hyperlink_that_appears_is_opened_and_closed :: proc(t: ^testing.T) {
	h := harness_make(20, 3); defer harness_free(h)
	frame(h, "plain")
	got := frame(h, LINK_A + "link" + LINK_OFF)
	// "plain" -> "link": five cells change (four glyphs plus the freed one).
	// The four linked cells open the link once between them -- a hyperlink is
	// established per RUN, not per cell, exactly as a style is -- and the blank
	// that follows closes it because its own link index is 0.
	testing.expect_value(t, got, "\e[1;1H" + LINK_A + "link" + LINK_OFF + " " + "\e[2;1H")
}

@(test)
test_diff_a_link_whose_url_changes_repaints_the_run :: proc(t: ^testing.T) {
	h := harness_make(20, 3); defer harness_free(h)
	frame(h, LINK_A + "abc" + LINK_OFF)
	// SAME GLYPHS, SAME STYLE, DIFFERENT DESTINATION. This is the case a
	// style-only cell model cannot see: every cell's bytes and SGR are
	// identical, so screens_differ answered false and the frame cost 0 bytes
	// while the user kept the old link. cell_eq now compares `link`.
	got := frame(h, LINK_B + "abc" + LINK_OFF)
	testing.expect_value(t, got, "\e[1;1H" + LINK_B + "abc" + LINK_OFF + "\e[2;1H")
	testing.expect(t, len(got) > 0, "a changed hyperlink destination must not cost zero bytes")
}

@(test)
test_diff_a_link_whose_id_changes_repaints_the_run :: proc(t: ^testing.T) {
	h := harness_make(20, 3); defer harness_free(h)
	SAME_URL_ID_1 :: "\e]8;id=1;https://example.com\e\\"
	SAME_URL_ID_2 :: "\e]8;id=2;https://example.com\e\\"
	frame(h, SAME_URL_ID_1 + "abc" + LINK_OFF)
	// Same URL, different link IDENTITY -- two runs with different ids are two
	// separate links to the terminal even when they point at the same place.
	// This is why screen_osc8 interns params AND URI rather than the URI alone.
	got := frame(h, SAME_URL_ID_2 + "abc" + LINK_OFF)
	testing.expect_value(t, got, "\e[1;1H" + SAME_URL_ID_2 + "abc" + LINK_OFF + "\e[2;1H")
}

@(test)
test_diff_an_unchanged_hyperlink_frame_still_costs_zero_bytes :: proc(t: ^testing.T) {
	h := harness_make(20, 3); defer harness_free(h)
	frame(h, LINK_A + "abc" + LINK_OFF + " tail")
	// The 0-byte contract is the whole reason .Diff exists and links must not
	// erode it: the link escapes are STATE, tracked per cell, not bytes
	// re-sent per frame.
	testing.expect_value(t, len(frame(h, LINK_A + "abc" + LINK_OFF + " tail")), 0)
	testing.expect_value(t, len(frame(h, LINK_A + "abc" + LINK_OFF + " tail")), 0)
}

@(test)
test_diff_a_hyperlink_that_disappears_is_closed :: proc(t: ^testing.T) {
	h := harness_make(20, 3); defer harness_free(h)
	frame(h, LINK_A + "abc" + LINK_OFF)
	got := frame(h, "abc")
	// Same three glyphs, now unlinked. The emitter is at link 0 already (the
	// previous frame closed), so all this costs is the three cells.
	testing.expect_value(t, got, "\e[1;1Habc\e[2;1H")
}

@(test)
test_diff_closes_a_link_left_open_at_the_end_of_a_frame :: proc(t: ^testing.T) {
	h := harness_make(8, 2); defer harness_free(h)
	frame(h, "xxxx")
	// A view that opens a link and never closes it. Left as-is, the terminal
	// would keep linkifying -- the next frame, the app's own writes, and the
	// user's shell after exit. render_diff closes every frame it ends styled or
	// linked, for the same reason it closes SGR.
	got := frame(h, LINK_A + "ab")
	testing.expect(t, strings.contains(got, LINK_OFF),
		"a frame that ends inside a hyperlink must close it")
	// The close lands where it lands for a reason worth reading: columns 2-3
	// held "xx" and are now blank at link 0, so diff_link(0) closes the link to
	// paint THEM -- the frame-closing reset then has nothing left to do. Either
	// way the terminal is not left linkified, which is the property.
	testing.expect_value(t, got, "\e[1;1H" + LINK_A + "ab" + LINK_OFF + "  " + "\e[2;1H")
}

@(test)
test_diff_never_clears_a_linked_tail_with_el :: proc(t: ^testing.T) {
	h := harness_make(20, 2); defer harness_free(h)
	frame(h, "abcdefghijklmnopqrst")
	// 18 trailing blanks, all INSIDE the link (the view never closes it). \e[K
	// would erase them, and an erased cell carries no link (screen.odin's
	// blank_cell) -- so using EL here would drop a hyperlink the frame asked
	// for. Real spaces under an open link instead. Same rule, and the same one
	// place it is scoped down, as the styled-tail case.
	got := frame(h, LINK_A + "ab" + "                  ")
	testing.expect(t, !strings.contains(got, "\e[K"), "a linked tail must not be cleared with EL")
	testing.expect_value(t, got,
		"\e[1;1H" + LINK_A + "ab" + "                  " + LINK_OFF + "\e[2;1H")
}

@(test)
test_diff_closes_the_link_before_an_el :: proc(t: ^testing.T) {
	h := harness_make(20, 2); defer harness_free(h)
	frame(h, "aaaaaaaaaaaaaaaaaaaa")
	// Four linked cells, then a 16-cell default blank tail -- long enough that
	// \e[K wins. The close MUST precede the erase: whether a terminal records
	// an open hyperlink on the cells \e[K blanks is not fixed by any standard,
	// so the emitter refuses to find out.
	got := frame(h, LINK_A + "bbbb" + LINK_OFF)
	testing.expect_value(t, got, "\e[1;1H" + LINK_A + "bbbb" + LINK_OFF + "\e[K" + "\e[2;1H")
	// And the ordering, asserted directly rather than only implied by the
	// byte-exact expectation above.
	close_at := strings.index(got, LINK_OFF)
	el_at    := strings.index(got, "\e[K")
	testing.expect(t, close_at >= 0 && el_at >= 0 && close_at < el_at,
		"the hyperlink must be closed BEFORE the \\e[K that erases the tail")
}

@(test)
test_diff_a_hyperlink_survives_an_unrelated_change_elsewhere :: proc(t: ^testing.T) {
	h := harness_make(20, 3); defer harness_free(h)
	frame(h, LINK_A + "abc" + LINK_OFF + "\nsecond")
	got := frame(h, LINK_A + "abc" + LINK_OFF + "\nsecoXd")
	// Row 0 is untouched, link and all: a hyperlink costs nothing to KEEP.
	testing.expect_value(t, got, "\e[2;5HX\e[3;1H")
}

@(test)
test_diff_a_link_and_a_style_are_independent_planes :: proc(t: ^testing.T) {
	h := harness_make(20, 3); defer harness_free(h)
	frame(h, LINK_A + "\e[31mabc\e[0m" + LINK_OFF)
	// Only the COLOUR changes; the link is identical. Both attributes must be
	// re-established for the rewritten cells (the emitter starts each frame at
	// the default for both), and neither may be confused for the other.
	got := frame(h, LINK_A + "\e[32mabc\e[0m" + LINK_OFF)
	testing.expect_value(t, got, "\e[1;1H\e[32m" + LINK_A + "abc" + "\e[0m" + LINK_OFF + "\e[2;1H")
}

@(test)
test_diff_a_hyperlink_survives_a_wrap :: proc(t: ^testing.T) {
	h := harness_make(4, 3); defer harness_free(h)
	frame(h, "xxxxxxxx")
	// Eight linked columns on a four-column screen: the link spans a wrap, so
	// the second physical row's cells carry it too and the emitter has to
	// re-establish it after the CUP to row 1 (it never assumes the terminal
	// kept anything across a cursor move).
	got := frame(h, LINK_A + "abcdefgh" + LINK_OFF)
	testing.expect_value(t, got,
		"\e[1;1H" + LINK_A + "abcd" + "\e[2;1H" + "efgh" + LINK_OFF + "\e[3;1H")
}

@(test)
test_diff_repaint_prologue_closes_a_link_only_once_links_are_in_play :: proc(t: ^testing.T) {
	// A program that never uses hyperlinks must emit byte-for-byte what it
	// emitted before T3-C -- that is the entire compatibility guarantee, and
	// diff_links_in_play is what delivers it.
	h := harness_make(10, 3); defer harness_free(h)
	testing.expect_value(t, frame(h, "hi"), "\e[?25l" + "\e[0m\e[H\e[2J" + "hi" + "\e[2;1H")

	// Once a link HAS been seen, a forced repaint closes any link the previous
	// occupant of the terminal may have left open -- \e[0m does not do it (SGR
	// and OSC 8 are independent attribute planes) and \e[2J does not either.
	h2 := harness_make(10, 3); defer harness_free(h2)
	got := frame(h2, LINK_A + "hi" + LINK_OFF)
	testing.expect_value(t, got, "\e[?25l" + "\e[0m" + LINK_OFF + "\e[H\e[2J" + LINK_A + "hi" + LINK_OFF + "\e[2;1H")
}

@(test)
test_diff_renderer_clear_closes_an_open_link :: proc(t: ^testing.T) {
	h := harness_make(10, 3); defer harness_free(h)
	// A frame that ends inside a link already closes it (see
	// test_diff_closes_a_link_left_open_at_the_end_of_a_frame), so reach
	// renderer_clear with emit_link set by clearing mid-frame: drive one frame
	// whose link IS closed, then assert clear emits no stray close.
	frame(h, LINK_A + "ab" + LINK_OFF)
	strings.builder_reset(&h.b)
	renderer_clear(&h.r)
	// \e[?25h: the frame above hid the caret (this mode owns the viewport) and
	// renderer_clear is where that ownership ends.
	testing.expect_value(t, strings.to_string(h.b), "\e[?25h" + "\e[H\e[J")
}

// A TRUNCATED ESCAPE IS A CONTRACT VIOLATION, so this test asserts what a
// RELEASE build does with one and is compiled out of a strict build, where the
// correct behaviour is the panic contract_test.odin pins instead. The two are
// the same rule seen from both sides: a debug build refuses the input, a
// release build degrades in the one direction that cannot open a link nobody
// asked for.
when !DIFF_STRICT {
@(test)
test_diff_an_unterminated_osc8_changes_nothing :: proc(t: ^testing.T) {
	h := harness_make(10, 2); defer harness_free(h)
	frame(h, "xx")
	// No ST, no BEL: the terminal is still waiting for the rest of this
	// sequence and will eat whatever is written next. Acting on half a URI
	// would open a link nobody asked for, so the model treats it as no link
	// change at all -- the same answer width.odin gives a truncated escape.
	//
	// The fragment is at the END of the view on purpose. An unterminated OSC
	// swallows everything after it (skip_escape returns the end of the string,
	// deliberately -- see its doc comment), so text placed after one is
	// consumed as payload rather than painted. That is pre-existing width-layer
	// behaviour, not something hyperlinks introduced, and putting the fragment
	// first would test that instead of this.
	got := frame(h, "ab" + "\e]8;;https://trunca")
	testing.expect(t, !strings.contains(got, "\e]8"), "an unterminated OSC 8 must not become a link")
	testing.expect_value(t, got, "\e[1;1Hab\e[2;1H")
}
}

@(test)
test_diff_accepts_bel_terminated_osc8_on_the_way_in :: proc(t: ^testing.T) {
	h := harness_make(10, 2); defer harness_free(h)
	frame(h, "xx")
	// xterm's BEL convention is as common in the wild as the standard ST, so
	// it is accepted on the way IN -- and normalised to ST on the way OUT, so
	// there is exactly one spelling on the wire to reason about.
	got := frame(h, "\e]8;;https://example.com/a\a" + "ab" + "\e]8;;\a")
	testing.expect_value(t, got, "\e[1;1H" + LINK_A + "ab" + LINK_OFF + "\e[2;1H")
}

// ---------------------------------------------------------------------------
// Mode isolation and lifecycle.
// ---------------------------------------------------------------------------

@(test)
test_diff_without_a_known_size_falls_back_to_the_full_screen_bytes :: proc(t: ^testing.T) {
	// No width/height: nothing to model. The frame must be .Full_Screen's, byte
	// for byte -- verified against a real .Full_Screen renderer rather than a
	// transcribed literal, so the two cannot drift.
	bd := strings.builder_make(); defer strings.builder_destroy(&bd)
	bf := strings.builder_make(); defer strings.builder_destroy(&bf)

	rd: Renderer
	renderer_init(&rd, &bd, 0, 0, .Diff)
	defer renderer_destroy(&rd)
	rf: Renderer
	renderer_init(&rf, &bf, 0, 0, .Full_Screen)

	for view in ([]string{"one\ntwo", "one\ntwo", "three"}) {
		strings.builder_reset(&bd)
		strings.builder_reset(&bf)
		renderer_render(&rd, view, Cursor{line = 0, col = 1, show = true})
		renderer_render(&rf, view, Cursor{line = 0, col = 1, show = true})
		testing.expect_value(t, strings.to_string(bd), strings.to_string(bf))
	}
}

@(test)
test_diff_repaints_in_full_after_a_resize :: proc(t: ^testing.T) {
	h := harness_make(20, 4); defer harness_free(h)
	frame(h, "hello")
	renderer_set_width(&h.r, 10)
	got := frame(h, "hello")
	// Identical view, but every cell's position is now a different thing. The
	// model is discarded and the screen repainted from a real \e[2J.
	testing.expect_value(t, got, "\e[0m\e[H\e[2J" + "hello" + "\e[2;1H")
	// ... and the frame after it is free again.
	testing.expect_value(t, len(frame(h, "hello")), 0)
}

@(test)
test_diff_clear_blanks_the_screen_and_resyncs_the_model :: proc(t: ^testing.T) {
	h := harness_make(10, 3); defer harness_free(h)
	frame(h, "abc")
	strings.builder_reset(&h.b)
	renderer_clear(&h.r)
	testing.expect_value(t, strings.to_string(h.b), "\e[?25h" + "\e[H\e[J")
	// The model now says "blank", so the next frame repaints its content --
	// without a \e[2J prologue, because renderer_clear already did the erasing.
	got := frame(h, "abc")
	// No leading move: renderer_clear left the cursor at home and the model
	// knows it, so the first cell needs no positioning at all. The \e[?25l is
	// back because renderer_clear showed the caret again.
	testing.expect_value(t, got, "\e[?25l" + "abc\e[2;1H")
}

@(test)
test_diff_renderer_destroy_is_safe_twice_and_on_unused_renderers :: proc(t: ^testing.T) {
	r: Renderer
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	renderer_init(&r, &b, 10, 3, .Diff)
	renderer_destroy(&r)
	renderer_destroy(&r)

	// A renderer that never rendered allocated nothing.
	r2: Renderer
	renderer_init(&r2, &b, 10, 3, .Diff)
	renderer_destroy(&r2)

	// And the other two modes never allocate at all.
	r3: Renderer
	renderer_init(&r3, &b, 10, 3, .Inline)
	renderer_render(&r3, "x")
	renderer_destroy(&r3)
}

@(test)
test_diff_content_taller_than_the_viewport_is_truncated_like_full_screen :: proc(t: ^testing.T) {
	h := harness_make(10, 2); defer harness_free(h)
	got := frame(h, "one\ntwo\nthree")
	// Two rows of viewport: "three" never appears. Same policy render_full_screen
	// documents -- scrolling is the application's job.
	testing.expect_value(t, got, "\e[?25l" + "\e[0m\e[H\e[2J" + "one" + "\e[2;1Htwo")
	testing.expect_value(t, len(frame(h, "one\ntwo\nthree")), 0)
	testing.expect_value(t, frame(h, "one\ntwo\nfour"), "")
}

@(test)
test_diff_cursor_placement_is_absolute_and_free_when_it_does_not_move :: proc(t: ^testing.T) {
	h := harness_make(20, 4); defer harness_free(h)
	frame(h, "hello\nworld", Cursor{line = 1, col = 3, show = true})
	// Same frame, same cursor: nothing at all.
	testing.expect_value(t, frame(h, "hello\nworld", Cursor{line = 1, col = 3, show = true}), "")
	// Cursor moves, content does not: a hide/show pair around one CUP.
	got := frame(h, "hello\nworld", Cursor{line = 0, col = 1, show = true})
	testing.expect_value(t, got, "\e[?25l\e[1;2H\e[?25h")
}

@(test)
test_diff_cursor_column_after_a_wide_rune_is_a_display_column :: proc(t: ^testing.T) {
	h := harness_make(20, 3); defer harness_free(h)
	// "界" is 2 columns, so a caret after it is at display column 2 -- the same
	// value display_width would give, and the same one the full-screen path
	// computes through the shared cursor_cell.
	got := frame(h, "界x", Cursor{line = 0, col = 2, show = true})
	// CHA, not CUP: the caret is on the row the emitter is already on.
	testing.expect_value(t, got, "\e[?25l" + "\e[0m\e[H\e[2J" + "界x" + "\e[3G" + "\e[?25h")
}

@(test)
test_diff_leaves_the_other_two_modes_untouched :: proc(t: ^testing.T) {
	// The mode enum grew a third member; neither of the other two may have
	// acquired a byte. render_test.odin pins both in detail -- this is the
	// cheap standing check that .Diff's existence changed nothing about them.
	bi := strings.builder_make(); defer strings.builder_destroy(&bi)
	ri: Renderer
	renderer_init(&ri, &bi)
	renderer_render(&ri, "hello\nworld")
	testing.expect_value(t, strings.to_string(bi), "hello\r\nworld\r\n")

	bf := strings.builder_make(); defer strings.builder_destroy(&bf)
	rf: Renderer
	renderer_init(&rf, &bf, 0, 0, .Full_Screen)
	renderer_render(&rf, "hello\nworld")
	testing.expect_value(t, strings.to_string(bf), "\e[?25l" + "\e[H" + "hello" + "\e[K" + "\r\n" + "world" + "\e[K" + "\r\n" + "\e[J")
}

// A whole Program driven through run() in .Diff mode. The point is not the
// bytes (with no tty there is no size, so this is the degraded path -- see
// test_diff_without_a_known_size_falls_back_to_the_full_screen_bytes) but the
// WIRING: that Program.render_mode reaches renderer_init, that the deferred
// renderer_destroy in run() actually fires, and that a diff-mode session
// therefore leaves nothing behind for tools/test.sh's leak audit to find.
@(test)
test_diff_mode_runs_a_whole_program_through_run :: proc(t: ^testing.T) {
	bd := strings.builder_make(); defer strings.builder_destroy(&bd)
	bf := strings.builder_make(); defer strings.builder_destroy(&bf)

	{
		src := input_source_from_bytes(transmute([]u8)string("aaq"))
		defer input_close(&src)
		p: Program(Counter)
		program_init(&p, Counter{}, counter_update, counter_view)
		p.render_mode = .Diff
		testing.expect(t, run(&p, &src, &bd) == nil, "diff-mode run should exit cleanly")
		testing.expect_value(t, p.model.n, 2)
	}
	{
		src := input_source_from_bytes(transmute([]u8)string("aaq"))
		defer input_close(&src)
		p: Program(Counter)
		program_init(&p, Counter{}, counter_update, counter_view)
		p.render_mode = .Full_Screen
		testing.expect(t, run(&p, &src, &bf) == nil, "full-screen run should exit cleanly")
	}

	testing.expect_value(t, strings.to_string(bd), strings.to_string(bf))
}

// ---------------------------------------------------------------------------
// F05 / F13 / F24 / F33: what a frame leaves behind, what it costs, and what
// happens when the model cannot represent it.
// ---------------------------------------------------------------------------

// F05. AN UNCLOSED SGR MUST NOT MAKE AN IDENTICAL FRAME COST ANYTHING.
//
// The mechanism was a loop between two pieces of carried state. Screen.style
// crossed frames (screen_copy copies it) and paint_frame never reset it, so
// screen_sgr re-accumulated the view's own escape onto the style it had already
// accumulated last frame: "\e[41m", then "\e[41m\e[41m", then three, and so on.
// Every one of those interned as a DIFFERENT style, so every cell of the bar
// compared unequal to itself and was repainted -- +16 bytes per frame, measured,
// growing without bound until the 1 MiB byte budget blew, at which point the
// table was dropped and the whole screen force-repainted. A sawtooth, forever,
// on a screen that never changed: ~4.1 KB/frame average against 0, and 43x the
// cost of the .Full_Screen repaint this mode exists to beat.
//
// paint_frame now starts every frame at the default pen in the model as well as
// on the wire, so the accumulation has nowhere to grow from.
@(test)
test_diff_cost_does_not_grow_when_a_view_leaves_a_style_open :: proc(t: ^testing.T) {
	h := harness_make(20, 4); defer harness_free(h)
	leaky :: "\e[41mstatus bar"

	frame(h, leaky)                      // the initial paint
	first := len(frame(h, leaky))
	testing.expect_value(t, first, 0)
	// Ten more, because "it grew by 16 bytes a frame" is only visible over
	// several: one repeat could be a constant, ten cannot.
	total := 0
	for _ in 0 ..< 10 { total += len(frame(h, leaky)) }
	testing.expectf(t, total == 0,
		"ten identical frames of a style-leaking view cost %d bytes; the contract is 0", total)

	// And the intern table has stopped growing, which is the cause rather than
	// the symptom. Two entries: the default at index 0, and "\e[41m".
	testing.expect_value(t, len(h.r.styles.spans), 2)
}

// F33. .Diff AND .Full_Screen MUST RENDER THE SAME VIEW THE SAME WAY ACROSS A
// RESIZE.
//
// They did not, for any view that left an SGR open past its last cell. .Diff's
// forced repaint blanked its model (style 0) and emitted \e[0m before \e[2J;
// .Full_Screen re-homed onto the previous frame's still-active pen and painted
// the frame's unstyled leading text in it. One frame -- the forced-repaint one
// -- rendered differently in the two modes, and under .Diff the application's
// colours visibly CHANGED at the moment the user dragged the window.
//
// Neither oracle could see it, because no case in either ever resized. That is
// F34, and the fuzz corpus now does resize; this is the minimal repro stated
// once, so a failure here says what broke instead of printing a seed.
@(test)
test_diff_and_full_screen_agree_across_a_resize_with_an_open_style :: proc(t: ^testing.T) {
	bd := strings.builder_make(); defer strings.builder_destroy(&bd)
	bf := strings.builder_make(); defer strings.builder_destroy(&bf)

	rd: Renderer; renderer_init(&rd, &bd, 10, 3, .Diff);        defer renderer_destroy(&rd)
	rf: Renderer; renderer_init(&rf, &bf, 10, 3, .Full_Screen)

	st, lt: Style_Table
	style_table_init(&st); defer style_table_destroy(&st)
	style_table_init(&lt); defer style_table_destroy(&lt)
	sd, sf: Screen
	screen_init(&sd, 10, 3, &st, &lt); defer screen_destroy(&sd)
	screen_init(&sf, 10, 3, &st, &lt); defer screen_destroy(&sf)
	scratch: [dynamic]u8; defer delete(scratch)

	step :: proc(rd, rf: ^Renderer, bd, bf: ^strings.Builder, sd, sf: ^Screen, scratch: ^[dynamic]u8, view: string) {
		strings.builder_reset(bd); strings.builder_reset(bf)
		renderer_render(rd, view)
		renderer_render(rf, view)
		vt_replay(sd, strings.to_string(bd^), scratch)
		vt_replay(sf, strings.to_string(bf^), scratch)
	}

	// The audit's own minimal case: frame 1 leaves \e[31m open, frame 2 is
	// plain, and the height changes between them.
	step(&rd, &rf, &bd, &bf, &sd, &sf, &scratch, "\e[31mabc")
	renderer_set_width(&rd, 10); renderer_set_height(&rd, 4)
	renderer_set_width(&rf, 10); renderer_set_height(&rf, 4)
	screen_init(&sd, 10, 4, &st, &lt)
	screen_init(&sf, 10, 4, &st, &lt)
	step(&rd, &rf, &bd, &bf, &sd, &sf, &scratch, "xyz")

	for y in 0 ..< 4 {
		for x in 0 ..< 10 {
			cf := screen_at(&sf, x, y)
			cd := screen_at(&sd, x, y)
			testing.expectf(t, cell_eq(&sf, cf, &sd, cd),
				"the two modes rendered (row %d, col %d) differently after a resize: repaint=%q sgr=%q  diff=%q sgr=%q",
				y, x, cell_bytes(&sf, cf), style_bytes(&st, cf.style), cell_bytes(&sd, cd), style_bytes(&st, cd.style))
		}
	}
	// And the specific cell the finding named: the frame's first character, on
	// the DEFAULT background in both modes rather than red in one of them.
	testing.expect_value(t, style_bytes(&st, screen_at(&sf, 0, 0).style), "")
}

// F13. A FRAME WHOSE STYLES CANNOT FIT AN EMPTY INTERN TABLE FALLS BACK TO THE
// REPAINT, INSTEAD OF PAINTING A WRONG SCREEN IN SILENCE.
//
// When paint_frame reported overflow, render_diff dropped the table, forced a
// repaint and retried once. If the retry overflowed too -- a single frame with
// more distinct accumulated SGR strings than an EMPTY table can hold -- the
// second `ok` was discarded. The frame was then emitted from a model in which
// screen_sgr had silently kept the PREVIOUS style for every cell past the cap
// (it returns false without assigning s.style, and screen_write keeps writing),
// so the user saw a screen that differs from the .Full_Screen repaint, with no
// diagnostic anywhere. docs/LIMITATIONS.md 3.7 already claimed this degraded to
// a repaint; it does now.
//
// THE CAP THIS REACHES IS THE BYTE BUDGET, NOT THE 4096-ENTRY ONE, and either
// is the same code path. A style is interned as the bytes ACCUMULATED since the
// last reset, so N distinct escapes with no reset between them intern
// 19+38+57+... bytes; that crosses STYLE_BYTES_MAX at N = 333. Reaching the
// entry cap instead would need 4096 escapes each preceded by \e[0m, which costs
// two orders of magnitude more to intern and proves the same thing.
@(test)
test_diff_falls_back_to_a_repaint_when_one_frame_overflows_the_style_table :: proc(t: ^testing.T) {
	sb := strings.builder_make(); defer strings.builder_destroy(&sb)
	// 500 distinct truecolour escapes, accumulating, then one glyph. Every
	// escape is ZERO WIDTH, so this is one physical row: a line the height
	// budget dropped would never be modelled and would prove nothing.
	for i in 0 ..< 500 {
		strings.write_string(&sb, "\e[38;2;")
		strings.write_int(&sb, i / 256)
		strings.write_string(&sb, ";")
		strings.write_int(&sb, i % 256)
		strings.write_string(&sb, ";0m")
	}
	strings.write_string(&sb, "Z\e[0m")
	storm := strings.clone(strings.to_string(sb)); defer delete(storm)

	bd := strings.builder_make(); defer strings.builder_destroy(&bd)
	bf := strings.builder_make(); defer strings.builder_destroy(&bf)
	rd: Renderer; renderer_init(&rd, &bd, 12, 3, .Diff);        defer renderer_destroy(&rd)
	rf: Renderer; renderer_init(&rf, &bf, 12, 3, .Full_Screen)

	run :: proc(rd, rf: ^Renderer, bd, bf: ^strings.Builder, view: string) -> (dif, ref: string) {
		strings.builder_reset(bd); strings.builder_reset(bf)
		renderer_render(rd, view)
		renderer_render(rf, view)
		return strings.to_string(bd^), strings.to_string(bf^)
	}

	// Frame 1: an ordinary frame, so the overflow is not confused with a first
	// paint (which is a repaint in both modes anyway).
	run(&rd, &rf, &bd, &bf, "plain first frame")

	dif, ref := run(&rd, &rf, &bd, &bf, storm)
	// THE ASSERTION, and it is the strongest one available: the user is shown
	// the repaint, byte for byte, rather than a diff computed from a model that
	// could not represent the frame.
	testing.expect_value(t, dif, ref)
	testing.expect(t, strings.contains(dif, "Z"), "the frame's only glyph must be painted")
	testing.expect(t, rd.force_repaint,
		"a frame the model could not represent must invalidate the model")
	// The tables were dropped, so the next frame starts from an empty one rather
	// than from 4096 entries nothing points at.
	testing.expect_value(t, len(rd.styles.spans), 1)

	// And the mode recovers: the next ordinary frame repaints from a real \e[2J
	// and the one after it is free again.
	dif2, _ := run(&rd, &rf, &bd, &bf, "plain again")
	testing.expect(t, strings.contains(dif2, "\e[2J"), "the frame after a fallback must resync")
	dif3, _ := run(&rd, &rf, &bd, &bf, "plain again")
	testing.expect_value(t, len(dif3), 0)
}

// F24, .Diff's half. The rule has to be the SAME rule .Full_Screen uses, not
// merely a similar one: the oracle compares cursor VISIBILITY between the two
// modes on every frame of every case, so a difference here is a divergence this
// package invented for itself.
@(test)
test_diff_hides_the_caret_it_owns :: proc(t: ^testing.T) {
	h := harness_make(10, 3); defer harness_free(h)

	got := frame(h, "hi")
	testing.expect(t, strings.has_prefix(got, "\e[?25l"),
		"the first .Diff frame must hide the caret it is about to park on top of content")
	testing.expect(t, !strings.contains(got, "\e[?25h"),
		"a frame that declared no cursor must not show the caret again")

	// THE 0-BYTE CONTRACT SURVIVES IT. This is the whole reason the hide is
	// conditioned on "not already hidden" rather than emitted per frame.
	testing.expect_value(t, len(frame(h, "hi")), 0)
	testing.expect_value(t, len(frame(h, "hi")), 0)

	// A changed frame still costs only the change -- no DECTCEM pair.
	// (the trailing park is the frame's cursor move, not a DECTCEM byte -- see
	// test_diff_one_changed_cell_costs_a_move_and_that_cell)
	testing.expect_value(t, frame(h, "ho"), "\e[1;2Ho\e[2;1H")

	// renderer_clear hands the caret back.
	strings.builder_reset(&h.b)
	renderer_clear(&h.r)
	testing.expect(t, strings.has_prefix(strings.to_string(h.b), "\e[?25h"),
		"renderer_clear must give the caret back")
}

// F34. THE COVERAGE ASSERTION: the generator actually reaches the three states
// the corpus used to be structurally unable to produce.
//
// A fuzz corpus that has been extended but does not in fact reach the new
// states is worse than one that was never extended, because it looks like
// coverage. So this counts, over the same 500 seeds the oracle runs, and fails
// if any of the three prongs is empty. The thresholds are loose (they are
// "clearly non-zero", not tuned percentages) precisely so that they pin the
// property rather than the current PRNG stream.
@(test)
test_the_fuzz_corpus_reaches_resizes_style_overflow_and_margin_clusters :: proc(t: ^testing.T) {
	CASES  :: 500
	vb := strings.builder_make(); defer strings.builder_destroy(&vb)

	resized_frames := 0
	storm_cases    := 0
	overflow_cases := 0
	leaky_frames   := 0

	for seed in u64(0) ..< u64(CASES) {
		f: Diff_Fuzz
		diff_fuzz_init(&f, seed, false, true)
		defer diff_fuzz_destroy(&f)
		if f.style_storm { storm_cases += 1 }

		db := strings.builder_make(); defer strings.builder_destroy(&db)
		r: Renderer
		renderer_init(&r, &db, f.cols, f.rows, .Diff)
		defer renderer_destroy(&r)

		saw_overflow := false
		for _ in 0 ..< f.frames {
			view, cur := diff_fuzz_frame(&f, &vb)
			if f.resized { resized_frames += 1 }
			renderer_set_width(&r, f.cols); renderer_set_height(&r, f.rows)
			strings.builder_reset(&db)
			renderer_render(&r, view, cur)
			// The model reports the pen it was left in; a frame that ends with
			// one open is the state F03/F05/F33 all live in.
			if r.pen_open || r.link_open { leaky_frames += 1 }
			// A frame that had to drop the intern tables is one that overflowed:
			// diff_styles_reset is the only thing that empties them mid-case.
			if len(r.styles.spans) <= 1 && len(view) > 64 { saw_overflow = true }
		}
		if saw_overflow { overflow_cases += 1 }
	}

	testing.expectf(t, resized_frames > 100,
		"the corpus resized on only %d frames -- F33 lives in the frame AFTER a resize and nothing else reaches it", resized_frames)
	testing.expectf(t, storm_cases > 20,
		"only %d seeds manufacture unbounded distinct styles", storm_cases)
	testing.expectf(t, overflow_cases > 10,
		"only %d cases actually overflowed an intern table -- the retry and fallback paths are untested without them", overflow_cases)
	testing.expectf(t, leaky_frames > 200,
		"only %d frames ended with an SGR or hyperlink still open", leaky_frames)
}
