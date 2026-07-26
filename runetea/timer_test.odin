package runetea

import "core:mem"
import "core:strings"
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
	cmd, h := tick(30 * time.Millisecond, tick_result_fn, struct{}{}, context.allocator)
	testing.expect(t, !cmd_is_nil(cmd), "a Cmd from tick() must not report as nil -- apply()/run() gate dispatch() on this")
	dispatch(&d, cmd)

	msg, ok := mailbox_recv(&m)
	testing.expect(t, ok, "expected the tick to fire")
	elapsed := time.tick_diff(start, time.tick_now())
	testing.expectf(t, elapsed >= 25 * time.Millisecond, "tick fired too early: %v", elapsed)
	_, is := msg.(Tick_Result)
	testing.expect(t, is, "expected a Tick_Result")

	timer_stop(h) // released purely to avoid a leak report; the timer already fired and released its own side
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

	cmd, h := tick(20 * time.Millisecond, tick_result_fn, struct{}{}, context.allocator)
	dispatch(&d, cmd)
	timer_stop(h) // cancel well before the 20ms fire

	// Give the would-be fire time to have happened if cancellation didn't
	// take -- then prove nothing arrived.
	time.sleep(60 * time.Millisecond)
	_, ok := mailbox_try_recv(&m)
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

	_, ok := mailbox_recv(&m)
	testing.expect(t, ok, "expected at least one fire before stopping")

	timer_stop(h)

	// Drain whatever was already in flight the instant timer_stop ran (an
	// Every can legitimately have one more fire already scheduled/racing
	// cancellation), then assert silence for a window comfortably longer
	// than the interval.
	drain_deadline := time.tick_add(time.tick_now(), 50 * time.Millisecond)
	for time.tick_diff(time.tick_now(), drain_deadline) > 0 {
		mailbox_try_recv(&m)
	}

	got_after_stop := false
	settle_deadline := time.tick_add(time.tick_now(), 60 * time.Millisecond)
	for time.tick_diff(time.tick_now(), settle_deadline) > 0 {
		if _, ok := mailbox_try_recv(&m); ok { got_after_stop = true }
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

	cmd, _ := every(5 * time.Millisecond, tick_result_fn, struct{}{}, context.allocator)
	dispatch(&d, cmd)

	// Let it fire at least once so the timer thread is definitely up and
	// the Every is definitely mid-repeat, then tear down immediately --
	// deliberately NOT calling timer_stop first, and deliberately not
	// draining the mailbox: the point is to destroy while it is still live.
	_, ok := mailbox_recv(&m)
	testing.expect(t, ok, "expected at least one fire before destroying")

	start := time.tick_now()
	dispatcher_destroy(&d)
	elapsed := time.tick_diff(start, time.tick_now())
	testing.expectf(t, elapsed < 2 * time.Second, "dispatcher_destroy should return promptly, not hang -- took %v", elapsed)

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

spin_update :: proc(m: Spin_Model, msg: any, alloc: mem.Allocator) -> (Spin_Model, Cmd) {
	m := m
	if v, is := msg.(Spin_Tick_Msg); is {
		m.fires += 1
		if m.fires >= m.quit_after { return m, quit_cmd() }
		c, _ := tick(5 * time.Millisecond, spin_tick_fn, Spin_Env{n = v.n + 1}, context.allocator)
		return m, c
	}
	return m, cmd_nil()
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
	init_cmd, _ := tick(5 * time.Millisecond, spin_tick_fn, Spin_Env{n = 0}, context.allocator)
	program_init(&p, Spin_Model{quit_after = 4}, spin_update, spin_view, init_cmd)

	err := run(&p, &src, &b)
	testing.expect(t, err == nil, "run should exit cleanly")
	testing.expect_value(t, p.model.fires, 4)
}

// Same integration, but for Every -- a single dispatch drives every quit-
// triggering fire on its own, with update() never reissuing anything.
Every_Model :: struct { fires: int }

every_tick_fn :: proc(env: rawptr, tk: time.Tick) -> any {
	return box(Spin_Tick_Msg{}, context.allocator)
}

every_update :: proc(m: Every_Model, msg: any, alloc: mem.Allocator) -> (Every_Model, Cmd) {
	m := m
	if _, is := msg.(Spin_Tick_Msg); is {
		m.fires += 1
		if m.fires >= 3 { return m, quit_cmd() }
	}
	return m, cmd_nil()
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
	init_cmd, _ := every(5 * time.Millisecond, every_tick_fn, struct{}{}, context.allocator)
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
	cmd1, h1 := tick(5 * time.Millisecond, tick_result_fn, struct{}{}, context.allocator)
	dispatch(&d, cmd1)
	_, ok1 := mailbox_recv(&m)
	testing.expect(t, ok1, "expected the tick to fire")
	timer_stop(h1) // must not double-free or crash even though the subsystem already released

	// Order 2: stop BEFORE the timer would have fired.
	cmd2, h2 := tick(50 * time.Millisecond, tick_result_fn, struct{}{}, context.allocator)
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

	c1, h1 := tick(10 * time.Millisecond, tick_result_fn, struct{}{}, context.allocator)
	c2, h2 := tick(10 * time.Millisecond, tick_result_fn, struct{}{}, context.allocator)
	dispatch(&d1, c1)
	dispatch(&d2, c2)

	_, ok1 := mailbox_recv(&m1)
	_, ok2 := mailbox_recv(&m2)
	timer_stop(h1)
	timer_stop(h2)
	testing.expect(t, ok1, "d1's tick should fire on d1's own mailbox")
	testing.expect(t, ok2, "d2's tick should fire on d2's own mailbox")
}
