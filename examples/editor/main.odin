package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import rg "../../runegloss"
import rt "../../runetea"
import ed "edit"

// A scrollable multi-line text editor -- spec §12's T1 deliverable ("prompts,
// menus, scrollable content"), and the first example in this repo that touches
// the input stack past `q`/Ctrl+C/Escape. examples/simple, examples/spinner
// and examples/http between them handle three keys; the CSI/SS3 decoder,
// xterm modifiers, the Kitty keyboard protocol and bracketed paste were
// validated by unit tests and pty tests only. This exercises all of them in
// one application:
//
//   arrows                  cursor movement, including across line boundaries
//   Home / End              start / end of line              (CSI H, CSI F)
//   Page_Up / Page_Down     scroll by a viewport             (CSI 5~, CSI 6~)
//   Backspace vs Delete     backward vs FORWARD delete       (0x7F vs CSI 3~)
//   Ctrl+Left / Ctrl+Right  word jump, xterm modifiers       (CSI 1;5D / 1;5C)
//   bracketed paste         multi-line insert, streamed      (CSI 200~ .. 201~)
//   Tab vs Ctrl+I           two DIFFERENT actions -- Kitty only (see edit's
//                           apply_key: on the legacy encoding both are 0x09)
//   mouse wheel             scroll the viewport              (CSI < 64/65;x;y M)
//
// Everything above lives in package edit next door, not in this file, so it
// can be driven through rt.run() from a test with scripted bytes
// (edit/editor_test.odin) instead of only by a human staring at a terminal.
// This file is terminal setup and nothing else.

DOC :: `The quick brown fox jumps over the lazy dog.
Type anything. Arrow keys move the caret, and Left at column 1
wraps to the end of the previous line.
Ctrl+Left and Ctrl+Right jump whole words -- that is CSI 1;5D
and CSI 1;5C, the xterm modifier encoding.
Backspace deletes backwards (0x7F). Delete deletes FORWARD
(CSI 3~). They are different sequences and different actions.
Home and End go to the ends of this line.
PageUp and PageDown scroll by a whole viewport, which is why
this document is deliberately longer than the ten rows the
view paints.
Paste something multi-line: bracketed paste streams it in as
ordinary keypresses with pasted = true, so the text lands as
text even when it contains what looks like an escape sequence.
Tab indents by four spaces.
Ctrl+I toggles the help panel -- a DIFFERENT key from Tab, but
only because the Kitty disambiguation flag is on.
Ctrl+C quits.`

main :: proc() {
	fd := posix.FD(os.fd(os.stdin))
	// install_crash_handlers BEFORE term_enter_raw, not after: term_enter_raw
	// flips raw_active = true before tcsetattr has actually touched the tty,
	// so a crash landing in that window is only recoverable if a handler
	// already exists to catch it (see install_crash_handlers' doc comment).
	rt.install_crash_handlers()
	// Two opt-ins, both of which this example genuinely needs -- unlike
	// examples/spinner and examples/http, which push .Disambiguate to
	// demonstrate the mechanism without any binding that depends on it.
	//
	// .Disambiguate is what makes Tab and Ctrl+I two different keys (`CSI 9 u`
	// vs `CSI 105;5 u`) instead of one shared byte 0x09. Without it,
	// Legacy_Key_Encoding can only pick which SIDE of that collision the app
	// sees -- never both -- so edit's Ctrl+I binding would be unreachable and
	// the help panel dead code. That degradation is graceful and visible: the
	// status line prints `kitty:off` when no `CSI ? u` reply came back.
	//
	// Deliberately NOT .Report_Event_Types, for the reason spelled out in
	// examples/spinner: with event types on every key arrives twice (press and
	// release) and edit's update() does not filter on Key_Msg.kind, so every
	// keystroke would be applied twice.
	//
	// `paste = true` is DECSET 2004, bracketed paste. Opting in is what turns
	// a pasted multi-line block into Paste_Start_Msg + runes with
	// pasted = true + Paste_End_Msg instead of a burst of raw keypresses in
	// which a newline would be Enter and a 'q' might be a quit binding.
	//
	// The matching teardown for both is written by rt.term_restore() below,
	// and by the crash-signal path -- exactly once between them.
	//
	// `mouse = .Normal` is DECSET 1000 (press and release) plus DECSET 1006 (SGR
	// extended coordinates, which term_enter_raw always pairs with a tracking
	// mode -- the legacy encoding cannot express a column past 223). .Normal and
	// not .Button_Event or .Any_Event because this editor binds the WHEEL and a
	// LEFT PRESS (T2-C's click-to-position, see ed.apply_mouse) and nothing else:
	// both are reported in every tracking mode, so asking for drag or all-motion
	// would flood the reader with reports nothing here consumes.
	//
	// Focus reporting (DECSET 1004) is NOT enabled: nothing in this example
	// reacts to Focus_Msg/Blur_Msg, and enabling a mode with no handler behind
	// it is exactly the "write nothing you did not need" rule term_enter_raw's
	// defaults exist to make easy.
	//
	// `alt = true` is DECSET 1049, the ALTERNATE SCREEN BUFFER (T2-C) -- the
	// terminal half of the cell renderer selected below (.Diff, which delivers
	// .Full_Screen's frame). It gives this
	// program a cleared buffer of its own and, on exit, hands the user back their
	// shell exactly as they left it: scrollback intact, this editor's frames
	// gone. The matching `?1049l` is written by rt.term_restore() below and by
	// the crash-signal path, exactly once between them -- which matters more here
	// than for any of the other opt-ins, because a program that dies without it
	// leaves the user unable to see their own terminal at all.
	if !rt.term_enter_raw(fd, {.Disambiguate}, true, .Normal, false, true) {
		fmt.eprintln("not a tty"); os.exit(1)
	}
	defer rt.term_restore()

	src, ok := rt.input_source_from_fd(fd)
	if !ok { fmt.eprintln("bad input source"); os.exit(1) }
	defer rt.input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: rt.Program(ed.Model)
	// rg.default_profile() detects once from $NO_COLOR/$TERM/$COLORTERM and
	// caches (runegloss/color.odin). THIS IS THE ONLY PLACE THE ENVIRONMENT IS
	// READ: package edit never calls new_style(), only new_style_profile(p), so
	// its view is a pure function of its Model and the same Model renders the
	// same bytes on every machine -- which is what makes edit/testdata's golden a
	// test rather than a record of the author's terminal.
	rt.program_init(&p, ed.init(DOC, rg.default_profile()), ed.update, ed.view)
	// The REAL terminal cursor, T2-A. Set after program_init because
	// program_init deliberately does not take it (see rt.Program.cursor) --
	// every example written before T2 keeps compiling untouched, and only the
	// one that actually needs a caret pays for one. This replaces the literal
	// '|' this editor used to paint into its own text; see ed.cursor.
	p.cursor = ed.cursor
	// T3-A. The DIFFED CELL RENDERER: the same frame .Full_Screen paints, but
	// delivered as the minimum set of writes that turns what is already on screen
	// into it. Everything .Full_Screen gave this example is still true of .Diff --
	// it is .Full_Screen's frame, so view line 0 is still screen row 0 and
	// ed.click_target's coordinates still mean what they meant (render.odin's
	// Render_Mode) -- and the wire cost collapses. Measured on this exact program
	// at 100x30 (`./tools/difftest/run.sh measure`): 754 B per keystroke
	// repainted, 115 B diffed, and 60 idle frames cost 45840 B repainted against
	// ZERO diffed. A whole interactive session on a real pty (100 keystrokes,
	// scrolling, a click) came to 8280 B against .Full_Screen's 44686 B.
	//
	// AN EDITOR IS THE APPLICATION THIS MODE EXISTS FOR. Typing changes a handful
	// of cells -- one character, the caret's two gutters, the Ln/Col counter -- in
	// a frame that is otherwise byte-identical to the last one, which is exactly
	// the shape a repaint handles worst.
	//
	// TWO THINGS .Diff NEEDS THAT .Full_Screen DID NOT, both already true here:
	//
	//  1. A KNOWN WIDTH AND HEIGHT. It models a viewport. Both come from
	//     rt.term_size inside run() (and stay live from Window_Size_Msg); with
	//     either unknown, every frame silently degrades to .Full_Screen's exact
	//     bytes. That degradation is why the editor's tests -- which have no tty
	//     -- cannot exercise this mode through run() alone, and why
	//     editor_test.odin drives a SIZED Renderer directly on top of doing so.
	//  2. A VIEW THAT CONTAINS STYLING BUT NO MOTION. SGR escapes are modelled per
	//     cell; a cursor move, an OSC or a raw tab written by the view would be a
	//     lie to the cell model. ed.view emits SGR, printable text and "\n" and
	//     nothing else -- RuneGloss guarantees that of its own output, and this
	//     editor never writes a control character of its own (Tab indents with
	//     spaces; a pasted 0x09 is dropped by apply_key). editor_test asserts it
	//     rather than trusting it.
	//
	// Set here rather than passed to program_init for the same reason p.cursor is
	// (rt.Program.render_mode): .Inline is the zero value, so no example written
	// before T2-C has to change.
	p.render_mode = .Diff
	// Seed the app's own copy of the terminal size. rt's renderer gets this
	// itself from term_size inside run(), but ed.click_target needs the WIDTH too
	// -- to account for view lines that wrap -- and a Window_Size_Msg only ever
	// arrives on a SIGWINCH, so an editor that is never resized would otherwise
	// spend its whole life assuming nothing wraps. ok=false leaves both 0, which
	// is exactly the assumption the renderer makes with an unknown width, so the
	// two stay consistent either way (see ed.Model.term_w).
	if w, h, ok := rt.term_size(fd); ok { p.model.term_w, p.model.term_h = w, h }

	// flush_fd = the tty, so each frame reaches the screen as it is rendered.
	if err := rt.run(&p, &src, &b, fd); err != nil { fmt.eprintln("error:", err) }
}
