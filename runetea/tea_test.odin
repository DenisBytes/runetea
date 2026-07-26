package runetea

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

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
	quit_now    :: proc(env: rawptr, cancel: ^Cancel_Token) -> any { return box(Quit_Msg{}, context.allocator) }

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

// Regression for FIX 1 (final fix-wave report): mailbox_send returned a
// single `bool` for two different conditions -- CLOSED and FULL -- and
// tea.odin's reader thread treated both as terminal, returning WITHOUT
// calling mailbox_close on Full. run()'s main loop then drained whatever was
// already queued and blocked forever in mailbox_recv: no keyboard, no EOF,
// no error, unkillable except by an external signal. Confirmed reproducible
// with an update proc doing nothing but `n += 1`: 500 keys exits cleanly,
// 1000 hangs. This test feeds well past that -- 2000 'a's -- through a
// Bytes_Source, whose reads are instant with no real-tty pacing, so the
// reader thread races far ahead of the one-message-at-a-time main loop and
// reliably overflows the 256-slot mailbox run() allocates internally
// (reader_thread's own buf is 1024 bytes, so the very first read already
// decodes ~1024 keys against that 256-slot cap).
//
// run() itself is what would hang, so it is driven on a background thread
// here and given a generous bounded wait rather than called directly -- a
// regression must FAIL this test observably within a few seconds, not wedge
// the entire suite. (Verified non-vacuous by temporarily reverting just the
// tea.odin half of FIX 1 and re-running this test under `timeout`: it hung
// past the timeout, as expected -- see the final fix-wave report.)
Overflow_Harness :: struct {
	src:  Input_Source,
	b:    strings.Builder,
	err:  Run_Error,
	done: bool,
}

@(test)
test_run_survives_a_mailbox_overflow :: proc(t: ^testing.T) {
	N :: 2000
	data := make([]u8, N + 1); defer delete(data)
	for i in 0 ..< N { data[i] = 'a' }
	data[N] = 'q'   // final key quits, so run() has a defined end if it doesn't hang

	h: Overflow_Harness
	h.src = input_source_from_bytes(data)
	h.b = strings.builder_make()

	th := thread.create(proc(th: ^thread.Thread) {
		h := cast(^Overflow_Harness)th.data
		p: Program(Counter)
		program_init(&p, Counter{}, counter_update, counter_view)
		h.err = run(&p, &h.src, &h.b)
		sync.atomic_store(&h.done, true)
	})
	th.data = &h
	// MUST inherit this thread's context (in particular context.allocator):
	// run() allocates internally (mailbox_init, frame_arena_init, its own
	// reader/pool/watcher threads), and letting it fall back to
	// runtime.default_context() mixes allocators under odin test's
	// Tracking_Allocator -- the exact hazard dispatch()'s own doc comment in
	// cmd.odin documents and guards against for detached Cmds.
	th.init_context = context
	thread.start(th)

	start := time.now()
	timeout :: 5 * time.Second
	for !sync.atomic_load(&h.done) {
		if time.since(start) > timeout {
			testing.expect(t, false,
				"run() did not complete within 5s of a 2000-key burst into a 256-slot mailbox -- "+
				"this is FIX 1's full-vs-closed deadlock (mailbox.odin/tea.odin) regressing")
			// Deliberately do not join: the background thread is wedged
			// inside run()'s mailbox_recv and will never return on its own
			// if this branch is reached. Leaking it here is what makes the
			// failure observable instead of hanging the whole test binary.
			return
		}
		time.sleep(10 * time.Millisecond)
	}

	thread.join(th)
	thread.destroy(th)
	input_close(&h.src)
	strings.builder_destroy(&h.b)

	testing.expect(t, h.err == nil, "run should exit cleanly once the transiently-full mailbox drains")
}

// THE structural fix this whole change exists to make (T1,
// docs/superpowers/cancellation-decision.md): run() must return promptly
// even while a Cmd is still running, instead of blocking in dispatcher_destroy
// until that Cmd finishes -- the addendum's measured "one 2-second Cmd in
// flight -> quit takes 2.000s". This end-to-end test pins the fix at run()'s
// own public boundary, not just at dispatcher_reap's level (cmd_test.odin
// already covers that directly) -- dispatches a 300ms Cmd on the first
// keypress, quits on the second, and asserts run() returns in well under
// 300ms. Non-vacuous: verified by temporarily reverting tea.odin's
// `defer dispatcher_reap(rc, QUIT_GRACE)` back to the original
// `defer dispatcher_destroy(&disp)` + `defer mailbox_destroy(&mbox)` pair and
// re-running -- elapsed then measures >= 300ms and the assertion below fails,
// exactly as expected (see docs/superpowers/cancellation-decision.md for the
// actual recorded numbers, before and after).
Slow_Quit_Env :: struct { finished: ^sync.Sema }

slow_quit_cmd_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	e := cast(^Slow_Quit_Env)env
	time.sleep(300 * time.Millisecond)
	// Signaled purely so this TEST can wait deterministically for the Cmd to
	// actually finish before returning -- see the test's own trailing
	// comment. The Msg itself is expected to be discarded: by the time this
	// Cmd resolves, run() has long since quit and closed the mailbox.
	sync.sema_post(e.finished)
	return box(Empty_Result{}, context.allocator)
}

Slow_Quit_Model :: struct { armed: bool, finished: ^sync.Sema }

slow_quit_update :: proc(m: Slow_Quit_Model, msg: any, alloc: mem.Allocator) -> (Slow_Quit_Model, Cmd) {
	m := m
	if _, is_key := msg.(Key_Msg); is_key {
		if !m.armed {
			m.armed = true
			return m, cmd_from(slow_quit_cmd_run, Slow_Quit_Env{finished = m.finished}, context.allocator)
		}
		return m, quit_cmd()
	}
	return m, cmd_nil()
}

slow_quit_view :: proc(m: Slow_Quit_Model, alloc: mem.Allocator) -> string { return "" }

@(test)
test_run_returns_promptly_with_a_slow_cmd_still_in_flight :: proc(t: ^testing.T) {
	finished: sync.Sema

	// "aq": 'a' dispatches the 300ms Cmd (first keypress), 'q' quits
	// (second) -- both already queued by the reader thread well before the
	// Cmd has any chance to finish, so it is still genuinely running when
	// run()'s main loop breaks out on Quit_Msg.
	src := input_source_from_bytes(transmute([]u8)string("aq"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Slow_Quit_Model)
	program_init(&p, Slow_Quit_Model{finished = &finished}, slow_quit_update, slow_quit_view)

	start := time.now()
	err := run(&p, &src, &b)
	elapsed := time.since(start)

	testing.expect(t, err == nil, "run should exit cleanly")
	testing.expectf(t, elapsed < 200 * time.Millisecond,
		"run() should return well before its 300ms Cmd finishes (QUIT_GRACE is 100ms) -- took %v", elapsed)

	// Let the Cmd itself finish, and give the trailing background teardown
	// (dispatcher_destroy + mailbox_destroy + free inside the reaper thread
	// dispatcher_reap spawned) a fixed margin, before this test function
	// returns: the SAME per-task Tracking_Allocator hazard
	// test_dispatcher_reap_does_not_block_the_caller documents (cmd_test.odin)
	// applies here too, one level up, since run() now tears its Dispatcher/
	// Mailbox down through that identical path.
	sync.sema_wait(&finished)
	time.sleep(150 * time.Millisecond)
}
