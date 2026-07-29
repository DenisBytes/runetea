package runetea

import "core:mem"
import "core:nbio"
import "core:sync"
import "core:thread"
import "core:time"

// Tick and Every -- see docs/superpowers/tick-every-decision.md for the full
// design rationale (four questions the task set out to answer, all covered
// there in depth). Short version of what lives in THIS file:
//
//   - A dedicated, lazily-started nbio timer thread, owned by the Dispatcher
//     it belongs to (cmd.odin's `Dispatcher.timers` field) -- one per run()/
//     run_nbio() session, exactly like the pool and Signal_Watcher, and torn
//     down from the SAME dispatcher_destroy call that already joins those,
//     so it cannot outlive the Mailbox its results feed.
//   - Registration (`tick`/`every`) never touches the pool: Cmd gained an
//     optional `timer: ^Timer_Handle` field (cmd.odin) that dispatch()
//     special-cases, handing the request to the timer thread via a plain
//     mutex-guarded pending list plus `nbio.wake_up` -- NOT core:nbio's own
//     cross-thread `exec` mechanism, which turned out to have a genuine
//     concurrency bug of its own under real multi-producer load; see
//     timer_dispatch's own comment and docs/superpowers/
//     tick-every-decision.md §8 for the full account. Either way, no pool
//     worker is ever occupied for the timer's own duration.
//   - Firing delivers directly to the Mailbox from the timer thread, reusing
//     cmd.odin's own deliver_result (retry on Full, discard on Closed) --
//     the same policy every other producer in this codebase already uses.
//   - Cancellation is a refcounted, cooperative flag (Timer_Handle),
//     structurally identical to cmd.odin's own Grace_Signal. The timer
//     subsystem ALWAYS holds one reference (released when the timer is
//     naturally done); a caller who asked for a stoppable timer
//     (tick_cancellable/every) holds a second, released by timer_stop.
//     Whichever side releases last frees it. Plain tick() hands out no
//     handle and therefore has exactly ONE reference -- see tick's own
//     comment for why that asymmetry is the fix to a real leak, not an
//     inconsistency.

// Named-proc-plus-explicit-env replacement for Go's `func(time.Time) Msg`
// closure -- same treatment Cmd.procedure already got (cmd.odin), and
// deliberately the SAME shape: env comes back as a rawptr, and the proc
// calls box() itself and returns the result, exactly like quit_run or any
// other Cmd body in this codebase (there is no second, different
// convention here for "how a user proc turns into a boxed Msg").
//
// No Cancel_Token parameter, unlike Cmd.procedure -- deliberate, not an
// oversight. A Cmd's procedure polls cancel_requested because it may run
// for a long time and needs a way to notice a mid-flight quit; a Timer_Fn is
// expected to be a trivial, near-instant "wrap this timestamp in a Msg"
// mapping (Go's own examples never do more), and cancelling a Tick/Every
// happens one layer up, at the scheduling level (Timer_Handle/timer_stop) --
// whether to even CALL fn at all, not something fn itself needs to check.
Timer_Fn :: #type proc(env: rawptr, t: time.Tick) -> any

// Cooperative, best-effort cancellation handle for a pending Tick or a
// repeating Every, returned alongside the Cmd by tick_cancellable()/every().
// Pass it to timer_stop to cancel.
//
// YOU MUST CALL timer_stop ON EVERY HANDLE YOU ARE GIVEN, exactly once, even
// if the timer already fired or already stopped on its own (both are
// explicitly safe -- see timer_stop). timer_stop is the ONLY thing that ever
// releases the caller's reference, so discarding a handle instead does not
// merely "leak the bytes of the handle": it pins refs at 1 forever, so the
// handle AND its cloned fn env are never freed. An earlier version of this
// comment claimed discarding was fine; it was wrong, and it was wrong in a
// way that mattered -- plain tick() used to hand out a handle too, and its
// own documented usage pattern (reissue a fresh tick() from update() on every
// fire) has no natural moment to call timer_stop at all, so it leaked one
// handle + one fn env PER FIRE, forever, linear in tick count. That is what
// the tick()/tick_cancellable() split below exists to make structurally
// impossible rather than merely documented.
//
// Refcounted exactly like cmd.odin's Grace_Signal, for the identical
// signal-then-free reason documented there. `refs` starts at:
//
//   2 -- tick_cancellable()/every(): one for whoever holds the returned
//        handle, released by timer_stop; one for the timer subsystem itself,
//        released in timer_fire once the timer is naturally done
//        (fired-and-not-repeating, cancelled, or the session's Mailbox has
//        closed).
//   1 -- plain tick(): the subsystem's reference and nothing else, because
//        no handle is handed out at all. It is NOT reachable by any caller,
//        so nothing can release it early and nothing can forget to release
//        it late.
//
// Whichever side's release call brings it to 0 is provably the last touch, so
// that side frees it.
//
// Fields past `cancelled` are internal bookkeeping the timer subsystem needs
// across repeats -- not part of the public contract, but Odin has no
// field-level privacy within a package, so they are visible; treat this as
// opaque and only call timer_stop on it.
Timer_Handle :: struct {
	cancelled: bool, // touched only via sync.atomic_load/store
	refs:      int,  // touched only via sync.atomic_add/atomic_sub; starts at 2, or at 1 for a plain tick() -- see above

	fn:        Timer_Fn,
	fn_env:    rawptr,
	fn_alloc:  mem.Allocator,
	dur:       time.Duration,
	repeat:    bool, // false = Tick (fires once), true = Every (reschedules itself)

	target: time.Tick,          // Every only: the intended next-fire instant, tracked independent of "now" so a slow fire doesn't accumulate drift -- see timer_rearm
	loop:   ^nbio.Event_Loop,    // captured once at dispatch time; same-thread rearms use it directly

	// Shutdown sweep bookkeeping -- see timer_service_sweep_armed. Touched
	// ONLY on the timer thread (timer_arm_initial/timer_fire/timer_rearm and
	// the sweep itself all run there), so no synchronization: `refs` remains
	// the only field in this struct with cross-thread traffic.
	ts:        ^Timer_Service,    // owning service, so timer_fire can find the armed list
	op:        ^nbio.Operation,   // the outstanding nbio timeout, alive until its callback runs; nil when none is armed
	armed_idx: int,               // index into ts.armed, or -1 when not armed (set to -1 by timer_new -- zeroing would falsely read as index 0)

	mailbox:   ^Mailbox,
	wake:      proc(rawptr),
	wake_data: rawptr,
}

// tick(d, fn, env, alloc) -> a Cmd that, once dispatched, fires exactly ONCE
// after d, delivering box()'d result of fn(env, tick_now()) to the Mailbox.
// Matches Bubble Tea's Tick semantics (commands.go): the timer begins when
// dispatched and runs for its entire duration, independent of the wall
// clock. To repeat, return another tick() from update() upon receiving the
// message -- exactly Go's own documented pattern.
//
// RETURNS NO HANDLE, and that is the whole point. The Tick is owned end-to-
// end by the timer subsystem: its Timer_Handle and cloned fn env are freed
// when it fires, when its Mailbox has closed, or when the subsystem fails to
// start -- always, with no cooperation required from the caller. There is
// nothing to remember to release and nothing to forget.
//
// WHY THIS IS NOT SYMMETRIC WITH every(), which does hand back a handle:
// docs/superpowers/tick-every-decision.md §b argues that "a timer that
// cannot be stopped is a leak with a nicer name", and that argument is
// entirely about Every -- a repeating timer nobody can stop is a live
// background operation for the rest of the session, doing real work forever.
// It was extended to Tick by symmetry, and that is precisely where it broke:
// a one-shot Tick has no natural moment for the caller to call timer_stop
// (the timer already fired, nothing tells the caller it fired, and "stop"
// after the fact is meaningless), so the reissue-from-update() pattern this
// very comment prescribes leaked a handle plus an fn env on EVERY fire --
// ~60 pairs per second for a 60fps spinner, for the life of the process. The
// fix is the same one this codebase already applies elsewhere (box() enforces
// POD rather than documenting it; batch() forces the detached path at every
// depth rather than trusting callers): make the common path structurally
// incapable of leaking instead of requiring caller discipline it cannot
// reasonably supply.
//
// NO CAPABILITY IS LOST: tick_cancellable below still covers the genuine
// "cancel a one-shot before it fires" case, at the cost of an explicit
// timer_stop the caller has actually opted into.
tick :: proc(d: time.Duration, fn: Timer_Fn, env: $E, alloc: mem.Allocator) -> Cmd {
	c, _ := timer_new(d, fn, env, alloc, repeat = false, caller_ref = false)
	return c
}

// tick(), but stoppable: identical firing semantics, plus a Timer_Handle the
// caller can pass to timer_stop to cancel the fire before it happens. For the
// case a plain tick() cannot express -- a timeout that some other event may
// make irrelevant before it elapses.
//
// THE CALLER MUST CALL timer_stop ON THE RETURNED HANDLE EXACTLY ONCE, even
// if the Tick has already fired (safe and explicitly supported, see
// timer_stop). Unlike tick(), this holds a second reference specifically so
// the caller's `h` stays valid after the subsystem is done with it, and
// timer_stop is the only thing that ever releases it. Do not reach for this
// as the default -- if you are not going to cancel, use tick().
tick_cancellable :: proc(d: time.Duration, fn: Timer_Fn, env: $E, alloc: mem.Allocator) -> (Cmd, ^Timer_Handle) {
	return timer_new(d, fn, env, alloc, repeat = false, caller_ref = true)
}

// every(d, fn, env, alloc) -> a Cmd that, once dispatched, fires repeatedly
// every d, on its own, without needing update() to reissue it -- this is
// the one deliberate divergence from Bubble Tea's Every, which (see
// commands.go's own doc comment) is ALSO single-fire; Go's "repeats" is
// purely a documented reissue-from-Update convention, identical to Tick's.
// RuneTea's Every instead auto-repeats via the dedicated timer thread, and
// is independently stoppable (timer_stop) -- because unlike Tick, an Every
// nobody ever cancels is a live background operation for the rest of the
// session, and "a timer that cannot be stopped is a leak with a nicer name"
// (see docs/superpowers/tick-every-decision.md §b).
//
// Does NOT align to wall-clock multiples of d the way Go's Every does
// (commands.go: `n.Truncate(duration).Add(duration)`) -- a deliberate
// divergence, not an oversight; see the decision doc §alignment for the
// full reasoning (short version: it needs time.now(), which spec §9
// explicitly says to avoid in this exact subsystem, and RuneTea's Every
// already diverges from Go's in the more fundamental way above, so
// preserving this specific secondary property isn't obligatory). What it
// DOES guarantee is drift-free repetition relative to its own start --
// see timer_rearm's comment.
//
// KEEPS the mandatory handle (refs = 2) that tick() above deliberately
// dropped, and that is not an oversight either -- it is the one case §b's
// argument actually applies to. An Every nobody ever stops keeps firing into
// the Mailbox for the whole session; that is a live background operation, not
// a few dozen stranded bytes, so "you forgot to stop it" is a genuine caller
// error worth forcing the caller to confront. THE CALLER MUST CALL timer_stop
// ON THE RETURNED HANDLE EXACTLY ONCE.
every :: proc(d: time.Duration, fn: Timer_Fn, env: $E, alloc: mem.Allocator) -> (Cmd, ^Timer_Handle) {
	return timer_new(d, fn, env, alloc, repeat = true, caller_ref = true)
}

// caller_ref: does the caller get its own reference (and therefore its own
// obligation to timer_stop)? true for tick_cancellable/every, false for plain
// tick, whose handle never leaves this package. See Timer_Handle's own
// comment on `refs`.
@(private = "file")
timer_new :: proc(d: time.Duration, fn: Timer_Fn, env: $E, alloc: mem.Allocator, repeat: bool, caller_ref: bool) -> (Cmd, ^Timer_Handle) {
	fnenv, ferr := new(E, alloc)
	if ferr != nil { return cmd_nil(), nil }
	fnenv^ = env

	h, herr := new(Timer_Handle, context.allocator)
	if herr != nil {
		free(fnenv, alloc)
		return cmd_nil(), nil
	}
	h.refs      = 2 if caller_ref else 1
	h.armed_idx = -1 // NOT 0 -- see the field's own comment
	h.fn        = fn
	h.fn_env    = rawptr(fnenv)
	h.fn_alloc  = alloc
	h.dur       = d
	h.repeat    = repeat

	return Cmd{timer = h}, h
}

// Cancels a pending Tick (from tick_cancellable) or a repeating Every.
// Best-effort and cooperative, same class as Cancel_Token (cmd.odin): if the
// timer thread has already begun firing this instant, the message may still
// be delivered -- there is no way to un-send something already in flight.
// Safe to call even after the timer already fired or stopped on its own.
//
// Call it EXACTLY once per handle, never twice and never zero times: this
// releases the caller's own reference (see Timer_Handle's own comment), so a
// second call decrements a reference that no longer exists -- against a
// handle the first call may already have freed -- and no call at all strands
// the handle and its fn env for the life of the process. There is no handle
// to get this wrong with for a plain tick(); that is deliberate.
//
// Safe with h == nil (mirrors cancel_requested's own nil handling).
timer_stop :: proc(h: ^Timer_Handle) {
	if h == nil { return }
	sync.atomic_store(&h.cancelled, true)
	timer_handle_release(h)
}

// Package-visible, not file-private, for exactly one caller outside this
// file: batch.odin's compose_free_unrun, which has to release the Tick/Every
// children of a batch()/sequence() that gets abandoned before it is ever
// dispatched. That release is the subsystem's own reference (nothing was ever
// registered, so no other path will ever release it) -- structurally the same
// case as timer_dispatch's own failure-to-start branch below.
@(private = "package")
timer_handle_release :: proc(h: ^Timer_Handle) {
	// atomic_sub returns the value BEFORE the subtraction (same convention
	// as cmd.odin's Grace_Signal, verified against this exact toolchain
	// there). Old value 1 means this call's own decrement just brought it
	// to 0 -- the other side already released, so this is provably the
	// last touch: safe to free both the cloned fn env and the handle
	// itself.
	if sync.atomic_sub(&h.refs, 1) == 1 {
		free(h.fn_env, h.fn_alloc)
		free(h, context.allocator)
	}
}

// One dedicated OS thread + nbio event loop per Dispatcher, lazily started
// on the first tick()/every() ever dispatched through it -- a program that
// never uses Tick/Every never pays for this thread (or, transitively, for
// the small chance of core:nbio initialization failure). Embedded directly
// in Dispatcher (cmd.odin) rather than a separate top-level type: it needs
// exactly the same lifetime as the pool it lives alongside (started after
// the Dispatcher exists, joined before the Mailbox it feeds is destroyed),
// and giving it its own init/destroy pair distinct from dispatcher_init/
// dispatcher_destroy would just be two lifecycles to keep in sync instead
// of one.
@(private = "package")
Timer_Service :: struct {
	// Guards started/loop/thread AND stop_requested -- ALL of them, not just
	// the first three. That is load-bearing, not incidental: see
	// timer_service_stop's own comment for the exact race (a genuine one,
	// caught live by ./tools/test.sh race) that requires stop_requested and
	// the wake_up call that accompanies it to share this SAME critical
	// section with timer_thread_body's own read of stop_requested, rather
	// than stop_requested being a separate atomic checked independently.
	start_mu:       sync.Mutex,
	started:        bool,
	stop_requested: bool, // see start_mu's own comment -- touched ONLY under start_mu, never atomically on its own
	thread:         ^thread.Thread,
	loop:           ^nbio.Event_Loop,
	ready:          sync.Sema,

	// WHY THE START FAILURE IS RECORDED AT ALL, and why in three fields.
	//
	// `loop == nil` is ambiguous, and the ambiguity is the whole reason these
	// exist: it means EITHER "the timer thread could not acquire an nbio event
	// loop" (a defect the application must be told about -- no Tick or Every on
	// this Dispatcher will ever fire again) OR "this Dispatcher has already been
	// torn down" (ordinary shutdown, where a diagnostic would be noise and the
	// Mailbox is closing anyway). Only the first is reportable.
	//
	// `start_failed` and `start_error` are written by the timer thread BEFORE it
	// posts `ready`, and read by anyone only AFTER waiting on `ready` -- exactly
	// the same publication discipline `loop` itself already uses, and the reason
	// neither is under start_mu: timer_service_ensure_started holds start_mu
	// across its sema_wait, so a thread taking start_mu to publish would
	// deadlock against it.
	//
	// `reported` is the once-per-Dispatcher latch, and it is a separate atomic
	// because it is written from DISPATCHING threads (any number of them), not
	// from the timer thread, and never inside start_mu.
	start_failed:   bool,     // published before `ready` is posted; read only after waiting on it
	start_error:    Msg_Text, // ditto -- what went wrong, in the same carrier Panicked_Msg uses
	reported:       bool,     // atomic; see timer_report_unavailable

	// Newly-dispatched handles waiting for the timer thread to arm their
	// FIRST nbio.timeout, guarded by pending_mu -- see timer_dispatch's own
	// comment for why registration hands off through this plain, mutex-
	// guarded list plus nbio.wake_up, rather than calling nbio.timeout_poly
	// directly from the dispatching thread (which is almost never the timer
	// thread itself).
	pending_mu: sync.Mutex,
	pending:    [dynamic]^Timer_Handle,

	// Every handle whose nbio timeout is currently outstanding. NO MUTEX, and
	// none is needed: arming, firing, rearming and the shutdown sweep all run
	// on the timer thread and nowhere else -- see timer_service_sweep_armed
	// for what this exists for and why a plain list is enough. (The one read
	// from another thread is the delete in timer_service_stop, which happens
	// strictly after thread.join.)
	armed: [dynamic]^Timer_Handle,
}

// Returns the running loop, starting the thread on the first call. nil means
// the timer subsystem failed to start (e.g. nbio.acquire_thread_event_loop
// itself failed) or has already been torn down -- callers must treat a nil
// result as "this Tick/Every will never fire" rather than crash.
@(private = "file")
timer_service_ensure_started :: proc(ts: ^Timer_Service) -> ^nbio.Event_Loop {
	sync.mutex_lock(&ts.start_mu)
	defer sync.mutex_unlock(&ts.start_mu)

	if ts.started { return ts.loop }
	if ts.stop_requested { return nil }

	ts.thread = thread.create(timer_thread_body)
	ts.thread.data = ts
	ts.thread.init_context = context
	thread.start(ts.thread)

	sync.sema_wait(&ts.ready) // blocks until the thread has published ts.loop (or failed to acquire one)
	ts.started = true
	return ts.loop
}

@(private = "file")
timer_thread_body :: proc(th: ^thread.Thread) {
	// Per-thread altstack (FIX 2, final fix-wave report), first action --
	// same convention as every other thread this package spawns (pool
	// workers, detached Cmds, Signal_Watcher, tea.odin's reader thread).
	install_crash_handlers()

	ts := cast(^Timer_Service)th.data

	// TEST-ONLY FAULT INJECTION, and read before the acquire so the failure
	// path below is reachable without breaking the process's nbio state. There
	// is no other way to exercise it: nbio.acquire_thread_event_loop fails only
	// on an io_uring/epoll setup failure (out of fds, a kernel that refuses),
	// none of which a test can provoke on demand, and the .Diff renderer's
	// compile-time RUNETEA_DIFF_FAULT precedent would put this path outside the
	// default `odin test` gate -- i.e. exactly where the bug lived for four
	// releases. Costs one relaxed atomic load, once per Dispatcher that ever
	// uses a timer at all. Set ONLY by timer_test.odin, always restored.
	forced := sync.atomic_load(&g_timer_force_start_failure)

	aerr: nbio.General_Error
	if !forced { aerr = nbio.acquire_thread_event_loop() }

	if forced || aerr != nil {
		// Publish with ts.loop left nil so timer_service_ensure_started's
		// waiter doesn't hang forever, and exit. Every future tick()/every()
		// dispatch on this Dispatcher sees ts.started == true with ts.loop ==
		// nil and treats it as "will never fire" (timer_dispatch below).
		//
		// NO LONGER SILENT (was docs/LIMITATIONS.md 2.14, "the worst-shaped
		// remaining limitation in the library"): start_failed/start_error are
		// published here, in the same pre-sema_post window ts.loop uses, and
		// timer_dispatch turns them into a Timer_Unavailable_Msg through the
		// Mailbox -- the same shape cmd.odin's Panicked_Msg uses for the
		// analogous "a background thing the app asked for can never produce a
		// result" case.
		ts.start_failed = true
		ts.start_error  = forced \
			? msg_text_from("timer subsystem: start failure forced by a test") \
			: msg_text_fmt("timer subsystem: nbio.acquire_thread_event_loop failed: %v", aerr)
		sync.sema_post(&ts.ready)
		return
	}
	defer nbio.release_thread_event_loop()

	ts.loop = nbio.current_thread_event_loop()
	sync.sema_post(&ts.ready)

	// Blocks in nbio.tick() whenever there is nothing to do; woken either by
	// a registered timeout firing, by timer_dispatch's own nbio.wake_up
	// after appending to ts.pending below, or by timer_service_stop's
	// explicit nbio.wake_up when tearing down. drain_pending runs BEFORE
	// every tick() call (not just once at startup) so a Tick/Every
	// registered while this thread is blocked gets armed the moment it
	// wakes, before waiting again.
	//
	// The stop check itself takes start_mu -- NOT a plain atomic load --
	// and that is load-bearing, not a style choice. A plain atomic flag
	// left room for a genuine race (caught live by ./tools/test.sh race):
	// timer_service_stop sets the flag and THEN calls nbio.wake_up(loop),
	// two separate steps: this thread's tick() can return for a completely
	// unrelated, legitimate reason (some OTHER Every's own timeout firing)
	// at basically the same instant, observe the just-set flag on ITS OWN
	// very next iteration, and proceed straight to `defer
	// nbio.release_thread_event_loop()` (which frees loop.wake and zeroes
	// the whole Event_Loop) -- all before timer_service_stop's OWN
	// subsequent wake_up(loop) call has actually executed, racing that call
	// against the free. Sharing start_mu between the two sides closes this:
	// timer_service_stop now sets stop_requested AND calls wake_up inside
	// ONE critical section, so this check can only ever observe
	// stop_requested == true AFTER that entire critical section --
	// including its wake_up call -- has fully completed. See
	// timer_service_stop's own comment and docs/superpowers/
	// tick-every-decision.md for the exact TSan report this fixed.
	for {
		sync.mutex_lock(&ts.start_mu)
		done := ts.stop_requested
		sync.mutex_unlock(&ts.start_mu)
		if done { break }

		timer_service_drain_pending(ts)
		nbio.tick()
	}

	// LAST statement, deliberately: it must run BEFORE the `defer
	// nbio.release_thread_event_loop()` registered above (defers are LIFO at
	// return), because that call is exactly what destroys the loop these
	// operations live in.
	timer_service_sweep_armed(ts)
}

// Releases every handle whose nbio timeout is still outstanding at shutdown.
// Runs on the timer thread, after its loop has stopped being ticked and
// before nbio.release_thread_event_loop tears the loop down.
//
// THIS CLOSES A REAL LEAK, not a theoretical one, and the design doc
// (docs/superpowers/tick-every-decision.md §b) previously argued it could not
// be closed at all: core:nbio's own loop teardown silently discards pending
// operations without invoking their callbacks, so a Tick/Every still armed
// when the session quits never reached timer_fire and never released the
// subsystem's reference. The doc concluded "there is no window to call
// timer_handle_release for it". There is: nbio.remove(op) cancels an
// outstanding operation, and nbio.timeout_poly has returned the ^Operation to
// pass it all along. The claim was wrong, and the leak it excused was the
// ordinary case, not an edge case -- an Every that is doing its job is armed
// essentially all the time, so it was armed at quit essentially always.
//
// nbio.remove's own two hard requirements are both met here by construction:
// it must run on the loop's own thread (this is that thread), and the target
// must not have had its callback invoked yet (a handle is in ts.armed only
// between arming and the timer_fire that removes it -- and nothing can be
// mid-callback, since the loop is no longer being ticked).
@(private = "file")
timer_service_sweep_armed :: proc(ts: ^Timer_Service) {
	for h in ts.armed {
		nbio.remove(h.op)
		h.op        = nil
		h.armed_idx = -1
		timer_handle_release(h)
	}
	clear(&ts.armed)
}

// ts.armed membership. Both run on the timer thread only -- see
// Timer_Service.armed's own comment. Removal is swap-with-last plus a stored
// index rather than a linear scan: a loaded session (tools/racecheck's timer
// phase dispatches thousands of concurrent Ticks) would otherwise make every
// single fire O(len(armed)).
@(private = "file")
timer_armed_add :: proc(ts: ^Timer_Service, h: ^Timer_Handle) {
	h.armed_idx = len(ts.armed)
	append(&ts.armed, h)
}

@(private = "file")
timer_armed_remove :: proc(ts: ^Timer_Service, h: ^Timer_Handle) {
	idx := h.armed_idx
	if idx < 0 { return }
	last := len(ts.armed) - 1
	ts.armed[idx] = ts.armed[last]        // self-assignment when idx == last, which is correct and needs no special case
	ts.armed[idx].armed_idx = idx
	pop(&ts.armed)
	h.armed_idx = -1
}

// Arms every handle appended to ts.pending since the last drain. Runs on the
// timer thread ONLY -- this is what makes the nbio.timeout_poly call inside
// timer_arm_initial below a same-thread call (nbio.exec's fast
// `op.l == &_tls_event_loop` path), never a cross-thread one. See
// timer_dispatch's own comment for why registration is split into "append
// under a plain mutex, then wake_up" instead of calling nbio.timeout_poly
// directly from whatever thread calls dispatch().
@(private = "file")
timer_service_drain_pending :: proc(ts: ^Timer_Service) {
	sync.mutex_lock(&ts.pending_mu)
	handles := ts.pending
	ts.pending = nil
	sync.mutex_unlock(&ts.pending_mu)
	if handles == nil { return }
	defer delete(handles)

	for h in handles { timer_arm_initial(ts, h) }
}

@(private = "file")
timer_arm_initial :: proc(ts: ^Timer_Service, h: ^Timer_Handle) {
	if sync.atomic_load(&h.cancelled) {
		timer_handle_release(h)
		return
	}
	h.ts     = ts
	h.target = time.tick_add(time.tick_now(), h.dur)
	timer_armed_add(ts, h)
	// Storing the returned ^Operation AFTER the call that arms it is safe
	// only because an nbio timeout never completes synchronously: core:nbio's
	// timeout_exec (impl_linux.odin) either enqueues an io_uring SQE or, for
	// duration <= 0, pushes onto l.completed -- both of which are reaped by a
	// LATER nbio.tick(), never by exec itself. If that ever stopped holding,
	// timer_fire could run (and free h) before this assignment landed.
	h.op = nbio.timeout_poly(h.dur, h, timer_fire, l = h.loop)
}

// Called from dispatcher_destroy (cmd.odin), LAST -- after the pool and
// every detached Cmd have already been joined. That ordering is load-
// bearing, not incidental: a detached Cmd is explicitly allowed to call
// dispatch() itself (cmd.odin's own doc comment on `detached`), so only
// once wait_group_wait has returned can dispatcher_destroy be sure nothing
// can still call timer_dispatch below and race this shutdown against the
// loop's own destruction. No-op if tick()/every() was never used on this
// Dispatcher (ts.started stays false, nothing was ever spawned).
//
// stop_requested is set AND wake_up is called INSIDE the SAME start_mu
// critical section, not two independent steps -- see timer_thread_body's
// own comment on its stop check for the exact race (a genuine
// use-after-free, caught live by ./tools/test.sh race) this closes: sharing
// the lock guarantees the timer thread cannot observe stop_requested ==
// true, and therefore cannot proceed to nbio.release_thread_event_loop()
// (which frees the very `loop` wake_up below touches), until this whole
// critical section -- wake_up included -- has fully finished.
@(private = "package")
timer_service_stop :: proc(ts: ^Timer_Service) {
	sync.mutex_lock(&ts.start_mu)
	started := ts.started
	loop := ts.loop
	th := ts.thread
	ts.stop_requested = true
	if started && loop != nil { nbio.wake_up(loop) } // loop is nil only if acquire_thread_event_loop itself failed -- the thread has already exited by then, nothing to wake
	sync.mutex_unlock(&ts.start_mu)

	if !started { return }

	thread.join(th)
	thread.destroy(th)

	// Anything still in ts.pending here was registered but never armed: the
	// timer thread's loop checks stop_requested BEFORE its drain, so a handle
	// appended in the last instant before this call can legitimately lose
	// that race and never reach timer_arm_initial. Nothing else will ever
	// release those, so release them here -- the thread is joined, so this is
	// single-threaded and cannot race the drain. Not merely tidy: with plain
	// tick()'s single reference, this release is what actually frees the
	// handle and its fn env, and skipping it would put back a slice of the
	// very per-Tick leak this design removes.
	//
	// delete on a nil dynamic array is a no-op, so the common case (the
	// thread's own last drain already emptied it) costs nothing.
	for h in ts.pending { timer_handle_release(h) }
	delete(ts.pending)

	// The handles themselves were already released by the timer thread's own
	// timer_service_sweep_armed; only the backing array is left to reclaim,
	// and only from here, after the join that proves nobody is still touching
	// it.
	delete(ts.armed)
}

// Handles a Cmd produced by tick()/every() -- called from dispatch()
// (cmd.odin) instead of the pool/detached path. Starts the Dispatcher's
// timer thread on first use, then hands the handle off to the timer thread
// via ts.pending (a plain mutex-guarded list, NOT core:nbio's own
// cross-thread mechanism) plus nbio.wake_up -- see timer_fire/timer_rearm
// below for what happens when it actually fires.
//
// WHY NOT call nbio.timeout_poly directly from here (the natural-looking
// approach, and what an earlier version of this file did): this proc runs
// on whatever thread called dispatch() -- essentially always a DIFFERENT
// thread from the timer thread that owns `loop`. core:nbio's own
// exec()/wake_up cross-thread path IS documented and does work for a single
// producer (docs/superpowers/nbio-decision.md §2b's own proof), but
// tools/racecheck's timer phase (many DRIVER threads calling dispatch()
// concurrently against the SAME Dispatcher) caught a genuine data race
// inside core:nbio itself under real concurrent cross-thread submission:
// mpsc_enqueue's `assert(mpscq.buffer[head & mpscq.mask] == nil)`
// (core:nbio/mpsc.odin) is a plain, non-atomic read one instruction before
// an atomic RMW on the same ring slot, and it can race mpsc_dequeue's own
// atomic write to that slot on the consumer (timer) thread when the ring
// wraps around under load. That is a bug in this exact nbio nightly's own
// mpsc implementation, not something fixable from this package (core: is
// the shared toolchain, not vendored into this repo) -- so this design
// simply never calls into nbio's cross-thread queue at all. Appending to
// ts.pending under an ordinary sync.Mutex, then calling nbio.wake_up
// (proven safe for concurrent multi-threaded use -- impl_linux.odin's
// _wake_up is a plain eventfd write(2), independently serialized by the
// kernel, touching no nbio-internal shared state) sidesteps it entirely:
// the ONLY thread that ever calls nbio.timeout_poly is the timer thread
// itself, draining ts.pending (timer_service_drain_pending above), which is
// always the same-thread nbio.exec path -- see docs/superpowers/
// tick-every-decision.md for the full TSan report and this fix.
@(private = "package")
timer_dispatch :: proc(d: ^Dispatcher, h: ^Timer_Handle) {
	ts := &d.timers
	loop := timer_service_ensure_started(ts)
	if loop == nil {
		// Timer subsystem could not start (or is already torn down) --
		// see timer_thread_body's own comment. Release the subsystem's
		// reference; this Tick/Every will never fire.
		timer_handle_release(h)
		// AND SAY SO. This used to be the whole of the failure path, which
		// meant a Dispatcher whose timer subsystem failed to start went on
		// accepting tick()/every() forever and firing none of them, with no
		// diagnostic of any kind -- an app's spinner simply stopped.
		timer_report_unavailable(d, ts)
		return
	}

	h.mailbox   = d.mailbox
	h.wake      = d.wake
	h.wake_data = d.wake_data
	h.loop      = loop

	sync.mutex_lock(&ts.pending_mu)
	append(&ts.pending, h)
	sync.mutex_unlock(&ts.pending_mu)

	nbio.wake_up(loop)
}

// Delivered through the Mailbox, to the application's own update(), when a
// Tick or Every was dispatched onto a Dispatcher whose timer subsystem could
// not start. It means exactly one thing, and it is permanent: NO TIMER ON THIS
// DISPATCHER WILL EVER FIRE. Anything the application drives off a Tick or an
// Every -- a spinner, a poll, a timeout, a debounce -- is dead for the rest of
// the session and needs a different strategy or an orderly quit.
//
// THE SHAPE IS Panicked_Msg's, deliberately (cmd.odin). Both are "a background
// facility the app asked for can never produce the result it promised", both
// are reported through the one channel the app is already draining rather than
// through a return value nobody checks, and both are simply unhandled -- not
// dropped -- by an update() with no matching case. Using the established shape
// means there is one convention here, not two.
//
// POD, per box()'s MESSAGE OWNERSHIP CONTRACT (arena.odin): Msg_Text, not a
// bare `string`, exactly as Panicked_Msg does. Pinned by
// test_timer_unavailable_msg_is_pod.
Timer_Unavailable_Msg :: struct {
	reason: Msg_Text,
}

// ONCE PER DISPATCHER, NOT ONCE PER FAILED DISPATCH -- the judgement call, made
// here and stated rather than left to be inferred from the atomic.
//
// The failure being reported is a property of the DISPATCHER (one timer thread,
// one nbio event loop, started once, lazily). It is not a property of the
// individual tick() that happened to be the one that discovered it, and it
// cannot change back: nothing retries the acquire. So every message after the
// first would carry identical information.
//
// Per-dispatch would also be actively harmful in precisely the situation this
// exists for. The applications that lean hardest on timers are the ones driving
// an animation, which re-dispatch on a cadence (a self-reissuing tick, or an
// every() the app restarts), and back-pressure on a full Mailbox is
// retry-forever, never drop (deliver_result, cmd.odin; docs/LIMITATIONS.md
// 2.15). A per-dispatch report would therefore let a broken timer subsystem
// saturate the Mailbox with warnings and stall the very application it was
// trying to warn -- a diagnostic that causes a worse failure than the one it
// describes. One message says the whole truth; the second says nothing new.
//
// The latch is an atomic exchange rather than a check-then-set because
// dispatch() may be called from any number of threads at once (that is exactly
// what tools/racecheck's timer phase does), and "exactly once" has to survive
// that.
//
// THE TORN-DOWN CASE IS NOT REPORTED, and that is the reason start_failed
// exists at all: timer_service_ensure_started also returns nil after
// timer_service_stop, which is ordinary shutdown, not a defect. The Mailbox is
// closing at that point anyway, so the message could not be delivered -- but
// gating on start_failed means the distinction is made on purpose rather than
// by accident of timing.
@(private = "file")
timer_report_unavailable :: proc(d: ^Dispatcher, ts: ^Timer_Service) {
	// Safe to read unsynchronised: written by the timer thread strictly before
	// its sema_post(&ts.ready), and this call is strictly after the matching
	// sema_wait inside timer_service_ensure_started. Same publication edge
	// ts.loop already relies on.
	if !ts.start_failed { return }
	if sync.atomic_exchange(&ts.reported, true) { return }

	msg := box(Timer_Unavailable_Msg{reason = ts.start_error}, context.allocator)
	if deliver_result(d.mailbox, msg) {
		if d.wake != nil { d.wake(d.wake_data) }
	} else {
		// Mailbox already closed -- nothing will ever receive this. Free it
		// here rather than leak it, exactly as timer_fire does for an
		// orphaned fire, and for the same reason: this is the thread (and
		// the allocator) that made the allocation.
		box_free(msg, context.allocator)
	}
}

// TEST-ONLY. When true, the next timer thread to start behaves as though
// nbio.acquire_thread_event_loop had failed -- see timer_thread_body for why
// this exists rather than a compile-time RUNETEA_TIMER_FAULT define. Nothing in
// the library ever writes it; timer_test.odin sets and restores it, and
// ODIN_TEST_THREADS=1 means no two tests contend for it.
@(private = "package")
g_timer_force_start_failure: bool

// Runs on the timer thread, inside nbio.tick(). Delivers the fired Msg
// straight to the Mailbox -- NOT through run_cmd_task/run_cmd_detached,
// which each deliver exactly one result per dispatch() and then finish;
// an Every delivers many results over its lifetime from repeated calls to
// THIS proc, so it needs its own delivery path, reusing cmd.odin's
// deliver_result (retry on Full, discard on Closed -- same policy every
// other producer in this codebase already uses; see
// docs/superpowers/tick-every-decision.md §c for why "retry, don't drop" is
// the right default here too).
@(private = "file")
timer_fire :: proc(op: ^nbio.Operation, h: ^Timer_Handle) {
	// This callback IS the end of `op`'s life (nbio.remove after a callback
	// has run is a documented use-after-free), so drop out of the shutdown
	// sweep list first thing, before any path below can return or free h.
	// timer_rearm re-adds if this is a repeating Every that continues.
	timer_armed_remove(h.ts, h)
	h.op = nil

	if sync.atomic_load(&h.cancelled) {
		timer_handle_release(h)
		return
	}

	t := time.tick_now() // CLOCK_MONOTONIC_RAW, per spec §9 -- never CLOCK_REALTIME, which can jump with NTP mid-session
	msg := h.fn(h.fn_env, t)

	delivered := true
	// msg.id != nil, not msg != nil -- same distinction cmd.odin's own
	// run_cmd_task/run_cmd_detached document at length: a boxed zero-sized
	// Msg legitimately has a nil `data` pointer, which `any == nil` alone
	// cannot tell apart from "genuinely nothing to send".
	if msg.id != nil {
		if deliver_result(h.mailbox, msg) {
			if h.wake != nil { h.wake(h.wake_data) }
		} else {
			// Mailbox closed -- the session is tearing down. Same
			// convention as run_cmd_task's own orphaned-result comment:
			// free the box here rather than leak it, safe because this is
			// the same thread (well, the same ALLOCATOR instance --
			// context.allocator on the timer thread, set once at
			// thread.create via init_context = context, same as every
			// other producer thread in this package) that made the
			// allocation via h.fn.
			box_free(msg, context.allocator)
			delivered = false
		}
	}

	if !h.repeat || !delivered {
		// One-shot Tick, or an Every whose Mailbox just closed -- either
		// way, done. Release the subsystem's own reference (see
		// Timer_Handle's comment); this also frees fn_env/h once the
		// caller's own reference (timer_stop, if ever called) has been
		// released too.
		timer_handle_release(h)
		return
	}

	timer_rearm(h)
}

// Schedules the NEXT fire of a repeating Every. Runs on the timer thread
// (same thread that just called timer_fire above), so nbio.timeout's
// `l = h.loop` resolves to the fast same-thread path (nbio.exec's own
// `op.l == &_tls_event_loop` check) -- no cross-thread queue/wake needed for
// a self-rearm.
//
// DRIFT (docs/superpowers/tick-every-decision.md §d): h.target advances by
// EXACTLY h.dur each time, computed from the PREVIOUS target rather than
// from "now" at rearm time -- so as long as one cycle (fn + delivery)
// finishes faster than h.dur, there is zero accumulated drift, regardless
// of how long any individual fire's box()/deliver_result call took.
//
// CATCHING UP (same section): if a fire's own processing (most likely a
// Full-mailbox retry inside deliver_result above) took so long that the
// naively-advanced target is already in the past by the time we get here,
// this resyncs to `now + h.dur` instead of scheduling a near-zero (or
// negative -- nbio.timeout treats duration <= 0 as "fire on the very next
// tick") wait. That means a stall causes AT MOST one skipped interval, never
// a burst of queued catch-up fires -- the right choice for anything driving
// a visible animation, where "fire everything you missed, all at once" would
// look like the UI jumping forward rather than ticking steadily.
@(private = "file")
timer_rearm :: proc(h: ^Timer_Handle) {
	now := time.tick_now()
	next := time.tick_add(h.target, h.dur)
	if time.tick_diff(next, now) >= 0 {
		next = time.tick_add(now, h.dur)
	}
	h.target = next

	// Back into the shutdown sweep list (timer_fire dropped this handle out
	// of it on entry): from here until the NEXT timer_fire there is once
	// again an outstanding operation that nbio's own loop teardown would
	// otherwise discard without ever releasing the handle.
	timer_armed_add(h.ts, h)

	// timeout_poly here too, for the same reason as timer_dispatch's own
	// comment, even though THIS call happens to be same-thread (timer_fire
	// and timer_rearm both run on the timer thread) and so wasn't the one
	// TSan actually caught -- keeping exactly one way to arm a timeout
	// throughout this file, rather than a same-thread-only shortcut here and
	// a cross-thread-safe path in timer_dispatch, is not worth the risk of
	// the two silently diverging later.
	h.op = nbio.timeout_poly(time.tick_diff(now, next), h, timer_fire, l = h.loop)
}
