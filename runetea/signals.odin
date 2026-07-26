package runetea

import "core:sync"
import "core:sys/posix"
import "core:thread"

Interrupt_Msg   :: struct {}
Window_Size_Msg :: struct { w, h: int }

// SIGWINCH is a BSD extension and is NOT a member of posix.Signal, which stops
// at the POSIX-standard set. The per-platform constant does exist, so cast it.
SIGWINCH :: posix.Signal(posix.SIGWINCH)

// Internal-only wakeup for signal_watcher_stop, deliberately NOT SIGWINCH.
// Reusing SIGWINCH for the stop wakeup (as an earlier draft of this file did)
// would make the watcher requery term_size and enqueue a spurious
// Window_Size_Msg on every shutdown, since the switch below can't tell "a
// real resize" from "stop() nudged sigwait". SIGUSR2 falls through the
// switch's default case (a deliberate no-op) and the loop simply re-checks
// sw.stop on its next iteration -- no fabricated message, no ambiguity.
//
// Deliberately NOT SIGUSR1: loop_test.odin's EINTR regression test
// (test_input_read_retries_on_eintr) already owns SIGUSR1 process-wide, with
// a real sigaction handler and an UNBLOCKED delivery target -- it relies on
// that signal reaching a poll()-blocked thread as an actual interrupt, not a
// queued-and-blocked one. Since ODIN_TEST_THREADS=1 reuses a single pool
// worker thread for every test in this package, and pthread_sigmask changes
// persist on a thread across sequential test invocations, blocking SIGUSR1
// here would leak into that unrelated test if this file's tests happen to
// run first, causing it to hang (SIGUSR1 blocked means it can no longer
// interrupt anything). Confirmed by reading loop_test.odin's use of SIGUSR1
// before picking a signal for this file. SIGUSR2 is unused anywhere else in
// this package.
@(private = "file")
SIG_WAKE :: posix.Signal.SIGUSR2

Signal_Watcher :: struct {
	thread:  ^thread.Thread,
	mailbox: ^Mailbox,
	tty:     posix.FD,
	running: bool,
	stop:    bool,

	// The watcher's own OS thread handle, captured by the watcher itself as
	// (almost) the first thing it does -- right after installing its own
	// per-thread crash-handler altstack, see FIX 2's comment in the thread
	// body below -- and published through `ready`. Every
	// wakeup aimed at this watcher -- signal_watcher_stop and this package's
	// own tests -- targets this handle directly with pthread_kill. See
	// signal_watcher_stop's doc comment for why that is load-bearing, not a
	// style choice: posix.raise() and posix.kill(getpid(), ...) were both
	// tried and both proven unsafe here (see task-7-report.md for the
	// reproductions).
	native: posix.pthread_t,
	ready:  sync.Sema,

	// Optional cross-thread notification, mirroring Dispatcher.wake
	// (cmd.odin) exactly -- same reason: run()'s poll-thread path leaves
	// this nil (mailbox_recv's own semaphore is the single wait point), and
	// run_nbio (loop_nbio.odin) sets it to nbio.wake_up so a SIGINT/SIGWINCH
	// delivered while the loop thread is parked in nbio.tick() is not stuck
	// there until some UNRELATED read or Cmd completion happens to wake it.
	wake:      proc(rawptr),
	wake_data: rawptr,
}

// Blocks the handled signals on the calling thread, then waits for them on a
// dedicated ordinary thread. Because sigwait is not a signal handler, this
// thread may take locks and allocate -- no async-signal-safety constraint
// applies. This is a closer analogue of Go's signal.Notify than a self-pipe.
//
// pthread_sigmask affects only the CALLING thread's mask; a new thread
// inherits whatever mask its creator had at the moment of thread.create, but
// no OTHER already-running thread is touched. If some other thread already
// exists with SIGINT/SIGTERM/SIGWINCH unblocked when this is called (e.g. a
// worker pool started earlier in main()), a process-directed raise of one of
// those signals can still be delivered to that thread's own (usually fatal)
// default disposition instead of reaching this watcher -- confirmed
// empirically, not theoretical: a minimal repro with one unrelated unblocked
// thread killed the process 5/5 times via SIGINT's default action even
// though a correctly-blocked sigwait watcher existed elsewhere in the same
// process (see task-7-report.md). Call this before spawning any other
// threads so every later thread inherits the block from this one.
//
// Blocks until the watcher thread has captured its own native handle and
// published it through sw.native, so that by the time this call returns,
// signal_watcher_stop (or anything else) can safely target that thread.
//
// Delivers `msg` to `m`, retrying on a transient Full and giving up on a
// terminal Closed (FIX 1, final fix-wave report). Used for both SIGWINCH and
// SIGINT/SIGTERM below -- a dropped message is not acceptable for either:
// silently discarding a resize means a repaint the user is actively looking
// at (they just resized the window) never happens, and silently discarding
// an Interrupt_Msg is worse, since it can swallow the user's own Ctrl+C or
// an operator's kill(1)/systemd stop with no visible effect at all. The
// watcher thread runs sigwait in an ordinary loop, not a signal handler, so
// blocking here briefly to retry carries none of async-signal-safety's
// restrictions -- unlike crash_handler in guard.odin, which must never do
// this. Retrying is bounded only by the mailbox eventually closing: run()'s
// main loop is the sole consumer and keeps draining concurrently, so a
// Full here is expected to clear on its own; Closed means run() has already
// torn down and nothing sent from here on could ever be received anyway.
@(private = "file")
send_or_retry :: proc(sw: ^Signal_Watcher, msg: any) {
	for {
		switch mailbox_send(sw.mailbox, msg) {
		case .Ok:
			if sw.wake != nil { sw.wake(sw.wake_data) }
			return
		case .Closed: return
		case .Full:   thread.yield()
		}
	}
}

// Clear this mask before spawning a child process, or $EDITOR inherits it.
signal_watcher_start :: proc(sw: ^Signal_Watcher, m: ^Mailbox, tty: posix.FD, wake: proc(rawptr) = nil, wake_data: rawptr = nil) {
	sw.mailbox = m
	sw.tty = tty
	sw.running = true
	sw.wake = wake
	sw.wake_data = wake_data

	set: posix.sigset_t
	posix.sigemptyset(&set)
	posix.sigaddset(&set, .SIGINT)
	posix.sigaddset(&set, .SIGTERM)
	posix.sigaddset(&set, SIG_WAKE)
	posix.sigaddset(&set, SIGWINCH)
	posix.pthread_sigmask(.BLOCK, &set, nil)   // Sig.BLOCK, not .SIG_BLOCK

	// init_context for the same reason as Task 5's detached dispatch: without
	// it the watcher thread runs under runtime.default_context(), so the
	// messages it boxes below come from a different allocator than the main
	// loop's. See core/thread/thread.odin:534.
	sw.thread = thread.create(proc(th: ^thread.Thread) {
		sw := cast(^Signal_Watcher)th.data

		// Per-thread altstack (FIX 2, final fix-wave report), installed
		// before anything else on this thread: sigaltstack only takes
		// effect on the CALLING thread, so whatever install_crash_handlers
		// call happened on the thread that called signal_watcher_start
		// covers that thread only, not this brand-new one. Without this,
		// a stack-overflow SIGSEGV on the watcher thread re-faults on its
		// own exhausted stack with no altstack to catch it.
		install_crash_handlers()

		// Publish our own handle next. A signal sent to it while it is
		// blocked (inherited from the creating thread above) simply queues
		// as pending on this specific thread -- correctness does not
		// depend on having reached sigwait yet, only on `ready` being
		// posted before a caller ever reads sw.native.
		sw.native = posix.pthread_self()
		sync.sema_post(&sw.ready)

		set: posix.sigset_t
		posix.sigemptyset(&set)
		posix.sigaddset(&set, .SIGINT)
		posix.sigaddset(&set, .SIGTERM)
		posix.sigaddset(&set, SIG_WAKE)
		posix.sigaddset(&set, SIGWINCH)

		for !sync.atomic_load(&sw.stop) {
			sig: posix.Signal
			// sigwait returns Errno; success is .NONE, not .OK
			if posix.sigwait(&set, &sig) != .NONE { continue }
			#partial switch sig {
			case SIGWINCH:
				w, h, ok := term_size(sw.tty)
				if !ok { w, h = 0, 0 }
				send_or_retry(sw, box(Window_Size_Msg{w = w, h = h}, context.allocator))
			case .SIGINT, .SIGTERM:
				send_or_retry(sw, box(Interrupt_Msg{}, context.allocator))
			case:
				// SIG_WAKE (signal_watcher_stop's nudge, handled by the loop
				// condition re-checking sw.stop above) or anything else not
				// subscribed here -- both deliberate no-ops.
			}
		}
	})
	sw.thread.data = sw
	sw.thread.init_context = context
	thread.start(sw.thread)

	sync.sema_wait(&sw.ready)
}

// Signals the watcher thread to exit and joins it. Safe to call once per
// start; running guards against a repeat call trying to join an already-
// destroyed thread.
//
// Wakes the watcher with pthread_kill(sw.native, SIG_WAKE) -- targeted
// directly at the watcher's own OS thread. Deliberately NOT posix.raise(),
// which sends to whichever thread calls raise() (thread-directed via
// tgkill under glibc/NPTL) -- almost never the watcher thread itself, so it
// would sit pending on the CALLER's thread forever and this join would
// never return. Deliberately NOT posix.kill(getpid(), ...) either: that is
// process-directed, and the kernel is free to deliver it to any thread in
// the process that doesn't have it blocked; if some other thread has a
// fatal default disposition for the signal (as any thread does by default
// for SIGWINCH/SIGINT/SIGTERM), the whole process can die there instead of
// waking this watcher. Both failure modes were reproduced in isolation
// before writing this -- see task-7-report.md. Targeting sw.native
// sidesteps them entirely: the watcher thread is the only possible
// recipient, so there is nothing to race against, including the case where
// no external signal ever arrives.
signal_watcher_stop :: proc(sw: ^Signal_Watcher) {
	if !sw.running { return }
	sync.atomic_store(&sw.stop, true)
	posix.pthread_kill(sw.native, SIG_WAKE)
	thread.join(sw.thread)
	thread.destroy(sw.thread)
	sw.running = false
}
