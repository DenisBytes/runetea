package main

// Verification binary, not a public example: examples/simple ported verbatim
// (same Model/update/view) onto run_nbio instead of run(), so it can be
// driven under a real pty (see docs/superpowers/nbio-decision.md, answer to
// 2a) to check the nbio-hosted loop end to end -- live keypress updates,
// clean quit on 'q', terminal restored -- exactly like examples/simple, but
// through core:nbio instead of the poll-thread reader.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import rt "../../runetea"

Model :: struct { ticks: int }

// `m` is a POINTER: mutate in place, return only the Cmd. See
// rt.Program.update (runetea/tea.odin).
update :: proc(m: ^Model, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	switch v in msg {
	case rt.Key_Msg:
		if v.code == .Rune && (v.r == 'q' || (v.r == 'c' && .Ctrl in v.mods)) {
			return rt.quit_cmd()
		}
		if v.code == .Escape { return rt.quit_cmd() }
		m.ticks += 1
	}
	return rt.cmd_nil()
}

view :: proc(m: Model, alloc: mem.Allocator) -> string {
	return fmt.aprintf("Hi. This program will exit on 'q'.\n\nKeys pressed: %d\n", m.ticks, allocator = alloc)
}

main :: proc() {
	fd := posix.FD(os.fd(os.stdin))
	rt.install_crash_handlers()
	if !rt.term_enter_raw(fd) { fmt.eprintln("not a tty"); os.exit(1) }
	defer rt.term_restore()

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: rt.Program(Model)
	rt.program_init(&p, Model{}, update, view)

	// F31/F12/F10, and these are verification binaries precisely BECAUSE a
	// harness reads their exit status. The old line was
	// `if err := rt.run_nbio(...); err != nil { fmt.eprintln(...) }` followed
	// by falling off the end of main, which exits 0 -- so a Terminal_Error or
	// a Panicked_Error here was indistinguishable from a clean quit to every
	// script that runs this, and the diagnostic was printed into whatever mode
	// run_nbio left the terminal in. term_restore FIRST (os.exit does not run
	// defers, so the `defer` above never fires on this path), then the
	// message, then rt.exit_code: nil -> 0, Interrupted_Error -> 130 (the
	// shell's 128+SIGINT, deliberately not 1 -- an external interrupt is a
	// request, not a fault), everything else -> 1.
	err := rt.run_nbio(&p, fd, &b, fd)
	if err != nil {
		rt.term_restore()
		fmt.eprintln("error:", err)
		os.exit(rt.exit_code(err))
	}
}
