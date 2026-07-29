package runetea

import "core:c"
import "core:strings"
import "core:testing"
import "core:sys/posix"

// --- a note on how these tests raise signals ---
//
// The brief for this task drafted these tests around posix.raise(sig). That
// does not work and was proven not to work before this file was written:
// raise() is thread-directed (glibc/NPTL implements it as
// pthread_kill(pthread_self(), sig)), so it queues on whichever thread calls
// it -- here, the same test-runner pool thread that called
// signal_watcher_start, never the watcher thread itself. A minimal C repro
// of exactly this shape (block on thread A, spawn thread B that inherits the
// block and sigwaits, have A raise() on itself) hung 100% of the time
// waiting for B to wake. See task-7-report.md for the reproduction.
//
// posix.kill(posix.getpid(), sig) (process-directed) was tried next and is
// closer to how a real terminal delivers SIGINT/SIGWINCH, but it is unsafe
// specifically UNDER THIS TEST RUNNER: with -define:ODIN_TEST_THREADS=1,
// there are two threads alive while a test body runs -- the pool worker
// executing this test (which blocks the signal via signal_watcher_start) and
// the test runner's own main thread driving the pool loop (which has never
// touched its signal mask and still has the default, fatal disposition for
// SIGINT/SIGTERM). A process-directed signal is a race for which thread the
// kernel picks; in a 5-run repro matching this exact topology, the runner's
// main thread lost that race and the whole process died via default
// disposition 5/5 times, in spite of a correctly-blocked sigwait watcher
// existing elsewhere in the same process. See task-7-report.md.
//
// Targeting the watcher thread's own OS handle with pthread_kill sidesteps
// both problems: only that one thread is ever a candidate for delivery, so
// there is no other thread's disposition to race against, and it works
// regardless of which thread happens to call it. signal_watcher_start
// blocks until sw.native is safe to read (see its doc comment), so there is
// also no need for the brief's original `time.sleep` before sending --
// pthread_kill queues on a thread that already has the signal blocked
// whether or not that thread has reached sigwait() yet.

@(test)
test_sigwinch_becomes_a_window_size_msg :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	defer mailbox_destroy(&m)

	sw: Signal_Watcher
	signal_watcher_start(&sw, &m, posix.FD(-1))  // invalid fd: size lookup fails, msg still sent
	defer signal_watcher_stop(&sw)

	testing.expect_value(t, posix.pthread_kill(sw.native, SIGWINCH), posix.Errno.NONE)

	msg, ok := mailbox_recv(&m)
	defer box_free(msg, context.allocator)
	testing.expect(t, ok, "expected a message from the signal watcher")
	_, is_size := msg.(Window_Size_Msg)
	testing.expect(t, is_size, "SIGWINCH should produce a Window_Size_Msg")
}

@(test)
test_sigint_becomes_an_interrupt_msg :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	defer mailbox_destroy(&m)

	sw: Signal_Watcher
	signal_watcher_start(&sw, &m, posix.FD(-1))
	defer signal_watcher_stop(&sw)

	testing.expect_value(t, posix.pthread_kill(sw.native, .SIGINT), posix.Errno.NONE)

	msg, ok := mailbox_recv(&m)
	defer box_free(msg, context.allocator)
	testing.expect(t, ok, "expected a message from the signal watcher")
	_, is_int := msg.(Interrupt_Msg)
	testing.expect(t, is_int, "SIGINT should produce an Interrupt_Msg")
}

// signal_watcher_stop must reliably terminate the watcher thread even when
// no signal was ever delivered to it -- e.g. a TUI that runs to a clean exit
// without the user ever hitting Ctrl-C or resizing the terminal. This is
// exactly thread.join(sw.thread) inside signal_watcher_stop; if the wakeup
// mechanism only worked when "primed" by a prior real signal, this test
// would hang instead of returning.
@(test)
test_signal_watcher_stop_terminates_with_no_signal_ever_sent :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	defer mailbox_destroy(&m)

	sw: Signal_Watcher
	signal_watcher_start(&sw, &m, posix.FD(-1))
	signal_watcher_stop(&sw)  // must return; no signal was ever raised

	testing.expect(t, !sw.running, "signal_watcher_stop should clear running")
}

// ============================================================================
// BUG 3: the blocked signal mask is inherited by CHILD PROCESSES.
//
// signal_watcher_start blocks SIGINT/SIGTERM/SIGWINCH/SIGUSR2 so a dedicated
// thread can sigwait() them. exec(2) resets handlers to SIG_DFL and drops the
// altstack, but it does NOT reset the blocked MASK -- so an application that
// shells out to $EDITOR hands it a terminal it cannot be interrupted from, and
// the symptom looks like a bug in the child. Nothing in RuneTea used to offer
// a way to clear it.
//
// MEASURED AFTER A REAL exec, not merely after a fork: the whole claim is about
// what survives exec, so the child below exec's /bin/cat on its own
// /proc/self/status and the parent reads SigBlk out of the result. Anything
// less would be testing a different proposition.
// ============================================================================

@(private = "file")
SIGBLK_WATCHED :: u64(1) << (2 - 1) |      // SIGINT
                  u64(1) << (15 - 1) |     // SIGTERM
                  u64(1) << (12 - 1) |     // SIGUSR2 (the watcher's own stop nudge)
                  u64(1) << (28 - 1)       // SIGWINCH

// Parses the hex mask out of the "SigBlk:\t<hex>" line of a /proc/<pid>/status
// dump. Returns ok=false if the field is absent, which is how this test
// notices that it measured nothing rather than passing vacuously.
@(private = "file")
parse_sigblk :: proc(status: string) -> (mask: u64, ok: bool) {
	key :: "SigBlk:"
	i := strings.index(status, key)
	if i < 0 { return 0, false }
	rest := status[i + len(key):]
	// Skip whitespace, then consume hex digits.
	for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t') { rest = rest[1:] }
	n := 0
	for n < len(rest) {
		c := rest[n]
		switch {
		case c >= '0' && c <= '9': mask = mask * 16 + u64(c - '0')
		case c >= 'a' && c <= 'f': mask = mask * 16 + u64(c - 'a') + 10
		case c >= 'A' && c <= 'F': mask = mask * 16 + u64(c - 'A') + 10
		case: return mask, n > 0
		}
		n += 1
	}
	return mask, n > 0
}

// Forks, optionally clears RuneTea's mask, exec's `cat /proc/self/status`, and
// returns the child's post-exec SigBlk.
@(private = "file")
child_sigblk_after_exec :: proc(unblock: bool) -> (mask: u64, ok: bool) {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK { return 0, false }

	pid := posix.fork()
	if pid < 0 {
		posix.close(fds[0]); posix.close(fds[1])
		return 0, false
	}
	if pid == 0 {
		// CHILD. Only async-signal-safe calls before exec, which is exactly
		// what signal_unblock_for_child is documented to be.
		posix.close(fds[0])
		posix.dup2(fds[1], posix.STDOUT_FILENO)
		if fds[1] > 2 { posix.close(fds[1]) }
		if unblock { signal_unblock_for_child() }
		argv := []cstring{"cat", "/proc/self/status", nil}
		posix.execv("/bin/cat", raw_data(argv))
		posix._exit(127)   // execv only returns on failure
	}

	posix.close(fds[1])
	buf: [16384]u8
	total := 0
	for total < len(buf) {
		n := posix.read(fds[0], raw_data(buf[total:]), uint(len(buf) - total))
		if n <= 0 { break }
		total += int(n)
	}
	posix.close(fds[0])

	status: c.int
	posix.waitpid(pid, &status, {})

	return parse_sigblk(string(buf[:total]))
}

@(test)
test_a_child_process_can_be_given_back_a_clean_signal_mask :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	defer mailbox_destroy(&m)

	// RESTORE THE MASK ON THE WAY OUT, and note WHY this test in particular has
	// to. signal_watcher_start blocks on the CALLING thread and nothing ever
	// unblocks it, and with -define:ODIN_TEST_THREADS=1 every test in this
	// package runs on the same pool worker -- so the block persists into every
	// later test on that thread. It does not matter for the other signals tests
	// because they sort alphabetically after term_test.odin's crash-path tests,
	// which fork children that must die by SIGTERM; this one sorts to the very
	// front of the package and would leave those children unkillable. Registered
	// BEFORE the stop so that, LIFO, it runs after it. Also the one place in the
	// suite that exercises signal_unblock_for_child on the calling thread rather
	// than in a child.
	defer signal_unblock_for_child()

	sw: Signal_Watcher
	signal_watcher_start(&sw, &m, posix.FD(-1))   // blocks the mask on THIS thread
	defer signal_watcher_stop(&sw)

	// FIRST, PROVE THE HAZARD IS REAL rather than assuming it. Without the
	// clear, every watched signal is still blocked on the far side of an exec.
	inherited, ok1 := child_sigblk_after_exec(false)
	if !testing.expect(t, ok1, "could not read the child's SigBlk (is /bin/cat present?)") { return }
	testing.expectf(t, inherited & SIGBLK_WATCHED == SIGBLK_WATCHED,
		"expected the child to inherit every watched signal blocked, SigBlk=%x", inherited)

	// THEN THE FIX: signal_unblock_for_child between fork and exec leaves the
	// child with none of them blocked -- Ctrl-C works again.
	cleared, ok2 := child_sigblk_after_exec(true)
	if !testing.expect(t, ok2, "could not read the child's SigBlk") { return }
	testing.expectf(t, cleared & SIGBLK_WATCHED == 0,
		"signal_unblock_for_child left signals blocked in the child, SigBlk=%x", cleared)
}

// The unblock and the block must be built from the SAME set, or a signal added
// to the watcher later is a signal a child silently keeps blocked. One
// definition, asserted to cover every signal the watcher waits on.
@(test)
test_runetea_signal_set_covers_every_signal_the_watcher_blocks :: proc(t: ^testing.T) {
	set: posix.sigset_t
	runetea_signal_set(&set)
	for sig in ([]posix.Signal{.SIGINT, .SIGTERM, .SIGUSR2, SIGWINCH}) {
		testing.expectf(t, posix.sigismember(&set, sig) == 1, "%v missing from runetea_signal_set", sig)
	}
}

// signal_watcher_start blocks RuneTea's set into the CALLING thread's mask --
// that is what makes sigwait on the watcher thread the only delivery path.
// pthread_sigmask changes are per-thread and permanent, so if stop does not put
// the mask back, an app that stops a watcher and carries on runs with
// SIGINT/SIGTERM/SIGWINCH/SIGUSR2 blocked for the rest of that thread's life,
// and everything it forks inherits that (the un-Ctrl-C-able $EDITOR case).
//
// This also removes a latent trap in this very file: under ODIN_TEST_THREADS=1
// every test shares one worker, so an unrestored mask leaked FORWARD into any
// later test that forks a child expected to die by a signal. The crash-path
// tests in term_test.odin only escaped it by alphabetical luck.
@(test)
test_stop_restores_the_signal_mask_it_displaced :: proc(t: ^testing.T) {
	before: posix.sigset_t
	posix.pthread_sigmask(.SETMASK, nil, &before)

	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 8), nil)
	defer mailbox_destroy(&m)

	sw: Signal_Watcher
	signal_watcher_start(&sw, &m, posix.FD(-1))

	during: posix.sigset_t
	posix.pthread_sigmask(.SETMASK, nil, &during)
	testing.expect(t, posix.sigismember(&during, .SIGINT) == 1,
		"start must block SIGINT on the calling thread -- otherwise sigwait is not the only delivery path")

	signal_watcher_stop(&sw)

	after: posix.sigset_t
	posix.pthread_sigmask(.SETMASK, nil, &after)
	for sig in ([?]posix.Signal{.SIGINT, .SIGTERM, .SIGUSR2}) {
		testing.expectf(t, posix.sigismember(&after, sig) == posix.sigismember(&before, sig),
			"stop left %v's blocked state changed: before=%d after=%d",
			sig, posix.sigismember(&before, sig), posix.sigismember(&after, sig))
	}
}

// SETMASK-to-saved, not UNBLOCK-of-our-set: a caller that had DELIBERATELY
// blocked one of these before calling start must still have it blocked after
// stop. Unblocking our own set would silently destroy state we did not create.
@(test)
test_stop_does_not_unblock_a_signal_the_caller_blocked_itself :: proc(t: ^testing.T) {
	mine: posix.sigset_t
	posix.sigemptyset(&mine)
	posix.sigaddset(&mine, .SIGTERM)
	prev: posix.sigset_t
	posix.pthread_sigmask(.BLOCK, &mine, &prev)
	defer posix.pthread_sigmask(.SETMASK, &prev, nil)

	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 8), nil)
	defer mailbox_destroy(&m)

	sw: Signal_Watcher
	signal_watcher_start(&sw, &m, posix.FD(-1))
	signal_watcher_stop(&sw)

	after: posix.sigset_t
	posix.pthread_sigmask(.SETMASK, nil, &after)
	testing.expect(t, posix.sigismember(&after, .SIGTERM) == 1,
		"the caller blocked SIGTERM before start; stop must not have cleared it")
}
