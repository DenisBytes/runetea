package runetea

import "core:mem"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"

Tick_Result :: struct { t: time.Tick }

tick_result_fn :: proc(env: rawptr, t: time.Tick) -> any {
	return box(Tick_Result{t = t}, context.allocator)
}

@(test)
test_tick_fires_once_after_duration :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 8), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)
	defer dispatcher_destroy(&d)

	start := time.tick_now()
	cmd := tick(30 * time.Millisecond, tick_result_fn, struct{}{}, context.allocator)
	testing.expect(t, !cmd_is_nil(cmd), "a Cmd from tick() must not report as nil -- apply()/run() gate dispatch() on this")
	dispatch(&d, cmd)

	msg, ok := mailbox_recv(&m)
	defer box_free(msg, context.allocator)
	testing.expect(t, ok, "expected the tick to fire")
	elapsed := time.tick_diff(start, time.tick_now())
	testing.expectf(t, elapsed >= 25 * time.Millisecond, "tick fired too early: %v", elapsed)
	_, is := msg.(Tick_Result)
	testing.expect(t, is, "expected a Tick_Result")

	// No timer_stop, and nothing to clean up: a plain tick() hands out no
	// handle at all, so the fire above already released the subsystem's only
	// reference and freed both the handle and the cloned fn env.
}

@(test)
test_every_fires_repeatedly_without_reissue :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)
	defer dispatcher_destroy(&d)

	cmd, h := every(20 * time.Millisecond, tick_result_fn, struct{}{}, context.allocator)
	dispatch(&d, cmd)

	// Three fires, with NO reissue from any update()-equivalent -- the
	// defining divergence from Bubble Tea's own Every (commands.go), which
	// only ever fires once per Cmd. See timer.odin's own doc comment on
	// every().
	for i in 0 ..< 3 {
		msg, ok := mailbox_recv(&m)
		defer box_free(msg, context.allocator) // per-iteration: Odin scopes defer to the loop BODY
		testing.expect(t, ok, "expected a repeated fire")
		_, is := msg.(Tick_Result)
		testing.expect(t, is, "expected a Tick_Result")
	}

	timer_stop(h)
}

@(test)
test_timer_stop_cancels_a_pending_tick :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 8), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)
	defer dispatcher_destroy(&d)

	cmd, h := tick_cancellable(20 * time.Millisecond, tick_result_fn, struct{}{}, context.allocator)
	dispatch(&d, cmd)
	timer_stop(h) // cancel well before the 20ms fire

	// Give the would-be fire time to have happened if cancellation didn't
	// take -- then prove nothing arrived.
	time.sleep(60 * time.Millisecond)
	ok := try_recv_and_free(&m)
	testing.expect(t, !ok, "a cancelled Tick must not deliver its message")
}

@(test)
test_timer_stop_stops_a_repeating_every :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)
	defer dispatcher_destroy(&d)

	cmd, h := every(15 * time.Millisecond, tick_result_fn, struct{}{}, context.allocator)
	dispatch(&d, cmd)

	ok := recv_and_free(&m)
	testing.expect(t, ok, "expected at least one fire before stopping")

	timer_stop(h)

	// Drain whatever was already in flight the instant timer_stop ran (an
	// Every can legitimately have one more fire already scheduled/racing
	// cancellation), then assert silence for a window comfortably longer
	// than the interval.
	drain_deadline := time.tick_add(time.tick_now(), 50 * time.Millisecond)
	for time.tick_diff(time.tick_now(), drain_deadline) > 0 {
		try_recv_and_free(&m)
	}

	got_after_stop := false
	settle_deadline := time.tick_add(time.tick_now(), 60 * time.Millisecond)
	for time.tick_diff(time.tick_now(), settle_deadline) > 0 {
		if try_recv_and_free(&m) { got_after_stop = true }
	}
	testing.expect(t, !got_after_stop, "no fire should arrive once the drain window has passed timer_stop")
}

// The teardown-safety case verification item 5 asks for directly: quit
// (dispatcher_destroy) while a repeating Every is still pending. Must not
// hang and must not touch the Mailbox/Dispatcher after they're gone --
// ./tools/test.sh race (tools/racecheck's own timer phase) is what actually
// proves the second half under ThreadSanitizer; this proves the first
// (bounded, synchronous return) under plain `odin test`.
@(test)
test_dispatcher_destroy_tears_down_a_pending_every :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)

	cmd, h := every(5 * time.Millisecond, tick_result_fn, struct{}{}, context.allocator)
	dispatch(&d, cmd)

	// Let it fire at least once so the timer thread is definitely up and
	// the Every is definitely mid-repeat, then tear down immediately --
	// deliberately NOT calling timer_stop first, and deliberately not
	// draining the mailbox: the point is to destroy while it is still live.
	ok := recv_and_free(&m)
	testing.expect(t, ok, "expected at least one fire before destroying")

	start := time.tick_now()
	dispatcher_destroy(&d)
	elapsed := time.tick_diff(start, time.tick_now())
	testing.expectf(t, elapsed < 2 * time.Second, "dispatcher_destroy should return promptly, not hang -- took %v", elapsed)

	// AFTER the destroy, never before -- the whole point of this test is that
	// the teardown happens with the Every still live. every()'s handle still
	// has to be released though (every() is refs = 2 and timer_stop is the
	// only thing that ever releases the caller's half), and doing it here
	// rather than skipping it is what proves the destroy path leaves the
	// handle in a state where a late timer_stop is still correct and safe.
	timer_stop(h)

	// Only safe now that dispatcher_destroy has proven the timer thread
	// (and pool, and every detached Cmd) is joined -- same precondition
	// mailbox_destroy already documents for every other producer.
	mailbox_destroy(&m)
}

// Integration: Tick driven through the full Program/run() stack (tea.odin),
// not just Dispatcher directly -- proves the Cmd produced by tick() survives
// apply()'s own `if !cmd_is_nil(cmd)` gate (cmd_is_nil must NOT report a
// timer Cmd as nil, or run()/apply() would silently never dispatch it) and
// that its result reaches update() like any other Msg.
Spin_Model :: struct { fires: int, quit_after: int }

Spin_Tick_Msg :: struct { n: int }

Spin_Env :: struct { n: int }

spin_tick_fn :: proc(env: rawptr, tk: time.Tick) -> any {
	e := cast(^Spin_Env)env
	return box(Spin_Tick_Msg{n = e.n}, context.allocator)
}

spin_update :: proc(m: ^Spin_Model, msg: any, alloc: mem.Allocator) -> Cmd {
	if v, is := msg.(Spin_Tick_Msg); is {
		m.fires += 1
		if m.fires >= m.quit_after { return quit_cmd() }
		return tick(5 * time.Millisecond, spin_tick_fn, Spin_Env{n = v.n + 1}, context.allocator)
	}
	return cmd_nil()
}

spin_view :: proc(m: Spin_Model, alloc: mem.Allocator) -> string {
	return "spinning"
}

@(test)
test_tick_drives_a_program_through_run :: proc(t: ^testing.T) {
	// An open pipe with nothing ever written, NOT input_source_from_bytes(""):
	// a Bytes_Source hits synthetic EOF (and closes the Mailbox) the instant
	// it's read, which can race ahead of the Tick this test needs to
	// actually observe -- see test_program_quits_from_an_async_init_cmd_with_
	// no_keypress's own comment above for the identical gotcha, hit first
	// there.
	fds: [2]posix.FD
	testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
	read_fd, write_fd := fds[0], fds[1]
	defer posix.close(write_fd)
	defer posix.close(read_fd)

	src, ok := input_source_from_fd(read_fd)
	testing.expect(t, ok, "input_source_from_fd should succeed")
	defer input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Spin_Model)
	init_cmd := tick(5 * time.Millisecond, spin_tick_fn, Spin_Env{n = 0}, context.allocator)
	program_init(&p, Spin_Model{quit_after = 4}, spin_update, spin_view, init_cmd)

	err := run(&p, &src, &b)
	testing.expect(t, err == nil, "run should exit cleanly")
	testing.expect_value(t, p.model.fires, 4)
}

// Counts allocations still outstanding in `track` that timer.odin itself made
// -- i.e. the two things timer_new allocates per Tick/Every: the cloned fn env
// and the Timer_Handle. Filtering by file rather than asserting
// len(allocation_map) == 0 is deliberate: the SAME tracking allocator also
// legitimately holds dispatcher_reap's one documented, bounded ^Thread leak
// (cmd.odin's own WHY self_cleanup = false comment), which this test is not
// about and must not be made to fail on.
@(private = "file")
timer_leak_count :: proc(track: ^mem.Tracking_Allocator) -> int {
	n := 0
	for _, entry in track.allocation_map {
		if strings.contains(entry.location.file_path, "timer.odin") { n += 1 }
	}
	return n
}

// Drives a Spin_Model program to `ticks` fires with EVERY allocation in the
// whole session (run()'s own, the reader thread's, the timer thread's, and
// every tick()'s) routed through a private Tracking_Allocator, and reports how
// much timer.odin state survived the session.
@(private = "file")
tick_program_timer_leaks :: proc(t: ^testing.T, ticks: int) -> int {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	{
		// Scoped, not restored by hand: every thread run() spawns inherits
		// this context (init_context = context, see cmd.odin/tea.odin), so
		// the timer thread's own `free(h, context.allocator)` resolves to
		// THIS allocator too -- which is the whole point. Leaving the block
		// restores the outer context automatically.
		context.allocator = mem.tracking_allocator(&track)

		// Open pipe, not input_source_from_bytes("") -- see
		// test_tick_drives_a_program_through_run's own comment.
		fds: [2]posix.FD
		testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
		read_fd, write_fd := fds[0], fds[1]
		defer posix.close(write_fd)
		defer posix.close(read_fd)

		src, ok := input_source_from_fd(read_fd)
		testing.expect(t, ok, "input_source_from_fd should succeed")
		defer input_close(&src)

		b := strings.builder_make(); defer strings.builder_destroy(&b)

		p: Program(Spin_Model)
		init_cmd := tick(2 * time.Millisecond, spin_tick_fn, Spin_Env{n = 0}, context.allocator)
		program_init(&p, Spin_Model{quit_after = ticks}, spin_update, spin_view, init_cmd)

		err := run(&p, &src, &b)
		testing.expect(t, err == nil, "run should exit cleanly")
		testing.expect_value(t, p.model.fires, ticks)
	}

	// run() deliberately does NOT block on teardown: dispatcher_reap hands
	// dispatcher_destroy (which is what joins the timer thread) to a
	// background reaper thread bounded by QUIT_GRACE = 100ms (tea.odin). Wait
	// past that bound before reading the map, or this could sample it while
	// the timer thread is still releasing handles and report a leak that
	// isn't one.
	time.sleep(250 * time.Millisecond)
	return timer_leak_count(&track)
}

// REGRESSION GATE for the leak this whole subsystem shipped with: a Tick used
// EXACTLY the way tick()'s own doc comment prescribes -- reissued from
// update() on every fire, Go's documented pattern -- must accumulate nothing.
//
// Two tick counts, not one, and that is the load-bearing part: the leak this
// gates was LINEAR in fire count (one Timer_Handle + one fn env per fire), so
// a partial fix that leaks a constant amount -- only the first tick, only the
// one still pending at quit -- would sail through a single-count assertion.
// Asserting the same zero at 4 and at 12 leaves no constant to hide in.
@(test)
test_repeated_ticks_through_run_leak_no_timer_state :: proc(t: ^testing.T) {
	leaked_4  := tick_program_timer_leaks(t, 4)
	leaked_12 := tick_program_timer_leaks(t, 12)
	testing.expectf(t, leaked_4  == 0, "4 ticks left %d timer.odin allocation(s) outstanding; expected 0", leaked_4)
	testing.expectf(t, leaked_12 == 0, "12 ticks left %d timer.odin allocation(s) outstanding; expected 0", leaked_12)
}

// Same integration, but for Every -- a single dispatch drives every quit-
// triggering fire on its own, with update() never reissuing anything.
Every_Model :: struct { fires: int }

every_tick_fn :: proc(env: rawptr, tk: time.Tick) -> any {
	return box(Spin_Tick_Msg{}, context.allocator)
}

every_update :: proc(m: ^Every_Model, msg: any, alloc: mem.Allocator) -> Cmd {
	if _, is := msg.(Spin_Tick_Msg); is {
		m.fires += 1
		if m.fires >= 3 { return quit_cmd() }
	}
	return cmd_nil()
}

every_view :: proc(m: Every_Model, alloc: mem.Allocator) -> string {
	return "spinning"
}

@(test)
test_every_drives_a_program_through_run_without_reissue :: proc(t: ^testing.T) {
	// See test_tick_drives_a_program_through_run's own comment on why an
	// open pipe, not input_source_from_bytes(""), is required here.
	fds: [2]posix.FD
	testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
	read_fd, write_fd := fds[0], fds[1]
	defer posix.close(write_fd)
	defer posix.close(read_fd)

	src, ok := input_source_from_fd(read_fd)
	testing.expect(t, ok, "input_source_from_fd should succeed")
	defer input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Every_Model)
	init_cmd, h := every(5 * time.Millisecond, every_tick_fn, struct{}{}, context.allocator)
	defer timer_stop(h) // every() is refs = 2; nothing but timer_stop ever releases the caller's half, quitting the Program included
	program_init(&p, Every_Model{}, every_update, every_view, init_cmd)

	err := run(&p, &src, &b)
	testing.expect(t, err == nil, "run should exit cleanly")
	testing.expect_value(t, p.model.fires, 3)
}

@(test)
test_timer_handle_refcount_survives_stop_and_natural_completion_in_any_order :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 8), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)
	defer dispatcher_destroy(&d)

	// Order 1: stop AFTER the natural fire has already released the
	// subsystem's own reference.
	cmd1, h1 := tick_cancellable(5 * time.Millisecond, tick_result_fn, struct{}{}, context.allocator)
	dispatch(&d, cmd1)
	ok1 := recv_and_free(&m)
	testing.expect(t, ok1, "expected the tick to fire")
	timer_stop(h1) // must not double-free or crash even though the subsystem already released

	// Order 2: stop BEFORE the timer would have fired.
	cmd2, h2 := tick_cancellable(50 * time.Millisecond, tick_result_fn, struct{}{}, context.allocator)
	dispatch(&d, cmd2)
	timer_stop(h2)
	time.sleep(70 * time.Millisecond) // let the subsystem's own release happen too, if cancellation didn't suppress the fire outright
}

@(test)
test_two_dispatchers_each_get_their_own_timer_thread :: proc(t: ^testing.T) {
	// Guards against a design that accidentally shares timer state across
	// Dispatchers (e.g. a package-level global instead of a per-Dispatcher
	// Timer_Service) -- two independent sessions must not interfere.
	m1, m2: Mailbox
	testing.expect_value(t, mailbox_init(&m1, 8), nil)
	testing.expect_value(t, mailbox_init(&m2, 8), nil)
	defer mailbox_destroy(&m1)
	defer mailbox_destroy(&m2)

	d1, d2: Dispatcher
	dispatcher_init(&d1, &m1, 1)
	dispatcher_init(&d2, &m2, 1)
	defer dispatcher_destroy(&d1)
	defer dispatcher_destroy(&d2)

	c1 := tick(10 * time.Millisecond, tick_result_fn, struct{}{}, context.allocator)
	c2 := tick(10 * time.Millisecond, tick_result_fn, struct{}{}, context.allocator)
	dispatch(&d1, c1)
	dispatch(&d2, c2)

	ok1 := recv_and_free(&m1)
	ok2 := recv_and_free(&m2)
	testing.expect(t, ok1, "d1's tick should fire on d1's own mailbox")
	testing.expect(t, ok2, "d2's tick should fire on d2's own mailbox")
}

// ============================================================================
// BUG 2: a timer subsystem that fails to start used to fail SILENTLY.
//
// timer_dispatch released the handle and returned. Every subsequent tick/every
// on that Dispatcher then never fired, forever, with no diagnostic of any kind
// -- an app's spinner simply stopped, an app's poll simply stopped, and nothing
// anywhere said why. It is now a Timer_Unavailable_Msg through the Mailbox,
// the same shape cmd.odin's Panicked_Msg uses.
//
// The failure is forced through g_timer_force_start_failure -- see
// timer_thread_body for why a runtime hook rather than a compile-time define
// (a compile-time one would put this path outside the default test gate, which
// is exactly where the bug survived).
// ============================================================================

@(private = "file")
recv_within :: proc(m: ^Mailbox, d: time.Duration) -> (msg: any, ok: bool) {
	deadline := time.tick_add(time.tick_now(), d)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if msg, ok = mailbox_try_recv(m); ok { return }
		time.sleep(time.Millisecond)
	}
	return nil, false
}

@(test)
test_timer_start_failure_is_reported_through_the_mailbox :: proc(t: ^testing.T) {
	sync.atomic_store(&g_timer_force_start_failure, true)
	defer sync.atomic_store(&g_timer_force_start_failure, false)

	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 8), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)
	defer dispatcher_destroy(&d)

	dispatch(&d, tick(time.Millisecond, tick_result_fn, struct{}{}, context.allocator))

	msg, ok := recv_within(&m, time.Second)
	defer box_free(msg, context.allocator)
	if !testing.expect(t, ok, "a timer subsystem that cannot start must say so, not go quiet") { return }

	tu, is := msg.(Timer_Unavailable_Msg)
	if !testing.expectf(t, is, "expected a Timer_Unavailable_Msg, got %v", msg) { return }
	testing.expect(t, tu.reason.len > 0, "the message must carry a reason, not an empty one")
	// A Tick_Result must NEVER arrive on a Dispatcher whose timer thread died:
	// the point of the message is that this timer can never fire.
	extra, more := recv_within(&m, 50 * time.Millisecond)
	defer box_free(extra, context.allocator)
	testing.expect(t, !more, "nothing else may arrive -- the timer cannot fire")
}

// ONCE PER DISPATCHER, NOT ONCE PER FAILED DISPATCH. An animation re-dispatches
// on a cadence and the Mailbox's back-pressure policy is retry-forever, so a
// per-dispatch report would let a broken timer subsystem saturate the Mailbox
// and stall the application it was trying to warn. See
// timer_report_unavailable's own comment for the full argument.
@(test)
test_timer_start_failure_is_reported_once_per_dispatcher :: proc(t: ^testing.T) {
	sync.atomic_store(&g_timer_force_start_failure, true)
	defer sync.atomic_store(&g_timer_force_start_failure, false)

	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 8), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)
	defer dispatcher_destroy(&d)

	for _ in 0 ..< 5 {
		dispatch(&d, tick(time.Millisecond, tick_result_fn, struct{}{}, context.allocator))
	}

	msg, ok := recv_within(&m, time.Second)
	defer box_free(msg, context.allocator)
	testing.expect(t, ok, "the first failed dispatch must report")
	_, is := msg.(Timer_Unavailable_Msg)
	testing.expect(t, is, "expected a Timer_Unavailable_Msg")

	extra, more := recv_within(&m, 100 * time.Millisecond)
	defer box_free(extra, context.allocator)
	testing.expectf(t, !more, "five failed dispatches produced more than one message: %v", extra)
}

// ORDINARY SHUTDOWN IS NOT A FAILURE. timer_service_ensure_started also returns
// nil once the Dispatcher has been torn down, and reporting THAT would turn
// every quit-with-a-timer-in-flight into a spurious diagnostic. start_failed is
// what tells the two apart.
@(test)
test_dispatching_a_timer_after_teardown_reports_nothing :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 8), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)
	dispatcher_destroy(&d)

	dispatch(&d, tick(time.Millisecond, tick_result_fn, struct{}{}, context.allocator))
	msg, ok := recv_within(&m, 100 * time.Millisecond)
	defer box_free(msg, context.allocator)
	testing.expectf(t, !ok, "a torn-down Dispatcher must stay quiet, got %v", msg)
}

// box() panics on a non-POD Msg at RUNTIME, not compile time
// (docs/LIMITATIONS.md 2.2), so every Msg type this package defines owes a test
// that boxes it once. This is that test for Timer_Unavailable_Msg.
@(test)
test_timer_unavailable_msg_is_pod :: proc(t: ^testing.T) {
	msg := box(Timer_Unavailable_Msg{reason = msg_text_from("nbio: out of file descriptors")}, context.allocator)
	defer box_free(msg, context.allocator)
	tu, is := msg.(Timer_Unavailable_Msg)
	testing.expect(t, is, "Timer_Unavailable_Msg must survive a box/unbox round trip")
	testing.expect_value(t, msg_text_string(&tu.reason), "nbio: out of file descriptors")
}
