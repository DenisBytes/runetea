package runetea

import "core:nbio"
import "core:strings"
import "core:sys/posix"

// nbio-hosted variant of run() (tea.odin). See
// docs/superpowers/nbio-decision.md for the full comparison and the T1
// LAND/ABANDON call; this function exists to test spec §6's central claim --
// "the nbio event loop IS RuneTea's event loop" -- in isolation, without
// touching run()'s proven poll-thread path (loop.odin's Fd_Source + tea.odin's
// reader thread), which 52 T0 tests depend on and which is UNCHANGED by
// anything in this file.
//
// Structural differences from run():
//
//   - Takes a raw fd, not an ^Input_Source. nbio.associate_handle needs a
//     real OS handle to hand the kernel; Input_Source's vtable (poll-then-
//     blocking-read on a second thread, cancelled by a self-pipe) has no
//     meaningful nbio implementation -- there is nothing to "poll" when reads
//     are already async callbacks, and nothing to "cancel via wake byte" when
//     there is no second thread blocked anywhere. A byte-slice/testing
//     backend for run_nbio needs its own seam (an in-process pipe, as
//     loop_nbio_test.odin uses) rather than reusing Bytes_Source.
//
//   - No reader thread. Input is decoded inside the nbio read callback
//     (nbio_on_read below), which runs ON THIS function's OWN calling thread
//     -- the thread that acquired the event loop. There is nothing else to
//     join at shutdown, unlike run()'s documented "input_wake before join"
//     contract: once this loop stops calling nbio.tick(), no further callback
//     can ever fire (nbio's own scheduling guarantee -- see core:nbio/doc.odin
//     "Callbacks are guaranteed to be invoked in a later tick, never
//     synchronously"), so simply not calling tick() again IS the shutdown.
//
//   - Cmd results and signal messages still travel over the same thread-safe
//     Mailbox run() uses, but arriving in the mailbox does not by itself wake
//     a thread parked in nbio.tick(): tick() blocks on the io_uring/kqueue/
//     IOCP fd, which knows nothing about the mailbox's semaphore. Dispatcher
//     and Signal_Watcher's new optional wake/wake_data hook (cmd.odin,
//     signals.odin) closes that gap -- both call nbio_wake (== nbio.wake_up)
//     immediately after a successful mailbox_send. This is the linchpin the
//     whole design in spec §6 depends on; see the direct, isolated proof in
//     tools/nbiowakecheck alongside the full-loop proof here.
run_nbio :: proc(p: ^Program($T), fd: posix.FD, out: ^strings.Builder, flush_fd: posix.FD = -1) -> Run_Error {
	fa: Frame_Arena
	if err := frame_arena_init(&fa); err != nil {
		return Terminal_Error{detail = "frame arena init failed"}
	}
	defer frame_arena_destroy(&fa)

	mbox: Mailbox
	if err := mailbox_init(&mbox, 256); err != nil {
		return Terminal_Error{detail = "mailbox init failed"}
	}
	defer mailbox_destroy(&mbox)

	if aerr := nbio.acquire_thread_event_loop(); aerr != nil {
		return Terminal_Error{detail = "nbio acquire_thread_event_loop failed"}
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	// Same relative ordering as run(), same reason: signal_watcher_start
	// blocks SIGINT/SIGTERM/SIGWINCH on the CALLING thread, and only threads
	// created AFTER that inherit the block (signals.odin's own doc comment).
	// The Dispatcher's pool must therefore start after the watcher, exactly
	// as in run().
	sw: Signal_Watcher
	if flush_fd >= 0 { signal_watcher_start(&sw, &mbox, flush_fd, wake = nbio_wake, wake_data = loop) }
	defer signal_watcher_stop(&sw)

	disp: Dispatcher
	dispatcher_init(&disp, &mbox, 4, wake = nbio_wake, wake_data = loop)
	defer dispatcher_destroy(&disp)

	r: Renderer
	// Same width-seeding rationale as run() (tea.odin) -- see the comment
	// there. Mirrored rather than shared because run() takes an ^Input_Source
	// with its own fd baked in, while run_nbio takes fd and flush_fd
	// separately; flush_fd is still the right one to query here for the same
	// reason it's the right one to write frames to (flush_frame's comment).
	initial_w := 0
	if flush_fd >= 0 {
		if w, _, ok := term_size(flush_fd); ok { initial_w = w }
	}
	renderer_init(&r, out, initial_w)

	// Initial paint, then the init Cmd -- identical to run(), and for the
	// same reason: an app whose first action is asynchronous must still show
	// its loading state immediately.
	//
	// Guarded via the SAME guarded_render (tea.odin) run()'s initial paint
	// uses -- see its doc comment (constraints a/d, tier1-coverage-decision.md)
	// for why this is one shared code path rather than a second hand-copy
	// that could drift. Early return here is safe for the identical reason
	// it is in run(): nothing has been dispatched (dispatch(init_cmd) is the
	// next line) and no read is in flight (nbio_issue_read is further below),
	// so every defer already registered above tears down with nothing
	// outstanding.
	if e := guarded_render(p, &fa, &r, out, flush_fd); e != nil { return e }
	if !cmd_is_nil(p.init_cmd) { dispatch(&disp, p.init_cmd) }

	rc: Nbio_Read_Ctx
	rc.mailbox = &mbox
	rc.legacy  = p.legacy
	h, aerr := nbio.associate_handle(uintptr(fd))
	if aerr != nil { return Terminal_Error{detail = "nbio associate_handle failed"} }
	rc.handle = h
	defer {
		delete(rc.pending)
		delete(rc.keys)
		delete(rc.enh)
		// Any entries still sitting unflushed (only reachable if the mailbox
		// closed mid-flush -- see nbio_flush_backlog) were boxed but never
		// handed to apply(), so nothing else will ever free them; box_free
		// them here rather than leaving them for delete(rc.backlog) below,
		// which only reclaims the [dynamic]any's own backing slice, not what
		// each element's box() call allocated.
		for i in rc.backlog_pos ..< len(rc.backlog) { box_free(rc.backlog[i], context.allocator) }
		delete(rc.backlog)
	}
	nbio_issue_read(&rc)

	for !p.quit {
		// Drain everything currently queued -- Key_Msgs the last tick's read
		// callback decoded, plus any Cmd/signal result that arrived and
		// called nbio_wake before we reached this point (mailbox_send and
		// nbio.wake_up cannot lose a wakeup relative to this drain: wake_up
		// writes to a SEMAPHORE-flagged eventfd, whose count persists
		// regardless of send-vs-wait ordering -- see the decision doc's
		// answer to 2b).
		for {
			msg, ok := mailbox_try_recv(&mbox)
			if !ok { break }
			if e := apply(p, msg, &fa, &disp, &r, out, flush_fd); e != nil { return e }
			if p.quit { break }
		}
		if p.quit { break }

		// Backpressure: a read that decoded more keys than the mailbox has
		// room for right now (e.g. a large paste) leaves them here instead of
		// spinning inside nbio_on_read -- there is no second thread on this
		// design for a spin-and-retry to yield to, so a blocking retry INSIDE
		// the callback would self-deadlock: the only thing that ever drains
		// the mailbox is this loop, and the callback runs on this same
		// thread, borrowed by nbio.tick(). See nbio_flush_backlog's own
		// comment. No new read is issued while backlog is nonempty, so
		// calling nbio.tick() here would have nothing to wake it -- loop back
		// to draining instead.
		if len(rc.backlog) > rc.backlog_pos {
			if nbio_flush_backlog(&rc) { break }   // mailbox closed mid-flush
			continue
		}

		if mailbox_closed_and_empty(&mbox) { break }   // EOF, drained -- mirrors run()'s mailbox_recv ok=false

		if terr := nbio.tick(); terr != nil {
			return Terminal_Error{detail = "nbio tick failed"}
		}
	}
	return nil
}

@(private = "file")
nbio_wake :: proc(data: rawptr) {
	nbio.wake_up(cast(^nbio.Event_Loop)data)
}

@(private = "file")
Nbio_Read_Ctx :: struct {
	mailbox:     ^Mailbox,
	handle:      nbio.Handle,
	buf:         [1024]u8,
	pending:     [dynamic]u8,        // undecoded tail (partial escape/UTF-8 sequence)
	keys:        [dynamic]Key_Msg,   // scratch, reused every callback
	// The terminal's answer to term_enter_raw's keyboard-enhancement query
	// (term.odin) -- a different Msg type, so decode_keys reports it on its
	// own stream. Scratch, reused every callback, same as `keys`.
	enh:         [dynamic]Keyboard_Enhancements_Msg,
	legacy:      Legacy_Key_Encoding, // copy of Program.legacy; see its comment
	// Boxed (via context.allocator), not raw Key_Msg -- box()'s own MESSAGE
	// OWNERSHIP CONTRACT (arena.odin) requires anything that reaches the
	// mailbox to be a real box() allocation, not an implicit `any` pointing
	// into this dynamic array's own backing storage. That was the ORIGINAL
	// shape here (`mailbox_send(rc.mailbox, rc.backlog[rc.backlog_pos])`
	// with `backlog: [dynamic]Key_Msg`) and it happened to work only because
	// nothing downstream ever freed a message; the moment apply() started
	// calling box_free() on every message (the T1 message-ownership fix,
	// see docs/superpowers/message-ownership-decision.md), that pattern
	// surfaced as Tracking_Allocator "bad free" reports -- free() was being
	// called on a pointer into the middle of this array's buffer, not on a
	// new()'d block's start address. Boxing once here, at append time, also
	// means a .Full retry in nbio_flush_backlog resends the SAME allocation
	// rather than boxing (and leaking) a fresh one on every retry attempt.
	backlog:     [dynamic]any,
	backlog_pos: int,                // next unsent index into backlog
}

@(private = "file")
nbio_issue_read :: proc(rc: ^Nbio_Read_Ctx) {
	op := nbio.read(rc.handle, 0, rc.buf[:], nbio_on_read)
	op.user_data[0] = rc
}

// Runs on the loop thread, inside nbio.tick(). Precondition (see run_nbio and
// nbio_flush_backlog): rc.backlog is always empty when a read is in flight,
// so appending fresh keys here never clobbers an unflushed one.
@(private = "file")
nbio_on_read :: proc(op: ^nbio.Operation) {
	rc := cast(^Nbio_Read_Ctx)op.user_data[0]

	// .EOF is the expected terminal case (input closed). Any other error is
	// treated the same way tea.odin's reader_thread treats a failed read:
	// input is gone, so close the mailbox and let run_nbio's main loop
	// unwind via mailbox_closed_and_empty.
	if op.read.err != nil || op.read.read <= 0 {
		mailbox_close(rc.mailbox)
		return
	}

	n := op.read.read
	append(&rc.pending, ..rc.buf[:n])
	clear(&rc.keys)
	clear(&rc.enh)
	consumed := decode_keys(rc.pending[:], &rc.keys, rc.legacy, &rc.enh)
	if consumed > 0 { remove_range(&rc.pending, 0, consumed) }

	// Boxed here, once per key, via context.allocator -- same convention as
	// tea.odin's reader_thread -- so every message that ever reaches the
	// mailbox is a genuine box() allocation. See Nbio_Read_Ctx's own comment
	// on `backlog` for why this replaced sending rc.keys' elements directly.
	for k in rc.keys { append(&rc.backlog, box(k, context.allocator)) }
	for e in rc.enh  { append(&rc.backlog, box(e, context.allocator)) }
	nbio_flush_backlog(rc)
}

// Tries to push everything in rc.backlog into the mailbox without blocking,
// and issues the next read ONLY once the backlog is fully drained. Called
// from nbio_on_read (right after decoding) and from run_nbio's own loop
// (after every drain, while backlog remains nonempty).
//
// Deliberately does NOT retry-with-yield the way tea.odin's reader_thread
// and cmd.odin's deliver_result do on Full: those run on a thread DIFFERENT
// from the one draining the mailbox, so yielding lets the drainer make
// progress concurrently. Here the "drainer" is run_nbio's own for loop on
// THIS SAME thread -- a blocking retry inside this callback would prevent
// that loop from ever running again, hanging exactly the way the FIX 1
// mailbox-full regression (addendum, spike-findings.md) hung the reader-
// thread path before it was fixed there. The fix here is architectural
// rather than a yield: stop, remember how far we got, and let the caller's
// own event-loop iteration make room before asking again.
//
// Returns true if the mailbox was closed mid-flush (caller should stop).
@(private = "file")
nbio_flush_backlog :: proc(rc: ^Nbio_Read_Ctx) -> (closed: bool) {
	for rc.backlog_pos < len(rc.backlog) {
		switch mailbox_send(rc.mailbox, rc.backlog[rc.backlog_pos]) {
		case .Ok:
			rc.backlog_pos += 1
		case .Full:
			return false
		case .Closed:
			return true
		}
	}
	clear(&rc.backlog)
	rc.backlog_pos = 0
	nbio_issue_read(rc)
	return false
}
