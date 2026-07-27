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
// this test can pass is if the async Quit_Msg genuinely reaches apply().
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
// through the SAME apply() (tea.odin, now package-visible) -- direct evidence
// that the two event-loop hosts differ only in how a message reaches apply(),
// not in what happens once it does. Both driven over a pipe (not
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
