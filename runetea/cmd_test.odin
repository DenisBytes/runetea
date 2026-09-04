#+private
// ^ Every declaration in this file is package-private, so that `odin doc
//   runetea` / `odin doc runegloss` -- the command README.md and docs/API.md
//   hand a newcomer for symbol discovery -- lists the library rather than the
//   test fixtures. Pinned by tools/doccheck/run.sh's `apidoc` check, which is
//   also where the argument for it is written out.
package runetea

import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
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
// detached Cmd's own thread, which the pool never sees. If
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

// ---------------------------------------------------------------------------
// A Cmd IS SINGLE-USE (cmd.odin's Cmd ledger). These pin the enforcement per
// Cmd kind -- cmd_from here, batch()/sequence() in batch_test.odin,
// tick()/every() in timer_test.odin -- because each kind owns a DIFFERENT
// shape of heap memory and each one failed differently before the ledger
// existed.
//
// What this test used to do on this toolchain, verbatim: dispatch the same
// cmd_from Cmd twice, run the body against freed env, then free the same
// pointer a second time -- SIGSEGV (exit 139) under the default allocator,
// 3/3 runs, and a hard "Tracking allocator error: Bad free" abort under
// odin test's own Tracking_Allocator, which is what this test would have
// produced. Neither is a test failure a suite can survive to report, which
// is exactly why the fix had to make the second dispatch a REFUSAL and not
// merely a documented hazard.
//
// Both messages are counted rather than ordered: dispatch #1 lands on a pool
// worker while the refusal for dispatch #2 is delivered inline on this
// thread, so either can reach the mailbox first.
@(test)
test_redispatching_a_cmd_from_is_refused_with_a_diagnostic :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	d: Dispatcher
	dispatcher_init(&d, &m, 2)

	c := cmd_from(fetch_run, Fetch_Env{url = "once"}, context.allocator)
	dispatch(&d, c)
	dispatch(&d, c)

	results, refusals := 0, 0
	for _ in 0 ..< 2 {
		msg, ok := mailbox_recv(&m)
		defer box_free(msg, context.allocator)   // per-iteration: Odin scopes defer to the loop BODY
		testing.expect(t, ok, "expected one result and one refusal")
		if _, is := msg.(Fetch_Result); is { results += 1 }
		if p, is := msg.(Panicked_Msg); is {
			refusals += 1
			text := p.message
			testing.expectf(t, strings.contains(msg_text_string(&text), "already dispatched"),
				"the refusal must say what went wrong, got %q", msg_text_string(&text))
			testing.expectf(t, strings.contains(msg_text_string(&text), "cmd_from"),
				"the refusal must name the Cmd kind, got %q", msg_text_string(&text))
		}
	}
	testing.expect_value(t, results, 1)
	testing.expect_value(t, refusals, 1)

	dispatcher_destroy(&d)
	mailbox_destroy(&m)
}

// The other half of the contract, and the reason the ledger uses a ticket
// rather than "does this Cmd own a pointer": cmd_nil() and quit_cmd() own
// nothing, so they carry the zero ticket and stay dispatchable forever.
// Existing code returns exactly these from update() on every single keystroke,
// so a guard that refused the second one would break every app in the repo
// rather than fix anything.
@(test)
test_cmd_nil_and_quit_cmd_survive_repeated_dispatch :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	d: Dispatcher
	dispatcher_init(&d, &m, 2)

	nilc := cmd_nil()
	quit := quit_cmd()
	for _ in 0 ..< 4 {
		dispatch(&d, nilc)    // must produce nothing at all, not even a refusal
		dispatch(&d, quit)
	}

	quits := 0
	for _ in 0 ..< 4 {
		msg, ok := mailbox_recv(&m)
		defer box_free(msg, context.allocator)
		testing.expect(t, ok, "expected four Quit_Msgs")
		if _, is := msg.(Quit_Msg);     is { quits += 1 }
		if _, is := msg.(Panicked_Msg); is { testing.fail_now(t, "a Cmd that owns nothing must never be refused") }
	}
	testing.expect_value(t, quits, 4)

	dispatcher_destroy(&d)
	mailbox_destroy(&m)
}

// F15: dispatch_ex's detached branch used to DISCARD
// thread.create_and_start_with_data's return value, one line after
// wait_group_add had already incremented d.inflight. On this toolchain that
// call returns nil -- silently, no fault -- whenever pthread_create fails
// (thread_unix.odin:122-125), measured at 16-100 nil returns per 100 spawns
// under an RLIMIT_NPROC that perturbs nothing else. The Cmd then never ran and
// d.inflight stayed permanently +1, so dispatcher_destroy's wait_group_wait
// below NEVER RETURNED.
//
// That is why this test drives the failure through g_cmd_force_spawn_failure
// instead of an rlimit: the pre-fix failure is a hang, not a wrong value, and
// a hang cannot be asserted on from inside the process it hangs. Run against
// the pre-fix dispatch_ex this test does not fail, it wedges the whole suite --
// which is precisely the user-visible symptom (run_nbio() frozen with the
// terminal still raw, no diagnostic, after the model already returned
// quit_cmd).
@(test)
test_a_failed_detached_spawn_reports_and_does_not_wedge_teardown :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	d: Dispatcher
	dispatcher_init(&d, &m, 2)

	sync.atomic_store(&g_cmd_force_spawn_failure, true)
	dispatch(&d, cmd_from(fetch_run, Fetch_Env{url = "never runs"}, context.allocator, detached = true))
	sync.atomic_store(&g_cmd_force_spawn_failure, false)

	msg, ok := mailbox_recv(&m)
	defer box_free(msg, context.allocator)
	testing.expect(t, ok, "a Cmd that could not be started must SAY so, not vanish")
	p, is := msg.(Panicked_Msg)
	testing.expect(t, is, "expected a Panicked_Msg reporting the failed spawn")
	if is {
		text := p.message
		testing.expectf(t, strings.contains(msg_text_string(&text), "could not start a thread"),
			"the report must name the failure, got %q", msg_text_string(&text))
	}

	// The whole point: this returns. Pre-fix it blocked forever on an
	// inflight count that nothing would ever decrement.
	dispatcher_destroy(&d)
	mailbox_destroy(&m)
}

// F35: back-pressure used to be a bare `case .Full: thread.yield()` with no
// backoff at all, which spins a producer thread at ~100% of a core for as long
// as the consumer stays behind. The CPU cost is not something a portable test
// can assert on without being flaky, so what this pins is the property the
// backoff must NOT break while fixing that: retry-on-Full is still
// retry-FOREVER, so a deliberately overflowing burst against a deliberately
// slow consumer still delivers every single message rather than shedding any.
// It passed before the backoff went in and passes after; it exists so a later
// "just drop on Full" simplification cannot land unnoticed.
@(test)
test_backpressure_delivers_every_message_to_a_slow_consumer :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 4), nil)   // deliberately tiny: 4 slots for 32 messages
	d: Dispatcher
	dispatcher_init(&d, &m, 4)

	SENT :: 32
	for i in 0 ..< SENT {
		dispatch(&d, cmd_from(fetch_run, Fetch_Env{url = "burst"}, context.allocator))
	}

	got := 0
	for _ in 0 ..< SENT {
		msg, ok := mailbox_recv(&m)
		defer box_free(msg, context.allocator)
		testing.expect(t, ok, "expected every burst message")
		if _, is := msg.(Fetch_Result); is { got += 1 }
		time.sleep(200 * time.Microsecond)   // stay behind the producers on purpose
	}
	testing.expect_value(t, got, SENT)

	dispatcher_destroy(&d)
	mailbox_destroy(&m)
}

// ---------------------------------------------------------------------------
// Detached-Cmd thread lifetime (cmd.odin's WHY self_cleanup = false comment).
//
// The defect these two pin is a DATA RACE, not a wrong answer, and a race test
// that merely runs the code proves nothing: ./tools/test.sh race caught the
// self_cleanup free racing _start's sync.post 2 times in 13 under real load
// and 0 times in 90 direct runs on an idle box. So these assert the STRUCTURE
// that removes the race instead of trying to observe the race: cmd.odin can
// only pass self_cleanup = false if something else joins and frees each
// `^Thread`, and d.detached_threads is that something. Both tests fail to
// COMPILE against the pre-fix file (there was no such field), and both fail at
// runtime against any later edit that keeps the field but drops half the
// scheme -- which is the regression they are actually here to catch, since
// self_cleanup = false with no sweep is heap growth proportional to how many
// detached Cmds have ever run, i.e. strictly worse than the race.
// ---------------------------------------------------------------------------

// Waits until every recorded detached thread reports .Done, so the assertion
// after it is about the SWEEP rather than about scheduling luck. Returns false
// on timeout; the caller reports that as its own failure rather than hanging
// the suite.
detached_threads_all_done :: proc(d: ^Dispatcher, within: time.Duration) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < within {
		all := true
		sync.mutex_lock(&d.detached_mu)
		for th in d.detached_threads {
			if !thread.is_done(th) { all = false; break }
		}
		sync.mutex_unlock(&d.detached_mu)
		if all { return true }
		time.sleep(time.Millisecond)
	}
	return false
}

@(test)
test_detached_cmd_threads_are_swept_by_the_next_dispatch :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 8), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)
	defer dispatcher_destroy(&d)

	// Strictly SEQUENTIAL: each Cmd's result is received before the next one
	// is dispatched, so peak concurrency is one and a correctly swept
	// Dispatcher must hold one `^Thread` at a time no matter how many run.
	ROUNDS :: 32
	for _ in 0 ..< ROUNDS {
		dispatch(&d, cmd_from(fetch_run, Fetch_Env{url = "sweep"}, context.allocator, detached = true))
		msg, ok := mailbox_recv(&m)
		defer box_free(msg, context.allocator)
		testing.expect(t, ok, "expected each detached result")
	}

	// Receiving a result only proves the BODY finished -- the thread may still
	// be inside the entry proc's epilogue, and a thread that is not .Done yet
	// is one the sweep is right to leave alone.
	testing.expect(t, detached_threads_all_done(&d, 2 * time.Second), "detached threads did not reach .Done")

	dispatch(&d, cmd_from(fetch_run, Fetch_Env{url = "sweep"}, context.allocator, detached = true))
	msg, ok := mailbox_recv(&m)
	defer box_free(msg, context.allocator)
	testing.expect(t, ok, "expected the final detached result")

	// One: the ROUNDS finished threads were joined and freed by this last
	// dispatch's sweep, and only its own thread remains recorded. Without the
	// sweep this is ROUNDS + 1 and grows for the life of the Dispatcher.
	sync.mutex_lock(&d.detached_mu)
	live := len(d.detached_threads)
	sync.mutex_unlock(&d.detached_mu)
	testing.expect_value(t, live, 1)
}

@(test)
test_dispatcher_destroy_frees_every_detached_thread :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)

	// Deliberately CONCURRENT and deliberately undrained: nothing here sweeps,
	// so every one of these threads is still recorded when destroy runs. The
	// slow body also puts real time between the spawn and the join, so the
	// drain is exercised against threads that are genuinely still running
	// rather than ones that happened to finish first.
	CMDS :: 6
	for _ in 0 ..< CMDS {
		dispatch(&d, cmd_from(fetch_run, Fetch_Env{url = "drain", delay = 20 * time.Millisecond}, context.allocator, detached = true))
	}
	sync.mutex_lock(&d.detached_mu)
	recorded := len(d.detached_threads)
	sync.mutex_unlock(&d.detached_mu)
	testing.expect_value(t, recorded, CMDS)

	dispatcher_destroy(&d)

	// Empty AND released: the drain joins each thread, frees each `^Thread`
	// and deletes the array itself. odin test's tracking allocator is the
	// other half of this assertion -- a `^Thread` the drain missed shows up as
	// a leak at thread_unix.odin:_create, which tools/test.sh's leak audit
	// allows exactly once (for dispatcher_reap's deliberate one-per-session
	// leak) and would flag here.
	testing.expect_value(t, len(d.detached_threads), 0)
	testing.expect_value(t, cap(d.detached_threads), 0)

	for _ in 0 ..< CMDS {
		msg, ok := mailbox_recv(&m)
		defer box_free(msg, context.allocator)
		testing.expect(t, ok, "every detached result was still delivered")
	}
}

// ============================================================================
// F07, THE dispatch_ex BACKSTOP.
//
// The constructor check (cmd_from/tick/every) only fires while a frame is
// armed, which is exactly when update() runs -- so it catches `return
// cmd_from(fn, env, alloc)` and nothing else. This is the other population: a
// Cmd whose env was cloned into a frame arena somewhere unarmed (a pool
// worker, a helper that ran before the first frame) and dispatched later. Same
// silent corruption -- the body reads a zeroed env and answers with nothing --
// and much harder to diagnose, because the construction and the damage are in
// different places.
//
// dispatch_ex REPORTS rather than panicking, and that is forced rather than
// chosen: apply_msg dispatches AFTER guarded() has returned, so a panic there
// would abort the process instead of ending the session. The report carries
// CMD_ALLOC_CONTRACT_PANIC's prefix, which apply_msg escalates to
// Panicked_Error -- so what the caller sees matches the constructor's refusal.
// ============================================================================
@(test)
test_dispatch_refuses_a_cmd_whose_env_lives_in_the_frame_arena :: proc(t: ^testing.T) {
	fa: Frame_Arena
	testing.expect_value(t, frame_arena_init(&fa), nil)
	defer frame_arena_destroy(&fa)

	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 8), nil)
	d: Dispatcher
	dispatcher_init(&d, &m, 2)

	// Built with no frame armed: the constructor cannot know, and does not
	// refuse. This is the smuggled-allocator shape, spelled out.
	c := cmd_from(fetch_run, Fetch_Env{url = "never runs"}, frame_allocator(&fa))

	prev := frame_guard_arm(frame_allocator(&fa))
	dispatch(&d, c)
	frame_guard_disarm(prev)

	msg, ok := mailbox_recv(&m)
	defer box_free(msg, context.allocator)
	if !testing.expect(t, ok, "the refusal must arrive on the mailbox") { return }
	p, is := msg.(Panicked_Msg)
	if !testing.expectf(t, is, "a Cmd env allocated from the live frame arena must be refused, not run against reclaimed memory -- got %v", msg) { return }
	text := p.message
	testing.expect(t, is_cmd_alloc_contract_panic(msg_text_string(&text)),
		"the report must carry the contract marker, so apply_msg escalates it to a session-ending Panicked_Error rather than leaving it in an empty `case Panicked_Msg`")

	dispatcher_destroy(&d)
	mailbox_destroy(&m)
}

// THE FALSE-POSITIVE THIS DESIGN REFUSES TO HAVE. Comparing only against
// virtual.arena_allocator_proc would have been one line shorter and would have
// rejected EVERY virtual.Arena in the program -- including an application's own
// long-lived one, which outlives every frame and is a perfectly correct home
// for a Cmd env. Refusing legal code is worse than the miss it prevents, so the
// `data` half of the comparison is what does the real work: the arena of the
// frame currently being processed, and no other.
@(test)
test_an_applications_own_arena_is_not_mistaken_for_the_frame_arena :: proc(t: ^testing.T) {
	fa: Frame_Arena
	testing.expect_value(t, frame_arena_init(&fa), nil)
	defer frame_arena_destroy(&fa)

	mine: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&mine), nil)
	defer virtual.arena_destroy(&mine)

	prev := frame_guard_arm(frame_allocator(&fa))
	defer frame_guard_disarm(prev)

	testing.expect(t, is_frame_allocator(frame_allocator(&fa)),
		"the armed frame arena's own allocator must be recognised -- that is the whole check")
	testing.expect(t, !is_frame_allocator(virtual.arena_allocator(&mine)),
		"an application's own virtual.Arena is NOT the frame arena and must not be refused")
	testing.expect(t, !is_frame_allocator(context.allocator),
		"context.allocator is the correct answer and must never be refused")

	// And with nothing armed, nothing is a frame allocator -- a stale pointer
	// from a finished session cannot start refusing later Cmds.
	frame_guard_disarm(nil)
	testing.expect(t, !is_frame_allocator(frame_allocator(&fa)),
		"between frames the guard is disarmed and refuses nothing")
	frame_guard_arm(frame_allocator(&fa))
}
