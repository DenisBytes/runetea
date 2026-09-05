package runetea

import "core:nbio"
import "core:strings"
import "core:sys/posix"
import "core:time"

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
//
//   - DECODED INPUT DOES NOT USE THE MAILBOX AT ALL, and this is the one
//     place the two hosts genuinely diverge rather than merely differ in
//     plumbing. run()'s reader is a separate thread, so its keys have to
//     cross a thread boundary and the Mailbox is exactly the right thing for
//     that. Here they do not cross one -- nbio_on_read decodes them on this
//     same thread, inside nbio.tick() -- so they go straight into
//     Nbio_Read_Ctx.backlog and the loop applies them from there. Routing
//     them through the Mailbox instead put the keyboard in a capacity fight
//     with the app's own timers and Cmds that it could lose permanently; see
//     the loop's own comment for the measurement. What follows from it: in
//     this host a keystroke that arrives while Cmd results are queued is
//     applied BEFORE them, whereas run() interleaves the two in mailbox
//     arrival order. Order WITHIN the input stream is identical in both.
run_nbio :: proc(p: ^Program($T), fd: posix.FD, out: ^strings.Builder, flush_fd: posix.FD = -1) -> Run_Error {
	fa: Frame_Arena
	if err := frame_arena_init(&fa); err != nil {
		return Terminal_Error{detail = "frame arena init failed"}
	}
	defer frame_arena_destroy(&fa)

	// Resolved once, and used both as the mailbox's capacity and as this
	// host's coalescing budget -- the two are the same number by construction
	// (Program.mailbox_cap, tea.odin).
	mbox_cap := program_mailbox_cap(p)

	// HEAP-ALLOCATED, in a Reap_Ctx, for exactly the reason run() does it: so
	// that quitting can be BOUNDED. See Reap_Ctx's own doc comment (cmd.odin).
	// A Cmd still running when the user quits may keep touching this
	// Dispatcher's pool and this Mailbox for as long as it runs, so both must
	// be able to outlive run_nbio's stack frame -- which a `mbox: Mailbox` /
	// `disp: Dispatcher` local, which is what these were, can never do.
	//
	// WHAT THE LOCALS COST. run_nbio tore down with `defer
	// dispatcher_destroy(&disp)`, which blocks in thread.pool_finish until
	// every in-flight Cmd returns. So quitting an application took as long as
	// its slowest Cmd, with the terminal already restored and nothing on
	// screen: press q against a Cmd sleeping 10 s and the shell prompt came
	// back 10 s later. run() has been bounded at QUIT_GRACE since the
	// cancellation work; this host simply never got the same treatment, and
	// LIMITATIONS 2.6 recorded the divergence rather than closing it.
	reap := new(Reap_Ctx, context.allocator)
	if reap == nil {
		return Terminal_Error{detail = "dispatcher/mailbox allocation failed"}
	}
	if err := mailbox_init(&reap.mbox, mbox_cap); err != nil {
		free(reap, context.allocator)
		return Terminal_Error{detail = "mailbox init failed"}
	}

	if aerr := nbio.acquire_thread_event_loop(); aerr != nil {
		mailbox_destroy(&reap.mbox)
		free(reap, context.allocator)
		return Terminal_Error{detail = "nbio acquire_thread_event_loop failed"}
	}
	loop := nbio.current_thread_event_loop()

	// Same relative ordering as run(), same reason: signal_watcher_start
	// blocks SIGINT/SIGTERM/SIGWINCH on the CALLING thread, and only threads
	// created AFTER that inherit the block (signals.odin's own doc comment).
	// The Dispatcher's pool must therefore start after the watcher, exactly
	// as in run().
	//
	// THE RETURN VALUE IS CHECKED, as run() has always checked it. It used to
	// be discarded here, so a failed pthread_create left a program that looked
	// fine and silently answered no SIGINT, no SIGTERM and no SIGWINCH for the
	// rest of its life -- the resize half of that being invisible until the
	// user resized. The two hosts now fail the same way, at the same point,
	// with the same message.
	sw: Signal_Watcher
	if flush_fd >= 0 && !signal_watcher_start(&sw, &reap.mbox, flush_fd, wake = nbio_wake, wake_data = loop) {
		nbio.release_thread_event_loop()
		mailbox_destroy(&reap.mbox)
		free(reap, context.allocator)
		return Terminal_Error{detail = "could not start the signal watcher thread (pthread_create failed)"}
	}

	dispatcher_init(&reap.disp, &reap.mbox, 4, wake = nbio_wake, wake_data = loop)

	// ONE ORDERED TEARDOWN, written as a single deferred block rather than as
	// three separate defers, because all three steps have to happen in an
	// order that defer's LIFO rule cannot express here on its own -- the nbio
	// release has to sit BETWEEN two things whose own setup order is fixed.
	//
	// 1. signal_watcher_stop FIRST. dispatcher_reap's PRECONDITION (cmd.odin)
	//    is that every OTHER producer into the mailbox is already stopped and
	//    joined by the time it is called, because it hands the mailbox to a
	//    background thread that will free it. The watcher is that other
	//    producer.
	//
	// 2. dispatcher_reap SECOND, with the same QUIT_GRACE run() uses. This is
	//    the whole change: it fires the cancellation token, closes the mailbox
	//    (so a Cmd finishing after this point gets .Closed and discards its
	//    result instead of retrying against a queue nobody drains -- the same
	//    "orphaned results are discarded" rule run() has always had), and then
	//    joins the pool on a BACKGROUND thread, waiting at most QUIT_GRACE for
	//    that to finish. Closing the mailbox on the teardown path is what the
	//    now-deleted `defer mailbox_close(&mbox)` was for; dispatcher_reap does
	//    it as its very first act, which is where run() has always got the same
	//    guarantee from, so the explicit defer is redundant rather than lost.
	//
	// 3. release_thread_event_loop LAST, AND ONLY IF THE REAP FINISHED IN
	//    TIME. This is the one genuinely subtle ordering constraint in this
	//    function, and it is why the release is not simply an early `defer`
	//    the way it used to be. This Dispatcher is built with
	//    `wake = nbio_wake, wake_data = loop`, so every pool worker and every
	//    timer fire calls nbio.wake_up(loop) after a successful delivery. If
	//    the loop were released while a worker could still do that, the wake
	//    would be a use-after-free on the event loop. A reap that returned
	//    TRUE is proof there is no such worker left: the reaper thread ran
	//    dispatcher_destroy to completion, which joins every pool worker and
	//    every detached Cmd. A reap that returned FALSE is proof of the
	//    opposite, so the loop is DELIBERATELY NOT RELEASED on that path --
	//    a bounded, one-per-session leak of a thread-local event loop, taken
	//    knowingly, on the pathological path where a Cmd has already outlived
	//    its cancellation by more than QUIT_GRACE. Freeing it there would
	//    trade a leak for a crash.
	//
	// p.reaper_pending carries the same meaning it does for run() -- see its
	// field comment (tea.odin) for what a caller must do about a `true`.
	defer view_leak_report(p.view_leak_frames, p.view_leak_blocks, p.view_leak_bytes)
	defer {
		signal_watcher_stop(&sw)
		finished := dispatcher_reap(reap, QUIT_GRACE)
		p.reaper_pending = !finished
		if finished { nbio.release_thread_event_loop() }
	}
	// (Historical note, kept because it is the reason the mailbox is closed on
	// the teardown path at all.)
	// CLOSE THE MAILBOX BEFORE TEARING DOWN ANYTHING THAT CAN STILL SEND INTO
	// IT. This used to be a bare `defer mailbox_close(&mbox)` declared
	// immediately after dispatcher_destroy's defer, so that
	// LIFO ordering ran it FIRST of the two -- which is the same invariant
	// run() gets from dispatcher_reap (cmd.odin closes the mailbox as its very
	// first act) and from its reader-teardown defer.
	//
	// WHAT ITS ABSENCE COST. run_nbio used to call mailbox_close in exactly one
	// place -- the EOF branch of nbio_on_read -- and never on the quit or error
	// teardown path. So `defer dispatcher_destroy(&disp)` ran against a mailbox
	// that was still OPEN and that nothing was draining any more, and every
	// producer in this package retries forever on Full precisely because Full is
	// documented as transient (mailbox.odin): a pool worker or detached Cmd in
	// deliver_result, a timer fire, a Signal_Watcher message in send_or_retry.
	// Any one of them landing on a full queue spun there for the rest of the
	// process's life, thread.pool_finish never returned, and the process hung
	// with the terminal still in raw mode and the alternate screen still up,
	// burning a core per stuck producer.
	//
	// It did not need a panic or anything exotic to reach: an ordinary
	// quit_cmd() quit with a repeating every() running and one Cmd still in
	// flight is enough, because dispatcher_destroy blocks in thread.pool_finish
	// for that Cmd and only stops the timer service afterwards -- the timer
	// fills the undrained mailbox during exactly that window. That is the shape
	// test_run_nbio_closes_the_mailbox_before_tearing_the_dispatcher_down
	// (loop_nbio_test.odin) drives: every(1 ms), one 1 s Cmd, then quit.
	// Without this line it did not return inside a 10 s bound; with it,
	// 1.003 s 3/3 -- exactly the in-flight Cmd's own duration, which
	// dispatcher_destroy waits for by design, and nothing more. run() on the
	// equivalent program never had the problem, because dispatcher_reap
	// (cmd.odin) closes the mailbox as its very first act.
	//
	// Closing before the pool join also makes the watcher, which is stopped
	// first now, collect cleanly: it sees .Closed and gives up rather than
	// parking in a retry loop.
	//
	// All of that still holds -- dispatcher_reap closes the mailbox as its
	// very first act, before it hands anything to the reaper thread -- so the
	// invariant this comment defends is now enforced by the shared teardown
	// path both hosts use, rather than by a defer only one of them had.

	r: Renderer
	// Same width-seeding rationale as run() (tea.odin) -- see the comment
	// there. Mirrored rather than shared because run() takes an ^Input_Source
	// with its own fd baked in, while run_nbio takes fd and flush_fd
	// separately; flush_fd is still the right one to query here for the same
	// reason it's the right one to write frames to (flush_frame's comment).
	// The HEIGHT is threaded through here for the same reason and with the same
	// degradation rules as in run() (T2-C) -- see the fuller note there.
	initial_w := 0
	initial_h := 0
	if flush_fd >= 0 {
		if w, h, ok := term_size(flush_fd); ok { initial_w, initial_h = w, h }
	}
	// THE USER'S RENDER-MODE PREFERENCE OVERRIDES THE APPLICATION'S, and only
	// in the direction that gives the terminal back: $RUNETEA_INLINE can force
	// .Inline, nothing can force a viewport-owning mode on an application that
	// did not ask for one. Resolved here rather than by mutating p.render_mode,
	// so the Program a caller handed in is not rewritten under it and can still
	// be inspected for what the APPLICATION wanted. See A11y_Prefs.inline_only
	// for why this is separate from no_alt (LIMITATIONS 11.2).
	mode := p.render_mode
	if a11y_prefs().inline_only { mode = .Inline }
	renderer_init(&r, out, initial_w, initial_h, mode)
	// T3-A: .Diff allocates two cell grids on its first sized frame; the
	// other two modes allocate nothing and this is a no-op for them. Deferred
	// right at construction so no early return -- and there are several, on
	// every panic path -- can skip it. tools/test.sh's leak audit is the gate
	// that would catch it if one did.
	defer renderer_destroy(&r)

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
	if !cmd_is_nil(p.init_cmd) { dispatch(&reap.disp, p.init_cmd) }

	rc: Nbio_Read_Ctx
	rc.mailbox = &reap.mbox
	rc.legacy  = p.legacy
	h, aerr := nbio.associate_handle(uintptr(fd))
	if aerr != nil { return Terminal_Error{detail = "nbio associate_handle failed"} }
	rc.handle = h
	defer {
		delete(rc.pending)
		delete(rc.keys)
		delete(rc.enh)
		delete(rc.st.markers)
		// Any entries still sitting unapplied (only reachable when the loop
		// broke out mid-backlog -- a quit, a panic, a write failure) were
		// boxed but never handed to apply_msg, so nothing else will ever free
		// them; box_free them here rather than leaving them for
		// delete(rc.backlog) below, which only reclaims the [dynamic]any's own
		// backing slice, not what each element's box() call allocated.
		for i in rc.backlog_pos ..< len(rc.backlog) { box_free(rc.backlog[i], context.allocator) }
		delete(rc.backlog)
	}
	nbio_issue_read(&rc)

	for !p.quit {
		// ONE ITERATION = apply the decoded input this thread is already
		// holding, then apply what is queued in the mailbox, then paint ONCE.
		// Identical shape to run()'s loop, by the same pair of shared procs
		// (apply_msg then guarded_render); see run()'s own comment for why
		// `dirty` is what keeps a quit from inventing an extra frame, and
		// apply_msg's for the amplification measurements that forced the
		// split.
		dirty := false

		// ---- INPUT FIRST, AND WITHOUT GOING THROUGH THE MAILBOX AT ALL ----
		//
		// This used to push decoded keys into the mailbox (nbio_flush_backlog)
		// and let the drain below pick them up, which put the keyboard in
		// direct competition with the Cmd/timer/signal producers for the 256
		// slots -- and lose. Under a producer that keeps the queue saturated,
		// mailbox_send returned .Full on every attempt the loop ever made, so
		// the key sat in this backlog forever. That is not a hypothetical
		// interaction of two bugs: with the drain bounded (below) but the keys
		// still routed through the mailbox, a 'q' written 500 ms into a session
		// running every(1 ms) against 2 ms of work per message was still
		// undelivered 20 s later -- the drain frees 256 slots and the timer
		// refills all 256 during the very same 512 ms the drain takes, so the
		// queue is never once observed with room in it.
		//
		// The mailbox exists to get messages ACROSS A THREAD BOUNDARY. These
		// did not cross one: nbio_on_read decoded them on THIS thread, inside
		// nbio.tick(), a few lines below. Round-tripping them through a
		// mutex-guarded, fixed-capacity, thread-safe ring bought nothing and
		// cost the keyboard its liveness. Applying them directly is both
		// simpler and strictly stronger: input can no longer be delayed,
		// dropped or reordered by how busy the app's own timers are.
		//
		// The trade this makes explicit: a keystroke that arrives while Cmd
		// results are queued is now applied BEFORE them, rather than behind
		// them. There was never a meaningful arrival order between two
		// different producers to preserve -- what does have to hold is the
		// order WITHIN the input stream (Paste_Start_Msg before the first
		// pasted character, a Mouse_Msg before whatever was typed after the
		// click), and that is exactly what this array preserves.
		//
		// Unbounded on purpose, unlike the mailbox drain: the backlog holds
		// what ONE 1024-byte read decoded to and nothing refills it while it
		// is being consumed (no new read is issued until it is empty), so
		// "everything already here" is a bounded, self-limiting quantity --
		// the definition of the coalescing rule rather than an exception to it.
		for rc.backlog_pos < len(rc.backlog) {
			msg := rc.backlog[rc.backlog_pos]
			rc.backlog_pos += 1
			e, updated := apply_msg(p, msg, &fa, &reap.disp, &r)
			if updated { dirty = true }
			if e != nil { return e }
			if p.quit { break }
		}
		if rc.backlog_pos >= len(rc.backlog) {
			clear(&rc.backlog)
			rc.backlog_pos = 0
			// Re-arm. `reading` is what makes this safe to ask every
			// iteration: nbio_on_read clears it, and a second read submitted
			// while one is in flight would race two callbacks over rc.buf.
			// It also has to be asked HERE rather than at the end of
			// nbio_on_read, because a read that decodes to nothing at all --
			// the first byte of a multi-byte escape sequence, half a UTF-8
			// rune -- leaves the backlog empty, and the old code's
			// "re-issue from inside the flush" then never fired: the loop
			// would park in tick() with no read outstanding and go deaf for
			// a reason that had nothing to do with the mailbox.
			if !rc.reading && !rc.eof { nbio_issue_read(&rc) }
		}

		// ---- THEN THE MAILBOX (Cmd results, timer fires, signals) ----
		//
		// Whatever arrived and called nbio_wake before we reached this point
		// is here (mailbox_send and nbio.wake_up cannot lose a wakeup relative
		// to this drain: wake_up writes to a SEMAPHORE-flagged eventfd, whose
		// count persists regardless of send-vs-wait ordering -- see the
		// decision doc's answer to 2b).
		//
		// THE DRAIN IS BOUNDED, and that bound is a fix for a hang, not a
		// tuning knob. It used to run to EMPTY, with nbio.tick() -- the ONLY
		// thing that ever completes a read -- sitting below it and reachable
		// only once the mailbox had been observed empty. Any producer that
		// kept the queue topped up therefore had absolute, unbounded priority
		// over reading the keyboard: with a sustained per-message cost above
		// the arrival interval, tick() ran exactly once (loop iteration 1) and
		// never again, so the read completion already sitting in the io_uring
		// completion queue was never reaped, no key was ever decoded, and the
		// program stayed permanently deaf while repainting happily enough to
		// look alive. It is a cliff, not a gradient: every(16 ms) against 12 ms
		// of work per message quits normally, every(16 ms) against 17 ms never
		// sees another keystroke, and so do 16/20 ms and 5/8 ms.
		// test_run_nbio_still_reads_input_while_the_mailbox_never_empties sits
		// well past that cliff (every(1 ms) against 2 ms of work) and writes a
		// 'q' 500 ms in: undelivered after 20 s without this bound and the
		// direct-apply path above, delivered in 1.08 s 3/3 with them.
		//
		// run() never had this failure mode because its reader is a separate
		// thread competing fairly for mailbox slots; here the reader IS this
		// thread.
		saturated := false   // the drain stopped on the budget, not on an empty queue
		for n := 0; n < mbox_cap && !p.quit; n += 1 {
			msg, ok := mailbox_try_recv(&reap.mbox)
			if !ok { break }
			e, updated := apply_msg(p, msg, &fa, &reap.disp, &r)
			if updated { dirty = true }
			if e != nil { return e }
			if n + 1 == mbox_cap { saturated = true }
		}

		if dirty {
			if e := guarded_render(p, &fa, &r, out, flush_fd); e != nil { return e }
		}
		if p.quit { break }

		// EOF, drained -- mirrors run()'s mailbox_recv ok=false. Both queues
		// have to be empty, not just the mailbox: the backlog may still hold
		// the keys decoded from the very read that hit EOF.
		if rc.backlog_pos >= len(rc.backlog) && mailbox_closed_and_empty(&reap.mbox) { break }

		// tick() is reached on EVERY iteration now; only its timeout varies.
		// NO_TIMEOUT (the default, and what this call used to pass
		// unconditionally) parks the thread until the kernel has something,
		// which is exactly right when the drain emptied the queue -- that is
		// the idle path, and it must not spin. But when the drain stopped on
		// the budget there is still work sitting in the mailbox, and blocking
		// here would stall it behind an io_uring completion that may never
		// come; a zero timeout submits and reaps whatever is already ready and
		// returns immediately (core:nbio/impl_linux.odin: timeout == 0 submits
		// with wait_nr 0 and no timespec). So the loop alternates
		// input/drain/paint/poll for as long as producers keep it busy, and
		// blocks only when there is genuinely nothing left to do.
		tick_timeout := nbio.NO_TIMEOUT
		if saturated { tick_timeout = time.Duration(0) }
		if terr := nbio.tick(tick_timeout); terr != nil {
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
	// The decoder's cross-call state and its non-key output, owned by THIS
	// reader (see input.odin's Input_State): `in_paste` has to survive between
	// callbacks, since a paste straddles reads; `markers` is scratch, cleared
	// every callback, and since T2-B carries mouse and focus events alongside
	// the paste boundaries.
	st:          Input_State,
	legacy:      Legacy_Key_Encoding, // copy of Program.legacy; see its comment
	// THE INPUT QUEUE. One nbio read completion decodes into here, and
	// run_nbio's loop applies these to the model directly -- they do NOT go
	// through the Mailbox. See the loop's own comment for why (the Mailbox
	// exists to cross a thread boundary and these never cross one, and routing
	// them through it made the keyboard lose a capacity fight it could not
	// win against a saturating timer).
	//
	// Boxed (via context.allocator), not raw Key_Msg, because apply_msg
	// box_free's every message it is handed -- box()'s MESSAGE OWNERSHIP
	// CONTRACT (arena.odin). That was NOT the original shape here
	// (`backlog: [dynamic]Key_Msg`, sent as an implicit `any` pointing into
	// this array's own backing storage) and it happened to work only because
	// nothing downstream ever freed a message; the moment the loop started
	// calling box_free() on every message (the T1 message-ownership fix, see
	// docs/superpowers/message-ownership-decision.md), that pattern surfaced
	// as Tracking_Allocator "bad free" reports -- free() on a pointer into the
	// middle of a dynamic array's buffer rather than on a new()'d block's
	// start address.
	backlog:     [dynamic]any,
	backlog_pos: int,                // next unapplied index into backlog

	// Is a read op outstanding? Written only on this thread (nbio_issue_read
	// sets it, nbio_on_read clears it), so no atomics: nbio callbacks run on
	// the loop thread, inside nbio.tick(). Two reads in flight at once would
	// race two callbacks over rc.buf, and the loop asks "should I re-arm?"
	// once per iteration, so it needs a way to answer that is not "did the
	// backlog just become empty" -- a read that decodes to nothing (the first
	// byte of an escape sequence, half a UTF-8 rune) leaves the backlog empty
	// without having produced anything.
	reading:     bool,
	// Input is gone (EOF or a read error). Nothing may re-arm a read after
	// this; nbio_on_read has already closed the mailbox and the loop is
	// unwinding.
	eof:         bool,
}

@(private = "file")
nbio_issue_read :: proc(rc: ^Nbio_Read_Ctx) {
	rc.reading = true
	op := nbio.read(rc.handle, 0, rc.buf[:], nbio_on_read)
	op.user_data[0] = rc
}

// Runs on the loop thread, inside nbio.tick(). Precondition, enforced by
// run_nbio's loop: rc.backlog is fully applied and cleared before a read is
// re-armed, so appending fresh keys here never clobbers an unapplied one.
@(private = "file")
nbio_on_read :: proc(op: ^nbio.Operation) {
	rc := cast(^Nbio_Read_Ctx)op.user_data[0]
	rc.reading = false

	// .EOF is the expected terminal case (input closed). Any other error is
	// treated the same way tea.odin's reader_thread treats a failed read:
	// input is gone, so close the mailbox and let run_nbio's main loop
	// unwind via mailbox_closed_and_empty. `eof` stops the loop re-arming a
	// read against a dead fd forever.
	if op.read.err != nil || op.read.read <= 0 {
		rc.eof = true
		mailbox_close(rc.mailbox)
		return
	}

	n := op.read.read
	append(&rc.pending, ..rc.buf[:n])
	clear(&rc.keys)
	clear(&rc.enh)
	clear(&rc.st.markers)
	consumed := decode_keys(rc.pending[:], &rc.keys, rc.legacy, &rc.enh, &rc.st)
	if consumed > 0 { remove_range(&rc.pending, 0, consumed) }

	// Boxed here, once per key, via context.allocator -- same convention as
	// tea.odin's reader_thread -- so every message the loop later box_free's
	// is a genuine box() allocation. See Nbio_Read_Ctx's own comment on
	// `backlog` for why this replaced handing rc.keys' elements on directly.
	//
	// Markers interleave with the keys, for the reason spelled out in
	// tea.odin's copy of this loop: their POSITION is their meaning, so
	// Paste_Start_Msg must be queued before the first pasted character and a
	// Mouse_Msg before whatever the user typed after clicking.
	mi := 0
	for k, idx in rc.keys {
		for mi < len(rc.st.markers) && rc.st.markers[mi].at <= idx {
			append(&rc.backlog, input_marker_box(rc.st.markers[mi]))
			mi += 1
		}
		append(&rc.backlog, box(k, context.allocator))
	}
	for ; mi < len(rc.st.markers); mi += 1 {
		append(&rc.backlog, input_marker_box(rc.st.markers[mi]))
	}
	for e in rc.enh  { append(&rc.backlog, box(e, context.allocator)) }
	// Nothing is sent or flushed from here. run_nbio's loop owns the backlog
	// and re-arms the next read once it has applied it; a callback that also
	// tried to move messages on would be doing so from inside nbio.tick(),
	// on the very thread that has to return to the loop to make progress.
}

