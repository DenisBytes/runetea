package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import rt "../../runetea"

Model :: struct { ticks: int }

update :: proc(m: Model, msg: any, alloc: mem.Allocator) -> (Model, rt.Cmd) {
	m := m
	switch v in msg {
	case rt.Key_Msg:
		if v.code == .Rune && (v.r == 'q' || (v.r == 'c' && .Ctrl in v.mods)) {
			return m, rt.quit_cmd()
		}
		if v.code == .Escape { return m, rt.quit_cmd() }
		m.ticks += 1
	}
	return m, rt.cmd_nil()
}

view :: proc(m: Model, alloc: mem.Allocator) -> string {
	return fmt.aprintf("Hi. This program will exit on 'q'.\n\nKeys pressed: %d\n", m.ticks, allocator = alloc)
}

main :: proc() {
	fd := posix.FD(os.fd(os.stdin))
	if !rt.term_enter_raw(fd) { fmt.eprintln("not a tty"); os.exit(1) }
	defer rt.term_restore()
	rt.install_crash_handlers()

	src, ok := rt.input_source_from_fd(fd)
	if !ok { fmt.eprintln("bad input source"); os.exit(1) }
	defer rt.input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: rt.Program(Model)
	rt.program_init(&p, Model{}, update, view)

	// flush_fd = the tty, so each frame reaches the screen as it is rendered.
	if err := rt.run(&p, &src, &b, fd); err != nil { fmt.eprintln("error:", err) }
}
