package main

// THE README'S QUICKSTART, and the only copy of it. README.md quotes this file
// verbatim and tools/doccheck/run.sh fails if the two ever drift -- a sample
// that stops compiling is worse than no sample at all, because it burns the
// reader's trust in the first five minutes.
//
// It is a port of Bubble Tea's own README example (the shopping list), so
// anyone arriving from Go can put the two side by side and see exactly what
// changed: `Update` takes `*Model` instead of returning one, `tea.Msg` is
// `any`, there is no `tea.NewProgram(...).Run()` that owns the terminal, and
// every allocation names the allocator it came from.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import rt "../../runetea"

CHOICES := [?]string{"Buy carrots", "Buy celery", "Buy kohlrabi"}

Model :: struct {
	cursor:   int,
	selected: [len(CHOICES)]bool,
	// F47. The terminal's height, so `view` can say "too small" instead of
	// painting a 7-row frame into a 1-row window -- where the terminal scrolls
	// all but the last row away and the program looks hung. Seeded in `main`
	// from rt.term_size and kept live from Window_Size_Msg; 0 is "unknown"
	// (no tty, or the ioctl failed) and never trips the guard.
	term_h:   int,
}

// The rows `view` below paints -- one question, one blank, one per choice, one
// blank, one hint -- PLUS ONE. Written as an expression rather than a number so
// that adding a choice cannot silently make the minimum wrong.
//
// The +1 is not slack, and this constant was `4 + len(CHOICES)` until it was
// measured. Under .Inline every line of the frame is terminated with "\r\n",
// the last one included (render_inline, runetea/render.odin), because the next
// frame's rewind counts \e[1A\e[2K pairs upward from column 1 of the row BELOW
// the frame. A frame of R rows therefore needs R+1 terminal rows; painting R
// into exactly R scrolls the top row into scrollback, and r.last_rows' clamp
// to term_height-1 means no later rewind can ever reach it again.
//
// MEASURED under a real pty (pyte replay, 60 columns, after one 'j'):
//   rows = 7 (the old minimum)   "What should we buy at the market?" is GONE.
//              The question this program exists to ask, scrolled away, on a
//              terminal the guard had just certified as big enough.
//   rows = 8   all seven lines present, and every taller terminal is correct.
MIN_ROWS :: 5 + len(CHOICES)

// `m` is a POINTER: mutate it in place and return only the Cmd. That is
// RuneTea's one deliberate divergence from Bubble Tea's value-based Update --
// see rt.Program.update (runetea/tea.odin) for the build-time measurements
// that bought it and the crash-safety property it cost.
update :: proc(m: ^Model, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	switch v in msg {
	case rt.Window_Size_Msg:
		// w == 0 / h == 0 is rt's "the ioctl failed" sentinel: ignore it rather
		// than clobbering a known-good size.
		if v.h > 0 { m.term_h = v.h }
	case rt.Key_Msg:
		// PASTED TEXT IS NOT KEYSTROKES (F37). Without this, every character of
		// a paste runs the bindings below -- a pasted "buy quinoa" quits on its
		// 'q' and the session is gone with no message. Bracketed paste (the
		// `paste = true` in main) is what makes the two DISTINGUISHABLE, by
		// setting `pasted` and by delivering the space as .Rune ' ' rather than
		// .Space; this branch is what makes the distinction matter. A list
		// picker has no text field, so the right thing to do with a paste is
		// nothing at all.
		if v.pasted { return rt.cmd_nil() }
		switch {
		case v.code == .Rune && v.r == 'q',
		     v.code == .Rune && v.r == 'c' && .Ctrl in v.mods,
		     v.code == .Escape:
			return rt.quit_cmd()
		case v.code == .Up, v.code == .Rune && v.r == 'k':
			if m.cursor > 0 { m.cursor -= 1 }
		case v.code == .Down, v.code == .Rune && v.r == 'j':
			if m.cursor < len(CHOICES) - 1 { m.cursor += 1 }
		case v.code == .Enter, v.code == .Space:
			m.selected[m.cursor] = !m.selected[m.cursor]
		}
	}
	return rt.cmd_nil()
}

// Everything allocated here comes from `alloc` -- the per-frame arena RuneTea
// hands the view -- and is reclaimed wholesale when the frame ends. Nothing in
// a view is ever freed by hand.
view :: proc(m: Model, alloc: mem.Allocator) -> string {
	// F47. One line that fits, rather than a frame whose first rows the
	// terminal scrolls away.
	if m.term_h > 0 && m.term_h < MIN_ROWS {
		return fmt.aprintf("need %d rows, have %d\n", MIN_ROWS, m.term_h, allocator = alloc)
	}
	b := strings.builder_make(alloc)
	strings.write_string(&b, "What should we buy at the market?\n\n")
	for choice, i in CHOICES {
		point := i == m.cursor ? ">" : " "
		check := m.selected[i] ? "x" : " "
		fmt.sbprintfln(&b, "%s [%s] %s", point, check, choice)
	}
	strings.write_string(&b, "\nPress q to quit.\n")
	return strings.to_string(b)
}

main :: proc() {
	fd := posix.FD(os.fd(os.stdin))

	// install_crash_handlers BEFORE term_enter_raw: term_enter_raw arms its
	// own restore flag before tcsetattr has touched the tty, so a crash in
	// that window is only recoverable if a handler already exists.
	rt.install_crash_handlers()
	// `paste = true` is DECSET 2004, bracketed paste. Without it the terminal
	// delivers pasted text as ordinary keystrokes with `pasted == false`, so
	// there is no way for update() to tell a paste from typing and every
	// pasted character runs a binding. Bubble Tea -- the thing this is a port
	// of -- enables it by default and offers WithoutBracketedPaste as the
	// opt-out; RuneTea makes the application own the terminal, so the opt-in
	// belongs here. It is HALF the fix on its own: see update's `v.pasted`
	// branch for the other half, and note that the two have to ship together
	// (DECSET 2004 alone still lets a pasted 'q' quit).
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
	// A Window_Size_Msg only ever arrives on a SIGWINCH, so a program that is
	// never resized would spend its whole life not knowing how tall its
	// terminal is. ok == false leaves it 0, which view() reads as "unknown".
	if _, h, ok := rt.term_size(fd); ok { p.model.term_h = h }

	// The last argument is the fd each finished frame is written to. Pass it
	// and the display updates live; leave it out (-1) and the whole session
	// accumulates in `b` instead, which is how the golden tests read it.
	err := rt.run(&p, &src, &b, fd)
	// term_restore FIRST, then the message, then a real exit status. Printing
	// before the terminal is restored writes the diagnostic into whatever mode
	// the program left the terminal in; falling off the end of main after an
	// error exits 0, which makes a crash indistinguishable from a clean quit to
	// anything that checks. rt.exit_code maps nil -> 0, Interrupted_Error ->
	// 130 and every genuine fault -> 1.
	if err != nil {
		rt.term_restore()
		fmt.eprintln("error:", err)
		os.exit(rt.exit_code(err))
	}
}
