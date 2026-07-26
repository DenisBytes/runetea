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
mailbox_destroy :: proc(m: ^Mailbox, allocator := context.allocator) {
	assert(sync.mutex_try_lock(&m.mutex),
		"mailbox_destroy: called while another thread holds the mailbox lock " +
		"(a send/recv is in flight) -- stop and join all producers first")
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
