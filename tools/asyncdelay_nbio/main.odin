package main

// Deterministic (no network) version of tools/http_nbio's scenario: an init
// Cmd that sleeps 300ms on a pool worker, then resolves. Exists purely to get
// a clean, unambiguous two-frame pty capture with a visible gap between them
// for docs/superpowers/nbio-decision.md's answer to 2a/2b -- http_nbio's real
// network round-trip is usually too fast (~20ms in this sandbox) against a
// human-readable read-with-quiet-window capture to show the two frames as
// obviously separate events rather than one coalesced read.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import rt "../../runetea"

Ready_Msg :: struct { value: int }

slow_cmd :: proc(env: rawptr, cancel: ^rt.Cancel_Token) -> any {
	time.sleep(300 * time.Millisecond)
	return rt.box(Ready_Msg{value = 42}, context.allocator)
}

Model :: struct { ready: bool, value: int }

// `m` is a POINTER: mutate in place, return only the Cmd. See
// rt.Program.update (runetea/tea.odin).
update :: proc(m: ^Model, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	switch v in msg {
	case rt.Key_Msg:
		if v.code == .Rune && v.r == 'q' { return rt.quit_cmd() }
	case Ready_Msg:
		m.ready = true; m.value = v.value
		return rt.quit_cmd()
	}
	return rt.cmd_nil()
}

view :: proc(m: Model, alloc: mem.Allocator) -> string {
	if m.ready { return fmt.aprintf("ready: value=%d\n", m.value, allocator = alloc) }
	return fmt.aprintf("waiting ...\n", allocator = alloc)
}

main :: proc() {
	fd := posix.FD(os.fd(os.stdin))
	rt.install_crash_handlers()
	if !rt.term_enter_raw(fd) { fmt.eprintln("not a tty"); os.exit(1) }
	defer rt.term_restore()

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	init := rt.cmd_from(slow_cmd, struct{}{}, context.allocator)

	p: rt.Program(Model)
	rt.program_init(&p, Model{}, update, view, init)

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
