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

	if err := rt.run_nbio(&p, fd, &b, fd); err != nil { fmt.eprintln("error:", err) }
}
