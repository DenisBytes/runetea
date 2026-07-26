package runetea

import "core:mem"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"

Quit_Msg :: struct {}

Killed_Error      :: struct {}
Interrupted_Error :: struct {}
Panicked_Error    :: struct { message: string }
Terminal_Error    :: struct { detail: string }

Run_Error :: union { Killed_Error, Interrupted_Error, Panicked_Error, Terminal_Error }

// Parametric over the model rather than an interface. This is STRONGER checking
// than Go's: Go verifies only method-set conformance, not that Update returns
// the same concrete type. The cost is that the model cannot be swapped for a
// different type mid-run -- use a `state` enum, or make T itself a vtable.
Program :: struct($T: typeid) {
	model:    T,
	update:   proc(model: T, msg: any, alloc: mem.Allocator) -> (T, Cmd),
	view:     proc(model: T, alloc: mem.Allocator) -> string,
	init_cmd: Cmd,
	quit:     bool,
}

// init_cmd is Bubble Tea's `Init() Cmd`: the command fired once before the
// first input is read. Without it, any app whose first action is asynchronous
// (fetch, timer, subprocess) can never start.
program_init :: proc(
	p: ^Program($T),
	model: T,
	update: proc(model: T, msg: any, alloc: mem.Allocator) -> (T, Cmd),
	view: proc(model: T, alloc: mem.Allocator) -> string,
	init_cmd := Cmd{},
) {
	p.model    = model
	p.update   = update
	p.view     = view
	p.init_cmd = init_cmd
	p.quit     = false
}

quit_run :: proc(env: rawptr) -> any { return box(Quit_Msg{}, context.allocator) }

quit_cmd :: proc() -> Cmd {
	return Cmd{procedure = quit_run, env = nil, allocator = context.allocator}
}

// Shared state for the guarded Update call. longjmp discards the frame, so the
// inputs and outputs live outside it.
@(private="file")
Step :: struct($T: typeid) {
	p:     ^Program(T),
	msg:   any,
	alloc: mem.Allocator,
	cmd:   Cmd,
}

// flush_fd >= 0 writes each frame to that fd and resets the builder, which is
// what makes the display update live. Pass -1 (the default) to accumulate the
// whole session in the builder instead -- that is what the golden harness reads.
run :: proc(p: ^Program($T), src: ^Input_Source, out: ^strings.Builder, flush_fd: posix.FD = -1) -> Run_Error {
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

	// Signal_Watcher MUST start before any other thread this function
	// creates (the Dispatcher's pool below, and the reader thread further
	// down): signal_watcher_start installs the blocked-signal mask on the
	// CALLING thread, and a thread created before that mask exists does NOT
	// inherit it -- it keeps the OS default disposition for SIGINT/SIGTERM
	// and stays killable regardless of whether a watcher is running
	// elsewhere (signals.odin's own doc comment on signal_watcher_start
	// documents the empirical proof: one pre-existing unblocked thread was
	// enough to kill the process 5/5 times via SIGINT's default action even
	// with a correctly-blocked watcher present). Without this, run()'s
	// stated premise -- "returns an error rather than dying" -- does not
	// hold for an EXTERNALLY delivered SIGINT (kill -INT, a supervisor,
	// another shell): term_enter_raw only clears ISIG, so a *terminal*-
	// generated Ctrl+C arrives as a raw 0x03 byte through input_read and
	// never touches this at all, but an external signal hits the OS
	// default disposition directly and kills the process outright, no
	// defers run, and the terminal is left raw with the alt screen active.
	//
	// Skipped when flush_fd < 0 (no real terminal -- the golden harness and
	// unit tests over Bytes_Source): there is nothing to protect and no
	// meaningful external-SIGINT target in that path, and starting a
	// watcher anyway would block SIGINT/SIGTERM/SIGWINCH/SIGUSR2 on the
	// CALLING thread for the rest of its life. Under odin test's
	// ODIN_TEST_THREADS=1 that thread is REUSED across every sequential
	// test in the run, so the mask would leak into unrelated tests -- the
	// exact cross-test pollution signals.odin's own SIG_WAKE-vs-SIGUSR1
	// comment already goes out of its way to avoid.
	sw: Signal_Watcher
	if flush_fd >= 0 { signal_watcher_start(&sw, &mbox, flush_fd) }
	// signal_watcher_stop no-ops on a never-started watcher (sw.running is
	// false in its zero value), so this is safe unconditionally. It must
	// run before mailbox_destroy -- the watcher is a mailbox producer, and
	// mailbox_destroy's precondition requires every producer stopped and
	// joined first -- which is why this defer is declared here, ahead of
	// dispatcher_init: LIFO means it fires after dispatcher_destroy but
	// before mailbox_destroy, exactly where it belongs.
	defer signal_watcher_stop(&sw)

	disp: Dispatcher
	dispatcher_init(&disp, &mbox, 4)
	defer dispatcher_destroy(&disp)

	r: Renderer
	renderer_init(&r, out)

	// Initial paint, then the init Cmd -- in that order, so an app whose first
	// action is asynchronous still shows its loading state immediately.
	{
		al := frame_allocator(&fa)
		renderer_render(&r, p.view(p.model, al))
		flush_frame(out, flush_fd)
		frame_reset(&fa)
	}
	if !cmd_is_nil(p.init_cmd) { dispatch(&disp, p.init_cmd) }

	// The mailbox is the SINGLE wait point. A reader thread turns bytes into
	// Key_Msgs and pushes them alongside Cmd results, so an async result
	// updates the view with no keypress -- without this, examples/http shows
	// "Checking..." until the user happens to hit a key.
	//
	// The spike reads on a thread rather than through nbio because the loop
	// still owns rendering; Task 6's nbio path replaces this reader in T1.
	rd := Reader_Ctx{src = src, mailbox = &mbox}
	reader := thread.create(reader_thread)
	reader.data = &rd
	reader.init_context = context
	thread.start(reader)
	defer {
		sync.atomic_store(&rd.stop, true)
		// MUST wake the reader before joining. It parks inside input_read
		// waiting on the tty, and checks `stop` only between reads -- quitting
		// via a UI action rather than a keypress would otherwise hang here
		// forever.
		input_wake(src)
		mailbox_close(&mbox)
		thread.join(reader)
		thread.destroy(reader)
	}

	for !p.quit {
		msg, ok := mailbox_recv(&mbox)
		if !ok { break }   // closed and drained
		if e := apply(p, msg, &fa, &disp, &r, out, flush_fd); e != nil { return e }
	}
	return nil
}

Reader_Ctx :: struct {
	src:     ^Input_Source,
	mailbox: ^Mailbox,
	stop:    bool,
}

@(private="file")
reader_thread :: proc(th: ^thread.Thread) {
	rd := cast(^Reader_Ctx)th.data

	// sigaltstack is per-thread (FIX 2, final fix-wave report). run()'s
	// caller may have already called install_crash_handlers() on the
	// thread that called run(), but that installs nothing here -- this is
	// a brand-new OS thread. As the first action, before anything that
	// could plausibly fault (decode_keys, box, mailbox_send).
	install_crash_handlers()

	buf: [1024]u8
	keys := make([dynamic]Key_Msg);  defer delete(keys)
	pending: [dynamic]u8;            defer delete(pending)

	for !sync.atomic_load(&rd.stop) {
		n, ok, woken := input_read(rd.src, buf[:])
		// `woken` is input_wake() asking us to shut down -- structurally
		// distinct from EOF so a clean quit is never misreported as input
		// dying. Loop back so the `stop` check above sees the flag.
		if woken { continue }
		if !ok || n == 0 {
			mailbox_close(rd.mailbox)   // EOF: input really is gone
			return
		}
		append(&pending, ..buf[:n])

		clear(&keys)
		consumed := decode_keys(pending[:], &keys)
		if consumed > 0 { remove_range(&pending, 0, consumed) }

		for k in keys {
			// Boxed on the heap, not the frame arena: this crosses a thread
			// boundary and outlives any single frame.
			msg := box(k, context.allocator)
			// FULL vs CLOSED must be handled differently (FIX 1, final
			// fix-wave report). The reader reads up to 1024 bytes per
			// read() and can send in a tight loop, while the main loop does
			// decode + render + write() per message -- the reader always
			// wins, and >1000 pasted characters is enough to fill the
			// 256-slot mailbox. Treating Full the same as Closed (as this
			// code used to, via a single `if !mailbox_send(...) { return
			// }`) made the reader exit WITHOUT calling mailbox_close, so the
			// main loop drained the queued messages and then blocked
			// forever in mailbox_recv -- no keyboard, no EOF, no error,
			// unkillable except by an external signal. Full is transient:
			// the main loop keeps draining concurrently, so spin until it
			// makes room. Closed is terminal: run() is tearing down and
			// nothing sent from here on can ever be received.
			for {
				result := mailbox_send(rd.mailbox, msg)
				if result == .Ok { break }
				if result == .Closed { return }
				thread.yield()
			}
		}
	}
}

// Writes the accumulated frame to flush_fd and resets the builder. With
// flush_fd < 0 the builder keeps accumulating -- the golden harness reads it.
//
// package-visible: run_nbio's initial paint (loop_nbio.odin) calls this
// directly, same as run() does above, for the same reason (paint before the
// init Cmd is dispatched).
@(private="package")
flush_frame :: proc(out: ^strings.Builder, flush_fd: posix.FD) {
	if flush_fd < 0 { return }
	s := strings.to_string(out^)
	if len(s) > 0 { posix.write(flush_fd, raw_data(s), len(s)) }
	strings.builder_reset(out)
}

// One Update/View cycle, guarded. Split out so `run` stays readable and so the
// guarded region is exactly the user code, not our loop bookkeeping.
//
// package-visible, not file-visible: loop_nbio.odin's run_nbio shares this
// verbatim rather than duplicating it, so both event-loop hosts run IDENTICAL
// Update/View/quit/panic-recovery logic and can only differ in how a message
// reaches this call, not in what happens once it does.
@(private="package")
apply :: proc(p: ^Program($T), msg: any, fa: ^Frame_Arena, disp: ^Dispatcher, r: ^Renderer, out: ^strings.Builder, flush_fd: posix.FD) -> Run_Error {
	if _, is_quit := msg.(Quit_Msg); is_quit { p.quit = true; return nil }
	if _, is_int := msg.(Interrupt_Msg); is_int { return Interrupted_Error{} }

	step := Step(T){p = p, msg = msg, alloc = frame_allocator(fa)}
	info := guarded(proc(ud: rawptr) {
		s := cast(^Step(T))ud
		s.p.model, s.cmd = s.p.update(s.p.model, s.msg, s.alloc)
	}, &step)

	if info.recovered {
		// longjmp ran no defers: reclaim the failed iteration wholesale.
		frame_reset(fa)
		return Panicked_Error{message = info.message}
	}

	if !cmd_is_nil(step.cmd) { dispatch(disp, step.cmd) }

	renderer_render(r, p.view(p.model, frame_allocator(fa)))
	flush_frame(out, flush_fd)
	frame_reset(fa)
	return nil
}
