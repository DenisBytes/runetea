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
}

// `m` is a POINTER: mutate it in place and return only the Cmd. That is
// RuneTea's one deliberate divergence from Bubble Tea's value-based Update --
// see rt.Program.update (runetea/tea.odin) for the build-time measurements
// that bought it and the crash-safety property it cost.
update :: proc(m: ^Model, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	switch v in msg {
	case rt.Key_Msg:
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
	if !rt.term_enter_raw(fd) { fmt.eprintln("not a tty"); os.exit(1) }
	defer rt.term_restore()

	src, ok := rt.input_source_from_fd(fd)
	if !ok { fmt.eprintln("bad input source"); os.exit(1) }
	defer rt.input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: rt.Program(Model)
	rt.program_init(&p, Model{}, update, view)

	// The last argument is the fd each finished frame is written to. Pass it
	// and the display updates live; leave it out (-1) and the whole session
	// accumulates in `b` instead, which is how the golden tests read it.
	if err := rt.run(&p, &src, &b, fd); err != nil { fmt.eprintln("error:", err) }
}
