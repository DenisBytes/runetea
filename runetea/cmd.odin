package runetea

import "core:mem"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

// Go's `type Cmd func() Msg` is a closure. Odin has no closures at all, so the
// captured environment becomes explicit. This is the port's largest permanent
// ergonomic cost and it touches every user program.
//
// `procedure` takes a `^Cancel_Token` as its second argument -- see
// Cancel_Token's own doc comment below and docs/superpowers/
// cancellation-decision.md for the full design. This is a real, deliberate
// ergonomic cost too (every Cmd body's signature grows one parameter), chosen
// specifically so cancellation needs NO change to cmd_from's own call shape
// (still exactly `cmd_from(fn, env, alloc)`) and no per-Cmd env boilerplate --
// a Cmd that does not care about cancellation just ignores the parameter. The
// token is wired up automatically by dispatch()/run_cmd_task/run_cmd_detached
// below; callers never construct or pass one themselves.
Cmd :: struct {
	procedure: proc(env: rawptr, cancel: ^Cancel_Token) -> any,
	env:       rawptr,
	allocator: mem.Allocator,   // frees env after procedure returns
	detached:  bool,            // bypass the pool -- see dispatch

	// Non-nil ONLY for a Cmd produced by tick()/every() (timer.odin) --
	// dispatch() below special-cases these entirely, bypassing procedure/
	// env/allocator/detached above (left zeroed for such a Cmd) in favor of
	// the dedicated timer thread. See timer.odin's own top-of-file comment
	// for why registering a timer doesn't fit run_cmd_task/run_cmd_detached's
	// "exactly one result per dispatch" shape.
	timer: ^Timer_Handle,

	// Non-nil ONLY for a Cmd produced by batch()/sequence() (batch.odin) --
	// same bypass pattern as `timer` immediately above, for the same reason:
	// a batch/sequence Cmd doesn't run a single procedure/env pair at all, it
	// coordinates a whole heap-owned list of child Cmds, which doesn't fit
	// run_cmd_task/run_cmd_detached's "exactly one result per dispatch" shape
	// either. See batch.odin's own top-of-file comment and
	// docs/superpowers/batch-sequence-decision.md for why this couldn't be a
	// Msg (BatchMsg([]Cmd), Go's own shape) instead: box()'s MESSAGE
	// OWNERSHIP CONTRACT (arena.odin) rejects any Msg with a slice field, and
	// []Cmd is exactly that.
	compose: ^Compose_Spec,
}

cmd_nil :: proc() -> Cmd { return Cmd{} }

// c.timer == nil and c.compose == nil are part of this check, not just
// c.procedure == nil: a Cmd produced by tick()/every() (timer.odin) or by
// batch()/sequence() (batch.odin) has procedure == nil by construction (it
// never runs through run_cmd_task/run_cmd_detached at all -- see dispatch()'s
// own special cases below), so checking procedure alone would misreport
// every such Cmd as nil. That matters beyond symmetry: apply() and run()
// (tea.odin) both guard their dispatch() call with `if !cmd_is_nil(cmd)`, so
// a wrong answer here would silently drop every Tick/Every/batch/sequence
// before dispatch() ever saw it.
cmd_is_nil :: proc(c: Cmd) -> bool { return c.procedure == nil && c.timer == nil && c.compose == nil }

// Heap-clones `env` so the Cmd can outlive the caller's frame.
//
// Set detached=true for a Cmd that itself dispatches and waits on other Cmds.
// Such coordinators must not occupy a pool worker: N coordinators on an N-wide
// pool leaves no worker for their children, which deadlocks. Detached is the
// deliberate equivalent of Go's leaked-goroutine-per-Cmd, used rarely.
cmd_from :: proc(fn: proc(env: rawptr, cancel: ^Cancel_Token) -> any, env: $E, alloc: mem.Allocator, detached := false) -> Cmd {
	p, err := new(E, alloc)
	if err != nil { return cmd_nil() }
	p^ = env
	return Cmd{procedure = fn, env = rawptr(p), allocator = alloc, detached = detached}
}

// COOPERATIVE cancellation flag, one per Dispatcher (i.e. one per run()/
// run_nbio() session -- see Dispatcher.cancel below). A Cmd polls it via
// cancel_requested to notice "the enclosing run() has started quitting" and
// return early instead of running to completion.
//
// THE HONEST LIMIT: this is polling, not preemption. Nothing about a
// Cancel_Token can interrupt a Cmd that is blocked inside a syscall it never
// returns from on its own -- time.sleep, net.recv_tcp with no timeout,
// waiting on a child process, etc. A Cmd that wants to be cancellable while
// doing I/O must combine this with a BOUNDED wait of its own (a socket
// timeout via net.set_option(.Receive_Timeout/.Send_Timeout), polled in a
// loop that checks cancel_requested between attempts -- see examples/http's
// check_server for a worked example) so it wakes up on its own periodically
// to check. See docs/superpowers/cancellation-decision.md for the full
// design, what core:net actually offers here, and why.
Cancel_Token :: struct {
	cancelled: bool,   // touched only via sync.atomic_load/store -- same pattern as Reader_Ctx.stop (tea.odin) and Signal_Watcher.stop (signals.odin)
}

// Safe to call with tok == nil -- always reports "not cancelled" in that
// case. That covers a Cmd invoked directly (not through dispatch()) in a
// test, and keeps this call unconditionally safe to sprinkle into any Cmd
// body regardless of how it was constructed.
cancel_requested :: proc(tok: ^Cancel_Token) -> bool {
	return tok != nil && sync.atomic_load(&tok.cancelled)
}

@(private = "file")
cancel_token_fire :: proc(tok: ^Cancel_Token) {
	sync.atomic_store(&tok.cancelled, true)
}

// PRECONDITION (mirrors mailbox.odin's mailbox_destroy contract): the caller
// must stop calling dispatch() before calling dispatcher_destroy, and must
// destroy the Dispatcher before destroying the Mailbox it was constructed
// with. dispatcher_destroy blocks until every pool worker AND every detached
// Cmd it ever dispatched has finished -- see the `inflight` field and the
// CRITICAL note on dispatcher_destroy below for why the latter needs its own
// tracking distinct from thread.Pool's built-in join.
Dispatcher :: struct {
	pool:      thread.Pool,
	mailbox:   ^Mailbox,
	inflight:  sync.Wait_Group,   // counts detached Cmds not yet finished
	cancel:    Cancel_Token,      // fired by dispatcher_destroy/dispatcher_reap; shared by every Cmd this Dispatcher ever runs

	// Lazily-started nbio timer thread backing tick()/every() (timer.odin).
	// Owned here, not by run()/run_nbio(), so it shares the Dispatcher's own
	// proven lifetime (started on demand, joined by dispatcher_destroy
	// before the Mailbox it feeds can be destroyed) instead of needing a
	// second set of teardown rules layered on top of run()'s. See
	// docs/superpowers/tick-every-decision.md §a.
	timers: Timer_Service,

	// Optional cross-thread notification, called after a Cmd result is
	// successfully handed to the mailbox (mailbox_send == .Ok) from whatever
	// worker thread produced it. nil for run()'s poll-thread path -- that
	// design's single wait point IS the mailbox's own semaphore
	// (mailbox_recv), so nothing else needs telling. run_nbio (loop_nbio.odin)
	// sets this to a wrapper around nbio.wake_up: nbio's blocking wait
	// (nbio.tick) knows nothing about the mailbox, so delivering a message
	// there does not by itself wake a loop thread parked in tick() -- this
	// hook is what closes that gap. Deliberately a plain proc(rawptr), not an
	// nbio type: keeps this file's proven, race-tested code free of an nbio
	// dependency for the (default, common) case where nothing is listening.
	wake:      proc(rawptr),
	wake_data: rawptr,
}

Task_Env :: struct {
	cmd:       Cmd,
	mailbox:   ^Mailbox,
	inflight:  ^sync.Wait_Group,  // detached only; nil for pool tasks
	wake:      proc(rawptr),      // copied from Dispatcher.wake at dispatch time
	wake_data: rawptr,
	cancel:    ^Cancel_Token,     // copied from &Dispatcher.cancel at dispatch time -- see Cancel_Token's own doc comment

	// Non-nil ONLY when this dispatch is itself a CHILD of a batch()/
	// sequence() coordinator (batch.odin's compose_dispatch) -- nil for every
	// top-level dispatch() call, which is the overwhelming majority. Signaled
	// (wait_group_done) exactly once, as one of this task's last actions,
	// regardless of outcome (delivered, orphaned, or panicked) -- this is how
	// a compose coordinator learns "this child is done" without round-
	// tripping the child's own result back through anything: the coordinator
	// only ever needs to know WHEN, never WHAT. See batch.odin's own doc
	// comment for the full design.
	done: ^sync.Wait_Group,
}

// Runs once per pool WORKER at pool startup (thread.Pool's own init_proc
// hook), not once per TASK -- a worker's OS thread is reused across many
// tasks, and sigaltstack only needs installing once per thread (FIX 2,
// final fix-wave report). Without this, a pool worker has no altstack at
// all: a stack-overflow SIGSEGV on one re-faults on its own exhausted stack
// and defeats Tier 2 for every Cmd that ever runs on the pool.
@(private="file")
pool_worker_install_crash_handlers :: proc(th: ^thread.Thread, user_data: rawptr) {
	install_crash_handlers()
}

dispatcher_init :: proc(d: ^Dispatcher, m: ^Mailbox, workers: int, wake: proc(rawptr) = nil, wake_data: rawptr = nil) {
	d.mailbox = m
	d.wake = wake
	d.wake_data = wake_data
	thread.pool_init(&d.pool, context.allocator, max(workers, 1), init_proc = pool_worker_install_crash_handlers)
	thread.pool_start(&d.pool)
}

// thread.pool_finish/pool_destroy genuinely join every pool worker -- that
// part was always correct. But a detached Cmd (see dispatch below) runs on
// its own self_cleanup thread that is tracked NOWHERE else, and core:thread
// explicitly forbids joining a self_cleanup thread. Without inflight, a
// detached Cmd still running -- or mid mailbox_send -- when this returns
// would let the caller's next line (typically mailbox_destroy, per its own
// documented precondition) free the mailbox out from under a live producer:
// a use-after-free on its buffer and mutex. wait_group_wait blocks until
// every dispatch(..., detached=true) call's matching wait_group_done has
// run, which happens as the LAST action in run_cmd_detached, after that
// Cmd's mailbox_send and its own cleanup free -- so by the time this
// procedure returns, nothing can still be touching d.mailbox.
//
// BLOCKS until every pool task AND every detached Cmd is done -- this is
// exactly the wait that makes a single slow Cmd stall run()'s quit by that
// Cmd's own duration (docs/superpowers/cancellation-decision.md). Fires
// d.cancel first so any polling Cmd gets the earliest possible notice, which
// can shorten but never eliminate that wait. run() itself no longer calls
// this directly -- see dispatcher_reap below, its non-blocking sibling, which
// runs this SAME sequence on a background thread instead. This procedure is
// kept, unchanged in its blocking contract, for callers that legitimately
// want to wait synchronously (direct unit tests below, and run_nbio, which
// deliberately keeps the synchronous path -- see loop_nbio.odin's own
// comment on why).
dispatcher_destroy :: proc(d: ^Dispatcher) {
	cancel_token_fire(&d.cancel)
	thread.pool_finish(&d.pool)
	thread.pool_destroy(&d.pool)
	sync.wait_group_wait(&d.inflight)
	// LAST, after the pool and every detached Cmd are provably finished --
	// see timer_service_stop's own doc comment (timer.odin) for why that
	// ordering is load-bearing (a detached Cmd may itself call dispatch(),
	// including a fresh tick()/every()) and not just a convenient place to
	// put it. No-op if this Dispatcher never had a Tick/Every dispatched
	// through it.
	timer_service_stop(&d.timers)
}

// Heap-owned bundle for run()'s non-blocking teardown path (dispatcher_reap,
// below). Both fields were stack locals in run()'s frame before this change,
// which is exactly why run() could not return until every in-flight Cmd
// finished: thread.Pool's own doc comment says its "memory address is not
// allowed to change until it is destroyed" while workers reference it, and
// mailbox_destroy documents the identical precondition for Mailbox. A Cmd
// still running when run() wants to quit may keep touching its Dispatcher's
// pool and its Mailbox for as long as it runs, so both must outlive run()'s
// own stack frame whenever run() returns before that Cmd finishes. Bundled
// into one struct so run() makes exactly one heap allocation up front and the
// reaper thread below frees exactly one block at the end.
Reap_Ctx :: struct {
	disp: Dispatcher,
	mbox: Mailbox,

	// Non-nil only when dispatcher_reap was called with grace > 0 -- see its
	// own doc comment. Deliberately a POINTER to a SEPARATELY allocated
	// object, not a Wait_Group/Sema embedded directly in Reap_Ctx: an
	// earlier version of this file put the wait target here and freed rc
	// immediately after signaling it, which ThreadSanitizer caught as a real
	// heap-use-after-free (sync/extended.odin:100, inside
	// wait_group_wait_with_timeout) -- a woken waiter can still be touching
	// the synchronization primitive's own memory for a brief window AFTER
	// the signaling call has already returned on the signaler's side (it has
	// to re-acquire a mutex, or re-check a loop condition, to actually
	// return from its own wait call), so freeing that memory right after
	// signaling it races the waiter's own in-progress wakeup. See
	// Grace_Signal's own comment for the fix.
	grace: ^Grace_Signal,
}

// Separate, refcounted handoff for dispatcher_reap's optional grace-period
// wait -- see Reap_Ctx.grace's comment for why this cannot simply live
// inside Reap_Ctx. A plain refcount of 2 (one held by the waiter, one by the
// reaper) sidesteps the signal-then-free race cleanly: whichever side
// finishes touching it LAST is the one whose release call actually frees it
// (grace_signal_release below), and each side's own release is always the
// LAST thing that side ever does with gs -- so gs can only be freed once
// BOTH sides have already finished every touch they were ever going to make,
// regardless of what sema_post/sema_wait_with_timeout do internally to
// hand off the wakeup.
@(private = "file")
Grace_Signal :: struct {
	sem:  sync.Sema,
	refs: int,   // starts at 2; touched only via sync.atomic_add/atomic_sub
}

@(private = "file")
grace_signal_release :: proc(gs: ^Grace_Signal) {
	// atomic_sub returns the value BEFORE the subtraction (verified against
	// this exact toolchain, not assumed -- LLVM atomicrmw's return convention
	// is not otherwise documented in core:sync/core:intrinsics). Old value 1
	// means this call's own decrement just brought it to 0, i.e. the OTHER
	// side already released -- this is provably the last touch, safe to free.
	if sync.atomic_sub(&gs.refs, 1) == 1 { free(gs) }
}

@(private = "file")
reap_thread :: proc(data: rawptr) {
	// Doesn't run any user Cmd code directly, but mirrors this package's own
	// "every thread we spawn installs crash handlers first" convention
	// (dispatch's detached branch, signal_watcher_start, tea.odin's reader
	// thread) for consistency -- cheap, and it does call into libc's
	// allocator via dispatcher_destroy/mailbox_destroy/free below.
	install_crash_handlers()

	rc := cast(^Reap_Ctx)data
	gs := rc.grace   // copy before free(rc) below invalidates rc itself; gs (if non-nil) is a SEPARATE allocation, unaffected by that free
	dispatcher_destroy(&rc.disp)   // the exact same blocking join dispatcher_destroy always did -- just off run()'s critical path now
	mailbox_destroy(&rc.mbox)      // safe: dispatcher_destroy's return is proof no pool/detached Cmd can still be touching rc.mbox, and the caller of dispatcher_reap already guaranteed every OTHER producer (reader thread, Signal_Watcher) was stopped and joined before handing rc off
	free(rc)
	if gs != nil {
		sync.sema_post(&gs.sem)   // wakes a waiter blocked in dispatcher_reap's own sema_wait_with_timeout, if grace hasn't already expired
		grace_signal_release(gs)   // this thread's own reference -- see Grace_Signal's comment
	}
}

// Non-blocking counterpart to dispatcher_destroy + mailbox_destroy called
// together -- the shape run()'s teardown actually needs. Fires rc.disp's
// cancellation token, closes rc.mbox (so a Cmd that finishes after this point
// gets .Closed on its very next mailbox_send and discards its result instead
// of retrying against a mailbox nobody drains anymore -- "orphaned results
// are discarded"), then hands rc off to a self-cleaning background thread
// that runs dispatcher_destroy + mailbox_destroy + free(rc) -- the SAME join
// and the SAME "nothing can still be touching rc.mbox" proof dispatcher_destroy
// always relied on -- just on a thread the caller does not have to wait for.
//
// `grace`, if positive, makes this wait -- WITH a timeout -- for the reaper
// to finish before returning, via a Grace_Signal (see its own comment for
// why that is a separate allocation rather than a field the caller could
// wait on directly). Returns whether the reaper actually finished within
// `grace` (always false for grace <= 0, which does not wait at all). This is
// NOT about correctness of rc.mbox/rc.disp -- dispatcher_reap is safe with
// grace=0 exactly as it was before this parameter existed. It is about a
// DIFFERENT hazard specific to a caller whose context.allocator has a
// lifetime shorter than "the rest of the process": odin test's own per-task
// allocator is rotated to a DIFFERENT test the moment a test proc returns,
// and rc (and everything rc.disp/rc.mbox ever allocated) was allocated
// through THAT allocator -- a reaper thread still freeing through it after
// rotation corrupts a different test's memory, observed empirically as
// spurious "bad free" reports when this was first tried with grace=0
// unconditionally (see docs/superpowers/cancellation-decision.md for the
// measurement). A short bounded wait makes the overwhelmingly common case --
// no Cmd in flight, or one that finishes quickly -- synchronous again (rc is
// fully torn down, including free(rc), before the caller's allocator can
// possibly be reused), while still bounding the worst case (a genuinely
// stuck Cmd) to `grace` instead of that Cmd's own duration, which is the
// actual fix this whole change exists to make. run() uses a short, fixed
// grace period for exactly this reason; a caller not exposed to a
// rotating-allocator hazard (or one that does not care about the
// difference) can pass 0.
//
// PRECONDITION, same as dispatcher_destroy's own: every OTHER producer into
// rc.mbox (a reader thread, a Signal_Watcher) must already be stopped and
// joined before calling this -- this call only accounts for rc.disp's own
// pool workers and detached Cmds, nothing else. Ownership of `rc` transfers
// to the reaper thread: the caller must not touch *rc again after this call
// returns, including via rc.disp or rc.mbox.
dispatcher_reap :: proc(rc: ^Reap_Ctx, grace: time.Duration = 0) -> (finished_in_time: bool) {
	cancel_token_fire(&rc.disp.cancel)
	mailbox_close(&rc.mbox)

	gs: ^Grace_Signal
	if grace > 0 {
		gs = new(Grace_Signal)
		gs.refs = 2   // one for the reaper thread, one for this waiter
		rc.grace = gs
	}

	// Deliberately self_cleanup = FALSE -- see the long comment on this exact
	// choice below the function for why self_cleanup = true is UNSAFE here
	// specifically (a genuine core:thread race, not this package's).
	// Detaching the underlying OS thread ourselves, right here on the
	// CALLING thread rather than racily inside the spawned thread's own
	// entry proc, is what reclaims its kernel-level resources (stack, TCB)
	// without that race: posix.pthread_detach only touches pthread-library
	// bookkeeping for the OS thread itself, never the Odin ^Thread struct's
	// own memory, so it cannot race anything the spawned thread does with
	// that struct (t.start_ok included). What is NOT reclaimed is the small,
	// fixed-size Odin-level ^Thread struct itself (a few hundred bytes) --
	// thread.destroy(t) would reclaim that too, but it calls thread.join(t)
	// internally, which would block this call on the very Cmd this whole
	// change exists to stop waiting for. That struct is intentionally
	// leaked: one per dispatcher_reap call, bounded, one-shot -- not
	// proportional to anything this change is trying to bound, and reclaimed
	// by the OS at process exit regardless.
	t := thread.create_and_start_with_data(rawptr(rc), reap_thread, init_context = context, self_cleanup = false)
	if t != nil { posix.pthread_detach(t.unix_thread) }

	if gs == nil { return false }
	ok := sync.sema_wait_with_timeout(&gs.sem, grace)
	grace_signal_release(gs)   // this call's own reference -- see Grace_Signal's comment
	return ok
}

// WHY self_cleanup = false ABOVE, NOT true: `thread.create_and_start_with_data(...,
// self_cleanup = true)` has its own genuine race, in core:thread itself, not
// in this package -- caught by ThreadSanitizer, reproducibly (roughly 1 in
// 5-8 runs of ./tools/test.sh race) with self_cleanup = true here:
//
//   thread.start(t) does `atomic_or(&t.flags, {.Started})` THEN
//   `sync.post(&t.start_ok)` (thread_unix.odin's `_start`) -- two SEPARATE
//   operations, not one atomic step. The newly created thread's own startup
//   loop is `for (.Started not_in atomic_load(&t.flags)) { sync.wait(&t.start_ok) }`
//   -- it can observe `.Started` already set (the atomic_or already ran) and
//   skip the wait ENTIRELY, before `_start`'s own `sync.post` call has
//   executed. If the thread's body then runs to completion fast enough --
//   and reap_thread, with no Cmd in flight, can finish in low microseconds,
//   far faster than most detached-Cmd bodies that do real work first -- it
//   reaches `.Self_Cleanup`'s `free(t, ...)` (thread_unix.odin's
//   `__unix_thread_entry_proc`) WHILE `_start`'s `sync.post(&t.start_ok)` is
//   still executing on the CALLING thread. That is a genuine
//   signal-then-free race on `t.start_ok`'s own memory -- structurally the
//   SAME class of bug Grace_Signal exists to avoid above, just living inside
//   core:thread's own self_cleanup implementation instead of this file's.
//   Not something this package can patch (out of scope: toolchain code, not
//   runetea's), and this task's own hard constraint is that a fast quit must
//   never corrupt memory -- so self_cleanup is simply not used for a thread
//   whose body can complete this fast. The existing detached-Cmd path
//   (dispatch's `c.detached` branch, run_cmd_detached) uses the SAME
//   self_cleanup = true API and is exposed to the identical underlying bug,
//   just far less likely to trigger it empirically (a Cmd body almost always
//   takes longer than `_start`'s own sync.post call to complete) -- left
//   alone here since it predates this change, was not observed to fail
//   under repeated race-gate runs, and reworking it is out of this task's
//   scope. See docs/superpowers/cancellation-decision.md for the full TSan
//   report this comment summarizes.

// Delivers a completed Cmd's result, retrying on a transient Full and
// giving up on a terminal Closed (FIX 1, final fix-wave report). A dropped
// result is not acceptable here: `_ = mailbox_send(...)` used to discard it
// outright whenever the mailbox happened to be full, which for
// examples/http meant the UI could sit on "Checking..." forever even
// though the network request had actually completed successfully -- the
// result was computed and then silently thrown away. run()'s main loop is
// the sole consumer and keeps draining concurrently while a pool worker or
// detached Cmd thread is blocked here, so Full is expected to clear; Closed
// means run() has already torn down and nothing sent from here on could
// ever be received anyway.
// Returns whether the message was actually handed to the mailbox (false only
// for Closed -- see the call sites' handling of a nil wake below).
//
// package-visible, not file-visible: timer.odin's timer_fire reuses this
// verbatim (same retry-on-Full/discard-on-Closed policy every producer in
// this codebase already follows) rather than duplicating it for a second,
// repeating-delivery code path that could drift from this one.
@(private="package")
deliver_result :: proc(m: ^Mailbox, msg: any) -> bool {
	for {
		switch mailbox_send(m, msg) {
		case .Ok:     return true
		case .Closed: return false
		case .Full:   thread.yield()
		}
	}
}

// Delivered through the SAME mailbox path as any normal Cmd result, when a
// Cmd's own procedure panics -- run_cmd_guarded below is what makes that
// true. See its doc comment and docs/superpowers/tier1-coverage-decision.md
// for the full reasoning; short version: the only synchronization a pool
// worker or detached Cmd thread has with the main loop is already the
// mailbox, and one exploding background Cmd (of possibly several in flight)
// should not be allowed to force the whole run() session to end -- the app
// gets to decide how to react, the same choice it already has for any other
// Cmd-reported error (examples/http's Err_Msg is the existing precedent).
// A Panicked_Msg that reaches an update() with no matching case is simply
// unhandled, exactly like any other Msg type an app doesn't care about --
// not silently dropped, since it still reached update()'s switch, just not
// acted on.
//
// POD, per box()'s MESSAGE OWNERSHIP CONTRACT (arena.odin): Msg_Text, not a
// bare `string`, carries the panic text -- truncated past 255 bytes exactly
// like every other Msg_Text use (msg.odin).
Panicked_Msg :: struct {
	message: Msg_Text,
}

// Shared state for the guarded Cmd call, mirroring tea.odin's Step/View_Step
// -- longjmp discards the frame, so the result (or lack of one) lives
// outside it.
@(private = "file")
Cmd_Step :: struct {
	cmd:    Cmd,
	cancel: ^Cancel_Token,
	result: any,
}

// Runs a Cmd's procedure under guarded(), turning a panic into a boxed
// Panicked_Msg instead of taking down the whole pool worker or detached
// thread (T1, docs/superpowers/tier1-coverage-decision.md -- Tier 1
// previously wrapped update only; spike-findings.md §4/addendum item 7).
// Shared by run_cmd_task and run_cmd_detached below so both thread classes
// get identical panic handling from one place, not two copies that could
// drift.
//
// Also owns freeing cmd.env exactly once, regardless of outcome (constraint
// c: longjmp skips defer, so the free that used to sit right after the bare
// procedure call must now run unconditionally AFTER guarded() returns --
// which, by the time this code runs, is back to ordinary non-longjmp control
// flow either way, panic or not). This is a real improvement over the
// pre-guard code, not just a preserved behavior: before this change a
// panicking Cmd took the whole process down (see box()'s own non-POD panic
// path, which used to abort here unconditionally -- message-ownership-
// decision.md §2 Option B), so cmd.env was never freed on that path either;
// now it always is.
//
// WHAT IS NOT RECLAIMED: any heap memory the Cmd body itself allocated
// (typically via context.allocator, since a Cmd's result must cross a thread
// boundary -- see arena.odin's LIFETIME CONTRACT) before panicking. Unlike
// apply()'s update/view guards, a Cmd has no frame-arena equivalent to
// wholesale-reclaim on the recovery path -- frame_allocator(fa) is
// per-run()-iteration and explicitly forbidden for anything crossing a
// thread boundary, which is exactly what a Cmd's own scratch allocations
// usually are not, but easily could be. A Cmd that panics after allocating
// its own scratch buffer leaks that buffer, the same as any non-guarded Odin
// code with no RAII would. This is a fundamental limit of setjmp/longjmp
// recovery, not something this change closes, and is recorded here rather
// than silently promised away.
run_cmd_guarded :: proc(cmd: Cmd, cancel: ^Cancel_Token) -> any {
	step := Cmd_Step{cmd = cmd, cancel = cancel}
	info := guarded(proc(ud: rawptr) {
		s := cast(^Cmd_Step)ud
		s.result = s.cmd.procedure(s.cmd.env, s.cancel)
	}, &step)

	if cmd.env != nil { free(cmd.env, cmd.allocator) }

	if info.recovered {
		// Msg types must be POD (message-ownership-decision.md): the panic
		// text -- an owned `string` cloned by guard_assertion_failure -- must
		// become a Msg_Text, not travel as-is. Unlike apply()'s update-panic
		// path (which hands info.message to the CALLER of run() via
		// Panicked_Error, so it cannot free it), nothing else ever holds a
		// reference to this particular copy once it's been copied into the
		// Msg_Text below -- there is no caller waiting on a Cmd's panic text
		// the way run()'s own caller waits on its return value -- so freeing
		// it immediately is correct, not merely convenient, and avoids adding
		// a second instance of guard.odin's already-documented
		// Panic_Info.message leak.
		defer delete(info.message, context.allocator)
		return box(Panicked_Msg{message = msg_text_from(info.message)}, context.allocator)
	}
	return step.result
}

@(private="file")
run_cmd_task :: proc(task: thread.Task) {
	te := cast(^Task_Env)task.data
	// Captured before free(te) below invalidates te itself -- same reason
	// run_cmd_detached's own `inflight := te.inflight` capture exists.
	done := te.done
	if te.cmd.procedure != nil {
		msg := run_cmd_guarded(te.cmd, te.cancel)
		// msg.id != nil, NOT msg != nil: Odin's `any == nil` compares by the
		// `data` field alone, and new() legitimately returns a nil pointer for
		// a zero-sized allocation -- which is exactly what box() does for any
		// zero-sized Msg (Quit_Msg is `struct {}`). `msg != nil` on such a
		// result is FALSE -- it silently discards the message, so a Cmd
		// returning Quit_Msg through this path would never reach the mailbox
		// and the program could never quit. Proven with a standalone repro
		// (`a: any = p^` for `p := new(Empty)` prints `a == nil: true` while
		// `a.id != nil: true`) and caught live: an init Cmd returning
		// Quit_Msg hung forever waiting on mailbox_recv, see
		// task-10-report.md. `.id` is nil ONLY for a genuinely absent message
		// (a real `nil` any, or box()'s own allocator-failure return), which
		// is what this check must key on instead.
		if msg.id != nil {
			if deliver_result(te.mailbox, msg) {
				if te.wake != nil { te.wake(te.wake_data) }
			} else {
				// Orphaned: the mailbox is already closed, which for the
				// pool/detached paths only ever happens once run() (or
				// run_nbio()) has quit and called dispatcher_reap/
				// dispatcher_destroy -- "orphaned results are discarded" is
				// the deliberate design (docs/superpowers/
				// cancellation-decision.md), but the box() allocation msg
				// itself still needs a home: freeing it here, rather than
				// leaking it, is safe because this runs on the SAME thread
				// that called box() to produce msg in the first place, so
				// context.allocator here is the SAME allocator instance that
				// made the allocation -- the identical convention apply()'s
				// own box_free call relies on (tea.odin/arena.odin).
				box_free(msg, context.allocator)
			}
		}
	}
	// Freed here, per-task, rather than accumulated in the Dispatcher and
	// freed only at dispatcher_destroy: a Dispatcher is meant to live for
	// the whole session of a long-running TUI, so retaining every completed
	// task's Task_Env until shutdown grows without bound across the run.
	free(te)
	// See Task_Env.done's own doc comment -- signaled after every other
	// action this task will ever take, so a compose coordinator waiting on
	// it never wakes early relative to this child's own delivery/cleanup.
	if done != nil { sync.wait_group_done(done) }
}

@(private="file")
run_cmd_detached :: proc(data: rawptr) {
	// Per-thread altstack (FIX 2, final fix-wave report), installed as the
	// first action. A detached Cmd gets a brand-new OS thread every single
	// dispatch (see dispatch's detached branch below) -- unlike the pool,
	// there is no reusable worker thread to amortize this over via an
	// init_proc hook, so it has to happen here, once per invocation.
	// Without it, a stack-overflow SIGSEGV on a detached Cmd's own thread
	// re-faults on its own exhausted stack and defeats Tier 2.
	install_crash_handlers()

	te := cast(^Task_Env)data
	inflight := te.inflight
	done := te.done   // captured before free(te) below, same reason as `inflight` above
	if te.cmd.procedure != nil {
		msg := run_cmd_guarded(te.cmd, te.cancel)
		// See run_cmd_task's comment: msg.id, not msg, distinguishes "a real
		// zero-sized Msg" from "genuinely nothing to send".
		if msg.id != nil {
			if deliver_result(te.mailbox, msg) {
				if te.wake != nil { te.wake(te.wake_data) }
			} else {
				// See run_cmd_task's identical comment for why this is safe
				// and not merely tolerated.
				box_free(msg, context.allocator)
			}
		}
	}
	free(te)
	// See Task_Env.done's own doc comment. Signaled BEFORE inflight below,
	// not after -- a compose coordinator waiting on `done` has no stake in
	// this Dispatcher's own inflight bookkeeping, so there is no ordering
	// requirement between the two beyond "both eventually happen"; inflight
	// keeps its documented "must be the LAST action" position regardless.
	if done != nil { sync.wait_group_done(done) }
	// Must be the LAST action: dispatcher_destroy's wait_group_wait treats
	// this as proof the Cmd is entirely done, including its mailbox_send and
	// its own te free, and unblocks a caller that may destroy the mailbox on
	// its very next line.
	sync.wait_group_done(inflight)
}

dispatch :: proc(d: ^Dispatcher, c: Cmd) {
	dispatch_ex(d, c, nil)
}

// The real body of dispatch(), extended with one internal-only parameter:
// `done`, non-nil ONLY when this call is itself dispatching a CHILD of a
// batch()/sequence() coordinator (batch.odin's compose_dispatch). Every
// external call site (apply()/run() in tea.odin, loop_nbio.odin, every test
// in cmd_test.odin) goes through the plain `dispatch` wrapper above, which
// always passes nil -- ordinary top-level dispatch behavior is completely
// unchanged.
//
// `done`, when non-nil, is signaled (wait_group_done) EXACTLY once no matter
// which branch below runs, including the two immediate-return cases (timer,
// nil Cmd) that have no Task_Env of their own to carry it. This is what lets
// a compose coordinator dispatch an arbitrary child -- ordinary Cmd, nested
// batch()/sequence(), even a raw Tick/Every -- through this exact same
// proc, uniformly, and learn "this child is done" without needing a second,
// parallel dispatch path: see batch.odin's own top-of-file comment for the
// full design and docs/superpowers/batch-sequence-decision.md for why that
// uniformity is the point, not an incidental simplification.
@(private = "package")
dispatch_ex :: proc(d: ^Dispatcher, c: Cmd, done: ^sync.Wait_Group) {
	// Tick/Every (timer.odin) bypass everything below: registering an nbio
	// timeout is a microsecond-fast, non-blocking call, so routing it
	// through a pool worker would only add latency and hold a worker slot
	// for no reason -- and a repeating Every delivers MANY results over its
	// lifetime, which doesn't fit run_cmd_task/run_cmd_detached's "exactly
	// one result per dispatch" shape at all (see cmd.odin's own msg.id-vs-msg
	// comment below in run_cmd_task). procedure/env/allocator/detached are
	// unused for such a Cmd (left zeroed by tick()/every()).
	if c.timer != nil {
		timer_dispatch(d, c.timer)
		// Fire-and-forget from a composing coordinator's point of view: a
		// Tick/Every nested inside batch()/sequence() is registered exactly
		// as if it had been returned directly from update(), but does NOT
		// gate the coordinator's own completion/ordering -- an Every in
		// particular never completes at all, so "wait for it" has no
		// sensible meaning here. See batch-sequence-decision.md's honest
		// accounting of this scope limit.
		if done != nil { sync.wait_group_done(done) }
		return
	}

	// batch()/sequence() (batch.odin) bypass everything below too, for the
	// same class of reason: a compose Cmd has no single procedure/env pair
	// to run through run_cmd_task/run_cmd_detached, it coordinates a whole
	// list of children. compose_dispatch below always converts this into a
	// SYNTHETIC detached Cmd and recurses into this exact same proc, so it
	// still ultimately runs through the ordinary detached branch below --
	// see compose_dispatch's own doc comment (batch.odin) for why that reuse
	// is deliberate, not incidental.
	if c.compose != nil {
		compose_dispatch(d, c.compose, done)
		return
	}

	if cmd_is_nil(c) {
		if done != nil { sync.wait_group_done(done) }
		return
	}

	if c.detached {
		// Elastic overflow: its own thread, self-cleaning, never pool-bound.
		//
		// init_context MUST be passed. Left at its nil default, the new OS
		// thread runs under runtime.default_context() instead of inheriting
		// this one -- a DIFFERENT context.allocator value. `te` below is
		// allocated through *this* thread's context.allocator (whatever the
		// caller has configured, e.g. odin test's Tracking_Allocator), but
		// run_cmd_detached's closing `free(te)` has no explicit allocator
		// argument, so it resolves context.allocator on the *new* thread.
		// Without inheritance those are two different allocators backed by
		// the same real heap with no shared bookkeeping/locking between
		// them -- proven to heap-corrupt and SIGSEGV inside libc free()
		// under odin test's tracking allocator (reproduced with a minimal
		// core:thread-only repro, no cmd.odin/Dispatcher logic involved).
		// Passing context here makes the child inherit the SAME allocator
		// value the pool path already gets for free via task.allocator
		// (thread_pool.odin:363 sets context.allocator = task.allocator
		// before running a task) -- see thread.create_and_start_with_data's
		// own _select_context_for_thread, which special-cases temp_allocator
		// to still get a fresh per-thread instance so its state isn't shared.
		//
		// wait_group_add MUST happen before create_and_start_with_data, not
		// after: the detached thread can run to completion (including its
		// matching wait_group_done) before this call even returns, and
		// add-after-spawn would race dispatcher_destroy's wait_group_wait
		// seeing a zero count that was never incremented for this Cmd.
		sync.wait_group_add(&d.inflight, 1)
		te := new(Task_Env)
		te^ = Task_Env{cmd = c, mailbox = d.mailbox, inflight = &d.inflight, wake = d.wake, wake_data = d.wake_data, cancel = &d.cancel, done = done}
		thread.create_and_start_with_data(rawptr(te), run_cmd_detached, init_context = context, self_cleanup = true)
		return
	}

	te := new(Task_Env)
	te^ = Task_Env{cmd = c, mailbox = d.mailbox, wake = d.wake, wake_data = d.wake_data, cancel = &d.cancel, done = done}
	thread.pool_add_task(&d.pool, context.allocator, run_cmd_task, te)
}
