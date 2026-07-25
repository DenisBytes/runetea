package runetea

import "core:testing"
import "core:thread"

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
			for j in 0 ..< PER { _ = mailbox_send(p.m, p.vals[j]) }
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
	testing.expect(t, mailbox_send(&m, 1), "first send should succeed")
	testing.expect(t, mailbox_send(&m, 2), "second send should succeed")
	testing.expect(t, !mailbox_send(&m, 3), "third send should report full")
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
