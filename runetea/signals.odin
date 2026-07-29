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

	// The caller's signal mask as it was the instant before
	// signal_watcher_start blocked our set into it, so signal_watcher_stop
	// can put it back EXACTLY -- see that proc for why restoring is not
	// optional and why unblocking our own set would be the wrong way to do
	// it.
	saved_mask:  posix.sigset_t,
	mask_saved:  bool,
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

// EXACTLY THE SIGNALS signal_watcher_start BLOCKS, filled into `set`. One
// definition, three call sites (the blocking call below, the watcher thread's
// own sigwait set, and signal_unblock_for_child) so the three cannot drift --
// a signal added to the watcher but not to the child's unblock would be a
// signal an app's $EDITOR silently inherits blocked, which is the exact bug
// this proc's existence closes.
//
// PUBLIC, and takes the set by pointer, so an application that wants to build
// a mask of its own (say, to block these across a critical section, or to
// restore them by hand after a posix_spawn with its own sigmask attribute) can
// ask RuneTea what it actually blocks rather than hard-coding a copy that goes
// stale.
runetea_signal_set :: proc(set: ^posix.sigset_t) {
	posix.sigemptyset(set)
	posix.sigaddset(set, .SIGINT)
	posix.sigaddset(set, .SIGTERM)
	posix.sigaddset(set, SIG_WAKE)
	posix.sigaddset(set, SIGWINCH)
}

// UNBLOCKS RUNETEA'S SIGNALS ON THE CALLING THREAD. Call this in a child
// process, between fork(2) and exec(2), or the child inherits a blocked
// SIGINT/SIGTERM/SIGWINCH and is un-Ctrl-C-able.
//
// THE PROBLEM THIS EXISTS FOR. signal_watcher_start blocks those signals so a
// dedicated thread can sigwait() them (see its own doc comment for why that
// design, and why it must run before any other thread exists). A blocked signal
// mask is per-thread, is inherited by every thread created afterwards, and --
// the part that bites -- SURVIVES exec(2). Everything else about a process's
// signal disposition is reset by exec: handlers go back to SIG_DFL, sigaltstack
// is dropped. The MASK is not. So a program that shells out to `$EDITOR`, a
// pager, or a build tool hands it a terminal it cannot be interrupted from, and
// the symptom (Ctrl+C does nothing) looks like a bug in the child.
//
//     pid := posix.fork()
//     if pid == 0 {
//         runetea.signal_unblock_for_child()   // <-- here, before exec
//         posix.execvp(...)
//         posix._exit(127)
//     }
//
// SAFE BETWEEN fork AND exec, which is not a small claim: the child of a fork
// in a multi-threaded process (and RuneTea is always multi-threaded -- watcher,
// reader, pool, timer) may call only async-signal-safe functions. pthread_sigmask
// is on POSIX's async-signal-safe list, so this call is legal there. It does
// nothing else -- no allocation, no locks, no logging -- precisely so that stays
// true.
//
// UNBLOCK, NOT SETMASK(empty). This clears exactly what RuneTea blocked and
// leaves anything the APPLICATION blocked for its own reasons alone. A blanket
// "empty the mask" would silently undo the embedder's decisions, which is not
// this library's call to make.
//
// RUNETEA ITSELF EXECS NOTHING, so there is no internal call site to fix: the
// only fork/exec pairs in this repository are test harnesses under tools/
// (tools/httpquitcheck, tools/tier1check), which are separate `main` programs,
// not part of the library. This is a primitive for applications, which is what
// tea.ExecProcess would need if RuneTea ever grows one (docs/LIMITATIONS.md
// 8.1) -- and what an application needs today to shell out correctly.
signal_unblock_for_child :: proc() {
	set: posix.sigset_t
	runetea_signal_set(&set)
	posix.pthread_sigmask(.UNBLOCK, &set, nil)
}

// See signal_unblock_for_child for how an application clears the mask this
// installs before spawning a child process -- without it, $EDITOR inherits it.
signal_watcher_start :: proc(sw: ^Signal_Watcher, m: ^Mailbox, tty: posix.FD, wake: proc(rawptr) = nil, wake_data: rawptr = nil) {
	sw.mailbox = m
	sw.tty = tty
	sw.running = true
	sw.wake = wake
	sw.wake_data = wake_data

	set: posix.sigset_t
	runetea_signal_set(&set)
	// Capture the mask we are about to modify, so stop can restore it exactly.
	// Passing nil here -- which this used to do -- makes the block permanent
	// for the life of the calling THREAD: see signal_watcher_stop.
	posix.pthread_sigmask(.BLOCK, &set, &sw.saved_mask)   // Sig.BLOCK, not .SIG_BLOCK
	sw.mask_saved = true

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
		runetea_signal_set(&set)

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

	// PUT THE CALLER'S SIGNAL MASK BACK. start blocked our set into the
	// CALLING thread's mask (that is what makes sigwait on the watcher thread
	// the only delivery path), and pthread_sigmask changes are per-thread and
	// permanent -- nothing else ever undoes them. Without this, an app that
	// stops a watcher and carries on runs with SIGINT/SIGTERM/SIGWINCH/SIGUSR2
	// blocked for the rest of that thread's life, and anything it forks
	// inherits the same mask (see signal_unblock_for_child, which exists for
	// the fork-exec case this does not cover).
	//
	// SETMASK to the saved value, NOT UNBLOCK of our own set: the caller may
	// have deliberately blocked one of these signals before ever calling
	// start, and unblocking our set would silently clear that. Restoring the
	// exact mask we displaced is the only version that cannot destroy state we
	// did not create.
	if sw.mask_saved {
		posix.pthread_sigmask(.SETMASK, &sw.saved_mask, nil)
		sw.mask_saved = false
	}
	sw.running = false
}
