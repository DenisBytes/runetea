package main

// Standalone ThreadSanitizer harness for RuneTea's concurrent primitives.
//
// WHY A STANDALONE PROGRAM, NOT `odin test`: verified 2026-07-26 -- `odin
// test -sanitize:thread` never reports a race on this toolchain, even given
// a deliberate, guaranteed 4-thread unsynchronized-counter race that IS
// caught by `odin build -sanitize:thread` (SUMMARY: ThreadSanitizer: data
// race ..., exit 66). See tools/test.sh's `race` case for the wiring. This
// file is built with `odin build`, the mode that actually works, and run
// directly (not re-run under `odin test`).
//
// Three phases, each hammering the ACTUAL public API of one primitive under
// real concurrency, each with its own Mailbox so a bug surfaced by one phase
// can't be masked or amplified by another:
//
//   A. Mailbox (runetea/mailbox.odin) -- several producer threads hammering
//      mailbox_send, TWO consumers draining concurrently (one via the
//      blocking mailbox_recv, one via the non-blocking mailbox_try_recv --
//      mailbox.odin's own doc comment says concurrent recv/try_recv callers
//      "stay balanced in aggregate", so this is documented-supported usage,
//      not a misuse), plus a THIRD thread that calls mailbox_close partway
//      through, while producers and consumers are both still active.
//
//   B. Dispatcher (runetea/cmd.odin) -- many pool-dispatched Cmds and many
//      detached Cmds, all landing results in the mailbox while a concurrent
//      drainer thread empties it, then dispatcher_destroy called
//      immediately after the last dispatch() -- i.e. while most of that
//      work is still queued or running. This is
//      test_dispatcher_destroy_waits_for_detached_cmds (cmd_test.odin) done
//      at volume, with a real concurrent drainer racing the teardown.
//
//   C. Signal_Watcher (runetea/signals.odin) -- start the watcher, bombard
//      it with SIGWINCH/SIGINT from several driver threads while a drainer
//      thread empties the mailbox concurrently, then signal_watcher_stop
//      while that drainer is still running.
//
// Every mailbox is destroyed only once its producers are provably done
// (joined, or via dispatcher_destroy's / signal_watcher_stop's own
// documented guarantees) -- matching mailbox_destroy's precondition.
//
// This program does not use core:testing at all, so it cannot reproduce (and
// therefore cannot mask) the previously-reported suspected race between
// dispatch()'s detached-Cmd teardown and core:testing's memory-report
// printer -- if that one is an artifact of the test runner, it will not
// appear here.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import rt "../../runetea"

main :: proc() {
	start := time.now()
	fmt.println("=== tools/racecheck ===")
	phase_mailbox()
	phase_dispatcher()
	phase_signals()
	phase_program()
	phase_program_nbio()
	phase_dispatcher_reap()
	phase_timers()
	phase_batch_sequence()
	fmt.printfln("=== racecheck: all phases completed without crashing (%v) ===", time.since(start))
}

// --- Phase A: Mailbox -------------------------------------------------

Ping_Msg :: struct { producer, seq: int }

MB_PRODUCERS :: 10
MB_SENDS     :: 60000 // per producer -> 600000 messages total
MB_CAP       :: 1024  // deliberately small vs. total sends: forces backpressure and lock contention

Mb_Producer :: struct {
	m:       ^rt.Mailbox,
	id:      int,
	closing: ^bool,
}

mb_producer_run :: proc(data: rawptr) {
	p := cast(^Mb_Producer)data
	for j in 0 ..< MB_SENDS {
		if sync.atomic_load(p.closing) { return }
		msg := rt.box(Ping_Msg{producer = p.id, seq = j}, context.allocator)
		attempts := 0
		for {
			r := rt.mailbox_send(p.m, msg)
			if r == .Ok { break }
			if r == .Closed { return }
			// Full: retry -- the consumers below are actively draining.
			// Bound the retries so a close mid-flight can never spin a
			// producer forever.
			attempts += 1
			if sync.atomic_load(p.closing) || attempts > 50000 { return }
			thread.yield()
		}
	}
}

Mb_Consumer :: struct {
	m:          ^rt.Mailbox,
	closing:    ^bool,
	recv_count: ^int, // atomic
}

mb_consumer_recv_run :: proc(data: rawptr) {
	c := cast(^Mb_Consumer)data
	for {
		_, ok := rt.mailbox_recv(c.m)
		if !ok { return } // authoritative: only false once closed AND drained
		sync.atomic_add(c.recv_count, 1)
	}
}

mb_consumer_try_run :: proc(data: rawptr) {
	c := cast(^Mb_Consumer)data
	idle := 0
	for {
		_, ok := rt.mailbox_try_recv(c.m)
		if ok {
			sync.atomic_add(c.recv_count, 1)
			idle = 0
			continue
		}
		// try_recv has no way to distinguish "empty but open" from "empty
		// and closed" (it never inspects m.closed), so it cannot terminate
		// on its own the way mailbox_recv can. It bails out on a long idle
		// streak after closing has started; mailbox_recv (above) is the one
		// that authoritatively drains whatever this leaves behind.
		if sync.atomic_load(c.closing) {
			idle += 1
			if idle > 5000 { return }
		}
		thread.yield()
	}
}

Mb_Closer :: struct {
	m:       ^rt.Mailbox,
	closing: ^bool,
}

mb_closer_run :: proc(data: rawptr) {
	c := cast(^Mb_Closer)data
	// Short and deliberately racy: fires while producers/consumers above are
	// still mid-flight, not after a clean quiescence. Concurrent close is
	// exactly the scenario under test.
	time.sleep(50 * time.Millisecond)
	sync.atomic_store(c.closing, true)
	rt.mailbox_close(c.m)
}

phase_mailbox :: proc() {
	fmt.println("--- phase A: mailbox (producers + dual consumers + concurrent close) ---")

	m: rt.Mailbox
	if err := rt.mailbox_init(&m, MB_CAP); err != nil {
		fmt.eprintln("mailbox_init failed:", err)
		os.exit(1)
	}

	closing: bool
	recv_count: int

	producers := make([]Mb_Producer, MB_PRODUCERS); defer delete(producers)
	prod_th := make([]^thread.Thread, MB_PRODUCERS); defer delete(prod_th)
	for i in 0 ..< MB_PRODUCERS {
		producers[i] = Mb_Producer{m = &m, id = i, closing = &closing}
		prod_th[i] = thread.create_and_start_with_data(&producers[i], mb_producer_run, init_context = context)
	}

	consumer := Mb_Consumer{m = &m, closing = &closing, recv_count = &recv_count}
	recv_th := thread.create_and_start_with_data(&consumer, mb_consumer_recv_run, init_context = context)
	try_th := thread.create_and_start_with_data(&consumer, mb_consumer_try_run, init_context = context)

	closer := Mb_Closer{m = &m, closing = &closing}
	closer_th := thread.create_and_start_with_data(&closer, mb_closer_run, init_context = context)

	for i in 0 ..< MB_PRODUCERS { thread.join(prod_th[i]) }
	for i in 0 ..< MB_PRODUCERS { thread.destroy(prod_th[i]) }
	thread.join(closer_th); thread.destroy(closer_th)

	// mailbox_recv's contract (ok=false only once closed AND drained)
	// guarantees this terminates once mailbox_close has fired.
	thread.join(recv_th); thread.destroy(recv_th)
	thread.join(try_th); thread.destroy(try_th)

	fmt.printfln("  mailbox: %d messages received (some sends may be cut short by the concurrent close)", recv_count)

	rt.mailbox_destroy(&m)
}

// --- Phase B: Dispatcher ------------------------------------------------

// tag was a bare `string` field ("pool"/"detached") -- never actually read
// anywhere below (only the message's PRESENCE is counted), so under box()'s
// MESSAGE OWNERSHIP CONTRACT (arena.odin) it is simply dropped rather than
// converted to a Msg_Text; there is nothing here worth the fixed-buffer cost.
Cmd_Result :: struct { id: int }

Pool_Env :: struct { id: int }

// PANIC_EVERY_N_POOL: a fraction of pool Cmds panic instead of returning
// normally -- T1 extension (docs/superpowers/tier1-coverage-decision.md),
// exercising run_cmd_guarded (cmd.odin) at volume under real
// ThreadSanitizer, not just single-shot unit tests. This is the scenario
// unit tests structurally cannot cover: guard.odin's g_guard/g_panic_msg/
// g_armed are thread_local, and the pool's 8 worker OS threads are REUSED
// across DP_POOL_CMDS/8 ~= 2500 tasks each -- this is what proves that
// arming and disarming that thread-local state thousands of times in a row
// on the SAME reused thread, concurrently with 7 other threads doing the
// same, never corrupts a jmp_buf or leaks a panic across tasks. 1/13 is
// arbitrary but deliberately not a divisor of 8 (the worker count) or 7 (the
// existing stagger below), so panics land unevenly across workers and
// interleave with normal completions rather than falling into a clean
// per-worker pattern.
PANIC_EVERY_N_POOL :: 13

pool_cmd_run :: proc(env: rawptr, cancel: ^rt.Cancel_Token) -> any {
	e := cast(^Pool_Env)env
	if e.id % PANIC_EVERY_N_POOL == 0 { panic("racecheck: pool cmd exploded") }
	// Stagger completion so a meaningful fraction are still running when the
	// dispatch loop below reaches dispatcher_destroy.
	if e.id % 7 == 0 { time.sleep(time.Millisecond) }
	return rt.box(Cmd_Result{id = e.id}, context.allocator)
}

Detached_Env :: struct { id: int }

// See PANIC_EVERY_N_POOL above -- same reasoning, applied to the OTHER
// guarded thread class: a detached Cmd gets a brand-new OS thread per
// dispatch (no worker reuse), so this instead proves install_crash_handlers
// + guarded() compose correctly on a thread that only ever runs ONE task
// before exiting, at volume, concurrently with the pool's reused-thread case
// above running in the same process.
PANIC_EVERY_N_DETACHED :: 11

detached_cmd_run :: proc(env: rawptr, cancel: ^rt.Cancel_Token) -> any {
	e := cast(^Detached_Env)env
	if e.id % PANIC_EVERY_N_DETACHED == 0 { panic("racecheck: detached cmd exploded") }
	if e.id % 5 == 0 { time.sleep(time.Millisecond) }
	return rt.box(Cmd_Result{id = e.id}, context.allocator)
}

Dispatch_Drainer :: struct {
	m:            ^rt.Mailbox,
	count:        ^int,
	panic_count:  ^int, // atomic; counts Panicked_Msg specifically, see phase_dispatcher's own verification of this against the expected panic rate
}

dispatch_drainer_run :: proc(data: rawptr) {
	d := cast(^Dispatch_Drainer)data
	for {
		msg, ok := rt.mailbox_recv(d.m)
		if !ok { return }
		if _, is_panic := msg.(rt.Panicked_Msg); is_panic {
			sync.atomic_add(d.panic_count, 1)
		}
		sync.atomic_add(d.count, 1)
	}
}

DP_POOL_WORKERS  :: 8
DP_POOL_CMDS     :: 20000
DP_DETACHED_CMDS :: 1500

phase_dispatcher :: proc() {
	fmt.println("--- phase B: dispatcher (pool + detached Cmds, destroy while in flight) ---")

	m: rt.Mailbox
	if err := rt.mailbox_init(&m, 1024); err != nil {
		fmt.eprintln("mailbox_init failed:", err)
		os.exit(1)
	}

	recv_count: int
	panic_count: int
	drainer_state := Dispatch_Drainer{m = &m, count = &recv_count, panic_count = &panic_count}
	drainer := thread.create_and_start_with_data(&drainer_state, dispatch_drainer_run, init_context = context)

	d: rt.Dispatcher
	rt.dispatcher_init(&d, &m, DP_POOL_WORKERS)

	for i in 0 ..< DP_POOL_CMDS {
		rt.dispatch(&d, rt.cmd_from(pool_cmd_run, Pool_Env{id = i}, context.allocator))
	}
	for i in 0 ..< DP_DETACHED_CMDS {
		rt.dispatch(&d, rt.cmd_from(detached_cmd_run, Detached_Env{id = i}, context.allocator, detached = true))
	}

	// Destroy immediately: most of the above is still queued or running.
	// dispatcher_destroy's contract guarantees every pool task AND every
	// detached Cmd (including its own mailbox_send) has completed by the
	// time this returns -- but the drainer thread above has been racing
	// that completion the whole time, concurrently pulling results out of
	// the SAME mailbox those worker/detached threads are sending into, and a
	// meaningful fraction of them panicked (PANIC_EVERY_N_POOL/_DETACHED
	// above) and went through run_cmd_guarded/guarded() concurrently on both
	// thread classes while this teardown was in flight.
	rt.dispatcher_destroy(&d)

	// dispatcher_destroy's return is the proof that no producer can still
	// be touching the mailbox -- safe to close now to unblock the drainer.
	rt.mailbox_close(&m)
	thread.join(drainer); thread.destroy(drainer)

	fmt.printfln("  dispatcher: %d results drained (dispatched %d pool + %d detached)",
		recv_count, DP_POOL_CMDS, DP_DETACHED_CMDS)

	// Every dispatch produces EXACTLY one mailbox message, panic or not
	// (run_cmd_guarded turns a panic into a Panicked_Msg rather than
	// dropping it) -- so recv_count must equal the total dispatched
	// regardless of how many panicked, and panic_count must equal the
	// expected count from the two moduli above exactly (not "close to" --
	// a lost or duplicated Panicked_Msg under concurrent thread_local
	// guard state would show up as a mismatch here, under real
	// ThreadSanitizer pressure, not just in a single-threaded unit test).
	expected_panics := (DP_POOL_CMDS + PANIC_EVERY_N_POOL - 1) / PANIC_EVERY_N_POOL
	expected_panics += (DP_DETACHED_CMDS + PANIC_EVERY_N_DETACHED - 1) / PANIC_EVERY_N_DETACHED
	if recv_count != DP_POOL_CMDS + DP_DETACHED_CMDS {
		fmt.eprintfln("  FAIL: expected %d total results, got %d", DP_POOL_CMDS + DP_DETACHED_CMDS, recv_count)
		os.exit(1)
	}
	if panic_count != expected_panics {
		fmt.eprintfln("  FAIL: expected %d Panicked_Msg results, got %d", expected_panics, panic_count)
		os.exit(1)
	}
	fmt.printfln("  dispatcher: %d of those were Panicked_Msg (expected %d) -- guarded Cmd panics survive pool-thread reuse and detached-thread volume under TSan",
		panic_count, expected_panics)

	rt.mailbox_destroy(&m)
}

// --- Phase C: Signal_Watcher ---------------------------------------------

SIG_DRIVERS     :: 6
SIG_ROUNDS_EACH :: 600 // 6 * 600 = 3600 signals total

Sig_Driver :: struct {
	sw: ^rt.Signal_Watcher,
	id: int,
}

sig_driver_run :: proc(data: rawptr) {
	s := cast(^Sig_Driver)data
	for i in 0 ..< SIG_ROUNDS_EACH {
		if i % 2 == 0 {
			posix.pthread_kill(s.sw.native, rt.SIGWINCH)
		} else {
			posix.pthread_kill(s.sw.native, .SIGINT)
		}
		thread.yield()
	}
}

Sig_Drainer :: struct {
	m:     ^rt.Mailbox,
	count: ^int,
}

sig_drainer_run :: proc(data: rawptr) {
	d := cast(^Sig_Drainer)data
	for {
		_, ok := rt.mailbox_recv(d.m)
		if !ok { return }
		sync.atomic_add(d.count, 1)
	}
}

phase_signals :: proc() {
	fmt.println("--- phase C: signal watcher (concurrent signals + concurrent drain + stop) ---")

	m: rt.Mailbox
	if err := rt.mailbox_init(&m, 128); err != nil {
		fmt.eprintln("mailbox_init failed:", err)
		os.exit(1)
	}

	sw: rt.Signal_Watcher
	rt.signal_watcher_start(&sw, &m, posix.FD(-1))

	recv_count: int
	drainer_state := Sig_Drainer{m = &m, count = &recv_count}
	drainer := thread.create_and_start_with_data(&drainer_state, sig_drainer_run, init_context = context)

	drivers := make([]Sig_Driver, SIG_DRIVERS); defer delete(drivers)
	driver_th := make([]^thread.Thread, SIG_DRIVERS); defer delete(driver_th)
	for i in 0 ..< SIG_DRIVERS {
		drivers[i] = Sig_Driver{sw = &sw, id = i}
		driver_th[i] = thread.create_and_start_with_data(&drivers[i], sig_driver_run, init_context = context)
	}

	// Join the drivers before stop: signal_watcher_stop joins sw.thread, and
	// a pthread_kill(sw.native, ...) issued after that join targets an
	// already-exited thread's stale handle -- undefined by POSIX. The
	// drainer below is not subject to that (it only ever touches the
	// mailbox), so it keeps running concurrently with signal_watcher_stop,
	// which is exactly the scenario under test.
	for i in 0 ..< SIG_DRIVERS { thread.join(driver_th[i]) }
	for i in 0 ..< SIG_DRIVERS { thread.destroy(driver_th[i]) }

	// Concurrent with the still-running drainer thread above.
	rt.signal_watcher_stop(&sw)

	rt.mailbox_close(&m)
	thread.join(drainer); thread.destroy(drainer)

	fmt.printfln("  signals: %d messages drained from %d signals sent",
		recv_count, SIG_DRIVERS * SIG_ROUNDS_EACH)

	rt.mailbox_destroy(&m)
}

// --- Phase D: Program / run() end-to-end ---------------------------------
//
// Phases A-C exercise Mailbox, Dispatcher and Signal_Watcher in isolation --
// none of them touch tea.odin, which is ALL new concurrency: a reader
// thread that boxes tty bytes into Key_Msgs and pushes them into the same
// mailbox a pool-dispatched Cmd result also lands in, with run()'s main
// loop as the single consumer racing both producers every iteration.
//
// Two quit paths are driven, alternating by iteration:
//   - via_cmd:  the init Cmd sleeps briefly and returns Quit_Msg with NO
//     keypress ever sent -- the scenario the mailbox-as-single-wait-point
//     design exists for (spec: "an async result updates the view with no
//     keypress"). This is also the shutdown-order hazard the brief calls
//     out explicitly: run() quits while the reader thread is still parked
//     in poll() on an open pipe that will never see more data, so run()'s
//     defer MUST call input_wake before thread.join or this phase hangs.
//     There is no separate timeout here -- a hang IS the failure signal.
//   - keypress: the feeder writes a few bursts then 'q', which Update turns
//     into quit_cmd(); that Cmd is dispatched (pool) and its Quit_Msg
//     result arrives back through the very same mailbox the reader thread
//     is still feeding, so the quit itself is racing live input.
//
// Runs entirely over an anonymous pipe (Fd_Source over posix.pipe), the
// same substitution nbiocheck/Phase-testing already established for
// exercising a real fd without a tty. No terminal semantics are under test
// here, only the concurrency.

Race_Model :: struct { n: int }

race_update :: proc(m: Race_Model, msg: any, alloc: mem.Allocator) -> (Race_Model, rt.Cmd) {
	m := m
	switch v in msg {
	case rt.Key_Msg:
		if v.code == .Rune && v.r == 'q' {
			return m, rt.quit_cmd()
		}
		m.n += 1
	}
	return m, rt.cmd_nil()
}

race_view :: proc(m: Race_Model, alloc: mem.Allocator) -> string {
	return fmt.aprintf("n=%d", m.n, allocator = alloc)
}

race_async_quit :: proc(env: rawptr, cancel: ^rt.Cancel_Token) -> any {
	time.sleep(2 * time.Millisecond)
	return rt.box(rt.Quit_Msg{}, context.allocator)
}

// Deliberately bounded, on BOTH paths: an unbounded feeder loop that only
// checks a stop flag between writes can block forever inside posix.write
// once run() has quit and the reader thread has stopped draining the pipe
// (its read end fills at 64KB and nothing empties it from then on) -- that
// is a real bug this phase hit during its own development (feeder thread
// wedged in pipe_write, thread.join on it then hung the whole phase; root-
// caused via /proc/<pid>/task/*/wchan showing pipe_write). A handful of
// small writes can never fill the pipe regardless of whether anything is
// still reading, so the feeder always finishes on its own -- no stop flag,
// no join-time race, while still overlapping the ~2ms async-quit delay
// (20-200 iterations * 200us) so real concurrent input is in flight when
// each quit path fires.
Race_Key_Feeder :: struct {
	w:      posix.FD,
	send_q: bool, // true: a short burst then "q"; false: a longer burst (via_cmd path)
}

race_key_feeder_run :: proc(data: rawptr) {
	f := cast(^Race_Key_Feeder)data
	ab := []u8{'a', 'b'}
	rounds := 200 if !f.send_q else 20
	for i in 0 ..< rounds {
		posix.write(f.w, raw_data(ab), len(ab))
		time.sleep(200 * time.Microsecond)
	}
	if f.send_q {
		q := []u8{'q'}
		posix.write(f.w, raw_data(q), len(q))
	}
}

RACE_PROGRAM_ITERS :: 30

phase_program :: proc() {
	fmt.println("--- phase D: Program/run() (reader thread racing async-Cmd and keypress-driven quits) ---")

	for iter in 0 ..< RACE_PROGRAM_ITERS {
		via_cmd := iter % 2 == 0

		fds: [2]posix.FD
		if posix.pipe(&fds) != .OK {
			fmt.eprintln("pipe failed")
			os.exit(1)
		}
		read_fd, write_fd := fds[0], fds[1]

		src, ok := rt.input_source_from_fd(read_fd)
		if !ok {
			fmt.eprintln("input_source_from_fd failed")
			os.exit(1)
		}

		feeder := Race_Key_Feeder{w = write_fd, send_q = !via_cmd}
		feeder_th := thread.create_and_start_with_data(&feeder, race_key_feeder_run, init_context = context)

		b := strings.builder_make(); defer strings.builder_destroy(&b)

		p: rt.Program(Race_Model)
		init_cmd := rt.cmd_nil()
		if via_cmd {
			init_cmd = rt.Cmd{procedure = race_async_quit, env = nil, allocator = context.allocator}
		}
		rt.program_init(&p, Race_Model{}, race_update, race_view, init_cmd)

		// THE shutdown-order assertion: if input_wake were ever dropped from
		// run()'s teardown, the via_cmd iterations would hang right here.
		err := rt.run(&p, &src, &b)
		if err != nil {
			fmt.eprintln("run() returned an error:", err)
			os.exit(1)
		}

		thread.join(feeder_th); thread.destroy(feeder_th)

		rt.input_close(&src)
		posix.close(write_fd)
		posix.close(read_fd)
	}

	fmt.printfln("  program: %d full run() cycles completed (%d async-Cmd quits with no keypress, %d keypress-driven quits)",
		RACE_PROGRAM_ITERS, (RACE_PROGRAM_ITERS + 1) / 2, RACE_PROGRAM_ITERS / 2)
}

// --- Phase E: Program/run_nbio() ---------------------------------------
//
// Same scenario as Phase D, same Race_Model/race_update/race_view/
// race_async_quit/Race_Key_Feeder, run through rt.run_nbio (loop_nbio.odin)
// instead of rt.run -- this is the ONLY thing this phase changes, so a
// TSan report here versus a clean Phase D would isolate the race to the
// nbio-hosted path specifically (loop_nbio.odin, or the wake hooks added to
// cmd.odin/signals.odin), not to Program/apply/Dispatcher/Signal_Watcher
// generally, which Phase D already covers at the same volume.
//
// Answers 2c from the decision doc empirically, not just by inspection: the
// Dispatcher pool and the Signal_Watcher thread both call the wake hook
// (nbio_wake -> nbio.wake_up) from threads that never acquire an nbio event
// loop of their own, concurrently with the loop thread (this one) ticking,
// reading, and tearing the whole thing down at the end of every iteration --
// exactly the "does nbio's one-loop-per-thread rule fight the pool/watcher"
// question, at volume, under ThreadSanitizer.
phase_program_nbio :: proc() {
	fmt.println("--- phase E: Program/run_nbio() (nbio loop racing async-Cmd wake_up and keypress-driven quits) ---")

	for iter in 0 ..< RACE_PROGRAM_ITERS {
		via_cmd := iter % 2 == 0

		fds: [2]posix.FD
		if posix.pipe(&fds) != .OK {
			fmt.eprintln("pipe failed")
			os.exit(1)
		}
		read_fd, write_fd := fds[0], fds[1]

		feeder := Race_Key_Feeder{w = write_fd, send_q = !via_cmd}
		feeder_th := thread.create_and_start_with_data(&feeder, race_key_feeder_run, init_context = context)

		b := strings.builder_make(); defer strings.builder_destroy(&b)

		p: rt.Program(Race_Model)
		init_cmd := rt.cmd_nil()
		if via_cmd {
			init_cmd = rt.Cmd{procedure = race_async_quit, env = nil, allocator = context.allocator}
		}
		rt.program_init(&p, Race_Model{}, race_update, race_view, init_cmd)

		err := rt.run_nbio(&p, read_fd, &b)
		if err != nil {
			fmt.eprintln("run_nbio() returned an error:", err)
			os.exit(1)
		}

		thread.join(feeder_th); thread.destroy(feeder_th)

		posix.close(write_fd)
		posix.close(read_fd)
	}

	fmt.printfln("  program_nbio: %d full run_nbio() cycles completed (%d async-Cmd quits with no keypress, %d keypress-driven quits)",
		RACE_PROGRAM_ITERS, (RACE_PROGRAM_ITERS + 1) / 2, RACE_PROGRAM_ITERS / 2)
}

// --- Phase F: dispatcher_reap --------------------------------------------
//
// Phases B/D/E already exercise dispatcher_reap indirectly through run()
// (T1's fast-quit fix, cmd.odin/tea.odin) -- this phase targets it directly,
// with a MIX of grace periods and Cmd durations chosen specifically to force
// BOTH of its outcomes under real concurrency: some Cmds finish within the
// grace period (the effectively-synchronous case that avoids the allocator-
// rotation hazard docs/superpowers/cancellation-decision.md describes), and
// some deliberately OUTLIVE it, forcing the true async-detach path where the
// reaper thread keeps running well after dispatcher_reap has already
// returned to its caller and a brand new Reap_Ctx for the NEXT iteration is
// already in flight. That second case is the one that actually matters for
// "no UAF" -- it is the only one where anything survives past the call that
// owns it, and it is exactly what caught the real heap-use-after-free this
// file's grace-period design was built around (see cmd.odin's Grace_Signal
// and the decision doc's account of that bug). Also exercises Cancel_Token:
// a subset of dispatched Cmds poll cancel_requested and race
// dispatcher_reap's own cancel_token_fire.
RD_ITERS :: 150
RD_GRACE :: 5 * time.Millisecond

Rd_Env :: struct {
	sleep:       time.Duration,
	cancel_poll: bool,
	completed:   ^int,   // atomic; owned by phase_dispatcher_reap, NOT by the Reap_Ctx a given Cmd runs under -- must outlive it regardless of when that Cmd's own reaper thread finishes
}

rd_cmd_run :: proc(env: rawptr, cancel: ^rt.Cancel_Token) -> any {
	e := cast(^Rd_Env)env
	if e.cancel_poll {
		waited: time.Duration
		for waited < e.sleep {
			if rt.cancel_requested(cancel) { break }
			time.sleep(200 * time.Microsecond)
			waited += 200 * time.Microsecond
		}
	} else {
		time.sleep(e.sleep)
	}
	sync.atomic_add(e.completed, 1)
	return rt.box(Cmd_Result{id = 0}, context.allocator)
}

phase_dispatcher_reap :: proc() {
	fmt.println("--- phase F: dispatcher_reap (direct, mixed grace outcomes, cancellation) ---")

	completed: int
	for i in 0 ..< RD_ITERS {
		// Heap-owned exactly the way tea.odin's run() does it -- see
		// Reap_Ctx's own doc comment (cmd.odin) for why this must be heap,
		// not a stack local, once dispatcher_reap can hand it to a
		// background thread that may still be running after this loop has
		// moved on to its next iteration (or phase_dispatcher_reap itself
		// has returned).
		rc := new(rt.Reap_Ctx)
		if err := rt.mailbox_init(&rc.mbox, 8); err != nil {
			fmt.eprintln("mailbox_init failed:", err)
			os.exit(1)
		}
		rt.dispatcher_init(&rc.disp, &rc.mbox, 2)

		env: Rd_Env
		switch i % 3 {
		case 0: env = Rd_Env{sleep = 30 * time.Millisecond, completed = &completed}                        // outlives RD_GRACE -- forces async-detach
		case 1: env = Rd_Env{sleep = 20 * time.Millisecond, cancel_poll = true, completed = &completed}    // races cancel_token_fire against the poll loop
		case:   env = Rd_Env{sleep = 0, completed = &completed}                                             // finishes inside RD_GRACE
		}
		rt.dispatch(&rc.disp, rt.cmd_from(rd_cmd_run, env, context.allocator))

		rt.dispatcher_reap(rc, RD_GRACE)
		// Deliberately does NOT touch rc again after this, on any path --
		// matching dispatcher_reap's own documented precondition. Whether
		// this call finished synchronously or detached, the next loop
		// iteration immediately starts a NEW, independent Reap_Ctx/Dispatcher
		// pool concurrently with whatever this one's reaper thread is still
		// doing -- exactly the overlap that stresses allocator/thread
		// lifetime the most.
	}

	// Give any reaper threads that outlived their own iteration's grace
	// period (the i%3==0 and slow i%3==1 cases above) a chance to actually
	// finish and post to `completed` before this phase -- and eventually the
	// whole process -- exits, so TSan's observation window covers them and
	// the printed count below is meaningful rather than a race against
	// process exit.
	time.sleep(500 * time.Millisecond)

	fmt.printfln("  dispatcher_reap: %d/%d Cmds completed (async-detach, cancellation, and in-grace outcomes all exercised)",
		sync.atomic_load(&completed), RD_ITERS)
}

// --- Phase G: Tick/Every timer thread (timer.odin) -----------------------
//
// All-new concurrency phases A-F never touch: timer.odin's dedicated,
// lazily-started nbio timer thread, one per Dispatcher. This phase drives:
//
//   - Several threads dispatching Tick onto the SAME Dispatcher
//     concurrently, stressing timer_service_ensure_started's lazy,
//     mutex-guarded start (exactly one caller must actually spawn the
//     thread) and nbio's own cross-thread timeout registration
//     (docs/superpowers/nbio-decision.md §2b) at volume.
//   - timer_stop racing the timer thread's own fire for a fraction of those
//     Ticks -- both "cancelled before it fires" and "cancelled just as (or
//     after) it fires" must be safe, never a double-release or UAF on
//     Timer_Handle.
//   - A handful of repeating Everys, deliberately NEVER stopped by anything
//     in this phase -- dispatcher_destroy must tear them down on its own.
//   - THE scenario verification item 5 asks for directly: dispatcher_destroy
//     called while those Everys are still actively mid-repeat, over many
//     independent create/destroy cycles (mirroring phase_dispatcher_reap's
//     own shape above), so a race in the timer thread's shutdown ordering
//     (cmd.odin's dispatcher_destroy, timer.odin's timer_service_stop) shows
//     up here under real ThreadSanitizer pressure, not just in a single
//     single-threaded unit test (runetea/timer_test.odin's
//     test_dispatcher_destroy_tears_down_a_pending_every covers the same
//     scenario without TSan, for a fast plain-test signal).
TIMER_ROUNDS         :: 40
TIMER_TICK_PER_ROUND :: 20 // Ticks dispatched concurrently per driver thread, per round
TIMER_EVERY_PER_ROUND :: 6 // repeating Everys alive per round, never explicitly stopped
TIMER_DRIVERS        :: 4

Timer_Result :: struct { n: int }

timer_fire_fn :: proc(env: rawptr, t: time.Tick) -> any {
	e := cast(^int)env
	return rt.box(Timer_Result{n = e^}, context.allocator)
}

Timer_Dispatch_Driver :: struct {
	d:     ^rt.Dispatcher,
	id:    int,
	count: int,
}

timer_dispatch_driver_run :: proc(data: rawptr) {
	dr := cast(^Timer_Dispatch_Driver)data
	for i in 0 ..< dr.count {
		n := dr.id*1_000_000 + i
		cmd, h := rt.tick(time.Duration(1 + i%5) * time.Millisecond, timer_fire_fn, n, context.allocator)
		rt.dispatch(dr.d, cmd)
		if i % 3 == 0 {
			// Race cancellation against the fire itself from a DIFFERENT
			// thread than the timer thread that will (or won't) deliver it
			// -- some win, some lose, both must be safe either way.
			rt.timer_stop(h)
		}
	}
}

Timer_Drainer :: struct {
	m:     ^rt.Mailbox,
	count: ^int, // atomic
}

timer_drainer_run :: proc(data: rawptr) {
	d := cast(^Timer_Drainer)data
	for {
		_, ok := rt.mailbox_recv(d.m)
		if !ok { return }
		sync.atomic_add(d.count, 1)
	}
}

phase_timers :: proc() {
	fmt.println("--- phase G: Tick/Every timer thread (concurrent dispatch, cancellation racing fires, destroy while an Every is pending) ---")

	total_fires := 0
	for round in 0 ..< TIMER_ROUNDS {
		m: rt.Mailbox
		if err := rt.mailbox_init(&m, 256); err != nil {
			fmt.eprintln("mailbox_init failed:", err)
			os.exit(1)
		}

		d: rt.Dispatcher
		rt.dispatcher_init(&d, &m, 2)

		recv_count: int
		drainer_state := Timer_Drainer{m = &m, count = &recv_count}
		drainer := thread.create_and_start_with_data(&drainer_state, timer_drainer_run, init_context = context)

		drivers := make([]Timer_Dispatch_Driver, TIMER_DRIVERS); defer delete(drivers)
		driver_th := make([]^thread.Thread, TIMER_DRIVERS); defer delete(driver_th)
		for i in 0 ..< TIMER_DRIVERS {
			drivers[i] = Timer_Dispatch_Driver{d = &d, id = i, count = TIMER_TICK_PER_ROUND}
			driver_th[i] = thread.create_and_start_with_data(&drivers[i], timer_dispatch_driver_run, init_context = context)
		}

		// Repeating Everys, deliberately never stopped by anything in this
		// phase -- dispatcher_destroy below is what must tear them down.
		for i in 0 ..< TIMER_EVERY_PER_ROUND {
			n := 9_000_000 + round*100 + i
			cmd, _ := rt.every(2 * time.Millisecond, timer_fire_fn, n, context.allocator)
			rt.dispatch(&d, cmd)
		}

		for i in 0 ..< TIMER_DRIVERS { thread.join(driver_th[i]) }
		for i in 0 ..< TIMER_DRIVERS { thread.destroy(driver_th[i]) }

		// Let the Everys above fire for real, several times over, before
		// tearing down -- THE scenario under test: destroy while a
		// repeating Every is genuinely still mid-repeat, not merely just
		// dispatched.
		time.sleep(10 * time.Millisecond)

		// Concurrent with: the drainer thread still draining, the timer
		// thread possibly mid-callback on one of the Everys above, and any
		// still-in-flight cross-thread nbio.timeout registration from the
		// driver threads' last dispatch() calls (already joined above, so
		// none are still running, but their registrations may not have
		// fired yet).
		rt.dispatcher_destroy(&d)

		rt.mailbox_close(&m)
		thread.join(drainer); thread.destroy(drainer)
		rt.mailbox_destroy(&m)

		total_fires += recv_count
	}

	fmt.printfln("  timers: %d create/destroy rounds completed (%d drivers x %d Ticks + %d never-stopped Everys per round), %d total fires drained before each round's teardown",
		TIMER_ROUNDS, TIMER_DRIVERS, TIMER_TICK_PER_ROUND, TIMER_EVERY_PER_ROUND, total_fires)
}

// --- Phase H: batch()/sequence() (runetea/batch.odin) --------------------
//
// All-new concurrency this task's own work adds: a compose Cmd (batch()/
// sequence()) always converts into a SYNTHETIC detached Cmd (batch.odin's
// compose_dispatch), which then runs entirely on its own dedicated OS
// thread and, from there, calls back into dispatch_ex for each of its own
// children -- ordinary Cmds, Tick/Every, or ANOTHER compose Cmd (nesting).
// This phase hammers exactly that machinery at volume, deliberately on a
// pool narrower than the number of concurrent coordinators, with real
// nesting (batch-of-sequence, sequence-of-batch) and a fraction of leaves
// panicking (reusing Cmd_Result/run_cmd_guarded's existing panic-recovery
// proof from phase B, now exercised through the NEW compose_dispatch/
// dispatch_ex `done` Wait_Group path instead of only the plain pool/detached
// paths phase B already covers).
//
// Two sub-phases, matching two DIFFERENT things worth proving under TSan:
//
//   H1 (settled): dispatch every coordinator, then drain the mailbox to the
//   EXACT expected leaf count before tearing down. Non-vacuous exact-count
//   accounting is possible here specifically because nothing races
//   cancellation against the fan-out -- every dispatched leaf is guaranteed
//   to run to completion and deliver exactly one message (normal or
//   Panicked_Msg), so a lost/duplicated/miscounted result under real
//   concurrent nested coordination would show up as a hard count mismatch,
//   not a vague "probably fine".
//
//   H2 (adversarial teardown): dispatch a fresh batch of coordinators and
//   call dispatcher_destroy IMMEDIATELY, with a concurrent drainer racing
//   it -- mirroring phase B's own shape exactly. UNLIKE phase B, this
//   phase's own Cmds (via compose_run_batch/compose_run_sequence) actively
//   check cancel_requested and ABANDON not-yet-dispatched children the
//   instant they notice it -- a genuine, deliberate behavioral difference
//   from a plain Cmd (which only reacts to cancellation if its own body
//   polls for it, per Cancel_Token's own cooperative-only contract). That
//   means the exact leaf count delivered here is NOT deterministic (some
//   coordinators may abandon most or all of their own children before ever
//   dispatching them, exactly as batch-sequence-decision.md documents) --
//   so H2 asserts only what actually matters for teardown safety: bounded
//   return time, no crash, no hang. See batch_test.odin's own
//   test_run_returns_promptly_with_a_nested_batch_and_sequence_both_mid_flight
//   for the same lesson learned directly (an earlier version of THAT test
//   asserted an exact count and hung the whole suite).
BS_POOL_WORKERS :: 3           // deliberately narrow
BS_COORDINATORS :: 40          // multiple of 4; ~13x the pool width
BS_PANIC_EVERY  :: 17

Leaf_Env :: struct { id: int }

leaf_cmd_run :: proc(env: rawptr, cancel: ^rt.Cancel_Token) -> any {
	e := cast(^Leaf_Env)env
	if e.id % BS_PANIC_EVERY == 0 { panic("racecheck: batch/sequence leaf exploded") }
	if e.id % 5 == 0 { time.sleep(500 * time.Microsecond) }
	return rt.box(Cmd_Result{id = e.id}, context.allocator)
}

bs_next_leaf :: proc(next_id: ^int, alloc: mem.Allocator) -> rt.Cmd {
	id := next_id^
	next_id^ += 1
	return rt.cmd_from(leaf_cmd_run, Leaf_Env{id = id}, alloc)
}

// Four shapes, cycled by (coordinator index % 4):
//   0: batch{leaf, leaf, leaf}                        -- 3 leaves, flat
//   1: sequence{leaf, leaf, leaf}                      -- 3 leaves, flat
//   2: batch{leaf, sequence{leaf, leaf}, leaf}          -- 4 leaves, nested sequence-in-batch
//   3: sequence{leaf, batch{leaf, leaf}, leaf}          -- 4 leaves, nested batch-in-sequence
// Every id comes from bs_next_leaf, which hands out a contiguous 0..N-1
// range regardless of shape -- so the FINAL next_id value after building all
// BS_COORDINATORS coordinators is exactly the total leaf count, and the
// exact expected-panic count is computable from it alone (ceil(N / BS_PANIC_EVERY),
// since ids 0..N-1 are all used exactly once each).
bs_make_shape :: proc(shape: int, next_id: ^int, alloc: mem.Allocator) -> rt.Cmd {
	switch shape {
	case 0:
		cmds := make([]rt.Cmd, 3, alloc)
		for i in 0 ..< 3 { cmds[i] = bs_next_leaf(next_id, alloc) }
		c := rt.batch(cmds, alloc)
		delete(cmds, alloc)
		return c
	case 1:
		cmds := make([]rt.Cmd, 3, alloc)
		for i in 0 ..< 3 { cmds[i] = bs_next_leaf(next_id, alloc) }
		c := rt.sequence(cmds, alloc)
		delete(cmds, alloc)
		return c
	case 2:
		inner := make([]rt.Cmd, 2, alloc)
		inner[0] = bs_next_leaf(next_id, alloc)
		inner[1] = bs_next_leaf(next_id, alloc)
		seq := rt.sequence(inner, alloc)
		delete(inner, alloc)

		outer := make([]rt.Cmd, 3, alloc)
		outer[0] = bs_next_leaf(next_id, alloc)
		outer[1] = seq
		outer[2] = bs_next_leaf(next_id, alloc)
		c := rt.batch(outer, alloc)
		delete(outer, alloc)
		return c
	case:
		inner := make([]rt.Cmd, 2, alloc)
		inner[0] = bs_next_leaf(next_id, alloc)
		inner[1] = bs_next_leaf(next_id, alloc)
		bch := rt.batch(inner, alloc)
		delete(inner, alloc)

		outer := make([]rt.Cmd, 3, alloc)
		outer[0] = bs_next_leaf(next_id, alloc)
		outer[1] = bch
		outer[2] = bs_next_leaf(next_id, alloc)
		c := rt.sequence(outer, alloc)
		delete(outer, alloc)
		return c
	}
}

phase_batch_sequence :: proc() {
	fmt.println("--- phase H: batch()/sequence() (nested coordinators outnumbering the pool) ---")
	phase_batch_sequence_settled()
	phase_batch_sequence_teardown()
}

phase_batch_sequence_settled :: proc() {
	fmt.println("  H1: settled (drain to the exact expected leaf count, then destroy) -- exact accounting through nested batch()/sequence() coordination")

	m: rt.Mailbox
	if err := rt.mailbox_init(&m, 512); err != nil {
		fmt.eprintln("mailbox_init failed:", err)
		os.exit(1)
	}

	d: rt.Dispatcher
	rt.dispatcher_init(&d, &m, BS_POOL_WORKERS)

	next_id := 0
	for i in 0 ..< BS_COORDINATORS {
		c := bs_make_shape(i % 4, &next_id, context.allocator)
		rt.dispatch(&d, c)
	}
	expected := next_id

	panic_count := 0
	for i in 0 ..< expected {
		msg, ok := rt.mailbox_recv(&m)
		if !ok {
			fmt.eprintfln("  FAIL: mailbox closed early, got %d/%d leaf results", i, expected)
			os.exit(1)
		}
		if _, is_panic := msg.(rt.Panicked_Msg); is_panic { panic_count += 1 }
	}

	rt.dispatcher_destroy(&d) // should return promptly: every coordinator and every leaf already finished
	rt.mailbox_destroy(&m)

	expected_panics := (expected + BS_PANIC_EVERY - 1) / BS_PANIC_EVERY
	if panic_count != expected_panics {
		fmt.eprintfln("  FAIL: expected %d Panicked_Msg leaf results, got %d", expected_panics, panic_count)
		os.exit(1)
	}

	fmt.printfln("  H1: %d coordinators (batch/sequence, some 2-deep nested), %d pool workers -> %d leaf results received exactly, %d of those panicked (expected %d) -- guarded panics survive the new compose_dispatch/dispatch_ex `done` path",
		BS_COORDINATORS, BS_POOL_WORKERS, expected, panic_count, expected_panics)
}

// See this file's own phase_dispatcher (Phase B) for the identical
// concurrent-drainer-races-destroy shape; Dispatch_Drainer is reused
// verbatim from there.
phase_batch_sequence_teardown :: proc() {
	fmt.println("  H2: adversarial teardown (dispatcher_destroy called immediately after dispatch, concurrent drainer, coordinators + children mid-flight)")

	m: rt.Mailbox
	if err := rt.mailbox_init(&m, 512); err != nil {
		fmt.eprintln("mailbox_init failed:", err)
		os.exit(1)
	}

	recv_count: int
	panic_count: int
	drainer_state := Dispatch_Drainer{m = &m, count = &recv_count, panic_count = &panic_count}
	drainer := thread.create_and_start_with_data(&drainer_state, dispatch_drainer_run, init_context = context)

	d: rt.Dispatcher
	rt.dispatcher_init(&d, &m, BS_POOL_WORKERS)

	next_id := 1_000_000 // cosmetic offset, no collision concern (separate mailbox from H1)
	for i in 0 ..< BS_COORDINATORS {
		c := bs_make_shape(i % 4, &next_id, context.allocator)
		rt.dispatch(&d, c)
	}

	start := time.now()
	rt.dispatcher_destroy(&d)
	elapsed := time.since(start)

	rt.mailbox_close(&m)
	thread.join(drainer); thread.destroy(drainer)

	if elapsed > 2 * time.Second {
		fmt.eprintfln("  FAIL: dispatcher_destroy took %v with batch/sequence coordinators mid-flight -- should be bounded (cancellation propagates to un-started children/steps immediately), not stalling", elapsed)
		os.exit(1)
	}

	fmt.printfln("  H2: dispatcher_destroy returned in %v with coordinators/children mid-flight (%d leaf results delivered before mailbox closed -- not asserted exact: compose's own eager cancellation legitimately abandons some un-started children/steps, see this phase's own doc comment)",
		elapsed, recv_count)
}
