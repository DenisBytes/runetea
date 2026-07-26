package runetea

import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
test_input_source_from_bytes_reads_all :: proc(t: ^testing.T) {
	src := input_source_from_bytes([]u8{'a', 'b', 'c'})
	defer input_close(&src)

	buf: [8]u8
	n, ok, woken := input_read(&src, buf[:])
	testing.expect(t, ok, "read should succeed")
	testing.expect(t, !woken, "a bytes source never reports woken")
	testing.expect_value(t, n, 3)
	testing.expect_value(t, string(buf[:n]), "abc")

	n2, ok2, _ := input_read(&src, buf[:])
	testing.expect(t, !ok2 || n2 == 0, "second read should report EOF")
}

@(test)
test_input_source_from_bytes_respects_small_buffer :: proc(t: ^testing.T) {
	src := input_source_from_bytes([]u8{'h', 'e', 'l', 'l', 'o'})
	defer input_close(&src)

	buf: [2]u8
	n, ok, _ := input_read(&src, buf[:])
	testing.expect(t, ok, "read should succeed")
	testing.expect_value(t, n, 2)
	testing.expect_value(t, string(buf[:n]), "he")
}

@(test)
test_input_source_from_fd_reads_a_pipe :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect_value(t, posix.pipe(&fds), posix.result.OK)
	defer { posix.close(fds[0]); posix.close(fds[1]) }

	msg := "xyz"
	posix.write(fds[1], raw_data(msg), len(msg))

	src, ok := input_source_from_fd(fds[0])
	testing.expect(t, ok, "fd source should initialise")
	defer input_close(&src)

	buf: [8]u8
	n, rok, woken := input_read(&src, buf[:])
	testing.expect(t, rok, "read should succeed")
	testing.expect(t, !woken, "a normal data read is not a wake")
	testing.expect_value(t, n, 3)
	testing.expect_value(t, string(buf[:n]), "xyz")
}

// --- fix round 1: EINTR must not be reported as read failure ---

// Shared between the test goroutine below and its worker thread. tid is
// written once by the worker (before it can possibly block) and read once
// by the test after tid_set is posted -- sema_wait/sema_post give that a
// happens-before edge, so there is no data race despite two threads
// touching tid.
Eintr_Shared :: struct {
	src:     ^Input_Source,
	tid:     posix.pthread_t,
	tid_set: sync.Sema,
	n:       int,
	ok:      bool,
	woken:   bool,
}

eintr_worker :: proc(data: rawptr) {
	sh := cast(^Eintr_Shared)data
	sh.tid = posix.pthread_self()
	sync.sema_post(&sh.tid_set)
	buf: [8]u8
	sh.n, sh.ok, sh.woken = input_read(sh.src, buf[:])
}

// core:sys/posix's read/poll bindings have no built-in EINTR retry
// (unistd.odin:720, poll.odin:25). A signal delivered while a reader thread
// is blocked inside input_read -- e.g. Task 7's SIGWINCH handler firing
// while a user drags a window edge -- must not be mistaken for EOF or a
// hard error. This installs a handler WITHOUT SA_RESTART (so the kernel
// does not silently restart poll()/read() on our behalf -- if it did, this
// test would pass even with the bug, since fd_source_read would never
// observe EINTR at all) and confirms a still-pending, later-arriving write
// is delivered normally afterward.
@(test)
test_input_read_retries_on_eintr :: proc(t: ^testing.T) {
	act := posix.sigaction_t{}
	act.sa_handler = proc "c" (sig: posix.Signal) {}
	// act.sa_flags left at its zero value: {} does NOT include .RESTART.
	testing.expect_value(t, posix.sigaction(.SIGUSR1, &act, nil), posix.result.OK)

	fds: [2]posix.FD
	testing.expect_value(t, posix.pipe(&fds), posix.result.OK)
	defer { posix.close(fds[0]); posix.close(fds[1]) }

	src, ok := input_source_from_fd(fds[0])
	testing.expect(t, ok, "fd source should initialise")
	defer input_close(&src)

	sh := Eintr_Shared{src = &src}
	th := thread.create_and_start_with_data(&sh, eintr_worker, init_context = context)

	sync.sema_wait(&sh.tid_set)
	// tid_set only proves the worker captured its tid, not that it has
	// reached poll() yet. There is no portable signal-safe way to observe
	// "now blocked inside poll()" from outside, so this sleep is a
	// best-effort window -- generous relative to how fast a thread reaches
	// its very next statement after posting a semaphore.
	time.sleep(20 * time.Millisecond)
	testing.expect_value(t, posix.pthread_kill(sh.tid, .SIGUSR1), posix.Errno.NONE)
	time.sleep(20 * time.Millisecond)

	msg := "ok"
	posix.write(fds[1], raw_data(msg), len(msg))
	thread.destroy(th)  // joins, then frees the ^Thread itself

	testing.expect(t, sh.ok, "EINTR must not be reported as read failure")
	testing.expect(t, !sh.woken, "this was a data delivery, not input_wake")
	testing.expect_value(t, sh.n, 2)
}

// --- fix round 1: input_wake must cancel a blocked reader ---

Wake_Shared :: struct {
	src:     ^Input_Source,
	started: sync.Sema,
	n:       int,
	ok:      bool,
	woken:   bool,
}

wake_worker :: proc(data: rawptr) {
	sh := cast(^Wake_Shared)data
	sync.sema_post(&sh.started)
	buf: [8]u8
	sh.n, sh.ok, sh.woken = input_read(sh.src, buf[:])
}

// Before this fix, Fd_Source held only a bare fd and input_close never
// closed it either -- nothing could unblock a thread parked in a real,
// data-less read. Task 10's reader thread checks a `stop` flag only BETWEEN
// reads then calls thread.join(); if the user quits without one more
// keypress arriving, that join hangs forever. thread.destroy below (join,
// then free), with no data ever written to the pipe, is the proof: it must
// return promptly because of input_wake, not because data showed up.
@(test)
test_input_wake_cancels_a_blocked_read :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect_value(t, posix.pipe(&fds), posix.result.OK)
	defer { posix.close(fds[0]); posix.close(fds[1]) }

	src, ok := input_source_from_fd(fds[0])
	testing.expect(t, ok, "fd source should initialise")
	defer input_close(&src)

	sh := Wake_Shared{src = &src}
	th := thread.create_and_start_with_data(&sh, wake_worker, init_context = context)

	sync.sema_wait(&sh.started)
	time.sleep(20 * time.Millisecond)  // best-effort window, see above

	input_wake(&src)
	thread.destroy(th)  // hangs forever against the pre-fix code -- see comment above

	testing.expect(t, sh.woken, "input_wake must report woken=true")
	testing.expect(t, !sh.ok, "a wake is not a successful data read")
	testing.expect_value(t, sh.n, 0)
}
