package runetea

import "core:testing"
import "core:thread"
import "core:time"

// Test-only mirrors of what apply() (tea.odin) does for every message the
// RUNTIME delivers: receive it, then box_free it. A test that drains a Mailbox
// directly -- bypassing run()/apply() entirely -- takes on that second half
// itself, and nothing else will ever do it (mailbox_destroy cannot: it does
// not know which allocator each boxed message came from). Every one of the 49
// `arena.odin:box()` leak lines this suite used to print was a test that had
// forgotten, and a suite that always reports leaks cannot report a NEW one.
//
// Use these where the test cares only THAT a message arrived. Where the value
// itself is needed, call mailbox_recv/mailbox_try_recv directly and pair it
// with an explicit `defer box_free(msg, context.allocator)` -- the value has
// to be read before the free, which a helper cannot express.
//
// context.allocator is the right allocator here by construction: every
// producer thread in this package inherits the dispatching thread's context
// (init_context = context, see cmd.odin/timer.odin), so a Cmd or Timer_Fn
// boxing with `context.allocator` boxed with THIS one.
recv_and_free :: proc(m: ^Mailbox) -> bool {
	msg, ok := mailbox_recv(m)
	box_free(msg, context.allocator)
	return ok
}

try_recv_and_free :: proc(m: ^Mailbox) -> bool {
	msg, ok := mailbox_try_recv(m)
	box_free(msg, context.allocator)
	return ok
}

N_PROD :: 4
PER    :: 250

Prod :: struct { m: ^Mailbox, vals: [PER]int }

@(test)
test_mailbox_no_loss_under_4_producers :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 4096), nil)
	defer mailbox_destroy(&m)

	prods := make([]Prod, N_PROD);        defer delete(prods)
	ts    := make([]^thread.Thread, N_PROD); defer delete(ts)

	for i in 0 ..< N_PROD {
		prods[i].m = &m
		for j in 0 ..< PER { prods[i].vals[j] = i * PER + j }
		th := thread.create(proc(th: ^thread.Thread) {
			p := cast(^Prod)th.data
			for j in 0 ..< PER {
				// This test's cap (4096) comfortably exceeds N_PROD*PER (1000)
				// total sends, so Full is not expected; retry anyway rather
				// than assume, and bail on Closed like any well-behaved
				// producer must (see Mailbox_Send_Result's doc comment).
				for {
					r := mailbox_send(p.m, p.vals[j])
					if r == .Ok || r == .Closed { break }
					thread.yield()
				}
			}
		})
		th.data = &prods[i]
		ts[i] = th
		thread.start(th)
	}

	seen := make(map[int]bool); defer delete(seen)
	for _ in 0 ..< N_PROD * PER {
		msg, ok := mailbox_recv(&m)
		if !ok { break }
		if v, is_int := msg.(int); is_int { seen[v] = true }
	}
	for th in ts { thread.join(th); thread.destroy(th) }

	testing.expectf(t, len(seen) == N_PROD * PER,
		"expected %d unique values, got %d (%d lost/duplicated)",
		N_PROD * PER, len(seen), N_PROD * PER - len(seen))
}

@(test)
test_mailbox_reports_full :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 2), nil)
	defer mailbox_destroy(&m)
	testing.expect_value(t, mailbox_send(&m, 1), Mailbox_Send_Result.Ok)
	testing.expect_value(t, mailbox_send(&m, 2), Mailbox_Send_Result.Ok)
	testing.expect_value(t, mailbox_send(&m, 3), Mailbox_Send_Result.Full)
}

@(test)
test_mailbox_close_wakes_receiver :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 4), nil)
	defer mailbox_destroy(&m)
	mailbox_close(&m)
	_, ok := mailbox_recv(&m)
	testing.expect(t, !ok, "recv on a closed, drained mailbox should report !ok")
}

Delayed_Send :: struct { m: ^Mailbox, val: int }

// Regression for: try_recv dequeuing without consuming a semaphore credit
// left a stale credit behind. The next recv() would then wake immediately
// on that stale credit, see an empty buffer, and misreport an open mailbox
// as closed -- exactly the sequence below, confirmed as a real bug before
// this fix (mailbox_recv returned <nil, false> here even though the mailbox
// was never closed).
@(test)
test_mailbox_try_recv_keeps_semaphore_in_sync :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 4), nil)
	defer mailbox_destroy(&m)

	testing.expect_value(t, mailbox_send(&m, 111), Mailbox_Send_Result.Ok)

	msg, ok := mailbox_try_recv(&m)
	testing.expect(t, ok, "try_recv should drain the buffered message")
	v, is_int := msg.(int)
	testing.expect(t, is_int, "try_recv message should be an int")
	if is_int { testing.expect_value(t, v, 111) }

	// Buffer is now empty and the mailbox is still open. If try_recv left a
	// stale credit behind, the recv() below would return immediately with
	// ok=false instead of blocking for this delayed send.
	ds := Delayed_Send{m = &m, val = 222}
	th := thread.create(proc(th: ^thread.Thread) {
		d := cast(^Delayed_Send)th.data
		time.sleep(50 * time.Millisecond)
		r := mailbox_send(d.m, d.val)
		assert(r == .Ok, "delayed send has ample room and an open mailbox; must not fail")
	})
	th.data = &ds
	thread.start(th)

	msg2, ok2 := mailbox_recv(&m)
	thread.join(th)
	thread.destroy(th)

	testing.expect(t, ok2, "recv should deliver the delayed send, not report closed")
	v2, is_int2 := msg2.(int)
	testing.expect(t, is_int2, "recv message should be an int")
	if is_int2 { testing.expect_value(t, v2, 222) }
}
