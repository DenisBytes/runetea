package runetea

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sys/posix"
import "core:testing"

Counter :: struct { n: int, done: bool }

counter_update :: proc(m: Counter, msg: any, alloc: mem.Allocator) -> (Counter, Cmd) {
	m := m
	switch v in msg {
	case Key_Msg:
		if v.code == .Rune && v.r == 'q' { m.done = true; return m, quit_cmd() }
		m.n += 1
	case Quit_Msg:
		m.done = true
	}
	return m, cmd_nil()
}

counter_view :: proc(m: Counter, alloc: mem.Allocator) -> string {
	return fmt.aprintf("count: %d", m.n, allocator = alloc)
}

@(test)
test_program_processes_keys_and_quits :: proc(t: ^testing.T) {
	src := input_source_from_bytes(transmute([]u8)string("aaq"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Counter)
	program_init(&p, Counter{}, counter_update, counter_view)

	err := run(&p, &src, &b)
	testing.expect(t, err == nil, "run should exit cleanly")
	testing.expect_value(t, p.model.n, 2)
	testing.expect(t, p.model.done, "model should have observed the quit")
}

@(test)
test_program_recovers_from_a_panicking_update :: proc(t: ^testing.T) {
	Boom :: struct { n: int }
	boom_update :: proc(m: Boom, msg: any, alloc: mem.Allocator) -> (Boom, Cmd) {
		panic("user update exploded")
	}
	boom_view :: proc(m: Boom, alloc: mem.Allocator) -> string { return "" }

	src := input_source_from_bytes(transmute([]u8)string("x"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Boom)
	program_init(&p, Boom{}, boom_update, boom_view)

	err := run(&p, &src, &b)
	_, panicked := err.(Panicked_Error)
	testing.expect(t, panicked, "a panicking Update must surface as Panicked_Error, not a crash")
}

// Regression: an init Cmd that resolves to Quit_Msg -- with NO keypress ever
// sent -- must actually end run(). This is the spec's marquee scenario for
// the mailbox-as-single-wait-point design ("an async result updates the view
// with no keypress"), and box()'s zero-size hazard (see cmd_test.odin) broke
// it completely: Quit_Msg is itself `struct {}`, so its boxed `any` compared
// equal to nil and was silently dropped by run_cmd_task's `if msg != nil`
// gate, hanging run() forever on mailbox_recv.
//
// Deliberately uses a real pipe (Fd_Source), NOT input_source_from_bytes:
// Bytes_Source hits EOF the instant its data is exhausted, which closes the
// mailbox and ends the loop for a reason UNRELATED to the async Quit_Msg --
// exactly the false-positive that let this bug hide behind
// test_program_processes_keys_and_quits above (its "aaq" stream hits EOF at
// the same moment quit_cmd() is dispatched, so that test passes via the
// EOF-closes-mailbox path regardless of whether the Quit_Msg round-trip
// works). An open pipe with nothing ever written to it never produces EOF,
// so this test can only pass if the async Quit_Msg is genuinely delivered.
@(test)
test_program_quits_from_an_async_init_cmd_with_no_keypress :: proc(t: ^testing.T) {
	Idle :: struct {}
	idle_update :: proc(m: Idle, msg: any, alloc: mem.Allocator) -> (Idle, Cmd) { return m, cmd_nil() }
	idle_view   :: proc(m: Idle, alloc: mem.Allocator) -> string { return "" }
	quit_now    :: proc(env: rawptr) -> any { return box(Quit_Msg{}, context.allocator) }

	fds: [2]posix.FD
	testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
	read_fd, write_fd := fds[0], fds[1]
	defer posix.close(write_fd)
	defer posix.close(read_fd)

	src, ok := input_source_from_fd(read_fd)
	testing.expect(t, ok, "input_source_from_fd should succeed")
	defer input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Idle)
	program_init(&p, Idle{}, idle_update, idle_view,
		Cmd{procedure = quit_now, env = nil, allocator = context.allocator})

	err := run(&p, &src, &b)
	testing.expect(t, err == nil, "run should exit cleanly from an async Quit_Msg with no keypress")
}
