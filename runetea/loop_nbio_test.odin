#+private
// ^ Every declaration in this file is package-private, so that `odin doc
//   runetea` / `odin doc runegloss` -- the command README.md and docs/API.md
//   hand a newcomer for symbol discovery -- lists the library rather than the
//   test fixtures. Pinned by tools/doccheck/run.sh's `apidoc` check, which is
//   also where the argument for it is written out.
package runetea

// Headless coverage for run_nbio (loop_nbio.odin), mirroring tea_test.odin's
// coverage of run() so the two hosts can be compared test-for-test. nbio
// needs a real OS handle (associate_handle), so every test here uses an
// anonymous pipe instead of Bytes_Source -- there is no nbio equivalent of
// feeding a byte slice directly (see loop_nbio.odin's file doc comment).

import "core:mem"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
test_run_nbio_processes_keys_and_quits :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
	read_fd, write_fd := fds[0], fds[1]
	defer posix.close(read_fd)

	testing.expect_value(t, posix.write(write_fd, raw_data(string("aaq")), 3), 3)
	posix.close(write_fd)   // EOF once "aaq" is drained -- belt and braces alongside the 'q' quit

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Counter)
	program_init(&p, Counter{}, counter_update, counter_view)

	err := run_nbio(&p, read_fd, &b)
	testing.expect(t, err == nil, "run_nbio should exit cleanly")
	testing.expect_value(t, p.model.n, 2)
	testing.expect(t, p.model.done, "model should have observed the quit")
}

// Same regression run() has (tea_test.odin's
// test_program_quits_from_an_async_init_cmd_with_no_keypress), driven through
// run_nbio instead: an init Cmd resolving to Quit_Msg, with NO keypress ever
// sent, must still end the loop. This is the one that actually exercises the
// linchpin -- Dispatcher's pool delivers the result via mailbox_send, then
// calls the wake hook (nbio_wake -> nbio.wake_up) to unblock a loop thread
// that may be parked in nbio.tick() with nothing else pending. Deliberately
// an open pipe with nothing ever written to it (not EOF-driven): the ONLY way
// this test can pass is if the async Quit_Msg genuinely reaches apply_msg.
@(test)
test_run_nbio_quits_from_an_async_init_cmd_with_no_keypress :: proc(t: ^testing.T) {
	Idle :: struct {}
	idle_update :: proc(m: ^Idle, msg: any, alloc: mem.Allocator) -> Cmd { return cmd_nil() }
	idle_view   :: proc(m: Idle, alloc: mem.Allocator) -> string { return "" }
	quit_now    :: proc(env: rawptr, cancel: ^Cancel_Token) -> any { return box(Quit_Msg{}, context.allocator) }

	fds: [2]posix.FD
	testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
	read_fd, write_fd := fds[0], fds[1]
	defer posix.close(write_fd)
	defer posix.close(read_fd)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Idle)
	program_init(&p, Idle{}, idle_update, idle_view,
		Cmd{procedure = quit_now, env = nil, allocator = context.allocator})

	err := run_nbio(&p, read_fd, &b)
	testing.expect(t, err == nil, "run_nbio should exit cleanly from an async Quit_Msg with no keypress")
}

// run_nbio-side regression test for the class of bug FIX 1 (final fix-wave
// report, spike-findings.md addendum) fixed on the reader-thread path: a
// burst of input larger than the mailbox's capacity must not hang the loop.
// The reader-thread fix was "retry with thread.yield() until the OTHER
// thread (the main loop) drains it". That fix does not transfer here -- there
// is no other thread; the loop thread IS what decodes the input AND what
// would need to drain it. loop_nbio.odin's answer is nbio_flush_backlog's
// stop-and-resume design (see its own comment). This test is the proof it
// actually avoids the deadlock a naive retry-in-callback port would hit: 2000
// 'a's into a 256-slot mailbox, i.e. one single nbio read completion handing
// nbio_on_read roughly 1024 decoded keys in one call, ~4x the mailbox's
// entire capacity.
//
// Driven on a background thread with a bounded wait, same reason
// tea_test.odin's Overflow_Harness is: a regression must fail this test
// observably within a few seconds, not wedge the whole suite.
Nbio_Overflow_Harness :: struct {
	read_fd: posix.FD,
	b:       strings.Builder,
	err:     Run_Error,
	done:    bool,
}

@(test)
test_run_nbio_survives_a_mailbox_overflow :: proc(t: ^testing.T) {
	N :: 2000
	data := make([]u8, N + 1); defer delete(data)
	for i in 0 ..< N { data[i] = 'a' }
	data[N] = 'q'   // final key quits, so run_nbio has a defined end if it doesn't hang

	fds: [2]posix.FD
	testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
	read_fd, write_fd := fds[0], fds[1]
	defer posix.close(write_fd)

	h: Nbio_Overflow_Harness
	h.read_fd = read_fd
	h.b = strings.builder_make()

	th := thread.create(proc(th: ^thread.Thread) {
		h := cast(^Nbio_Overflow_Harness)th.data
		p: Program(Counter)
		program_init(&p, Counter{}, counter_update, counter_view)
		h.err = run_nbio(&p, h.read_fd, &h.b)
		sync.atomic_store(&h.done, true)
	})
	th.data = &h
	th.init_context = context   // see tea_test.odin's Overflow_Harness for why this must be inherited
	thread.start(th)

	// Written AFTER run_nbio has had a moment to associate the handle and
	// issue its first read, so the whole 2001 bytes land as one burst that
	// nbio's read op can plausibly deliver close to in one completion
	// (matching the scenario's intent -- a decode batch bigger than the
	// mailbox). thread.start above returns as soon as the OS thread exists,
	// not once it reaches nbio.associate_handle, so a short sleep here is a
	// best-effort timing choice, not a correctness requirement: if the write
	// raced ahead of the read association, the pipe simply buffers it
	// (64KiB default on Linux, well over 2001 bytes) until the read is
	// issued.
	time.sleep(20 * time.Millisecond)
	testing.expect_value(t, posix.write(write_fd, raw_data(data), len(data)), len(data))

	start := time.now()
	timeout :: 5 * time.Second
	for !sync.atomic_load(&h.done) {
		if time.since(start) > timeout {
			testing.expect(t, false,
				"run_nbio did not complete within 5s of a 2000-key burst into a 256-slot mailbox -- "+
				"the single-thread backpressure design (nbio_flush_backlog) is not working")
			return
		}
		time.sleep(10 * time.Millisecond)
	}

	thread.join(th)
	thread.destroy(th)
	posix.close(read_fd)
	strings.builder_destroy(&h.b)

	testing.expect(t, h.err == nil, "run_nbio should exit cleanly once the transiently-full mailbox drains")
}

// Byte-for-byte parity between run() and run_nbio for the identical input,
// through the SAME apply_msg + guarded_render pair (tea.odin, both
// package-visible) -- direct evidence that the two event-loop hosts differ only
// in how a message reaches those calls, not in what happens once it does.
//
// Coalescing puts one residual timing dependence in this assertion, and it is
// worth naming. run_nbio's batching is deterministic (single thread, one read
// completion, three keys). run()'s is not: its reader is a separate thread, so
// whether all three keys are queued before the loop wakes on the first is a
// scheduling question. In practice the reader decodes a whole read() and
// pushes it in a tight loop long before the loop thread is rescheduled, so both
// hosts produce the same two frames -- but if this ever goes flaky, the property
// to keep is the model plus the FINAL frame, not the exact batch split. Both driven over a pipe (not
// Bytes_Source) so the comparison is fair: run() gets Fd_Source's poll+read,
// run_nbio gets nbio's read op, same three keys "aaq" either way.
@(test)
test_run_and_run_nbio_produce_identical_output :: proc(t: ^testing.T) {
	poll_fds: [2]posix.FD
	testing.expect(t, posix.pipe(&poll_fds) == .OK, "pipe should succeed")
	testing.expect_value(t, posix.write(poll_fds[1], raw_data(string("aaq")), 3), 3)
	posix.close(poll_fds[1])

	src, ok := input_source_from_fd(poll_fds[0])
	testing.expect(t, ok, "input_source_from_fd should succeed")

	poll_out := strings.builder_make(); defer strings.builder_destroy(&poll_out)
	poll_p: Program(Counter)
	program_init(&poll_p, Counter{}, counter_update, counter_view)
	poll_err := run(&poll_p, &src, &poll_out)
	input_close(&src)
	posix.close(poll_fds[0])
	testing.expect(t, poll_err == nil, "run should exit cleanly")

	nbio_fds: [2]posix.FD
	testing.expect(t, posix.pipe(&nbio_fds) == .OK, "pipe should succeed")
	testing.expect_value(t, posix.write(nbio_fds[1], raw_data(string("aaq")), 3), 3)
	posix.close(nbio_fds[1])

	nbio_out := strings.builder_make(); defer strings.builder_destroy(&nbio_out)
	nbio_p: Program(Counter)
	program_init(&nbio_p, Counter{}, counter_update, counter_view)
	nbio_err := run_nbio(&nbio_p, nbio_fds[0], &nbio_out)
	posix.close(nbio_fds[0])
	testing.expect(t, nbio_err == nil, "run_nbio should exit cleanly")

	testing.expect_value(t, poll_p.model.n, nbio_p.model.n)
	testing.expectf(t, strings.to_string(poll_out) == strings.to_string(nbio_out),
		"run() and run_nbio produced different output for identical input\n run():     %q\n run_nbio(): %q",
		strings.to_string(poll_out), strings.to_string(nbio_out))
}

// ============================================================================
// FRAME COALESCING (run_nbio).
//
// run_nbio drained the mailbox in a batch but still called the old apply() --
// update AND render AND write(2) -- once per message, so it coalesced exactly
// nothing; the drain only decided how often it went back to the kernel. Same
// assertion as run()'s (tea_test.odin), and here it is exact rather than
// bounded: this host is single-threaded, so a 201-byte read arrives as ONE
// completion, decodes to 201 keys, and every one of them is in the mailbox
// before the loop next drains. One frame is not "usually" the answer, it is
// the answer.
// ============================================================================
@(test)
test_run_nbio_coalesces_a_burst_into_one_frame :: proc(t: ^testing.T) {
	N :: 200
	payload := strings.builder_make(); defer strings.builder_destroy(&payload)
	for i in 0 ..< N { strings.write_rune(&payload, rune('a' + i % 26)) }
	want := strings.clone(strings.to_string(payload)); defer delete(want)
	strings.write_rune(&payload, '!')

	fds: [2]posix.FD
	testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
	read_fd, write_fd := fds[0], fds[1]
	defer posix.close(read_fd)
	s := strings.to_string(payload)
	testing.expect_value(t, posix.write(write_fd, raw_data(s), len(s)), len(s))
	posix.close(write_fd)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Burst_Log)
	program_init(&p, Burst_Log{seen = strings.builder_make()}, burst_update, burst_view)
	defer strings.builder_destroy(&p.model.seen)   // see tea_test.odin's copy of this line

	testing.expect(t, run_nbio(&p, read_fd, &b) == nil, "run_nbio should exit cleanly")
	testing.expectf(t, strings.to_string(p.model.seen) == want,
		"update() did not see all %d keys in order -- got %d chars",
		N, strings.builder_len(p.model.seen))

	frames := strings.count(strings.to_string(b), "<")
	testing.expectf(t, frames <= 4,
		"run_nbio painted %d frames for a %d-key burst delivered in one read (pre-coalescing: %d)",
		frames, N, N + 2)
}

// ============================================================================
// F02: run_nbio never closed the mailbox on its teardown path, so
// dispatcher_destroy ran against an open queue nothing drained any more and
// every retry-forever producer that landed on it spun for the rest of the
// process's life.
//
// The repro needs no panic and nothing exotic -- just the ordinary shape of a
// spinner app: a repeating every() plus one Cmd still in flight when the user
// quits. dispatcher_destroy blocks in thread.pool_finish waiting for that Cmd
// and only stops the timer service AFTERWARDS, and the timer fills the
// undrained 256-slot mailbox during exactly that window (1 ms interval, so
// ~256 ms in). With the mailbox left open the timer thread parks in
// send_or_retry forever, the finished Cmd parks in deliver_result forever, and
// pool_finish never returns: the process hangs with the terminal still raw and
// the alternate screen still up.
//
// Driven on a background thread with a bounded wait for the same reason
// Nbio_Overflow_Harness is: a regression has to FAIL this test within seconds,
// not wedge the whole suite.
// ============================================================================
Nbio_Teardown_Tick :: struct {}

Nbio_Teardown_Ctx :: struct {
	stage:     int,
	slow_done: sync.Sema,
	read_fd:   posix.FD,
	b:         strings.Builder,
	err:       Run_Error,
	done:      bool,
}

nbio_teardown_tick_fn :: proc(env: rawptr, tk: time.Tick) -> any {
	return box(Nbio_Teardown_Tick{}, context.allocator)
}

nbio_teardown_slow_fn :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	c := (cast(^^Nbio_Teardown_Ctx)env)^
	// Long enough that dispatcher_destroy is definitely still inside
	// thread.pool_finish while the 1 ms timer keeps filling the mailbox.
	time.sleep(1 * time.Second)
	sync.sema_post(&c.slow_done)
	return box(Empty_Result{}, context.allocator)
}

Nbio_Teardown_Model :: struct { ctx: ^Nbio_Teardown_Ctx }

nbio_teardown_update :: proc(m: ^Nbio_Teardown_Model, msg: any, alloc: mem.Allocator) -> Cmd {
	if _, is_tick := msg.(Nbio_Teardown_Tick); is_tick {
		m.ctx.stage += 1
		switch m.ctx.stage {
		case 1: return cmd_from(nbio_teardown_slow_fn, m.ctx, context.allocator)
		case 2: return quit_cmd()
		}
	}
	return cmd_nil()
}

nbio_teardown_view :: proc(m: Nbio_Teardown_Model, alloc: mem.Allocator) -> string { return "" }

@(test)
test_run_nbio_closes_the_mailbox_before_tearing_the_dispatcher_down :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
	read_fd, write_fd := fds[0], fds[1]
	defer posix.close(write_fd)   // never written: this session ends via the timer, not a key

	c := new(Nbio_Teardown_Ctx); defer free(c)
	c.read_fd = read_fd
	c.b = strings.builder_make()

	every_cmd, handle := every(1 * time.Millisecond, nbio_teardown_tick_fn, 0, context.allocator)

	th := thread.create(proc(th: ^thread.Thread) {
		c := cast(^Nbio_Teardown_Ctx)th.data
		p: Program(Nbio_Teardown_Model)
		// The init Cmd is stashed on the context by the test below before the
		// thread starts; see there for why it cannot be built in here.
		program_init(&p, Nbio_Teardown_Model{ctx = c}, nbio_teardown_update, nbio_teardown_view,
			g_nbio_teardown_init_cmd)
		c.err = run_nbio(&p, c.read_fd, &c.b)
		sync.atomic_store(&c.done, true)
	})
	g_nbio_teardown_init_cmd = every_cmd
	th.data = c
	th.init_context = context   // see tea_test.odin's Overflow_Harness for why this must be inherited
	thread.start(th)

	start := time.now()
	timeout :: 10 * time.Second
	for !sync.atomic_load(&c.done) {
		if time.since(start) > timeout {
			testing.expect(t, false,
				"run_nbio did not return within 10s of quitting with a repeating every() and one Cmd in flight -- "+
				"the mailbox is not being closed before dispatcher_destroy, so a producer is spinning on Full forever")
			timer_stop(handle)
			return   // deliberately leaks the wedged thread rather than hanging the suite
		}
		time.sleep(20 * time.Millisecond)
	}

	thread.join(th)
	thread.destroy(th)
	timer_stop(handle)
	posix.close(read_fd)
	strings.builder_destroy(&c.b)

	testing.expect(t, c.err == nil, "run_nbio should exit cleanly")

	// Let the 1 s Cmd finish before this test's Tracking_Allocator rotates --
	// same trailing-wait discipline tea_test.odin's slow-Cmd test documents.
	// It has almost certainly already fired (dispatcher_destroy waited for it),
	// so this is a no-op in the normal case.
	sync.sema_wait(&c.slow_done)
}

// An Odin thread proc is a plain `proc(^thread.Thread)` with no closure, and
// `every()` has to be called from the TEST (which owns the ^Timer_Handle and
// the timer_stop it obliges) rather than from inside the thread body. A
// package-level handoff is the smallest thing that bridges the two; it is only
// ever written before thread.start and read once after, so the start is the
// happens-before edge and it needs no atomics.
@(private = "file")
g_nbio_teardown_init_cmd: Cmd

// ============================================================================
// F16: while the mailbox stayed non-empty, run_nbio's drain never fell through
// to nbio.tick() -- the ONLY thing that completes a read -- so the loop read no
// input for the rest of the process's life while repainting happily enough to
// look alive.
//
// The trigger is a sustained per-message cost above the arrival interval, and
// it is a cliff rather than a gradient: every(16 ms) against 12 ms of work per
// message quits normally; every(16 ms) against 17 ms never sees another key.
// This test sits well past the cliff (1 ms interval, 2 ms of work) and asserts
// the only thing that matters -- a keystroke written long after the loop is
// running still reaches update().
// ============================================================================
Nbio_Starve_Ctx :: struct {
	read_fd: posix.FD,
	b:       strings.Builder,
	err:     Run_Error,
	done:    bool,
	keys:    int,
}

nbio_starve_tick_fn :: proc(env: rawptr, tk: time.Tick) -> any {
	return box(Nbio_Teardown_Tick{}, context.allocator)
}

Nbio_Starve_Model :: struct { ctx: ^Nbio_Starve_Ctx }

nbio_starve_update :: proc(m: ^Nbio_Starve_Model, msg: any, alloc: mem.Allocator) -> Cmd {
	switch v in msg {
	case Nbio_Teardown_Tick:
		// The whole point: every message costs more than the interval between
		// messages, so the mailbox never empties on its own.
		time.sleep(2 * time.Millisecond)
	case Key_Msg:
		if v.code == .Rune && v.r == 'q' {
			sync.atomic_store(&m.ctx.keys, 1)
			return quit_cmd()
		}
	}
	return cmd_nil()
}

nbio_starve_view :: proc(m: Nbio_Starve_Model, alloc: mem.Allocator) -> string { return "" }

@(private = "file")
g_nbio_starve_init_cmd: Cmd

@(test)
test_run_nbio_still_reads_input_while_the_mailbox_never_empties :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
	read_fd, write_fd := fds[0], fds[1]
	defer posix.close(write_fd)

	c := new(Nbio_Starve_Ctx); defer free(c)
	c.read_fd = read_fd
	c.b = strings.builder_make()

	every_cmd, handle := every(1 * time.Millisecond, nbio_starve_tick_fn, 0, context.allocator)

	th := thread.create(proc(th: ^thread.Thread) {
		c := cast(^Nbio_Starve_Ctx)th.data
		p: Program(Nbio_Starve_Model)
		program_init(&p, Nbio_Starve_Model{ctx = c}, nbio_starve_update, nbio_starve_view,
			g_nbio_starve_init_cmd)
		c.err = run_nbio(&p, c.read_fd, &c.b)
		sync.atomic_store(&c.done, true)
	})
	g_nbio_starve_init_cmd = every_cmd
	th.data = c
	th.init_context = context
	thread.start(th)

	// Written well after the loop has settled into the starving state, so the
	// key genuinely has to survive a mailbox that is already saturated.
	time.sleep(500 * time.Millisecond)
	testing.expect_value(t, posix.write(write_fd, raw_data(string("q")), 1), 1)

	start := time.now()
	timeout :: 20 * time.Second
	for !sync.atomic_load(&c.done) {
		if time.since(start) > timeout {
			testing.expect(t, false,
				"run_nbio never processed a keystroke written 500ms into a session whose mailbox never empties -- "+
				"nbio.tick() is unreachable, so no read ever completes and the program is permanently deaf")
			timer_stop(handle)
			return   // deliberately leaks the wedged thread rather than hanging the suite
		}
		time.sleep(20 * time.Millisecond)
	}

	thread.join(th)
	thread.destroy(th)
	timer_stop(handle)
	posix.close(read_fd)
	strings.builder_destroy(&c.b)

	testing.expect(t, c.err == nil, "run_nbio should exit cleanly")
	testing.expect_value(t, sync.atomic_load(&c.keys), 1)
}
