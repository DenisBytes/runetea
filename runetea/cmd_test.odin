package runetea

import "core:sync"
import "core:testing"
import "core:time"

// Fetch_Env is Cmd env, not a Msg -- it is never passed to box() (cmd_from
// heap-clones it directly and cmd.odin frees it as one opaque block once the
// Cmd finishes), so it is exempt from box()'s POD requirement and may keep
// a bare `string` field.
Fetch_Env :: struct { url: string, delay: time.Duration }

// Fetch_Result IS a Msg (returned through box() below), so its `url` field
// must be POD -- see arena.odin's MESSAGE OWNERSHIP CONTRACT. Msg_Text, not
// string.
Fetch_Result :: struct { url: Msg_Text, status: int }

fetch_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	e := cast(^Fetch_Env)env
	time.sleep(e.delay)
	return box(Fetch_Result{url = msg_text_from(e.url), status = 200}, context.allocator)
}

@(test)
test_cmd_carries_env_without_closures :: proc(t: ^testing.T) {
	c := cmd_from(fetch_run, Fetch_Env{url = "https://example.com", delay = 0}, context.allocator)
	testing.expect(t, !cmd_is_nil(c), "cmd should be populated")

	msg := c.procedure(c.env, nil)
	r, ok := msg.(Fetch_Result)
	testing.expect(t, ok, "expected a Fetch_Result")
	url := r.url
	testing.expect_value(t, msg_text_string(&url), "https://example.com")
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
		defer box_free(msg, context.allocator) // per-iteration: Odin scopes defer to the loop BODY, not the whole proc
		testing.expect(t, ok, "expected a result")
		if r, is := msg.(Fetch_Result); is { u := r.url; seen[msg_text_string(&u)] = true }
	}
	testing.expect_value(t, len(seen), len(urls))
}

@(test)
test_cmd_nil_is_detectable :: proc(t: ^testing.T) {
	testing.expect(t, cmd_is_nil(cmd_nil()), "cmd_nil must be reported as nil")
}

// T1 extension (docs/superpowers/tier1-coverage-decision.md): Cmd bodies were
// the other unguarded user-code call site spike-findings.md §4/addendum item
// 7 flagged, alongside View. run_cmd_guarded (cmd.odin) is what closes it --
// these two tests pin BOTH thread classes it runs on (pool below, detached
// further down), since guard.odin's thread_local state means each needs its
// own proof, not just one.
panicking_pool_task_cmd_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	panic("boom on pool")
}

@(test)
test_dispatch_recovers_a_panicking_cmd_on_the_pool :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 8), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)
	defer dispatcher_destroy(&d)

	dispatch(&d, cmd_from(panicking_pool_task_cmd_run, struct{}{}, context.allocator))

	// Plain blocking mailbox_recv, same as every other dispatch test in this
	// file (e.g. test_dispatch_delivers_a_zero_sized_result_pool above) --
	// deliberately no bespoke timeout wrapper: against the UNGUARDED code
	// this replaced, a panicking Cmd took the whole process down immediately
	// (message-ownership-decision.md §2, Option B's "honest, immediate
	// process abort" -- true for a non-POD box() panic and equally true for
	// a bare user panic() before this fix), so a regression here would
	// crash this test binary outright, not hang it -- a timeout wrapper
	// would add machinery this specific failure mode doesn't need.
	msg, ok := mailbox_recv(&m)
	defer box_free(msg, context.allocator)
	testing.expect(t, ok, "expected a result even though the Cmd panicked -- the mailbox must not just silently have nothing")
	pm, is := msg.(Panicked_Msg)
	testing.expect(t, is, "a panicking pool Cmd must deliver a Panicked_Msg, not vanish")
	if is {
		pm := pm
		testing.expect_value(t, msg_text_string(&pm.message), "boom on pool")
	}
}

panicking_detached_cmd_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	panic("boom detached")
}

@(test)
test_dispatch_recovers_a_panicking_cmd_when_detached :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 8), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)
	defer dispatcher_destroy(&d)

	dispatch(&d, cmd_from(panicking_detached_cmd_run, struct{}{}, context.allocator, detached = true))

	msg, ok := mailbox_recv(&m)
	defer box_free(msg, context.allocator)
	testing.expect(t, ok, "expected a result even though the detached Cmd panicked")
	pm, is := msg.(Panicked_Msg)
	testing.expect(t, is, "a panicking detached Cmd must deliver a Panicked_Msg, not vanish or take the process down")
	if is {
		pm := pm
		testing.expect_value(t, msg_text_string(&pm.message), "boom detached")
	}
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

empty_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
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
	// A zero-sized box has a nil data pointer and so frees nothing (box_free's
	// own doc comment) -- kept anyway so every drain in this file follows the
	// same rule, and so this test keeps working if Empty_Result ever grows a field.
	defer box_free(msg, context.allocator)
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
	// A zero-sized box has a nil data pointer and so frees nothing (box_free's
	// own doc comment) -- kept anyway so every drain in this file follows the
	// same rule, and so this test keeps working if Empty_Result ever grows a field.
	defer box_free(msg, context.allocator)
	testing.expect(t, ok, "expected the zero-sized result to reach the mailbox")
	_, is := msg.(Empty_Result)
	testing.expect(t, is, "zero-sized Msg types must not be silently dropped")
}

// A coordinator Cmd waits on children it dispatches. On a fixed pool sized N,
// N such coordinators occupy every worker and their children never get one --
// deadlock. Detached Cmds bypass the pool, which is the elastic-overflow path.
// This test pins that: more coordinators than workers must still complete.
Coord_Env :: struct { d: ^Dispatcher, inner: ^Mailbox }

coord_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	e := cast(^Coord_Env)env
	// A child unit of work, run inline here to keep the test deterministic;
	// the point under test is that the coordinator itself is not pool-bound.
	return box(Fetch_Result{url = msg_text_from("coord"), status = 1}, context.allocator)
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
		defer box_free(msg, context.allocator)
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

slow_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	time.sleep(150 * time.Millisecond)
	return box(Fetch_Result{url = msg_text_from("slow"), status = 2}, context.allocator)
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
	//
	// The drain is NOT part of what this test asserts (deliberately not
	// draining before the destroy is the whole point, see this test's own
	// comment above) -- it is ownership cleanup. The slow Cmd's result is
	// sitting in the mailbox boxed and unclaimed, and mailbox_destroy will
	// not free it: it deletes its ring buffer without knowing which allocator
	// any message inside came from. Nothing else ever will, so this test must.
	try_recv_and_free(&m)
	mailbox_destroy(&m)
}

// T1 structural fix (docs/superpowers/cancellation-decision.md): dispatcher_reap
// is dispatcher_destroy + mailbox_destroy's non-blocking sibling, the one
// run() actually uses so it can return promptly while a Cmd is still
// running. This pins the "does not block" half directly, mirroring
// test_dispatcher_destroy_waits_for_detached_cmds's own shape (dispatch a
// slow Cmd, time the teardown call) but asserting the OPPOSITE: unlike that
// test's `elapsed >= 100ms`, this one is non-vacuous only if it reliably
// FAILS against the plain, always-blocking dispatcher_destroy this replaced
// -- verified by temporarily swapping this test's dispatcher_reap(rc, 20ms)
// call for dispatcher_destroy(&rc.disp) + mailbox_destroy(&rc.mbox) and
// re-running: it then takes >= 300ms (the Cmd's own sleep) and this test's
// `elapsed < 150ms` assertion fails, exactly as expected.
Reap_Slow_Env :: struct { done: ^sync.Sema }

reap_slow_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	e := cast(^Reap_Slow_Env)env
	time.sleep(300 * time.Millisecond)
	// Signals a Sema this TEST owns on its own stack -- not anything inside
	// rc, which dispatcher_reap has already taken ownership of by the time
	// this Cmd is even running. See the test's own trailing comment for why
	// that distinction matters.
	sync.sema_post(e.done)
	return box(Fetch_Result{url = msg_text_from("reap-slow"), status = 3}, context.allocator)
}

@(test)
test_dispatcher_reap_does_not_block_the_caller :: proc(t: ^testing.T) {
	done: sync.Sema

	// Heap-owned exactly the way tea.odin's run() does it -- see Reap_Ctx's
	// own doc comment (cmd.odin): dispatcher_reap can hand rc off to a
	// background thread that outlives this test function, so rc cannot be a
	// stack local here either.
	rc := new(Reap_Ctx)
	testing.expect_value(t, mailbox_init(&rc.mbox, 8), nil)
	dispatcher_init(&rc.disp, &rc.mbox, 1)

	dispatch(&rc.disp, cmd_from(reap_slow_run, Reap_Slow_Env{done = &done}, context.allocator))

	start := time.now()
	finished := dispatcher_reap(rc, 20 * time.Millisecond)
	elapsed := time.since(start)

	testing.expect(t, !finished, "dispatcher_reap should NOT finish within a 20ms grace period against a 300ms Cmd")
	testing.expectf(t, elapsed < 150 * time.Millisecond,
		"dispatcher_reap should return close to its 20ms grace period, not block for the Cmd's full 300ms -- took %v", elapsed)

	// Deliberately does NOT touch rc again after dispatcher_reap: ownership
	// transferred to the reaper thread on that call, per its own documented
	// precondition. Waiting on `done` instead -- a Sema this test owns on its
	// own stack, signaled by the Cmd body itself as basically its last action
	// -- is what lets this test return only once the Cmd has genuinely
	// finished, WITHOUT odin test's per-task Tracking_Allocator racing the
	// reaper thread's own free(rc) call the way an earlier version of this
	// fix did: that version put the wait target directly inside Reap_Ctx and
	// freed Reap_Ctx immediately after signaling it, which ThreadSanitizer
	// caught as a genuine heap-use-after-free (see cmd.odin's Grace_Signal
	// for the fix and docs/superpowers/cancellation-decision.md for the
	// account of that bug).
	sync.sema_wait(&done)
	// Small fixed margin for the trailing dispatcher_destroy/mailbox_destroy/
	// free(rc) inside the reaper thread, which runs after the Cmd body's own
	// sema_post above -- not a correctness requirement of the fix itself,
	// purely to keep this test's own memory report clean (same reasoning as
	// the margin below in test_cancel_token_observed_by_a_polling_cmd).
	time.sleep(50 * time.Millisecond)
}

// HALF 2 (docs/superpowers/cancellation-decision.md): a Cmd can poll
// cancel_requested to notice the enclosing Dispatcher session is quitting.
// This pins that the token actually reaches a running Cmd promptly --
// dispatcher_reap fires it as its very first action, before the reaper
// thread is even spawned, so a Cmd polling every 5ms should see it within a
// poll interval or two, not run anywhere near its own 100-iteration bound.
Cancel_Probe :: struct {
	done:       sync.Sema,
	observed:   bool,
	iterations: int,
}

Cancel_Poll_Env :: struct { probe: ^Cancel_Probe }

cancel_poll_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	e := cast(^Cancel_Poll_Env)env
	p := e.probe
	for i in 0 ..< 100 {
		if cancel_requested(cancel) {
			p.observed = true
			p.iterations = i
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	sync.sema_post(&p.done)
	return box(Empty_Result{}, context.allocator)
}

@(test)
test_cancel_token_observed_by_a_polling_cmd :: proc(t: ^testing.T) {
	probe: Cancel_Probe

	rc := new(Reap_Ctx)
	testing.expect_value(t, mailbox_init(&rc.mbox, 8), nil)
	dispatcher_init(&rc.disp, &rc.mbox, 1)

	dispatch(&rc.disp, cmd_from(cancel_poll_run, Cancel_Poll_Env{probe = &probe}, context.allocator))

	// grace=0: this test only cares about the token firing promptly, not
	// about dispatcher_reap's own return timing (that is
	// test_dispatcher_reap_does_not_block_the_caller's job, above).
	dispatcher_reap(rc, 0)

	sync.sema_wait(&probe.done)          // deterministic: waits for the Cmd body itself, not the reaper
	time.sleep(20 * time.Millisecond)    // margin for the trailing teardown -- see the test above for why

	testing.expect(t, probe.observed, "the polling Cmd should have observed cancel_requested before its own 100-iteration bound")
	testing.expectf(t, probe.iterations < 5,
		"cancellation should be observed within a couple of 5ms poll intervals, not after running the full bound -- took %d iterations",
		probe.iterations)
}
