package runetea

import "core:fmt"

// THE .Diff RENDERER'S VIEW CONTRACT, MADE CHECKABLE.
//
// render.odin has always DESCRIBED this contract ("views may contain styling
// and hyperlinks, not motion"). A contract nobody can check is a contract that
// gets violated, and the violation is silent: .Full_Screen tolerates a view
// that moves the cursor or embeds a \r, .Diff renders a screen the user never
// asked for and then believes it. So the description is joined here by
//
//   * view_diff_safe   -- a public predicate an application can call itself,
//                         in its own tests, on its own views.
//   * DIFF_STRICT      -- an assertion the .Diff renderer runs on every frame,
//                         ON in debug builds, off in release.
//
// WHY A CHECK AND NOT A SANITISER. A sanitiser would have to decide what a
// stray \e[5A MEANS -- drop it? treat the bytes as text? -- and every answer is
// a guess about intent that changes what the user sees without telling them.
// Refusing to guess is the same rule width.odin applies to a truncated escape
// and screen_osc8 applies to an unterminated OSC 8. The one thing worth
// automating is the DIAGNOSIS, which is what this file is.
//
// THE OTHER TWO MODES ARE UNAFFECTED. .Inline and .Full_Screen pass the view's
// bytes through untouched and are welcome to whatever a terminal does with
// them; nothing here runs for them.

// What is wrong with a view, in .Diff terms.
//
// .None is the zero value and means "nothing is wrong", so `ok` and `why` never
// disagree.
Diff_Contract :: enum u8 {
	None,
	// A C0 control byte in the view's text. \n is excluded -- renderer_render
	// splits on it before any of this -- but \r, \t, \b, \a and friends all
	// move the cursor or ring a bell, and the cell model has no way to express
	// what they did. \t is the one that bites in practice: it is a MOVE to the
	// next tab stop, whose position depends on terminal state RuneTea does not
	// model, so a tab in a view puts every following cell somewhere the diff
	// does not think it is. Expand tabs to spaces in the view instead --
	// examples/editor does exactly that (its TAB_WIDTH).
	Control_Byte,
	// A CSI that is not SGR: cursor motion (CUU/CUD/CUF/CUB/CUP/CHA/VPA),
	// erase (EL/ED), scroll region, mode set/reset, anything. The view is
	// telling the terminal to do something the cell model did not do.
	Motion_Escape,
	// An OSC, DCS, PM, APC or SOS string that is not an OSC 8 hyperlink -- a
	// window title, a clipboard write, a sixel image. Zero width, so the
	// LAYOUT survives, but the payload is dropped by the diff and will not be
	// re-sent when the row is repainted. Emit these outside the view.
	Other_String_Escape,
	// An nF / Fe / Fp / Fs escape: charset selection ("\e(B"), index ("\eD"),
	// save/restore cursor ("\e7"/"\e8"), reverse index ("\eM").
	Other_Escape,
	// An escape that runs off the end of the view. The terminal will consume
	// its missing tail from whatever bytes are written next, which in .Diff
	// mode is the next frame's cursor move -- so a truncated escape does not
	// merely vanish, it EATS the beginning of the next thing sent.
	Truncated_Escape,
}

// Reports whether `view` is something the .Diff renderer can model exactly.
//
// `at` is the byte offset of the first offending byte, so a caller can point at
// it. ok == true implies why == .None and at == len(view).
//
// ALLOCATES NOTHING and is O(len(view)) with no lookahead beyond the escape
// scanner width.odin already uses -- cheap enough to run on every frame of a
// debug build, which is what DIFF_STRICT does.
//
// SGR AND OSC 8 ARE THE ENTIRE PERMITTED VOCABULARY, because they are exactly
// the two escapes screen.odin's cell model tracks (see screen_escape). That is
// not a coincidence to be kept in sync by hand: any escape this proc accepts
// and screen_escape ignores is silent data loss, and the test suite pins the
// two lists against each other.
@(require_results)
view_diff_safe :: proc(view: string) -> (ok: bool, at: int, why: Diff_Contract) {
	i := 0
	for i < len(view) {
		b := view[i]
		if b == ESC {
			j := skip_escape(view, i)
			if w := classify_escape(view[i:j]); w != .None { return false, i, w }
			i = j
			continue
		}
		// C0, plus DEL. \n is legal here and nowhere else: renderer_render has
		// already split the view on it, so by the time a line reaches the cell
		// model there are none left, and rejecting it would make every
		// multi-line view -- i.e. every real view -- fail this check.
		if b < 0x20 && b != '\n' { return false, i, .Control_Byte }
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

// Whether the .Diff renderer asserts its own view contract on every frame.
//
// DEFAULTS TO ODIN_DEBUG, i.e. on for `odin build -debug` and off for a release
// build, which is the shape of every other "cost nothing in production" check
// in this package (render.odin's DIFF_FAULT is the same idea with the opposite
// default). Force it either way with
//
//   -define:RUNETEA_DIFF_STRICT=true      // on, even in a release build
//   -define:RUNETEA_DIFF_STRICT=false     // off, even in a debug build
//
// WHY A PANIC AND NOT A SILENT DEGRADE. The whole failure this exists to catch
// is a view that renders correctly under .Full_Screen and wrongly under .Diff,
// on somebody else's terminal, days later. There is nothing to degrade TO: the
// renderer cannot know what the escape meant. A panic in a debug build, naming
// the byte offset and the reason, converts that into a stack trace on the
// developer's own machine on the first frame that contains it.
DIFF_STRICT :: #config(RUNETEA_DIFF_STRICT, ODIN_DEBUG)

// The assertion itself. Called by render_diff only under `when DIFF_STRICT`,
// so in a release build this proc is not merely skipped -- it is not reachable
// and the check costs no cycles at all.
//
// Lives here rather than in render.odin so that the message can be formatted:
// render.odin is deliberately free of core:fmt (see its write_csi), and a
// diagnostic that could not say WHERE the violation was would be most of the
// value thrown away.
@(private = "package")
diff_contract_assert :: proc(view: string) {
	ok, at, why := view_diff_safe(view)
	if ok { return }
	// A short excerpt around the offence -- enough to recognise the line,
	// bounded so a 100 KB view does not become a 100 KB panic message.
	lo := max(at - 16, 0)
	hi := min(at + 16, len(view))
	fmt.panicf(
		"runetea: view violates the .Diff renderer's contract (%v) at byte %d: ...%q...\n" +
		"  .Diff models SGR and OSC 8 hyperlinks per cell and nothing else; anything\n" +
		"  that moves the cursor, erases, or carries a payload is silently lost.\n" +
		"  Call runetea.view_diff_safe(view) to check this yourself, use .Full_Screen\n" +
		"  if the view genuinely needs to drive the terminal, or build with\n" +
		"  -define:RUNETEA_DIFF_STRICT=false to disable this assertion.",
		why, at, view[lo:hi])
}
