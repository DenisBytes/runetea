package runetea

import "core:fmt"

// THE RENDERER'S VIEW CONTRACT, MADE CHECKABLE -- FOR EVERY MODE, NOT ONLY .Diff.
//
// render.odin has always DESCRIBED this contract ("views may contain styling
// and hyperlinks, not motion"). A contract nobody can check is a contract that
// gets violated, and the violation is silent: .Diff renders a screen the user
// never asked for and then believes it. So the description is joined here by
//
//   * view_render_safe -- what ANY mode can survive.
//   * view_diff_safe   -- that, plus what a CELL GRID can additionally model.
//   * VIEW_STRICT      -- an assertion the renderer runs on every frame, on in
//                         a plain `odin build`, off in an optimised one.
//
// THIS FILE USED TO SAY "THE OTHER TWO MODES ARE UNAFFECTED. .Inline and
// .Full_Screen pass the view's bytes through untouched and are welcome to
// whatever a terminal does with them; nothing here runs for them." That was
// wrong, and it was wrong in the mode that is the ZERO VALUE and the one four
// of the five shipped examples use. .Inline does not merely pass bytes
// through: it records how many physical rows it painted (Renderer.last_rows,
// from rows_for_line) and rewinds exactly that many at the head of the next
// frame. A view that moves the cursor makes that count a lie, the rewind erases
// the wrong rows, and the error does not cancel out -- the frame walks down the
// screen one row per frame, forever, stacking a complete stale copy of itself
// above each new one. "Welcome to whatever a terminal does with them" is true
// only of a renderer that keeps no state between frames, and none of the three
// is one.
//
// SO THERE ARE TWO TIERS, and they differ by exactly one byte:
//
//   RENDER TIER (view_render_safe) -- what the ROW ACCOUNTING can survive. No
//   cursor motion, no erase, no C0 but \n and \t, no truncated escape.
//
//   DIFF TIER (view_diff_safe) -- the render tier MINUS the tab. A tab is a
//   MOVE, and a cell grid can record what is IN a cell but not a jump between
//   them; .Inline and .Full_Screen hand the byte to the terminal and measure
//   its effect (width.odin models HT), while .Diff would have to invent the
//   cells the terminal skipped over and does not paint.
//
// WHY A CHECK AND NOT A SANITISER. A sanitiser would have to decide what a
// stray \e[5A MEANS -- drop it? treat the bytes as text? -- and every answer is
// a guess about intent that changes what the user sees without telling them.
// Refusing to guess is the same rule width.odin applies to a truncated escape
// and screen_osc8 applies to an unterminated OSC 8. The one thing worth
// automating is the DIAGNOSIS, which is what this file is.

// What is wrong with a view. Shared by both tiers -- the reasons are the same
// reasons, and only the verdict on \t differs -- so a caller that wants to
// print `why` has one vocabulary to learn rather than two.
//
// STILL NAMED Diff_Contract even though view_render_safe returns it too:
// renaming it would have churned docs/API.md, docs/LIMITATIONS.md, README.md
// and every application that spells the type out, to buy a slightly better word
// for a value whose members did not change. The type's job is to say what is
// wrong with a view; the .Diff tier is simply the strictest reader of it.
//
// .None is the zero value and means "nothing is wrong", so `ok` and `why` never
// disagree.
Diff_Contract :: enum u8 {
	None,
	// A C0 control byte in the view's text. \r, \b, \a and friends all move the
	// cursor or ring a bell, and no renderer can express what they did: they
	// break the row count every mode keeps, so BOTH tiers reject them.
	//
	// TWO C0 BYTES ARE NOT IN THAT SET.
	//
	//   \n is legal everywhere -- renderer_render splits the view on it before
	//   any of this, so by the time a line reaches a renderer there are none
	//   left, and rejecting it would fail every multi-line view, i.e. every real
	//   one.
	//
	//   \t is legal in the RENDER tier and illegal in the DIFF tier, and it used
	//   to be illegal in both. It moved tiers because width.odin now MODELS it:
	//   HT is the one C0 byte with a defined column effect (advance to the next
	//   tab stop, clamped at the right margin), so rows_for_line can now count a
	//   tabbed line's rows correctly and .Inline's rewind stays in step. Before
	//   that it could not: display_width scored \t as 0, a tabbed line measured
	//   short, and .Inline slid one row down the screen every frame forever.
	//   Rejecting it here was never a fix for that -- the check was .Diff-only
	//   and compiled out of the build command the README publishes, so the
	//   failure shipped with a green test suite and no diagnostic.
	//
	//   It stays illegal under .Diff because the cell grid has to know WHICH
	//   cells a glyph landed in, and a tab lands in none of them. Expand tabs to
	//   spaces in the view -- examples/editor does exactly that (its TAB_WIDTH)
	//   -- or use .Inline / .Full_Screen, which now measure them.
	Control_Byte,
	// A CSI that is not SGR: cursor motion (CUU/CUD/CUF/CUB/CUP/CHA/VPA),
	// erase (EL/ED), scroll region, mode set/reset, anything. The view is
	// telling the terminal to do something the renderer did not do -- the cell
	// model did not record it, and, in the other two modes, the physical row
	// count did not include it. .Inline's rewind is itself CUU + EL, so a view
	// carrying its own CUU is competing with the renderer for the same cursor.
	Motion_Escape,
	// An OSC, DCS, PM, APC or SOS string that is not an OSC 8 hyperlink -- a
	// window title, a clipboard write, a sixel image. Zero width, so the LAYOUT
	// survives: the payload is dropped by the diff and will not be re-sent when
	// the row is repainted, and under the other two modes a DCS sixel or a Kitty
	// APC blob PAINTS, which no mode's row count includes. Emit these outside
	// the view.
	Other_String_Escape,
	// An nF / Fe / Fp / Fs escape: charset selection ("\e(B"), index ("\eD"),
	// save/restore cursor ("\e7"/"\e8"), reverse index ("\eM"). Half of these
	// move the cursor or scroll, which is why the whole family is rejected in
	// both tiers rather than split by hand into the harmless and the fatal.
	Other_Escape,
	// An escape that runs off the end of the view. The terminal will consume its
	// missing tail from whatever bytes are written next -- in .Diff mode the next
	// frame's cursor move, in .Inline mode the next frame's CUU -- so a truncated
	// escape does not merely vanish, it EATS the beginning of the next thing
	// sent, whichever mode sent it.
	Truncated_Escape,
}

// Reports whether `view` is something ANY of the three render modes can carry
// without corrupting its own row accounting. THE MODE-GENERAL TIER.
//
// This is the predicate an application that uses the DEFAULT mode wants, and
// until the audit sweep it did not exist -- the only checkable contract in the
// package was .Diff's, which is stricter than .Inline needs and, being
// .Diff-only, was never run for the mode most applications actually use. An
// application that uses .Diff wants view_diff_safe below, which is this plus
// one byte.
//
// `at` is the byte offset of the first offending byte, so a caller can point at
// it. ok == true implies why == .None and at == len(view).
//
// ALLOCATES NOTHING and is O(len(view)) with no lookahead beyond the escape
// scanner width.odin already uses -- cheap enough to run on every frame of a
// non-optimised build, which is what VIEW_STRICT does.
@(require_results)
view_render_safe :: proc(view: string) -> (ok: bool, at: int, why: Diff_Contract) {
	return contract_scan(view, tab_ok = true)
}

// Reports whether `view` is something the .Diff renderer can model exactly:
// view_render_safe, and additionally no tab.
//
// SGR AND OSC 8 ARE THE ENTIRE PERMITTED VOCABULARY, because they are exactly
// the two escapes screen.odin's cell model tracks (see screen_escape). That is
// not a coincidence to be kept in sync by hand: any escape this proc accepts
// and screen_escape ignores is silent data loss, and the test suite pins the
// two lists against each other.
@(require_results)
view_diff_safe :: proc(view: string) -> (ok: bool, at: int, why: Diff_Contract) {
	return contract_scan(view, tab_ok = false)
}

// ONE SCANNER, TWO VERDICTS. The two predicates differ by a single byte value,
// and writing them as two loops would have been two chances to disagree about
// where an escape ends -- the exact class of drift width.odin's "one scanner,
// one answer" note exists to prevent. `tab_ok` is the whole difference.
@(private = "file")
contract_scan :: proc(view: string, tab_ok: bool) -> (ok: bool, at: int, why: Diff_Contract) {
	i := 0
	for i < len(view) {
		b := view[i]
		if b == ESC {
			j := skip_escape(view, i)
			if w := classify_escape(view[i:j]); w != .None { return false, i, w }
			i = j
			continue
		}
		// C0, plus DEL. \n is legal in both tiers and nowhere else:
		// renderer_render has already split the view on it, so by the time a
		// line reaches a renderer there are none left, and rejecting it would
		// make every multi-line view -- i.e. every real view -- fail this check.
		// \t is legal in the render tier only; see Diff_Contract.Control_Byte.
		if b == '\n' || (tab_ok && b == '\t') { i += 1; continue }
		if b < 0x20 { return false, i, .Control_Byte }
		if b == 0x7F { return false, i, .Control_Byte }
		i += 1
	}
	return true, len(view), .None
}

// `seq` is one whole escape as skip_escape delimited it.
@(private = "file")
classify_escape :: proc(seq: string) -> Diff_Contract {
	if len(seq) < 2 { return .Truncated_Escape }   // bare trailing ESC

	switch seq[1] {
	case '[':
		// A CSI is complete iff skip_escape stopped on a final byte in
		// 0x40..0x7E. Anything else means it ran out of string (truncated) or
		// hit a byte that cannot belong to a CSI (malformed) -- and a malformed
		// CSI is a motion escape as far as the terminal is concerned, because
		// the terminal will keep looking for the final byte in what comes next.
		last := seq[len(seq) - 1]
		if len(seq) < 3 || last < 0x40 || last > 0x7E { return .Truncated_Escape }
		if last == 'm' { return .None }   // SGR: the one CSI the model tracks
		return .Motion_Escape

	case ']', 'P', '^', '_', 'X':
		// Terminated? skip_escape returns len(s) for an unterminated one, so a
		// sequence that does not END in ST or BEL never got closed.
		terminated := (len(seq) >= 3 && seq[len(seq) - 2:] == ST) ||
		              (len(seq) >= 2 && seq[len(seq) - 1] == BEL)
		if !terminated { return .Truncated_Escape }
		if seq[1] == ']' && len(seq) >= len(OSC8_OPEN) && seq[:len(OSC8_OPEN)] == OSC8_OPEN {
			return .None   // OSC 8: the other escape the model tracks
		}
		return .Other_String_Escape

	case:
		// nF escapes carry intermediates then a final byte; a two-byte Fe/Fp/Fs
		// has no intermediates. Either way skip_escape returns len(s) with no
		// final byte consumed when it ran off the end -- which is exactly the
		// case where the last byte is an intermediate (0x20..0x2F).
		last := seq[len(seq) - 1]
		if last >= 0x20 && last <= 0x2F { return .Truncated_Escape }
		return .Other_Escape
	}
}

// Whether the renderer asserts the view contract on every frame.
//
// THE DEFAULT MOVED, and this is the point of the change. It used to be plain
// ODIN_DEBUG, which is set only by `odin build -debug`. The build command this
// project's own README publishes (README.md:62, `odin build . -collection:rune=
// vendor/runetea`) does not pass -debug, so the check was compiled out of the
// only build instructions anybody is given -- and docs/API.md's "debug builds
// assert the same contract on every frame and panic naming the byte offset" was
// describing a build nobody was told to make. A tab in a .Diff view therefore
// produced permanently wrong output with no diagnostic of any kind, and the
// intermittent self-heal on a resize (any force-repaint fixes the screen for
// exactly one frame, then it re-corrupts) pointed diagnosis away from the view.
//
// So the condition is now "this is not an optimised build" rather than "this is
// a -debug build":
//
//   * `odin build .`            -> ODIN_OPTIMIZATION_MODE == .Minimal -> ON
//   * `odin build . -debug`     -> ON
//   * `odin test`               -> ON
//   * `odin build . -o:speed`   -> OFF
//   * `odin build . -o:aggressive` -> OFF
//
// which is the shape the requirement actually has: the check must cost nothing
// in a SHIPPED build, and "shipped" is spelled -o:speed, not "not -debug". It
// stays a compile-time `when`, so in an optimised build the assertion is not
// merely skipped -- it is not reachable and costs no cycles at all. Force it
// either way with
//
//   -define:RUNETEA_VIEW_STRICT=true      // on, even at -o:speed
//   -define:RUNETEA_VIEW_STRICT=false     // off, even in a plain build
//
// WHY A PANIC AND NOT A SILENT DEGRADE. The whole failure this exists to catch
// is a view that renders correctly under one mode and wrongly under another, on
// somebody else's terminal, days later. There is nothing to degrade TO: the
// renderer cannot know what the escape meant. A panic in a development build,
// naming the byte offset and the reason, converts that into a stack trace on the
// developer's own machine on the first frame that contains it.
VIEW_STRICT :: #config(RUNETEA_VIEW_STRICT, ODIN_DEBUG || ODIN_OPTIMIZATION_MODE < .Speed)

// The .Diff renderer's own switch, kept as a separate name because render.odin
// and the diff oracle both spell it and because .Diff's contract is genuinely
// the stricter of the two -- somebody may want the cheap tier on and the strict
// tier off. DEFAULTS TO VIEW_STRICT, so it inherits the corrected default above;
// -define:RUNETEA_DIFF_STRICT=true|false still overrides it on its own.
DIFF_STRICT :: #config(RUNETEA_DIFF_STRICT, VIEW_STRICT)

// The assertions themselves. Called by the renderer under `when VIEW_STRICT` /
// `when DIFF_STRICT`, so in an optimised build neither proc is reachable.
//
// They live here rather than in render.odin so that the message can be
// formatted: render.odin is deliberately free of core:fmt (see its write_csi),
// and a diagnostic that could not say WHERE the violation was would be most of
// the value thrown away.
//
// FOR .Inline AND .Full_Screen -- the mode-general tier. A tab passes; anything
// that moves the cursor does not, because both modes count the physical rows
// they painted and rewind or truncate against that count.
@(private = "package")
render_contract_assert :: proc(view: string) {
	ok, at, why := view_render_safe(view)
	if ok { return }
	fmt.panicf(
		"runetea: view violates the renderer's contract (%v) at byte %d: ...%q...\n" +
		"  Every render mode counts the physical rows it painted and acts on that\n" +
		"  count (.Inline rewinds by it, .Full_Screen truncates against it). A view\n" +
		"  that moves the cursor, erases, or carries a payload makes the count a\n" +
		"  lie, and the error compounds one row per frame.\n" +
		"  Call runetea.view_render_safe(view) to check this yourself, or build with\n" +
		"  -define:RUNETEA_VIEW_STRICT=false to disable this assertion.",
		why, at, excerpt(view, at))
}

// FOR .Diff -- the cell-grid tier, which additionally cannot model a tab.
@(private = "package")
diff_contract_assert :: proc(view: string) {
	ok, at, why := view_diff_safe(view)
	if ok { return }
	fmt.panicf(
		"runetea: view violates the .Diff renderer's contract (%v) at byte %d: ...%q...\n" +
		"  .Diff models SGR and OSC 8 hyperlinks per cell and nothing else; anything\n" +
		"  that moves the cursor, erases, or carries a payload is silently lost. A\n" +
		"  tab is a move: expand tabs to spaces, or use .Inline / .Full_Screen,\n" +
		"  which measure them (width.odin models HT).\n" +
		"  Call runetea.view_diff_safe(view) to check this yourself, use .Full_Screen\n" +
		"  if the view genuinely needs to drive the terminal, or build with\n" +
		"  -define:RUNETEA_DIFF_STRICT=false to disable this assertion.",
		why, at, excerpt(view, at))
}

// A short excerpt around the offence -- enough to recognise the line, bounded so
// a 100 KB view does not become a 100 KB panic message. Byte-sliced, not
// rune-sliced: a diagnostic is allowed to cut a rune in half, and a %q of
// invalid UTF-8 is still readable, whereas a diagnostic that could itself fail
// is not a diagnostic.
@(private = "file")
excerpt :: proc(view: string, at: int) -> string {
	lo := max(at - 16, 0)
	hi := min(at + 16, len(view))
	return view[lo:hi]
}
