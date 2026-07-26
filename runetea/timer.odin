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
//     structurally identical to cmd.odin's own Grace_Signal: one reference
//     for the caller (released by timer_stop), one for the timer subsystem
//     (released when the timer is naturally done). Whichever side releases
//     last frees it.

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
// repeating Every, returned alongside the Cmd from tick()/every(). Pass it to
// timer_stop to cancel; discarding it instead is fine and leaks nothing MORE
// than the bytes of the handle itself once both sides (caller + subsystem)
// have released their own reference -- see docs/superpowers/
// tick-every-decision.md §b for the full "why must this be stoppable"
// argument and the exact leak/lifetime tradeoff being made here.
//
// Refcounted exactly like cmd.odin's Grace_Signal, for the identical
// signal-then-free reason documented there: `refs` starts at 2 (one for
// whoever holds the returned handle, released by timer_stop; one for the
// timer subsystem itself, released in timer_fire once the timer is
// naturally done -- fired-and-not-repeating, cancelled, or the session's
// Mailbox has closed). Whichever side's release call brings it to 0 is
// provably the last touch, so that side frees it.
//
// Fields past `cancelled` are internal bookkeeping the timer subsystem needs
// across repeats -- not part of the public contract, but Odin has no
// field-level privacy within a package, so they are visible; treat this as
// opaque and only call timer_stop on it.
Timer_Handle :: struct {
	cancelled: bool, // touched only via sync.atomic_load/store
	refs:      int,  // touched only via sync.atomic_add/atomic_sub; starts at 2

	fn:        Timer_Fn,
	fn_env:    rawptr,
	fn_alloc:  mem.Allocator,
	dur:       time.Duration,
	repeat:    bool, // false = Tick (fires once), true = Every (reschedules itself)

	target: time.Tick,          // Every only: the intended next-fire instant, tracked independent of "now" so a slow fire doesn't accumulate drift -- see timer_rearm
	loop:   ^nbio.Event_Loop,    // captured once at dispatch time; same-thread rearms use it directly

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
tick :: proc(d: time.Duration, fn: Timer_Fn, env: $E, alloc: mem.Allocator) -> (Cmd, ^Timer_Handle) {
	return timer_new(d, fn, env, alloc, repeat = false)
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
every :: proc(d: time.Duration, fn: Timer_Fn, env: $E, alloc: mem.Allocator) -> (Cmd, ^Timer_Handle) {
	return timer_new(d, fn, env, alloc, repeat = true)
}

@(private = "file")
timer_new :: proc(d: time.Duration, fn: Timer_Fn, env: $E, alloc: mem.Allocator, repeat: bool) -> (Cmd, ^Timer_Handle) {
	fnenv, ferr := new(E, alloc)
	if ferr != nil { return cmd_nil(), nil }
	fnenv^ = env

	h, herr := new(Timer_Handle, context.allocator)
	if herr != nil {
		free(fnenv, alloc)
		return cmd_nil(), nil
	}
	h.refs     = 2
	h.fn       = fn
	h.fn_env   = rawptr(fnenv)
	h.fn_alloc = alloc
	h.dur      = d
	h.repeat   = repeat

	return Cmd{timer = h}, h
}

// Cancels a pending Tick or a repeating Every. Best-effort and cooperative,
// same class as Cancel_Token (cmd.odin): if the timer thread has already
// begun firing this instant, the message may still be delivered -- there is
// no way to un-send something already in flight. Safe to call at most once
// per handle (releases the caller's own reference, see Timer_Handle's own
// comment) and safe to call even after the timer already fired/stopped on
// its own. Safe with h == nil (mirrors cancel_requested's own nil handling).
timer_stop :: proc(h: ^Timer_Handle) {
	if h == nil { return }
	sync.atomic_store(&h.cancelled, true)
	timer_handle_release(h)
}

@(private = "file")
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

	// Newly-dispatched handles waiting for the timer thread to arm their
	// FIRST nbio.timeout, guarded by pending_mu -- see timer_dispatch's own
	// comment for why registration hands off through this plain, mutex-
	// guarded list plus nbio.wake_up, rather than calling nbio.timeout_poly
	// directly from the dispatching thread (which is almost never the timer
	// thread itself).
	pending_mu: sync.Mutex,
	pending:    [dynamic]^Timer_Handle,
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

	if aerr := nbio.acquire_thread_event_loop(); aerr != nil {
		// Best-effort failure path: publish with ts.loop left nil so
		// timer_service_ensure_started's waiter doesn't hang forever, and
		// exit. Every future tick()/every() dispatch on this Dispatcher
		// sees ts.started == true with ts.loop == nil and treats it as "will
		// never fire" (timer_dispatch below) -- a documented limit, not
		// silently ignored; see docs/superpowers/tick-every-decision.md.
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

	for h in handles { timer_arm_initial(h) }
}

@(private = "file")
timer_arm_initial :: proc(h: ^Timer_Handle) {
	if sync.atomic_load(&h.cancelled) {
		timer_handle_release(h)
		return
	}
	h.target = time.tick_add(time.tick_now(), h.dur)
	nbio.timeout_poly(h.dur, h, timer_fire, l = h.loop)
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

	// Defensive, not load-bearing: by this point no producer can still be
	// appending to ts.pending (see this proc's own doc comment on why), so
	// the timer thread's own last drain (timer_service_drain_pending, inside
	// its loop) should already have emptied it. delete on a nil dynamic
	// array is a no-op either way.
	delete(ts.pending)
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
		// best effort, see timer_thread_body's own comment. Release the
		// subsystem's reference; the Tick/Every simply never fires.
		timer_handle_release(h)
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

	// timeout_poly here too, for the same reason as timer_dispatch's own
	// comment, even though THIS call happens to be same-thread (timer_fire
	// and timer_rearm both run on the timer thread) and so wasn't the one
	// TSan actually caught -- keeping exactly one way to arm a timeout
	// throughout this file, rather than a same-thread-only shortcut here and
	// a cross-thread-safe path in timer_dispatch, is not worth the risk of
	// the two silently diverging later.
	nbio.timeout_poly(time.tick_diff(now, next), h, timer_fire, l = h.loop)
}
