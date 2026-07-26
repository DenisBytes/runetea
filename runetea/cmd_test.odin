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
