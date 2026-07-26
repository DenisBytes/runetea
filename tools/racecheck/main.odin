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

Cmd_Result :: struct { tag: string, id: int }

Pool_Env :: struct { id: int }

pool_cmd_run :: proc(env: rawptr) -> any {
	e := cast(^Pool_Env)env
	// Stagger completion so a meaningful fraction are still running when the
	// dispatch loop below reaches dispatcher_destroy.
	if e.id % 7 == 0 { time.sleep(time.Millisecond) }
	return rt.box(Cmd_Result{tag = "pool", id = e.id}, context.allocator)
}

Detached_Env :: struct { id: int }

detached_cmd_run :: proc(env: rawptr) -> any {
	e := cast(^Detached_Env)env
	if e.id % 5 == 0 { time.sleep(time.Millisecond) }
	return rt.box(Cmd_Result{tag = "detached", id = e.id}, context.allocator)
}

Dispatch_Drainer :: struct {
	m:     ^rt.Mailbox,
	count: ^int,
}

dispatch_drainer_run :: proc(data: rawptr) {
	d := cast(^Dispatch_Drainer)data
	for {
		_, ok := rt.mailbox_recv(d.m)
		if !ok { return }
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
	drainer_state := Dispatch_Drainer{m = &m, count = &recv_count}
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
	// the SAME mailbox those worker/detached threads are sending into.
	rt.dispatcher_destroy(&d)

	// dispatcher_destroy's return is the proof that no producer can still
	// be touching the mailbox -- safe to close now to unblock the drainer.
	rt.mailbox_close(&m)
	thread.join(drainer); thread.destroy(drainer)

	fmt.printfln("  dispatcher: %d results drained (dispatched %d pool + %d detached)",
		recv_count, DP_POOL_CMDS, DP_DETACHED_CMDS)

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

race_async_quit :: proc(env: rawptr) -> any {
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
