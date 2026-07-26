package runetea

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
