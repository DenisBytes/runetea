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

slow_cmd :: proc(env: rawptr) -> any {
	time.sleep(300 * time.Millisecond)
	return rt.box(Ready_Msg{value = 42}, context.allocator)
}

Model :: struct { ready: bool, value: int }

update :: proc(m: Model, msg: any, alloc: mem.Allocator) -> (Model, rt.Cmd) {
	m := m
	switch v in msg {
	case rt.Key_Msg:
		if v.code == .Rune && v.r == 'q' { return m, rt.quit_cmd() }
	case Ready_Msg:
		m.ready = true; m.value = v.value
		return m, rt.quit_cmd()
	}
	return m, rt.cmd_nil()
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

	if err := rt.run_nbio(&p, fd, &b, fd); err != nil { fmt.eprintln("error:", err) }
}
