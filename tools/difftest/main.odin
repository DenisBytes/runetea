package main

// THE DIFF RENDERER'S SECOND ORACLE, and the one with no shared ancestry.
//
// runetea/diff_oracle_test.odin already asserts the real invariant -- replaying
// the diff renderer's bytes must land on the same screen as replaying the full
// repaint's -- and it does so on the gate, with no external dependencies. What
// it CANNOT do is notice a mistake in what a terminal does with a byte, because
// its VT model and the renderer's cell model are the same code (screen.odin).
//
// This program closes that gap. It emits both byte streams, for the same
// seed-derived corpus, and hands them to pyte -- a third-party VT100 emulator
// written in Python by people who have never seen this repository. tools/
// difftest/check.py replays each pair and compares the resulting screens cell
// for cell. A misconception about wrapping, about what \e[K erases, about where
// a wide cluster lands or about what \n does on the bottom row shows up there
// and nowhere else.
//
//   ./tools/difftest/run.sh              the pyte cross-check
//   ./tools/difftest/run.sh measure      the byte-count measurements
//
// ON THE GATE SINCE 2026-09-03, and this header used to argue the opposite:
// "it would make python3 + pyte a hard build dependency of `odin test`, and a
// missing module becomes a green run". That is an argument against the SKIP,
// not against the dependency -- and every checker that needs pyte now exits
// non-zero without it rather than skipping. tools/difftest/run.sh carries the
// full reversal and what it cost (~3 s of wall clock).

import "core:fmt"
import "core:os"
import "core:strings"
import rt "../../runetea"
import edit "../../examples/editor/edit"

// How many generated cases the corpus holds. Fewer than the in-package oracle's
// 500 because every case crosses a process boundary as hex; pyte's own replay is
// the slow part, not the generation.
CASES :: 200

main :: proc() {
	mode := "dump"
	if len(os.args) > 1 { mode = os.args[1] }
	switch mode {
	case "dump":    dump_corpus()
	case "measure": measure()
	case:
		fmt.eprintfln("usage: difftest [dump|measure]")
		os.exit(2)
	}
}

// ---------------------------------------------------------------------------
// Corpus dump: the two byte streams, per frame, as hex.
// ---------------------------------------------------------------------------
//
// Hex rather than raw bytes because the payload IS escape sequences and this
// goes through a pipe: any transport that could be misread as terminal control
// is a transport that can hide the very bug being hunted.
dump_corpus :: proc() {
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	for seed in u64(0) ..< u64(CASES) {
		f: rt.Diff_Fuzz
		// pyte_safe: pyte measures width per CODE POINT with wcwidth, so VS16
		// emoji and regional-indicator flags are a case where this package and
		// pyte disagree BY DESIGN (width.odin defects 2 and 3). Feeding those
		// here would fail on a disagreement the harness was built to have and
		// prove nothing. The in-package oracle runs the full alphabet.
		//
		// `resizes` is F34's third prong, and the one that took longest to reach
		// here. A resize is the ONE mutation the generator cannot perform on its
		// own -- the size lives in this harness's Renderer and in check.py's pyte
		// screens, not in Diff_Fuzz -- so it is opt-in, and opting in obliges this
		// harness to do BOTH halves: push f.cols/f.rows into both renderers, and
		// emit a SIZE record so check.py can resize both emulator screens. Until
		// that landed the prong existed only in runetea/diff_oracle_test.odin,
		// whose VT model IS the renderer's own screen.odin -- precisely the sharing
		// this program exists to escape. What it reaches: .Diff's forced-repaint
		// prologue running against .Full_Screen's carry-on-painting, which is where
		// F33's SGR carry-over divergence lived.
		rt.diff_fuzz_init(&f, seed, pyte_safe = true, resizes = true)
		defer rt.diff_fuzz_destroy(&f)

		vb := strings.builder_make(); defer strings.builder_destroy(&vb)
		rb := strings.builder_make(); defer strings.builder_destroy(&rb)
		db := strings.builder_make(); defer strings.builder_destroy(&db)

		r_ref: rt.Renderer
		rt.renderer_init(&r_ref, &rb, f.cols, f.rows, .Full_Screen)
		defer rt.renderer_destroy(&r_ref)

		r_dif: rt.Renderer
		rt.renderer_init(&r_dif, &db, f.cols, f.rows, .Diff)
		defer rt.renderer_destroy(&r_dif)

		fmt.printfln("CASE %d %d %d %d", seed, f.cols, f.rows, f.frames)
		for n in 0 ..< f.frames {
			view, cur := rt.diff_fuzz_frame(&f, &vb)
			// THE SIZE RECORD, emitted BEFORE this frame's bytes and only when
			// the generator actually changed the geometry. The ordering is the
			// whole contract: check.py must resize its two screens before it
			// feeds them a frame that was rendered for the new size, or every
			// cell comparison after it is against a screen of the wrong shape and
			// the divergences it reports are its own.
			//
			// Conditional on f.resized rather than emitted every frame, even
			// though renderer_set_width is a documented no-op for an unchanged
			// value: an unconditional SIZE would put a pyte Screen.resize call on
			// every frame of every case, and pyte returns early on an equal size
			// only by an explicit check added in its 0.7.0. Leaning on that would
			// be leaning on a third-party implementation detail, in a harness
			// whose entire reason to exist is not to.
			if f.resized {
				rt.renderer_set_width(&r_ref, f.cols)
				rt.renderer_set_height(&r_ref, f.rows)
				rt.renderer_set_width(&r_dif, f.cols)
				rt.renderer_set_height(&r_dif, f.rows)
				fmt.printfln("SIZE %d %d %d", n, f.cols, f.rows)
			}
			strings.builder_reset(&rb)
			strings.builder_reset(&db)
			rt.renderer_render(&r_ref, view, cur)
			rt.renderer_render(&r_dif, view, cur)
			fmt.printfln("REF %d %s", n, hex(&b, strings.to_string(rb)))
			fmt.printfln("DIF %d %s", n, hex(&b, strings.to_string(db)))
		}
	}
}

@(private = "file")
HEX := "0123456789abcdef"

@(private = "file")
hex :: proc(b: ^strings.Builder, s: string) -> string {
	strings.builder_reset(b)
	for i in 0 ..< len(s) {
		strings.write_byte(b, HEX[s[i] >> 4])
		strings.write_byte(b, HEX[s[i] & 0xF])
	}
	return strings.to_string(b^)
}

// ---------------------------------------------------------------------------
// Measurement.
// ---------------------------------------------------------------------------

measure :: proc() {
	fmt.println("=== T3-A byte counts: .Full_Screen repaint vs .Diff ===")
	fmt.println()

	COLS :: 80
	ROWS :: 24

	// A dense but realistic 80x24 frame: 24 lines of 79 columns.
	base := make_screenful(COLS, ROWS)
	defer delete(base)

	one := mutate(base, COLS, 12, 40, 'X'); defer delete(one)
	five := mutate_run(base, COLS, 12, 40, 5); defer delete(five)
	all := make_screenful_alt(COLS, ROWS); defer delete(all)

	report_pair("identical consecutive frames", COLS, ROWS, base, base)
	report_pair("one changed cell",             COLS, ROWS, base, one)
	report_pair("five changed cells, one line", COLS, ROWS, base, five)
	report_pair("full-screen change",           COLS, ROWS, base, all)

	fmt.println()
	fmt.println("--- 60 fps for one second, static screen (the ssh case) ---")
	rep := 0
	dif := 0
	dif_first := 0
	{
		rb := strings.builder_make(); defer strings.builder_destroy(&rb)
		db := strings.builder_make(); defer strings.builder_destroy(&db)
		r_ref: rt.Renderer; rt.renderer_init(&r_ref, &rb, COLS, ROWS, .Full_Screen)
		r_dif: rt.Renderer; rt.renderer_init(&r_dif, &db, COLS, ROWS, .Diff)
		defer rt.renderer_destroy(&r_dif)
		for i in 0 ..< 60 {
			strings.builder_reset(&rb); strings.builder_reset(&db)
			rt.renderer_render(&r_ref, base)
			rt.renderer_render(&r_dif, base)
			rep += len(strings.to_string(rb))
			d := len(strings.to_string(db))
			dif += d
			if i == 0 { dif_first = d }
		}
	}
	fmt.printfln("  repaint: %d bytes/s      diff: %d bytes/s (%d of that is frame 1's initial paint; every later frame is 0)",
		rep, dif, dif_first)

	fmt.println()
	fmt.println("--- examples/editor, typing 'The quick brown fox' (19 keystrokes) ---")
	measure_editor()
}

@(private = "file")
report_pair :: proc(what: string, cols, rows: int, a, b: string) {
	rb := strings.builder_make(); defer strings.builder_destroy(&rb)
	db := strings.builder_make(); defer strings.builder_destroy(&db)
	r_ref: rt.Renderer; rt.renderer_init(&r_ref, &rb, cols, rows, .Full_Screen)
	r_dif: rt.Renderer; rt.renderer_init(&r_dif, &db, cols, rows, .Diff)
	defer rt.renderer_destroy(&r_dif)

	// Frame 1 establishes the screen in both; only frame 2 is measured.
	rt.renderer_render(&r_ref, a)
	rt.renderer_render(&r_dif, a)
	strings.builder_reset(&rb)
	strings.builder_reset(&db)
	rt.renderer_render(&r_ref, b)
	rt.renderer_render(&r_dif, b)

	nr := len(strings.to_string(rb))
	nd := len(strings.to_string(db))
	pct := 0.0
	if nr > 0 { pct = 100.0 * f64(nd) / f64(nr) }
	fmt.printfln("  %-30s repaint %d B    diff %d B   (%.1f%%)", what, nr, nd, pct)
}

@(private = "file")
make_screenful :: proc(cols, rows: int) -> string {
	b := strings.builder_make()
	for y in 0 ..< rows {
		if y > 0 { strings.write_byte(&b, '\n') }
		for x in 0 ..< cols - 1 {
			strings.write_byte(&b, u8('a' + u8((x + y) % 26)))
		}
	}
	return strings.to_string(b)
}

@(private = "file")
make_screenful_alt :: proc(cols, rows: int) -> string {
	b := strings.builder_make()
	for y in 0 ..< rows {
		if y > 0 { strings.write_byte(&b, '\n') }
		for x in 0 ..< cols - 1 {
			strings.write_byte(&b, u8('A' + u8((x + y + 7) % 26)))
		}
	}
	return strings.to_string(b)
}

@(private = "file")
mutate :: proc(s: string, cols, line, col: int, c: u8) -> string {
	return mutate_run(s, cols, line, col, 1, c)
}

@(private = "file")
mutate_run :: proc(s: string, cols, line, col, n: int, c: u8 = 'X') -> string {
	buf := make([]u8, len(s))
	copy(buf, s)
	// Lines are cols-1 chars plus one '\n', so the offset arithmetic is exact.
	off := line * cols + col
	for i in 0 ..< n {
		if off + i < len(buf) && buf[off + i] != '\n' { buf[off + i] = c }
	}
	return string(buf)
}

// Drives the REAL examples/editor model through real keystrokes and renders
// every resulting frame through both renderers. Not a synthetic view string:
// the editor's frame is 20-odd lines of header, rule, gutter-numbered text,
// rule and a status line that changes on every keystroke, which is exactly the
// shape that makes a repaint expensive and a diff cheap.
@(private = "file")
measure_editor :: proc() {
	COLS :: 100
	ROWS :: 30

	// .True_Color, and stated rather than detected, for the same reason
	// examples/editor/edit's tests force a profile: a measurement whose numbers
	// depend on $TERM is a measurement nobody can reproduce. It is also the
	// EXPENSIVE end -- truecolour SGR is the longest escape RuneGloss emits -- so
	// these numbers are the worst case for the diff, not the flattering one.
	m := edit.init("The quick brown fox jumps over the lazy dog.\nSecond line of text.\nThird line.", .True_Color)
	m.term_w = COLS
	m.term_h = ROWS

	rb := strings.builder_make(); defer strings.builder_destroy(&rb)
	db := strings.builder_make(); defer strings.builder_destroy(&db)
	r_ref: rt.Renderer; rt.renderer_init(&r_ref, &rb, COLS, ROWS, .Full_Screen)
	r_dif: rt.Renderer; rt.renderer_init(&r_dif, &db, COLS, ROWS, .Diff)
	defer rt.renderer_destroy(&r_dif)

	total_ref := 0
	total_dif := 0
	frames    := 0

	render_once :: proc(m: ^edit.Model, r_ref, r_dif: ^rt.Renderer, rb, db: ^strings.Builder) -> (int, int) {
		strings.builder_reset(rb)
		strings.builder_reset(db)
		v := edit.view(m^, context.allocator); defer delete(v)
		c := edit.cursor(m^, context.allocator)
		rt.renderer_render(r_ref, v, c)
		rt.renderer_render(r_dif, v, c)
		return len(strings.to_string(rb^)), len(strings.to_string(db^))
	}

	// Initial paint -- excluded from the average, exactly as it would be in a
	// real session: the first frame is a full repaint in BOTH modes by
	// definition, and averaging it in would flatter neither honestly.
	render_once(&m, &r_ref, &r_dif, &rb, &db)

	for r in "The quick brown fox" {
		// context.allocator, not a per-frame arena: apply_key gained an
		// allocator parameter when the editor's key handling started needing
		// one, and what it allocates from it (if anything) outlives the call
		// the way the Model does. Every return here is cmd_nil or quit_cmd,
		// both of which own nothing, so discarding the Cmd is safe -- it would
		// not be for a Cmd with an env, now that a Cmd is single-use and
		// carries a heap ledger entry.
		edit.apply_key(&m, rt.Key_Msg{code = .Rune, r = r}, context.allocator)
		a, b := render_once(&m, &r_ref, &r_dif, &rb, &db)
		total_ref += a
		total_dif += b
		frames    += 1
	}

	fmt.printfln("  %d frames    repaint %d B total, %d B/frame", frames, total_ref, total_ref / frames)
	fmt.printfln("  %d frames    diff    %d B total, %d B/frame   (%.1f%% of repaint)",
		frames, total_dif, total_dif / frames, 100.0 * f64(total_dif) / f64(total_ref))

	// And the case that matters most over a link: nothing changed.
	idle_ref := 0
	idle_dif := 0
	for _ in 0 ..< 60 {
		a, b := render_once(&m, &r_ref, &r_dif, &rb, &db)
		idle_ref += a
		idle_dif += b
	}
	fmt.printfln("  60 idle frames (nothing typed):  repaint %d B    diff %d B", idle_ref, idle_dif)

}
