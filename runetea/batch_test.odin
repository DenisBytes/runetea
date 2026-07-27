package runetea

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// --- empty / single-element cases (batch-sequence-decision.md's own
// "do not allocate a coordinator thread for a single Cmd" requirement) ------

@(test)
test_batch_of_nothing_is_nil :: proc(t: ^testing.T) {
	c := batch([]Cmd{}, context.allocator)
	testing.expect(t, cmd_is_nil(c), "batch() of zero Cmds must report nil")
}

@(test)
test_sequence_of_nothing_is_nil :: proc(t: ^testing.T) {
	c := sequence([]Cmd{}, context.allocator)
	testing.expect(t, cmd_is_nil(c), "sequence() of zero Cmds must report nil")
}

@(test)
test_batch_of_only_nil_cmds_is_nil :: proc(t: ^testing.T) {
	cmds := []Cmd{cmd_nil(), cmd_nil(), cmd_nil()}
	c := batch(cmds, context.allocator)
	testing.expect(t, cmd_is_nil(c), "batch() of only nil Cmds must report nil")
}

@(test)
test_batch_of_one_returns_that_cmd_unwrapped :: proc(t: ^testing.T) {
	inner := cmd_from(fetch_run, Fetch_Env{url = "single", delay = 0}, context.allocator)
	cmds := []Cmd{cmd_nil(), inner, cmd_nil()}
	c := batch(cmds, context.allocator)
	testing.expect(t, c.compose == nil, "batch() of a single real Cmd must not allocate a Compose_Spec/coordinator")
	testing.expect_value(t, c.procedure, inner.procedure)
	testing.expect_value(t, c.env, inner.env)
	free(c.env, c.allocator)
}

@(test)
test_sequence_of_one_returns_that_cmd_unwrapped :: proc(t: ^testing.T) {
	inner := cmd_from(fetch_run, Fetch_Env{url = "single", delay = 0}, context.allocator)
	cmds := []Cmd{inner}
	c := sequence(cmds, context.allocator)
	testing.expect(t, c.compose == nil, "sequence() of a single real Cmd must not allocate a Compose_Spec/coordinator")
	testing.expect_value(t, c.procedure, inner.procedure)
	free(c.env, c.allocator)
}

// --- concurrency proof: batch ~ max(duration), sequence ~ sum(duration) ----

Batch_Slow_Env :: struct { dur: time.Duration }

batch_slow_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	e := cast(^Batch_Slow_Env)env
	time.sleep(e.dur)
	return box(Empty_Result{}, context.allocator)
}

@(private = "file")
bs_measure :: proc(t: ^testing.T, kind: Compose_Kind, n: int, dur: time.Duration) -> time.Duration {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, n)
	defer dispatcher_destroy(&d)

	cmds := make([]Cmd, n, context.allocator); defer delete(cmds)
	for i in 0 ..< n { cmds[i] = cmd_from(batch_slow_run, Batch_Slow_Env{dur = dur}, context.allocator) }

	c: Cmd
	switch kind {
	case .Batch:    c = batch(cmds, context.allocator)
	case .Sequence: c = sequence(cmds, context.allocator)
	}

	start := time.tick_now()
	dispatch(&d, c)
	for _ in 0 ..< n {
		testing.expect(t, recv_and_free(&m), "expected a child's result")
	}
	return time.tick_diff(start, time.tick_now())
}

// THE concurrency proof VERIFICATION item 3 asks for directly: a batch of N
// slow Cmds completes in ~max(duration), a sequence of the SAME N Cmds
// completes in ~sum(duration), and the two measurably differ. N and DUR are
// deliberately generous (4 x 80ms) so scheduling jitter on a loaded CI box
// can't blur the two outcomes together.
@(test)
test_batch_and_sequence_wall_clock_differ_as_expected :: proc(t: ^testing.T) {
	N :: 4
	DUR :: 80 * time.Millisecond

	batch_elapsed := bs_measure(t, .Batch, N, DUR)
	seq_elapsed := bs_measure(t, .Sequence, N, DUR)

	fmt.printfln("[batch-sequence timing] N=%d children x %v each -- batch: %v (expected ~%v)  sequence: %v (expected ~%v)",
		N, DUR, batch_elapsed, DUR, seq_elapsed, time.Duration(N) * DUR)

	testing.expectf(t, batch_elapsed < DUR * 2,
		"batch of %d x %v children should finish close to max(duration) (~%v), not accumulate -- took %v", N, DUR, DUR, batch_elapsed)
	testing.expectf(t, seq_elapsed >= time.Duration(N) * DUR - 15 * time.Millisecond,
		"sequence of %d x %v children should finish close to sum(duration) (~%v) -- took %v", N, DUR, time.Duration(N) * DUR, seq_elapsed)
	testing.expectf(t, seq_elapsed > batch_elapsed * 2,
		"sequence (%v) should take substantially longer than batch (%v) for IDENTICAL children -- if not, batch isn't actually running them concurrently", seq_elapsed, batch_elapsed)
}

// --- nesting: batch-of-batch, sequence-of-batch ----------------------------

// Tagged, distinguishable result -- lets these tests assert WHICH children
// arrived and in what relative order without depending on wall-clock timing.
Order_Result :: struct { tag: int }

order_cmd_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	e := cast(^int)env
	return box(Order_Result{tag = e^}, context.allocator)
}

@(test)
test_batch_containing_a_nested_batch_delivers_all_leaves :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 4)
	defer dispatcher_destroy(&d)

	inner := make([]Cmd, 2, context.allocator); defer delete(inner)
	inner[0] = cmd_from(order_cmd_run, 10, context.allocator)
	inner[1] = cmd_from(order_cmd_run, 11, context.allocator)
	nested_batch := batch(inner, context.allocator)

	outer := make([]Cmd, 2, context.allocator); defer delete(outer)
	outer[0] = nested_batch
	outer[1] = cmd_from(order_cmd_run, 12, context.allocator)

	dispatch(&d, batch(outer, context.allocator))

	seen := make(map[int]bool); defer delete(seen)
	for _ in 0 ..< 3 {
		msg, ok := mailbox_recv(&m)
		defer box_free(msg, context.allocator) // per-iteration: Odin scopes defer to the loop BODY
		testing.expect(t, ok, "expected a leaf result from the batch-of-batch")
		if r, is := msg.(Order_Result); is { seen[r.tag] = true }
	}
	testing.expect_value(t, len(seen), 3)
	testing.expect(t, seen[10] && seen[11] && seen[12], "all three leaves (including the nested batch's two) must be delivered")
}

// Sequence's ordering guarantee must survive nesting: a nested batch counts
// as "one step" that is only done once ALL of its own children are done --
// proven here structurally (message identity + arrival order), not by
// timing, so this cannot be flaky under scheduler jitter.
@(test)
test_sequence_waits_for_a_nested_batch_to_fully_finish_before_continuing :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 4)
	defer dispatcher_destroy(&d)

	inner := make([]Cmd, 2, context.allocator); defer delete(inner)
	inner[0] = cmd_from(order_cmd_run, 1, context.allocator)
	inner[1] = cmd_from(order_cmd_run, 2, context.allocator)
	nested_batch := batch(inner, context.allocator)

	outer := make([]Cmd, 2, context.allocator); defer delete(outer)
	outer[0] = nested_batch
	outer[1] = cmd_from(order_cmd_run, 3, context.allocator)

	dispatch(&d, sequence(outer, context.allocator))

	first_two := make(map[int]bool); defer delete(first_two)
	for _ in 0 ..< 2 {
		msg, ok := mailbox_recv(&m)
		defer box_free(msg, context.allocator) // per-iteration: Odin scopes defer to the loop BODY
		testing.expect(t, ok, "expected one of the nested batch's two children")
		if r, is := msg.(Order_Result); is { first_two[r.tag] = true }
	}
	testing.expect(t, first_two[1] && first_two[2],
		"the nested batch's two children must BOTH arrive before the sequence's own next step -- sequence must treat a nested batch as one step that finishes only once all of it has")

	msg, ok := mailbox_recv(&m)
	defer box_free(msg, context.allocator)
	testing.expect(t, ok, "expected the sequence's final step result")
	r, is := msg.(Order_Result)
	testing.expect(t, is && r.tag == 3, "expected the final step's Order_Result specifically, arriving strictly after the nested batch's own two")
}

// --- cancellation -----------------------------------------------------

// Deterministic pre-cancellation: d.cancel.cancelled is public field-level
// surface (Cancel_Token has no field privacy, only a documented "touch only
// via atomic ops" convention) -- setting it directly before ever dispatching
// simulates "the session is already quitting" without needing
// dispatcher_reap/dispatcher_destroy's own, incompatible lifecycle
// preconditions. See docs/superpowers/batch-sequence-decision.md for why
// this is legitimate rather than reaching around the API.
@(test)
test_cancelled_batch_skips_all_unstarted_children :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	// No `defer mailbox_destroy(&m)` here -- destroyed explicitly below,
	// AFTER dispatcher_destroy, matching the documented ordering precondition
	// (mailbox.odin); a deferred call on top of that explicit one would
	// double-destroy.

	d: Dispatcher
	dispatcher_init(&d, &m, 2)

	sync.atomic_store(&d.cancel.cancelled, true)

	cmds := make([]Cmd, 3, context.allocator); defer delete(cmds)
	cmds[0] = cmd_from(order_cmd_run, 20, context.allocator)
	cmds[1] = cmd_from(order_cmd_run, 21, context.allocator)
	cmds[2] = cmd_from(order_cmd_run, 22, context.allocator)

	dispatch(&d, batch(cmds, context.allocator))

	dispatcher_destroy(&d) // must return promptly -- the coordinator sees cancel_requested on its very first check and never dispatches anything
	ok := try_recv_and_free(&m)
	testing.expect(t, !ok, "a batch dispatched after cancellation must not run any of its children")

	mailbox_destroy(&m)
}

@(test)
test_cancelled_sequence_skips_all_unstarted_steps :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	// See test_cancelled_batch_skips_all_unstarted_children's identical
	// comment -- no top-level defer, destroyed explicitly below instead.

	d: Dispatcher
	dispatcher_init(&d, &m, 2)

	sync.atomic_store(&d.cancel.cancelled, true)

	cmds := make([]Cmd, 3, context.allocator); defer delete(cmds)
	cmds[0] = cmd_from(order_cmd_run, 30, context.allocator)
	cmds[1] = cmd_from(order_cmd_run, 31, context.allocator)
	cmds[2] = cmd_from(order_cmd_run, 32, context.allocator)

	dispatch(&d, sequence(cmds, context.allocator))

	dispatcher_destroy(&d)
	ok := try_recv_and_free(&m)
	testing.expect(t, !ok, "a sequence dispatched after cancellation must not run any of its steps")

	mailbox_destroy(&m)
}

// Deeper proof, MID-flight: cancellation fires while step 0 is genuinely
// running (gated by a semaphore this test controls), and step 1 must never
// start. Deterministic throughout -- no wall-clock race: sema_wait blocks
// until step 0 has DEFINITELY started (proving step 1 has DEFINITELY not,
// per sequence's own one-at-a-time design), and the final "step 1 never
// arrives" check uses the same bounded sleep-then-check idiom
// test_timer_stop_cancels_a_pending_tick (timer_test.odin) already
// establishes for this exact class of negative proof.
Gate_Env :: struct {
	tag:     int,
	started: ^sync.Sema,
	release: ^sync.Sema,
}

gate_cmd_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	e := cast(^Gate_Env)env
	sync.sema_post(e.started)
	sync.sema_wait(e.release)
	return box(Order_Result{tag = e.tag}, context.allocator)
}

@(test)
test_cancelled_sequence_lets_the_in_flight_step_finish_but_starts_no_more :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)

	started, release: sync.Sema

	cmds := make([]Cmd, 2, context.allocator); defer delete(cmds)
	cmds[0] = cmd_from(gate_cmd_run, Gate_Env{tag = 100, started = &started, release = &release}, context.allocator)
	cmds[1] = cmd_from(order_cmd_run, 101, context.allocator) // must NEVER run

	dispatch(&d, sequence(cmds, context.allocator))

	sync.sema_wait(&started) // step 0 is now genuinely running -- step 1 is provably not yet dispatched

	sync.atomic_store(&d.cancel.cancelled, true) // cancel while step 0 is mid-flight
	sync.sema_post(&release)                    // let step 0 finish

	msg, ok := mailbox_recv(&m)
	defer box_free(msg, context.allocator)
	testing.expect(t, ok, "expected step 0's own result -- an already-dispatched step must run to completion, cooperative cancellation only")
	r, is := msg.(Order_Result)
	testing.expect(t, is && r.tag == 100, "expected step 0's result specifically")

	ok2 := try_recv_and_free(&m)
	time.sleep(100 * time.Millisecond)
	ok3 := try_recv_and_free(&m)
	testing.expect(t, !ok2 && !ok3, "step 1 must never be dispatched once cancellation was noticed before it started")

	dispatcher_destroy(&d)
}

// --- tension 3: the pool deadlock -----------------------------------------

// "batch specifically survives more coordinators than pool workers" --
// COORDS batch() Cmds, each with its own children, on a pool narrower than
// COORDS. Non-vacuous companion below proves WHY this doesn't deadlock.
@(test)
test_batch_coordinators_exceed_pool_width_without_deadlock :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 128), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2) // deliberately narrower than COORDS below
	defer dispatcher_destroy(&d)

	COORDS :: 8              // 4x the pool width
	CHILDREN_PER_BATCH :: 2

	for i in 0 ..< COORDS {
		cmds := make([]Cmd, CHILDREN_PER_BATCH, context.allocator)
		for j in 0 ..< CHILDREN_PER_BATCH {
			cmds[j] = cmd_from(order_cmd_run, i * 100 + j, context.allocator)
		}
		dispatch(&d, batch(cmds, context.allocator))
		delete(cmds)
	}

	got := 0
	for _ in 0 ..< COORDS * CHILDREN_PER_BATCH {
		if !recv_and_free(&m) { break }
		got += 1
	}
	testing.expect_value(t, got, COORDS * CHILDREN_PER_BATCH)
}

// Non-vacuous proof: a hand-built coordinator shaped EXACTLY like what
// compose_dispatch (batch.odin) would produce if it did NOT force
// detached = true -- occupies a pool worker itself while dispatching a child
// through the SAME (narrow) pool and waiting on it. batch()/sequence()
// themselves have no way to construct this (compose_dispatch always forces
// detached), so this pins the underlying mechanism directly at the Cmd/
// dispatch() level instead, using the same "many more coordinators than
// workers" shape as the test above.
//
// Bounded throughout via wait_group_wait_with_timeout, never a bare wait --
// even the branch that reproduces the deadlock cannot hang this test or the
// suite: a stuck coordinator simply gives up after 500ms, frees its pool
// worker, and reports timed_out = true.
Fake_Wg_Env :: struct { wg: ^sync.Wait_Group }

fake_child_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	e := cast(^Fake_Wg_Env)env
	sync.wait_group_done(e.wg)
	return box(Empty_Result{}, context.allocator)
}

Fake_Coord_Env :: struct {
	d:         ^Dispatcher,
	wg:        ^sync.Wait_Group,
	timed_out: ^bool,
	detached:  bool,
}

fake_coord_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	e := cast(^Fake_Coord_Env)env
	sync.wait_group_add(e.wg, 1)
	dispatch(e.d, cmd_from(fake_child_run, Fake_Wg_Env{wg = e.wg}, context.allocator))
	ok := sync.wait_group_wait_with_timeout(e.wg, 500 * time.Millisecond)
	e.timed_out^ = !ok
	return box(Empty_Result{}, context.allocator)
}

@(test)
test_a_non_detached_coordinator_would_deadlock_against_its_own_children_on_a_narrow_pool :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 32), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2) // narrow: fewer workers than coordinators below
	defer dispatcher_destroy(&d)

	COORDS :: 4

	// Branch 1: NON-detached, deliberately -- the exact shape
	// compose_dispatch NEVER produces. Each of these occupies a pool worker
	// for its own entire wait below.
	wgs := make([]sync.Wait_Group, COORDS); defer delete(wgs)
	timed_out := make([]bool, COORDS); defer delete(timed_out)
	for i in 0 ..< COORDS {
		dispatch(&d, cmd_from(fake_coord_run, Fake_Coord_Env{d = &d, wg = &wgs[i], timed_out = &timed_out[i]}, context.allocator))
	}
	// 2*COORDS, not COORDS: each coordinator delivers its OWN result AND its
	// child delivers one too, so this branch puts 2*COORDS messages in the
	// mailbox. Draining only half of them left the other half sitting there
	// for branch 2 below to consume instead of branch 2's own -- which made
	// branch 2's assertion vacuous (it could return before its coordinators
	// had written timed_out2 at all, reading the zeroed default) AND raced
	// this test's deferred dispatcher_destroy against a detached coordinator
	// still about to dispatch its child, orphaning that child's Task_Env and
	// Cmd env in the pool queue. That was the intermittent
	// cmd_from()/dispatch_ex() leak pair this suite used to print in roughly
	// one run in three.
	//
	// Draining all 2*COORDS is also what makes the timed_out reads below
	// well-defined: a coordinator's result reaches the mailbox strictly after
	// it has written timed_out.
	for _ in 0 ..< 2 * COORDS {
		testing.expect(t, recv_and_free(&m), "expected a result from every fake coordinator and every child, timed out or not")
	}
	any_timed_out := false
	for v in timed_out { if v { any_timed_out = true } }
	testing.expect(t, any_timed_out,
		"non-vacuous check failed: with COORDS > pool width and coordinators occupying a worker while waiting on their own pool-dispatched child, at least one MUST time out -- if none ever does, this test is not actually proving the deadlock risk is real")

	// Branch 2: the SAME shape, but detached = true -- exactly what
	// compose_dispatch actually does. None should time out.
	wgs2 := make([]sync.Wait_Group, COORDS); defer delete(wgs2)
	timed_out2 := make([]bool, COORDS); defer delete(timed_out2)
	for i in 0 ..< COORDS {
		dispatch(&d, cmd_from(fake_coord_run, Fake_Coord_Env{d = &d, wg = &wgs2[i], timed_out = &timed_out2[i]}, context.allocator, detached = true))
	}
	for _ in 0 ..< 2 * COORDS { // 2*COORDS -- see branch 1's own comment above
		testing.expect(t, recv_and_free(&m), "expected a result from every detached fake coordinator and every child")
	}
	for v in timed_out2 {
		testing.expect(t, !v, "a DETACHED coordinator must never time out waiting for its own pool-dispatched child, even on a narrow pool -- this is the mechanism compose_dispatch relies on")
	}
}

// --- quit latency: batch AND sequence (nested) mid-flight ------------------

Batch_Quit_Env :: struct {
	dur:   time.Duration,
	count: ^int, // atomic; incremented by whichever leaves actually get to run
}

batch_quit_leaf_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	e := cast(^Batch_Quit_Env)env
	time.sleep(e.dur)
	sync.atomic_add(e.count, 1)
	return box(Empty_Result{}, context.allocator)
}

Batch_Quit_Model :: struct { armed: bool, count: ^int }

batch_quit_update :: proc(m: ^Batch_Quit_Model, msg: any, alloc: mem.Allocator) -> Cmd {
	if _, is_key := msg.(Key_Msg); is_key {
		if !m.armed {
			m.armed = true
			// batch(sequence(batch(...), leaf), leaf) -- batch AND sequence
			// BOTH mid-flight simultaneously, nested, per this test's own
			// requirement (VERIFICATION item 4).
			inner_batch := make([]Cmd, 2, context.allocator)
			inner_batch[0] = cmd_from(batch_quit_leaf_run, Batch_Quit_Env{dur = 300 * time.Millisecond, count = m.count}, context.allocator)
			inner_batch[1] = cmd_from(batch_quit_leaf_run, Batch_Quit_Env{dur = 300 * time.Millisecond, count = m.count}, context.allocator)

			seq_steps := make([]Cmd, 2, context.allocator)
			seq_steps[0] = batch(inner_batch, context.allocator)
			seq_steps[1] = cmd_from(batch_quit_leaf_run, Batch_Quit_Env{dur = 150 * time.Millisecond, count = m.count}, context.allocator)
			delete(inner_batch)

			outer_batch := make([]Cmd, 2, context.allocator)
			outer_batch[0] = sequence(seq_steps, context.allocator)
			outer_batch[1] = cmd_from(batch_quit_leaf_run, Batch_Quit_Env{dur = 300 * time.Millisecond, count = m.count}, context.allocator)
			delete(seq_steps)

			c := batch(outer_batch, context.allocator)
			delete(outer_batch)
			return c
		}
		return quit_cmd()
	}
	return cmd_nil()
}

batch_quit_view :: proc(m: Batch_Quit_Model, alloc: mem.Allocator) -> string { return "" }

// THE structural proof VERIFICATION item 4 asks for: quit while a batch AND
// a sequence (nested inside each other) are mid-flight must still return
// within run()'s QUIT_GRACE bound, not stall for the ~450ms these nested
// Cmds actually take to finish in the background. Mirrors tea_test.odin's
// own test_run_returns_promptly_with_a_slow_cmd_still_in_flight exactly,
// extended to a compound batch(sequence(batch(...))) shape.
//
// NOT waited on via a fixed "N posts must happen" semaphore count (an
// earlier version of this test did exactly that, via sync.Sema, and hung
// the suite indefinitely): run()'s own teardown (dispatcher_reap) fires
// cancellation essentially immediately once 'q' is processed, and
// compose_run_batch/compose_run_sequence check cancel_requested BEFORE
// dispatching each remaining child -- with Bytes_Source's zero-pacing input,
// this can (and, empirically, reliably does) race ahead of the coordinator
// thread(s) even STARTING their own fan-out, so anywhere from 0 to 4 of the
// leaves below may actually get dispatched at all. That is not a bug, it is
// exactly the abandon-unstarted-children behavior batch-sequence-decision.md
// documents -- a test that assumes all N always run is asserting something
// the design deliberately does NOT guarantee. So this waits a fixed, bounded
// margin (comfortably longer than the slowest possible leaf) and reports
// how many leaves actually got to run, rather than requiring a specific
// count.
@(test)
test_run_returns_promptly_with_a_nested_batch_and_sequence_both_mid_flight :: proc(t: ^testing.T) {
	count: int

	// "aq": 'a' dispatches the nested batch/sequence (first keypress), 'q'
	// quits (second) -- both already queued by the reader thread well before
	// any of the four leaves below have any chance to finish.
	src := input_source_from_bytes(transmute([]u8)string("aq"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Batch_Quit_Model)
	program_init(&p, Batch_Quit_Model{count = &count}, batch_quit_update, batch_quit_view)

	start := time.now()
	err := run(&p, &src, &b)
	elapsed := time.since(start)

	testing.expect(t, err == nil, "run should exit cleanly")
	testing.expectf(t, elapsed < 200 * time.Millisecond,
		"run() should return well before its slowest nested Cmd finishes (~450ms; QUIT_GRACE is 100ms) -- took %v", elapsed)

	fmt.printfln("[quit latency] run() returned in %v with batch(sequence(batch(leaf,leaf), leaf), leaf) still mid-flight", elapsed)

	// Bounded margin, comfortably longer than the slowest possible leaf
	// (300ms) plus the trailing background teardown (dispatcher_destroy +
	// mailbox_destroy + free inside the reaper thread) -- same
	// tracking-allocator-race reasoning test_run_returns_promptly_with_a_
	// slow_cmd_still_in_flight documents (tea_test.odin), just a fixed wait
	// instead of a semaphore count since that count is not deterministic
	// here (see this test's own comment above).
	time.sleep(600 * time.Millisecond)
	fmt.printfln("[quit latency] %d/4 nested leaves actually got to run before cancellation reached them (0-4 all legitimate, not asserted)", sync.atomic_load(&count))
}


