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

mailbox_destroy :: proc(m: ^Mailbox, allocator := context.allocator) {
	delete(m.buf, allocator)
	m^ = {}
}

// Returns false if the mailbox is closed or full. Safe from any thread.
mailbox_send :: proc(m: ^Mailbox, msg: any) -> bool {
	sync.mutex_lock(&m.mutex)
	if m.closed || m.len == len(m.buf) {
		sync.mutex_unlock(&m.mutex)
		return false
	}
	m.buf[m.tail] = msg
	m.tail = (m.tail + 1) % len(m.buf)
	m.len += 1
	sync.mutex_unlock(&m.mutex)
	sync.sema_post(&m.items)
	return true
}

// Blocks until a message is available. ok=false once closed and drained.
mailbox_recv :: proc(m: ^Mailbox) -> (msg: any, ok: bool) {
	sync.sema_wait(&m.items)
	sync.mutex_lock(&m.mutex)
	defer sync.mutex_unlock(&m.mutex)
	if m.len == 0 { return nil, false }
	msg = m.buf[m.head]
	m.head = (m.head + 1) % len(m.buf)
	m.len -= 1
	return msg, true
}

// Non-blocking. Used by the event loop, which must never block on the mailbox
// because nbio owns the blocking wait.
mailbox_try_recv :: proc(m: ^Mailbox) -> (msg: any, ok: bool) {
	sync.mutex_lock(&m.mutex)
	defer sync.mutex_unlock(&m.mutex)
	if m.len == 0 { return nil, false }
	msg = m.buf[m.head]
	m.head = (m.head + 1) % len(m.buf)
	m.len -= 1
	return msg, true
}

mailbox_close :: proc(m: ^Mailbox) {
	sync.mutex_lock(&m.mutex)
	m.closed = true
	sync.mutex_unlock(&m.mutex)
	sync.sema_post(&m.items)  // wake the consumer so it observes closure
}
