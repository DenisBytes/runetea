package runetea

import "core:mem"
import "core:sync"

// Buffered MPSC mailbox.
//
// NEVER replace this with an unbuffered core:sync/chan. That implementation has
// a single `unbuffered_data` slot and releases the mutex inside `sync.wait`, so
// a second sender overwrites the slot before the receiver copies it. Measured:
// 4 producers x 250 unique values -> 629 received, 371 lost.
Mailbox :: struct {
	buf:    []any,
	head:   int,        // consumer index
	tail:   int,        // producer index
	len:    int,
	mutex:  sync.Mutex,
	items:  sync.Sema,  // counts queued messages
	closed: bool,
}

mailbox_init :: proc(m: ^Mailbox, cap: int, allocator := context.allocator) -> mem.Allocator_Error {
	assert(cap > 0, "mailbox capacity must be positive")
	m.buf = make([]any, cap, allocator) or_return
	return nil
}

// Frees the mailbox's backing buffer and zeroes the struct (including the
// mutex and semaphore).
//
// PRECONDITION: every producer that might call mailbox_send must be stopped
// and joined, and no thread may be inside mailbox_recv / mailbox_try_recv,
// before this is called. Destroying a mailbox that a producer is still
// sending into is a use-after-free; zeroing a mutex/semaphore out from under
// a thread that holds or waits on it is undefined behavior. Task 5's thread
// pool and Task 7's signal-watcher thread are exactly the long-lived
// producers that must be joined first.
//
// Best-effort guard: asserts the mutex is uncontended at the moment of the
// call, which catches the common case of destroying while a send/recv is
// in flight. It cannot catch a producer that is about to call mailbox_send
// but hasn't reached the lock yet -- that ordering is still on the caller.
//
// DRAINS AND FREES WHATEVER IS STILL QUEUED, and that is not tidiness -- it
// closes a leak on the ordinary exit path, not an exotic one. apply()
// (tea.odin) is the single place a boxed Msg is box_free'd, and it only ever
// sees messages it actually dequeued; anything sitting behind the Quit_Msg
// that ended the session -- or behind a Panicked_Error / Interrupted_Error /
// Terminal_Error early return -- was boxed by a producer and then simply
// abandoned here. loop_nbio.odin:129 already box_frees leftover BACKLOG
// entries with a comment explaining that boxed-but-never-applied messages
// have no other owner; the ring 74 lines above it was the same case with the
// reasoning missing rather than a stated tradeoff.
//
// context.allocator, not `allocator`: the parameter names the allocator that
// made the RING (m.buf), which is not necessarily the one that boxed the
// messages inside it. Every producer in this package boxes with its own
// context.allocator, and every producer thread inherits the dispatching
// thread's context (init_context = context, cmd.odin/timer.odin), so
// context.allocator here is the same instance -- the identical convention
// apply()'s own box_free call already relies on. A caller that boxes through
// some other allocator and destroys the mailbox under a different context is
// outside that convention and always was.
//
// box_free is safe on a nil-data `any` (arena.odin), which is exactly what a
// queued zero-sized Msg such as Quit_Msg is, so no entry needs special-casing.
//
// ONE PRECONDITION THIS MAKES ENFORCEABLE RATHER THAN NEW: every `any` handed
// to mailbox_send must be a box() allocation, never a bare `any` pointing at a
// stack local, a literal or a struct field. That was ALWAYS the contract --
// apply() (tea.odin) box_free's every message it dequeues, so a non-boxed
// entry was already a free() of a pointer no allocator issued -- but until the
// drain below existed, a message that was never dequeued escaped the
// consequence. It no longer does, and the failure is loud (odin test's
// Tracking_Allocator reports `bad free @ arena.odin:box_free()`) rather than
// silent. mailbox_test.odin's test_mailbox_reports_full is the one call site
// in the repo that was relying on the escape hatch; it now boxes.
mailbox_destroy :: proc(m: ^Mailbox, allocator := context.allocator) {
	assert(sync.mutex_try_lock(&m.mutex),
		"mailbox_destroy: called while another thread holds the mailbox lock " +
		"(a send/recv is in flight) -- stop and join all producers first")
	// Under the lock the assert just took, so the drain observes exactly the
	// state the assert proved was quiescent. m.items is deliberately NOT
	// rebalanced as messages come off: nothing may be waiting on it by this
	// point (the precondition above), and the whole struct is zeroed two
	// lines below anyway.
	for {
		msg, ok := mailbox_pop(m)
		if !ok { break }
		box_free(msg, context.allocator)
	}
	sync.mutex_unlock(&m.mutex)
	delete(m.buf, allocator)
	m^ = {}
}

// FULL and CLOSED are deliberately distinct outcomes, not both folded into a
// single `false` -- see mailbox_send's doc comment for why conflating them
// was a real bug (FIX 1, final fix-wave report): a producer that treats a
// momentarily-full mailbox the same as a permanently-closed one gives up
// and never sends again, even though the consumer is still draining and
// would have made room a moment later.
Mailbox_Send_Result :: enum { Ok, Full, Closed }

// Reports Ok, Full, or Closed -- see Mailbox_Send_Result. Safe from any
// thread.
//
// Full is a TRANSIENT condition: the consumer may still be actively
// draining, and a later send with the same message can succeed. Closed is
// TERMINAL: the mailbox is being torn down and no future send can ever
// succeed. Callers that busy-loop retrying on Full must check for Closed on
// every attempt and give up then, or they risk retrying forever against a
// mailbox that will never accept anything again. Callers that don't want to
// retry (e.g. because giving up on Full is an acceptable, documented
// tradeoff for that call site) must say so explicitly rather than silently
// discarding via `_ = mailbox_send(...)` -- that spelling was exactly what
// let a full-vs-closed conflation hide as a silent message drop in more
// than one call site before this fix.
mailbox_send :: proc(m: ^Mailbox, msg: any) -> Mailbox_Send_Result {
	sync.mutex_lock(&m.mutex)
	if m.closed {
		sync.mutex_unlock(&m.mutex)
		return .Closed
	}
	if m.len == len(m.buf) {
		sync.mutex_unlock(&m.mutex)
		return .Full
	}
	m.buf[m.tail] = msg
	m.tail = (m.tail + 1) % len(m.buf)
	m.len += 1
	// Post while still holding the lock. This guarantees that any thread
	// which later locks the mutex and observes the new m.len has this
	// message's credit already sitting in the semaphore -- see mailbox_pop
	// and mailbox_try_recv below, which depend on that ordering to prove
	// their sema_wait calls cannot block.
	sync.sema_post(&m.items)
	sync.mutex_unlock(&m.mutex)
	return .Ok
}

// Must be called with m.mutex held. Pops one message off the ring buffer,
// or reports ok=false if it's empty. Does not touch the semaphore -- callers
// are responsible for keeping m.items in lockstep with the buffer.
@(private)
mailbox_pop :: proc(m: ^Mailbox) -> (msg: any, ok: bool) {
	if m.len == 0 { return nil, false }
	msg = m.buf[m.head]
	m.head = (m.head + 1) % len(m.buf)
	m.len -= 1
	return msg, true
}

// Blocks until a message is available. ok=false once closed and drained.
mailbox_recv :: proc(m: ^Mailbox) -> (msg: any, ok: bool) {
	sync.sema_wait(&m.items)
	sync.mutex_lock(&m.mutex)
	defer sync.mutex_unlock(&m.mutex)
	return mailbox_pop(m)
}

// Non-blocking. Used by the event loop, which must never block on the mailbox
// because nbio owns the blocking wait.
mailbox_try_recv :: proc(m: ^Mailbox) -> (msg: any, ok: bool) {
	sync.mutex_lock(&m.mutex)
	msg, ok = mailbox_pop(m)
	sync.mutex_unlock(&m.mutex)
	if ok {
		// Consume the credit mailbox_send posted for this message so
		// m.items stays in lockstep with the buffer. This cannot block:
		// mailbox_pop only returns ok=true after observing m.len > 0 under
		// the lock, and mailbox_send posts before it unlocks, so this
		// message's credit is already present in the semaphore by the time
		// we get here. (Relies on a single consumer, as documented for the
		// whole mailbox; concurrent recv/try_recv callers would still stay
		// balanced in aggregate but an individual call could then observe
		// a transient wait.)
		sync.sema_wait(&m.items)
	}
	return
}

mailbox_close :: proc(m: ^Mailbox) {
	sync.mutex_lock(&m.mutex)
	m.closed = true
	sync.mutex_unlock(&m.mutex)
	sync.sema_post(&m.items)  // wake the consumer so it observes closure
}

// True once the mailbox is closed AND fully drained -- the non-blocking
// equivalent of mailbox_recv's ok=false return. Needed by any consumer that
// polls via mailbox_try_recv instead of blocking in mailbox_recv (loop_nbio.odin's
// run_nbio, which must never block on the mailbox -- nbio owns the blocking
// wait): try_recv's own ok=false is ambiguous between "empty for now, a
// producer may still send" and "closed, nothing will ever arrive again",
// and only this call, taken under the same lock as every other mailbox
// operation, can tell the two apart without racing mailbox_close.
mailbox_closed_and_empty :: proc(m: ^Mailbox) -> bool {
	sync.mutex_lock(&m.mutex)
	defer sync.mutex_unlock(&m.mutex)
	return m.closed && m.len == 0
}
