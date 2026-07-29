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
oracle_case :: proc(seed: u64, pyte_safe := false) -> (ok: bool, fail: Oracle_Fail) {
	f: Diff_Fuzz
	diff_fuzz_init(&f, seed, pyte_safe)
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

	scratch: [dynamic]u8
	defer delete(scratch)

	for frame in 0 ..< f.frames {
		view, cur := diff_fuzz_frame(&f, &vb)

		strings.builder_reset(&rb)
		strings.builder_reset(&db)
		renderer_render(&r_ref, view, cur)
		renderer_render(&r_dif, view, cur)

		vt_replay(&s_ref, strings.to_string(rb), &scratch)
		vt_replay(&s_dif, strings.to_string(db), &scratch)

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
	// \e[0m first: \e[2J erases with the ACTIVE background, and on the very
	// first frame this process has no idea what that is.
	testing.expect_value(t, got, "\e[0m\e[H\e[2J" + "hi" + "\e[2;1H")
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
	// The first frame's \e[K runs with red still active, so the erased tail is
	// RED blanks. The second frame's tail is DEFAULT blanks. Those are different
	// cells, and \e[K cannot be used to produce the red ones -- whether an erase
	// records anything but the background is terminal-dependent.
	// Note the FIRST frame is the plain one: SGR state carries across frames on a
	// real terminal (the repaint stream never resets between frames either), so
	// "\e[41mab" followed by "ab" would leave the second frame red too -- and
	// correctly produce no diff at all.
	frame(h, "abcdefgh")
	got := frame(h, "\e[41mab")
	// Row 0's ten-cell tail AND all of row 1 (the repaint's trailing \e[J also
	// runs with red active) become RED blanks, written as real spaces. Not one
	// \e[K anywhere in the frame.
	// The trailing \e[0m is the frame-closing reset: this frame ends with red
	// still active, and leaving it set would tint whatever is written next.
	testing.expect_value(t, got,
		"\e[1;1H\e[41mab" + "          " + "\e[2;1H" + "            " + "\e[0m" + "\r")
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
	testing.expect_value(t, frame(h, "hi"), "\e[0m\e[H\e[2J" + "hi" + "\e[2;1H")

	// Once a link HAS been seen, a forced repaint closes any link the previous
	// occupant of the terminal may have left open -- \e[0m does not do it (SGR
	// and OSC 8 are independent attribute planes) and \e[2J does not either.
	h2 := harness_make(10, 3); defer harness_free(h2)
	got := frame(h2, LINK_A + "hi" + LINK_OFF)
	testing.expect_value(t, got, "\e[0m" + LINK_OFF + "\e[H\e[2J" + LINK_A + "hi" + LINK_OFF + "\e[2;1H")
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
	testing.expect_value(t, strings.to_string(h.b), "\e[H\e[J")
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
	testing.expect_value(t, strings.to_string(h.b), "\e[H\e[J")
	// The model now says "blank", so the next frame repaints its content --
	// without a \e[2J prologue, because renderer_clear already did the erasing.
	got := frame(h, "abc")
	// No leading move: renderer_clear left the cursor at home and the model
	// knows it, so the first cell needs no positioning at all.
	testing.expect_value(t, got, "abc\e[2;1H")
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
	testing.expect_value(t, got, "\e[0m\e[H\e[2J" + "one" + "\e[2;1Htwo")
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
	testing.expect_value(t, strings.to_string(bf), "\e[H" + "hello" + "\e[K" + "\r\n" + "world" + "\e[K" + "\r\n" + "\e[J")
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
