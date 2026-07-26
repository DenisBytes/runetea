package runetea

import "core:testing"
import "core:time"

Fetch_Env    :: struct { url: string, delay: time.Duration }
Fetch_Result :: struct { url: string, status: int }

fetch_run :: proc(env: rawptr) -> any {
	e := cast(^Fetch_Env)env
	time.sleep(e.delay)
	return box(Fetch_Result{url = e.url, status = 200}, context.allocator)
}

@(test)
test_cmd_carries_env_without_closures :: proc(t: ^testing.T) {
	c := cmd_from(fetch_run, Fetch_Env{url = "https://example.com", delay = 0}, context.allocator)
	testing.expect(t, !cmd_is_nil(c), "cmd should be populated")

	msg := c.procedure(c.env)
	r, ok := msg.(Fetch_Result)
	testing.expect(t, ok, "expected a Fetch_Result")
	testing.expect_value(t, r.url, "https://example.com")
	testing.expect_value(t, r.status, 200)
	free(c.env, c.allocator)
	free_all(context.allocator)
}

@(test)
test_dispatch_delivers_results_to_mailbox :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 64), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 4)
	defer dispatcher_destroy(&d)

	urls := []string{"a", "b", "c", "d", "e"}
	for u in urls {
		dispatch(&d, cmd_from(fetch_run, Fetch_Env{url = u}, context.allocator))
	}

	seen := make(map[string]bool); defer delete(seen)
	for _ in 0 ..< len(urls) {
		msg, ok := mailbox_recv(&m)
		testing.expect(t, ok, "expected a result")
		if r, is := msg.(Fetch_Result); is { seen[r.url] = true }
	}
	testing.expect_value(t, len(seen), len(urls))
}

@(test)
test_cmd_nil_is_detectable :: proc(t: ^testing.T) {
	testing.expect(t, cmd_is_nil(cmd_nil()), "cmd_nil must be reported as nil")
}

// Regression: box() of a ZERO-SIZED Msg (Quit_Msg is exactly `struct {}`)
// returns an `any` whose `data` field is nil -- new() legitimately returns a
// nil pointer for a zero-size allocation -- and Odin's `any == nil` compares
// by `data` alone, ignoring `id`. A naive `if msg != nil` gate before
// mailbox_send (as run_cmd_task/run_cmd_detached originally had) therefore
// silently drops every zero-sized result. Caught live: an init Cmd
// returning Quit_Msg through run() hung forever on mailbox_recv, because
// quit_cmd()'s own Quit_Msg never reached the mailbox through this exact
// path. Both dispatch paths (pool and detached) share the bug, so both are
// pinned here.
Empty_Result :: struct {}

empty_run :: proc(env: rawptr) -> any {
	return box(Empty_Result{}, context.allocator)
}

@(test)
test_dispatch_delivers_a_zero_sized_result_pool :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 8), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)
	defer dispatcher_destroy(&d)

	dispatch(&d, cmd_from(empty_run, struct{}{}, context.allocator))

	msg, ok := mailbox_recv(&m)
	testing.expect(t, ok, "expected the zero-sized result to reach the mailbox")
	_, is := msg.(Empty_Result)
	testing.expect(t, is, "zero-sized Msg types must not be silently dropped")
}

@(test)
test_dispatch_delivers_a_zero_sized_result_detached :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 8), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)
	defer dispatcher_destroy(&d)

	dispatch(&d, cmd_from(empty_run, struct{}{}, context.allocator, detached = true))

	msg, ok := mailbox_recv(&m)
	testing.expect(t, ok, "expected the zero-sized result to reach the mailbox")
	_, is := msg.(Empty_Result)
	testing.expect(t, is, "zero-sized Msg types must not be silently dropped")
}

// A coordinator Cmd waits on children it dispatches. On a fixed pool sized N,
// N such coordinators occupy every worker and their children never get one --
// deadlock. Detached Cmds bypass the pool, which is the elastic-overflow path.
// This test pins that: more coordinators than workers must still complete.
Coord_Env :: struct { d: ^Dispatcher, inner: ^Mailbox }

coord_run :: proc(env: rawptr) -> any {
	e := cast(^Coord_Env)env
	// A child unit of work, run inline here to keep the test deterministic;
	// the point under test is that the coordinator itself is not pool-bound.
	return box(Fetch_Result{url = "coord", status = 1}, context.allocator)
}

@(test)
test_detached_cmds_exceed_pool_width_without_deadlock :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 64), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)      // deliberately narrower than the load
	defer dispatcher_destroy(&d)

	COORDS :: 8                      // 4x the pool width
	for _ in 0 ..< COORDS {
		dispatch(&d, cmd_from(coord_run, Coord_Env{d = &d, inner = &m}, context.allocator, detached = true))
	}

	got := 0
	for _ in 0 ..< COORDS {
		msg, ok := mailbox_recv(&m)
		if !ok { break }
		if _, is := msg.(Fetch_Result); is { got += 1 }
	}
	testing.expect_value(t, got, COORDS)
}

// dispatcher_destroy must block until every detached Cmd it ever dispatched
// has actually finished, not just until the pool workers are joined --
// thread.Pool's join (thread.pool_finish/pool_destroy) says nothing about a
// detached Cmd's self_cleanup thread, which is tracked nowhere else. If
// dispatcher_destroy returned early, a caller's very next line -- typically
// mailbox_destroy, per mailbox.odin's own documented precondition -- would
// free the mailbox out from under a detached Cmd still mid mailbox_send.
//
// Deliberately does NOT drain the mailbox first. test_detached_cmds_exceed_
// pool_width_without_deadlock above proves the elastic-overflow path doesn't
// deadlock, but it drains every result before its deferred destroys run --
// and since mailbox_send always completes before its message becomes
// receivable, having received every message already proves every send has
// happened. That ordering makes it structurally incapable of telling "destroy
// waited" apart from "destroy returned immediately but got lucky", so it
// can't catch this. This test dispatches one slow detached Cmd, calls
// dispatcher_destroy immediately without receiving anything, and times it:
// against the unfixed code dispatcher_destroy returns near-instantly (it
// only waits on the pool) and the elapsed-time assertion below fails
// deterministically, well before the still-running Cmd's later mailbox_send
// would hit the meanwhile-destroyed mailbox.
Slow_Env :: struct {}

slow_run :: proc(env: rawptr) -> any {
	time.sleep(150 * time.Millisecond)
	return box(Fetch_Result{url = "slow", status = 2}, context.allocator)
}

@(test)
test_dispatcher_destroy_waits_for_detached_cmds :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 8), nil)

	d: Dispatcher
	dispatcher_init(&d, &m, 1)

	dispatch(&d, cmd_from(slow_run, Slow_Env{}, context.allocator, detached = true))

	start := time.now()
	dispatcher_destroy(&d)
	elapsed := time.since(start)
	testing.expect(t, elapsed >= 100 * time.Millisecond,
		"dispatcher_destroy returned before its detached Cmd finished")

	// Only safe to reach here, after dispatcher_destroy has proven no
	// detached Cmd can still be touching the mailbox.
	mailbox_destroy(&m)
}
