package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import rt "../../runetea"

// DELIBERATELY UNSTYLED AND DELIBERATELY .Inline, while every other example in
// this directory now uses RuneGloss and the editor uses the .Diff renderer.
//
// This file exists to be the smallest complete RuneTea program -- a Model, an
// update, a view, six lines of terminal setup -- and it is the first thing
// anybody reads. Every import it does not have is a question the reader does not
// have to answer before they understand the loop. examples/spinner is one file
// further on and shows what a styled view looks like (rg.Styles stored in the
// Model); examples/editor shows the whole apparatus.
//
// The same reasoning keeps the renderer at .Inline (the zero value): this program
// prints three lines and exits, leaving them in the user's scrollback. .Diff and
// .Full_Screen own the whole viewport, which is the right trade for an editor and
// the wrong one for a program this size.
Model :: struct {
	ticks:  int,
	// F47. The terminal's height, so view() can say "too small" rather than
	// paint a 3-row frame into a 1-row window, where the terminal scrolls
	// everything but the last row away and the program looks hung. Seeded in
	// main from rt.term_size and kept live from Window_Size_Msg; 0 is
	// "unknown" (no tty, or a failed ioctl) and never trips the guard.
	term_h: int,
}

// The rows view() paints -- the greeting, a blank, the counter -- PLUS ONE.
//
// The +1 is not slack, and this constant was 3 until it was measured. Under
// .Inline every line of the frame is terminated with "\r\n", the last one
// included (render_inline, runetea/render.odin): the next frame's rewind
// counts \e[1A\e[2K pairs upward from column 1 of the row BELOW the frame, so
// there has to be such a row. A frame of R rows therefore needs R+1 terminal
// rows, and painting R into exactly R scrolls the top row into scrollback --
// where r.last_rows' clamp to term_height-1 means no later rewind can reach
// it, so it is gone for the rest of the session, not merely for one frame.
//
// MEASURED under a real pty (pyte replay, 60 columns, after one keypress):
//   rows = 3   the screen shows a blank line, then "Keys pressed: 1". The
//              greeting -- the line that tells the user how to quit -- was
//              painted and scrolled away.
//   rows = 4   all three lines present, and every taller terminal is correct.
// One row is the single height at which even the fallback line below cannot be
// shown; see docs/LIMITATIONS.md 3.20 for why that one is not an example's to
// fix.
MIN_ROWS :: 3 + 1

// `m` is a POINTER: mutate it in place, return only the Cmd. See
// rt.Program.update (runetea/tea.odin) for why the signature is this shape and
// for the crash-safety property it cost.
update :: proc(m: ^Model, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	switch v in msg {
	case rt.Window_Size_Msg:
		// h == 0 is rt's "the ioctl failed" sentinel; ignore it rather than
		// clobbering a known-good height.
		if v.h > 0 { m.term_h = v.h }
	case rt.Key_Msg:
		// PASTED TEXT IS NOT KEYSTROKES (F37). main enables bracketed paste, so
		// a paste arrives as runes with `pasted` set -- and without this branch
		// every one of them would run the bindings below, so pasting anything
		// containing a 'q' would silently quit. This program counts KEYPRESSES,
		// and a paste is one gesture, not a burst of them.
		if v.pasted { return rt.cmd_nil() }
		if v.code == .Rune && (v.r == 'q' || (v.r == 'c' && .Ctrl in v.mods)) {
			return rt.quit_cmd()
		}
		if v.code == .Escape { return rt.quit_cmd() }
		m.ticks += 1
	}
	return rt.cmd_nil()
}

view :: proc(m: Model, alloc: mem.Allocator) -> string {
	// F47. One line that fits, rather than a frame the terminal scrolls away.
	if m.term_h > 0 && m.term_h < MIN_ROWS {
		return fmt.aprintf("need %d rows, have %d\n", MIN_ROWS, m.term_h, allocator = alloc)
	}
	return fmt.aprintf("Hi. This program will exit on 'q'.\n\nKeys pressed: %d\n", m.ticks, allocator = alloc)
}

main :: proc() {
	fd := posix.FD(os.fd(os.stdin))
	// install_crash_handlers BEFORE term_enter_raw, not after: term_enter_raw
	// flips raw_active = true before tcsetattr has actually touched the tty,
	// so a crash landing in that window is only recoverable if a handler
	// already exists to catch it (see install_crash_handlers' doc comment).
	rt.install_crash_handlers()
	// `paste = true` is DECSET 2004, bracketed paste -- the only thing that
	// makes a paste DISTINGUISHABLE from typing. Bubble Tea enables it by
	// default (WithoutBracketedPaste is the opt-out); RuneTea makes the
	// application own the terminal, so the opt-in belongs here. It is half the
	// fix: update()'s `v.pasted` branch is the other half, and neither works
	// without the other.
	if !rt.term_enter_raw(fd, {paste = true}) { fmt.eprintln("not a tty"); os.exit(1) }
	defer rt.term_restore()

	src, ok := rt.input_source_from_fd(fd)
	// term_restore BEFORE os.exit: os.exit does not run defers, so the line
	// above never fires on this path and the terminal is left in raw mode.
	if !ok { rt.term_restore(); fmt.eprintln("bad input source"); os.exit(1) }
	defer rt.input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: rt.Program(Model)
	rt.program_init(&p, Model{}, update, view)
	// A Window_Size_Msg only ever arrives on a SIGWINCH, so without this seed a
	// program that is never resized would never learn its own height.
	if _, h, ok := rt.term_size(fd); ok { p.model.term_h = h }

	// flush_fd = the tty, so each frame reaches the screen as it is rendered.
	err := rt.run(&p, &src, &b, fd)
	// term_restore FIRST, then the message, then a real exit status: printing
	// before the restore writes the diagnostic into whatever mode the program
	// left the terminal in, and falling off the end of main after an error
	// exits 0, which makes a crash indistinguishable from a clean quit to
	// anything that checks.
	if err != nil {
		rt.term_restore()
		fmt.eprintln("error:", err)
		os.exit(rt.exit_code(err))
	}
}
