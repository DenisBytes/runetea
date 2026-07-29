package runetea

// ============================================================================
// START HERE. This file is RuneTea's entry point -- Program(T), run(), and the
// event loop that drives them.
//
// BEFORE YOU BUILD ON THIS PACKAGE, READ docs/LIMITATIONS.md. It is the single
// consolidated, user-facing list of what RuneTea does not do, does not do
// fully, or does differently from what you would reasonably expect: the POD
// Msg contract, cancellation being cooperative rather than preemptive, what a
// recovered `update` panic leaves your model in, which platforms are real,
// which terminal escapes a view may legally contain, and everything else. Each
// entry says whether it is intrinsic or merely not-yet-built, when it bites,
// and what to do instead, and cross-references the source comment that argues
// the case. It exists so that none of that has to be discovered by running
// into it.
// ============================================================================

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

Quit_Msg :: struct {}

// DECLARED BUT NEVER PRODUCED, as of v1.0 -- nothing in this package
// constructs one, so a `case Killed_Error` in a caller's switch is currently
// dead code. Recorded here rather than deleted because Bubble Tea's
// ErrProgramKilled is the shape a future Program.kill()/hard-abort would
// return, and a variant that quietly appears in a union later is a worse
// surprise than one that is documented as unreachable now. Anything a running
// session can actually end with is Interrupted_Error, Panicked_Error or
// Terminal_Error below (or nil). Stated in docs/API.md §9 too, so a caller
// does not have to grep for constructions to find out.
Killed_Error      :: struct {}
Interrupted_Error :: struct {}

// THE CALLER OWNS `message` AND MUST delete() IT (with the same
// context.allocator run() was called under). It is guarded()'s own cloned
// panic string (guard.odin: the clone is mandatory, the original lives in a
// frame longjmp discards), handed onward rather than freed, precisely so the
// panic text outlives run(). That is the ONE allocation any Run_Error carries
// -- everything else in this union is plain data or a static string. Note the
// contrast with cmd.odin:520, which is the same Panic_Info consumed INSIDE
// the runtime and therefore does its own `defer delete(info.message, ...)`.
Panicked_Error    :: struct { message: string }

// `detail` is a static string literal; nothing to free.
//
// `errno` is .NONE for every failure that is not a syscall failure (a failed
// allocation, a failed nbio init). It exists because the one Terminal_Error a
// running, healthy program can actually hit -- flush_frame's write to the tty
// giving up -- is unactionable without it: "write to the terminal failed" does
// not distinguish the pty going away (EIO) from a closed fd (EBADF) from a
// vanished reader (EPIPE), and this codebase's rule is that a failure reaches
// the user with what it knows, not with what is convenient to carry. A POSIX
// Errno is a plain integer enum, so this adds no allocation and nothing to
// free, and every existing `Terminal_Error{detail = ...}` construction still
// compiles unchanged with .NONE.
Terminal_Error    :: struct { detail: string, errno: posix.Errno }

Run_Error :: union { Killed_Error, Interrupted_Error, Panicked_Error, Terminal_Error }

// Parametric over the model rather than an interface. This is STRONGER checking
// than Go's: Go verifies only method-set conformance, not that Update returns
// the same concrete type. The cost is that the model cannot be swapped for a
// different type mid-run -- use a `state` enum, or make T itself a vtable.
Program :: struct($T: typeid) {
	model:    T,

	// BY POINTER, NOT BY VALUE -- and this cost a real safety property. Read
	// both halves before writing an update proc.
	//
	// WHY POINTER. The original signature was
	//   proc(model: T, msg: any, alloc: mem.Allocator) -> (T, Cmd)
	// called as `p.model, cmd = p.update(p.model, msg, alloc)` in apply().
	// That one by-value round-trip made LLVM codegen SUPERLINEAR in
	// sizeof(T), which put a hard ceiling on how large a model a RuneTea app
	// could have. Measured via .superpowers/bigprobe -- a minimal Program
	// whose model is a [N]int -- as wall-clock `odin build` of the whole
	// probe, BEFORE against a git-HEAD checkout of the old signature and
	// AFTER against this tree, same machine, same toolchain:
	//
	//     model size   by value                by pointer
	//        2 KiB       1.01 s                  1.04 s
	//        8 KiB       2.28 s                  1.18 s
	//       16 KiB       8.97 s                  1.17 s
	//       32 KiB     105.91 s                  1.07 s
	//       64 KiB     did not finish in 200 s   1.12 s
	//      256 KiB     (not attempted)           1.27 s
	//        1 MiB     (not attempted)           1.20 s
	//
	// The ~1.1 s floor in the right-hand column is the fixed cost of compiling
	// runetea itself and linking; the MARGINAL cost of model size is now
	// indistinguishable from noise out to 1 MiB, where the left-hand column
	// was already unusable at 32 KiB.
	//
	// Bisected to this exact call, not to anything around it: instantiating
	// Program(T) + program_init with no run() compiled in 0.6 s at 32 KiB;
	// bypassing guarded()/setjmp entirely moved 85 s to 86 s; deleting JUST
	// the update call from apply() moved 85 s to 0.7 s. `odin check` stayed at
	// 0.25 s throughout, so it is codegen, not the front end -- and it is not
	// generic Odin behaviour either: a control program passing and returning
	// the same struct by value in a hot loop compiles in 0.5 s flat at 64 KiB.
	// The full record is in docs/superpowers/specs/2026-07-25-runetea-design.md
	// ("DECISION REVERSED -- update takes ^T").
	//
	// WHAT IT COST: TIER-1 RECOVERY NO LONGER PROTECTS MODEL STATE.
	// With the by-value signature, a panicking update left p.model completely
	// untouched -- guarded()'s longjmp skipped the `p.model = ...` assignment
	// in apply(), so the model still held the LAST GOOD state and recovery
	// resumed from something consistent by construction. With a pointer,
	// update mutates p.model directly, so a panic partway through leaves the
	// model HALF-MUTATED: some fields updated, some not, invariants between
	// them possibly broken. Tier 1 still guarantees the process survives, the
	// terminal is restored, the frame arena is reclaimed and run() returns
	// Panicked_Error -- it does NOT guarantee anything about the contents of
	// p.model afterwards.
	//
	// AN APP CANNOT ROLL THIS BACK ITSELF. The obvious mitigation --
	// snapshotting `old := m^` at the top of update and restoring it on
	// failure -- does not work, because longjmp skips the APP's code too: it
	// jumps straight out of update back into apply(), so no restore line, no
	// `defer`, and no error path inside update ever executes. The only
	// mitigation that actually holds is STRUCTURAL: do everything that can
	// fail FIRST (compute into locals, index-check, assert), and only write
	// into m^ once nothing further can panic. Then a panic leaves the model
	// exactly as it was, because nothing had been written yet.
	//
	// See docs/superpowers/tier1-coverage-decision.md §5 and apply()'s own
	// comment at the guarded() call.
	update:   proc(model: ^T, msg: any, alloc: mem.Allocator) -> Cmd,

	view:     proc(model: T, alloc: mem.Allocator) -> string,

	// OPTIONAL (T2-A). nil -- the zero value, and what program_init leaves it
	// as -- means "this program does not place the cursor", and then the
	// renderer emits not one extra byte (render.odin's Cursor). Set it
	// directly on either side of the program_init call, exactly like `legacy`
	// below; program_init deliberately does not take it, so no call site
	// written before T2 has to change.
	//
	// Called once per frame, immediately AFTER view and under the SAME
	// guarded() call (see guarded_render), from the same model and with the
	// same frame allocator -- so it can build whatever prefix string it needs
	// to measure with display_width, and that string dies with the frame.
	//
	// IT IS THE APP'S JOB to keep this consistent with what view actually
	// painted; nothing can check that for it. The coordinates are the VIEW's
	// (logical line index + DISPLAY column), not the terminal's -- see Cursor.
	cursor:   proc(model: T, alloc: mem.Allocator) -> Cursor,

	// OPTIONAL (T2-C). Which renderer this program wants. .Inline is the ZERO
	// VALUE -- and what program_init leaves it as -- so every program written
	// before T2-C keeps the rewind renderer with nothing said and renders byte
	// for byte as it did. Set it directly on either side of the program_init
	// call, exactly like `cursor` and `legacy` above.
	//
	// Read ONCE, at renderer construction, by run() and run_nbio(); changing it
	// mid-session does nothing (see renderer_init on why the mode is fixed at
	// construction).
	//
	// THIS DOES NOT ENTER THE ALTERNATE SCREEN. The two are separate opt-ins on
	// purpose -- this one picks a renderer, term_enter_raw's `alt` picks a
	// terminal buffer -- and an application that wants the usual full-screen
	// experience asks for both. See term_enter_raw for why they are not coupled.
	render_mode: Render_Mode,

	init_cmd: Cmd,
	quit:     bool,
	// Which side of each legacy C0 collision this program wants (see
	// Legacy_Key in input.odin). The zero value is the sane default, so no
	// existing program has to say anything. Bubble Tea does NOT expose this --
	// the flags live one layer below it, in ultraviolet -- so this is a
	// deliberate addition, not a port artefact.
	//
	// Read by the input reader (a separate thread in run(), the loop thread in
	// run_nbio()) and copied into its context before that thread starts, so it
	// is write-once-before-run, never mutated while a run is in flight.
	// program_init deliberately leaves it alone: set it on either side of the
	// program_init call and both work.
	legacy:   Legacy_Key_Encoding,
}

// init_cmd is Bubble Tea's `Init() Cmd`: the command fired once before the
// first input is read. Without it, any app whose first action is asynchronous
// (fetch, timer, subprocess) can never start.
program_init :: proc(
	p: ^Program($T),
	model: T,
	update: proc(model: ^T, msg: any, alloc: mem.Allocator) -> Cmd,
	view: proc(model: T, alloc: mem.Allocator) -> string,
	init_cmd := Cmd{},
) {
	p.model    = model
	p.update   = update
	p.view     = view
	p.init_cmd = init_cmd
	p.quit     = false
}

quit_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any { return box(Quit_Msg{}, context.allocator) }

quit_cmd :: proc() -> Cmd {
	return Cmd{procedure = quit_run, env = nil, allocator = context.allocator}
}

// Shared state for the guarded Update call. longjmp discards the frame, so the
// inputs and the one output live outside it.
//
// `cmd` is the ONLY output now: update mutates p.model through the ^T it is
// handed, so the model does not travel back through here the way it did under
// the by-value signature (Program.update's comment). A field that no longer
// exists is a field that cannot be silently skipped by longjmp -- which was
// precisely the mechanism that used to preserve the model on a panic, and is
// precisely what no longer happens.
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

	// Heap-allocated, not stack locals: see Reap_Ctx's own doc comment
	// (cmd.odin) for why. If a Cmd is still in flight when this run() session
	// quits, run() must be able to return before that Cmd finishes (that is
	// the whole point of this change -- see
	// docs/superpowers/cancellation-decision.md) -- so rc.disp and rc.mbox
	// must both outlive run()'s own stack frame, which a plain `mbox: Mailbox`
	// / `disp: Dispatcher` local could never do.
	rc := new(Reap_Ctx, context.allocator)
	if rc == nil {
		return Terminal_Error{detail = "dispatcher/mailbox allocation failed"}
	}
	if err := mailbox_init(&rc.mbox, 256); err != nil {
		free(rc, context.allocator)
		return Terminal_Error{detail = "mailbox init failed"}
	}

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
	if flush_fd >= 0 { signal_watcher_start(&sw, &rc.mbox, flush_fd) }

	dispatcher_init(&rc.disp, &rc.mbox, 4)
	// Declared BEFORE signal_watcher_stop's defer just below -- the OPPOSITE
	// of the two calls' own required order above (signal_watcher_start must
	// run before dispatcher_init; see that comment) -- so that at return time
	// it runs AFTER signal_watcher_stop instead. defer's LIFO order is fixed
	// by DECLARATION position, not by when the matching setup call actually
	// ran, so both orderings hold simultaneously: setup runs watcher-then-
	// dispatcher, teardown runs (reader, declared further below, first, then)
	// watcher-then-dispatcher-reap.
	//
	// This ordering is load-bearing for dispatcher_reap specifically (its own
	// PRECONDITION, cmd.odin): dispatcher_reap hands rc off to a BACKGROUND
	// thread, so by the time it is even CALLED, every other producer that
	// could still touch rc.mbox -- this Signal_Watcher, and the reader
	// thread torn down in the defer declared further below -- must already be
	// stopped and joined. If dispatcher_reap ran first, the background reaper
	// could reach mailbox_destroy (whenever rc.disp's own Cmds happen to
	// finish, possibly before this function even returns) while the watcher
	// or reader thread is still alive and could still be mid mailbox_send --
	// exactly the use-after-free Task 5 fixed once already, reintroduced via
	// a different producer. Reordering these two defers is what keeps that
	// proof intact while still letting run() return without waiting for an
	// in-flight Cmd.
	//
	// QUIT_GRACE bounds the worst case (a Cmd still running when the user
	// quits) to itself instead of that Cmd's own duration -- see
	// dispatcher_reap's own doc comment (cmd.odin) and
	// docs/superpowers/cancellation-decision.md for why a SHORT bounded wait,
	// not grace=0 (pure fire-and-forget), is what run() actually needs: it
	// keeps the overwhelmingly common case (no Cmd in flight, or one that
	// finishes quickly) fully synchronous, which matters for any caller whose
	// context.allocator does not outlive this call by much -- odin test's own
	// per-task allocator is exactly such a caller, rotated to a different
	// test the moment THIS test's run() call returns.
	QUIT_GRACE :: 100 * time.Millisecond
	defer dispatcher_reap(rc, QUIT_GRACE)
	defer signal_watcher_stop(&sw)

	r: Renderer
	// term_size(flush_fd) is only meaningful when flush_fd is a real tty (the
	// only case flush_fd >= 0 covers -- see flush_frame's doc comment above).
	// With flush_fd < 0 (the golden harness, unit tests) there is no fd to
	// query at all, so width stays 0/unknown and the renderer's rewind falls
	// back to exactly its pre-fix, one-row-per-logical-line behavior -- see
	// rows_for_line in width.odin for why that is deliberate, not a gap. A
	// failed ioctl (term_size ok=false, e.g. a pty with no size ever set)
	// degrades the same way: initial_w stays 0.
	//
	// THE HEIGHT USED TO BE DISCARDED HERE (`if w, _, ok := ...`). term_size has
	// always returned it; T2-C's full-screen renderer is the first thing that
	// needs it, and it needs it from the very first frame -- a Window_Size_Msg
	// only arrives on a SIGWINCH, so a program that is never resized would
	// otherwise run its whole life with an unknown height. Same degradation
	// rules as the width: no fd, or a failed ioctl, leaves it 0 == unknown,
	// which the full-screen renderer reads as "do not truncate".
	initial_w := 0
	initial_h := 0
	if flush_fd >= 0 {
		if w, h, ok := term_size(flush_fd); ok { initial_w, initial_h = w, h }
	}
	renderer_init(&r, out, initial_w, initial_h, p.render_mode)
	// T3-A: .Diff allocates two cell grids on its first sized frame; the
	// other two modes allocate nothing and this is a no-op for them. Deferred
	// right at construction so no early return -- and there are several, on
	// every panic path -- can skip it. tools/test.sh's leak audit is the gate
	// that would catch it if one did.
	defer renderer_destroy(&r)

	// Initial paint, then the init Cmd -- in that order, so an app whose first
	// action is asynchronous still shows its loading state immediately.
	//
	// Guarded (T1, docs/superpowers/tier1-coverage-decision.md): this is a
	// real call to user code -- p.view -- happening before the mailbox loop,
	// the reader thread, or the dispatcher have processed anything, and a
	// panic here is exactly as real a crash as one from apply()'s per-frame
	// render (guarded_render below is the SAME helper both call, so there is
	// only one guarded-view code path to reason about, not two that could
	// drift). Returning early on a panic here is correct, not merely
	// tolerated: nothing has been dispatched yet (dispatch(init_cmd) is the
	// next line) and the reader thread does not exist yet (created further
	// below), so every defer already registered above (dispatcher_reap,
	// signal_watcher_stop) tears down cleanly with nothing outstanding to
	// wait for.
	if e := guarded_render(p, &fa, &r, out, flush_fd); e != nil { return e }
	if !cmd_is_nil(p.init_cmd) { dispatch(&rc.disp, p.init_cmd) }

	// The mailbox is the SINGLE wait point. A reader thread turns bytes into
	// Key_Msgs and pushes them alongside Cmd results, so an async result
	// updates the view with no keypress -- without this, examples/http shows
	// "Checking..." until the user happens to hit a key.
	//
	// The spike reads on a thread rather than through nbio because the loop
	// still owns rendering; Task 6's nbio path replaces this reader in T1.
	rd := Reader_Ctx{src = src, mailbox = &rc.mbox, legacy = p.legacy}
	reader := thread.create(reader_thread)
	reader.data = &rd
	reader.init_context = context
	thread.start(reader)
	// Declared LAST, so it is the FIRST of this function's defers to run --
	// see the comment above dispatcher_reap's own defer for why that
	// ordering (reader, then watcher, then dispatcher_reap) is load-bearing,
	// not incidental.
	defer {
		sync.atomic_store(&rd.stop, true)
		// MUST wake the reader before joining. It parks inside input_read
		// waiting on the tty, and checks `stop` only between reads -- quitting
		// via a UI action rather than a keypress would otherwise hang here
		// forever.
		input_wake(src)
		mailbox_close(&rc.mbox)
		thread.join(reader)
		thread.destroy(reader)
	}

	for !p.quit {
		msg, ok := mailbox_recv(&rc.mbox)
		if !ok { break }   // closed and drained
		if e := apply(p, msg, &fa, &rc.disp, &r, out, flush_fd); e != nil { return e }
	}
	return nil
}

Reader_Ctx :: struct {
	src:     ^Input_Source,
	mailbox: ^Mailbox,
	stop:    bool,
	// Copied from Program.legacy before thread.start, and only read after --
	// the start is the happens-before edge, so this needs no atomics the way
	// `stop` does.
	legacy:  Legacy_Key_Encoding,
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
	// The terminal's answer to term_enter_raw's keyboard-enhancement query
	// (term.odin). A second output stream because it is a different Msg type,
	// not a Key_Msg -- see decode_keys' note on the ordering that costs.
	enh  := make([dynamic]Keyboard_Enhancements_Msg); defer delete(enh)
	pending: [dynamic]u8;            defer delete(pending)
	// The decoder's cross-call state and its non-key output, owned by THIS
	// reader (input.odin's Input_State explains why it cannot be a global):
	// `in_paste` has to survive from one decode_keys call to the next, because
	// a paste of any size straddles reads. `markers` is scratch, cleared and
	// reused every read like `keys`; since T2-B it carries mouse and focus
	// events as well as the paste boundaries.
	st := Input_State{};             defer delete(st.markers)

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
		clear(&enh)
		clear(&st.markers)
		consumed := decode_keys(pending[:], &keys, rd.legacy, &enh, &st)
		if consumed > 0 { remove_range(&pending, 0, consumed) }

		// Boxed on the heap, not the frame arena: these cross a thread
		// boundary and outlive any single frame.
		//
		// Paste markers are INTERLEAVED with the keys rather than appended
		// after them, because their position is their meaning: Paste_Start_Msg
		// has to reach update() before the first pasted character and
		// Paste_End_Msg after the last. `at` is monotonic, so one index into
		// the marker list walked alongside the keys is enough. (`enh` is the
		// contrast: it genuinely has no ordering requirement -- see
		// decode_keys' note -- so it is flushed at the end.)
		mi := 0
		for k, idx in keys {
			for mi < len(st.markers) && st.markers[mi].at <= idx {
				if reader_send(rd.mailbox, input_marker_box(st.markers[mi])) { return }
				mi += 1
			}
			if reader_send(rd.mailbox, box(k, context.allocator)) { return }
		}
		for ; mi < len(st.markers); mi += 1 {
			if reader_send(rd.mailbox, input_marker_box(st.markers[mi])) { return }
		}
		for e in enh  { if reader_send(rd.mailbox, box(e, context.allocator)) { return } }
	}
}

// Blocks until `msg` is in the mailbox, or until the mailbox closes.
// Returns true if it closed -- the caller must then stop reading entirely.
//
// FULL vs CLOSED must be handled differently (FIX 1, final fix-wave report),
// which is the whole reason this is not a bare `if !mailbox_send(...)`. The
// reader reads up to 1024 bytes per read() and can send in a tight loop, while
// the main loop does decode + render + write() per message -- the reader
// always wins, and >1000 pasted characters is enough to fill the 256-slot
// mailbox. Treating Full the same as Closed (as this code used to) made the
// reader exit WITHOUT calling mailbox_close, so the main loop drained the
// queued messages and then blocked forever in mailbox_recv -- no keyboard, no
// EOF, no error, unkillable except by an external signal. Full is transient:
// the main loop keeps draining concurrently, so spin until it makes room.
// Closed is terminal: run() is tearing down and nothing sent from here on can
// ever be received.
//
// A proc rather than an inlined loop because there are now two kinds of
// message to send (keys and the keyboard-enhancement reply) and Odin has no
// closures to capture `rd` with -- two copies of this reasoning would be two
// copies to get wrong.
@(private="file")
reader_send :: proc(mbox: ^Mailbox, msg: any) -> (closed: bool) {
	for {
		switch mailbox_send(mbox, msg) {
		case .Ok:     return false
		case .Closed: return true
		case .Full:   thread.yield()
		}
	}
}

// WRITES THE WHOLE BUFFER OR SAYS WHY IT COULD NOT. write(2) is allowed to
// transfer fewer bytes than it was asked for and report success, and this used
// to be one unlooped `posix.write` with its result discarded -- so a short write
// silently dropped the tail of a frame. That is not a cosmetic loss: a frame is
// a stream of escape sequences, so the cut can land INSIDE one, leaving the
// terminal parsing the next frame's bytes as the arguments of a sequence that
// was never finished. Two subsystems already carried workarounds for it
// (term.odin's sticky cursor_hidden, whose comment named this exact call).
//
// THE LOOP'S THREE CASES, and why each is what it is:
//
//   n > 0             progress. Advance and keep going; this is the short write
//                     and it is ORDINARY, not an error -- a tty with a full
//                     output queue, a signal landing mid-transfer, a pipe.
//   EINTR             a signal was delivered before ANY byte moved. Retry
//                     verbatim: nothing was consumed, so there is nothing to
//                     account for. This package blocks its own signals but
//                     an application's SIGCHLD/SIGALRM handler is its own
//                     business, and SA_RESTART is not something we control.
//   EAGAIN            the fd is O_NONBLOCK (which RuneTea never sets, but an
//                     embedder can hand us any fd it likes). Yield and retry,
//                     the same "transient, retry; terminal, give up" policy
//                     every producer in this codebase already applies to a full
//                     Mailbox (reader_send, deliver_result, send_or_retry).
//
// Anything else -- and a return of 0 for a non-empty buffer, which no character
// device or pipe is permitted to do and which would otherwise spin forever --
// is UNRECOVERABLE and ends the session with a Terminal_Error carrying the
// errno.
//
// WHY AN ERROR RETURN AND NOT A PANIC, AND NOT SILENCE. Silence is what the bug
// was. A panic is worse than the disease: this runs mid-frame, with the terminal
// in raw mode and possibly on the alternate screen, and the one thing that must
// still happen is the caller's `defer term_restore()`. Returning a Run_Error
// gets exactly that -- run() unwinds normally, the dispatcher is reaped, the
// terminal is restored, and the application is told, in the same union it
// already handles for every other way a session can end. And the failures that
// reach here are not survivable anyway: EIO/EPIPE/EBADF all mean the terminal
// this program was drawing on is gone, so "keep rendering" would be drawing to
// nothing, forever, at full frame rate.
//
// The builder is reset EITHER WAY (deferred): on the error path the session is
// over, and holding a partial frame's bytes for a retry that will never come
// only makes the next thing to touch the builder wrong.
//
// With flush_fd < 0 the builder keeps accumulating and nothing is written -- the
// golden harness reads it.
//
// package-visible: run_nbio's initial paint (loop_nbio.odin) calls this
// directly, same as run() does above, for the same reason (paint before the
// init Cmd is dispatched).
@(private="package")
flush_frame :: proc(out: ^strings.Builder, flush_fd: posix.FD) -> Run_Error {
	if flush_fd < 0 { return nil }
	defer strings.builder_reset(out)
	return write_all(flush_fd, strings.to_string(out^))
}

// The loop itself, split out of flush_frame so the policy above has exactly one
// implementation and so a test can drive it against a deliberately short-writing
// fd without going through a whole Program. See flush_frame for the reasoning.
@(private="package")
write_all :: proc(fd: posix.FD, s: string) -> Run_Error {
	sent := 0
	for sent < len(s) {
		// Cleared first: errno is only meaningful after a call that FAILED,
		// and a stale value from some earlier syscall must not be able to
		// masquerade as this write's own.
		posix.set_errno(.NONE)
		remaining := len(s) - sent
		n := posix.write(fd, raw_data(s[sent:]), uint(remaining))
		if n > 0 {
			sent += int(n)
			continue
		}
		err := posix.errno()
		#partial switch err {
		case .EINTR:
			continue
		case .EAGAIN:
			// NOT also .EWOULDBLOCK: on every platform this package builds
			// for the two are the same numeric value, so listing both would
			// be a duplicate switch case.
			thread.yield()
			continue
		}
		// n == 0 with bytes left to send lands here too, with errno .NONE --
		// deliberately treated as terminal rather than retried, because a
		// zero-return that is not an error has no defined recovery and
		// retrying it is an infinite loop.
		return Terminal_Error{detail = "write to the terminal failed mid-frame", errno = err}
	}
	return nil
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
	// Every msg reaching apply() came off the mailbox, which means it was
	// boxed with context.allocator (never frame_allocator(fa) -- see
	// Frame_Arena's LIFETIME CONTRACT in arena.odin): tea.odin's reader
	// thread and loop_nbio.odin's nbio_on_read both box Key_Msg that way,
	// cmd.odin's pool/detached paths box Cmd results that way (via whatever
	// the Cmd body itself passed to box() -- always context.allocator by
	// convention, see cmd.odin), and signals.odin boxes Window_Size_Msg/
	// Interrupt_Msg that way. box_free is therefore correct here regardless
	// of which of those produced `msg`, and regardless of which of the
	// branches below actually runs -- deferred so it fires on every exit
	// path (the two early returns below, the panic-recovered return, and
	// the normal end-of-frame return alike) exactly once. Sound only
	// because of box()'s MESSAGE OWNERSHIP CONTRACT (arena.odin): every
	// boxed Msg is POD, so this is always the ONLY allocation to reclaim
	// for it -- see docs/superpowers/message-ownership-decision.md.
	defer box_free(msg, context.allocator)

	if _, is_quit := msg.(Quit_Msg); is_quit { p.quit = true; return nil }
	if _, is_int := msg.(Interrupt_Msg); is_int { return Interrupted_Error{} }

	// Window_Size_Msg updates the renderer's width for FUTURE rewinds (see
	// renderer_set_width's doc comment on why last_rows itself is untouched
	// here) and then falls through to the user's own update() below, same as
	// any other message -- unlike Quit/Interrupt above, a resize is not
	// terminal to the loop and Bubble Tea apps commonly react to it for their
	// own layout. ws.w == 0 is signals.odin's own "term_size lookup failed"
	// sentinel (SIGWINCH fired but the ioctl came back empty) -- ignored here
	// so a bad lookup can't clobber a previously-known-good width.
	//
	// T2-C: the HEIGHT is applied here too, and guarded separately rather than
	// under the same `ws.w > 0` test. signals.odin's failure sentinel sets BOTH
	// to 0, so in practice they move together -- but they are two independent
	// pieces of state on the Renderer, and one guard covering both would mean a
	// future partial-failure mode silently clobbering the good half of a
	// previously-known-good size.
	if ws, is_resize := msg.(Window_Size_Msg); is_resize {
		if ws.w > 0 { renderer_set_width(r, ws.w) }
		if ws.h > 0 { renderer_set_height(r, ws.h) }
	}

	// THE MODEL IS PASSED BY POINTER -- update mutates p.model IN PLACE.
	//
	// This used to be `s.p.model, s.cmd = s.p.update(s.p.model, ...)`, and
	// that assignment was doing double duty: it was also the mechanism that
	// made a recovered update panic leave the model in its last good state,
	// because longjmp skipped the store. That property is GONE and nothing
	// here replaces it -- see Program.update's own comment for the build-time
	// measurements that bought the trade and why an app cannot roll the
	// mutation back itself (longjmp skips the app's code too, so no snapshot-
	// restore line inside update ever runs).
	//
	// So, precisely, on the recovery path below:
	//   GUARANTEED -- the process survives, the frame arena is reclaimed
	//     wholesale, the message is box_free'd by the defer above, the
	//     terminal is restored by the caller's own defer, and run() returns
	//     Panicked_Error carrying the panic text.
	//   NOT GUARANTEED -- anything at all about the contents of p.model. It
	//     may be fully updated, untouched, or half-written with cross-field
	//     invariants broken. run() ends the session immediately on this path
	//     (it does not loop back into update with the damaged model), so the
	//     exposure is bounded to whatever the CALLER of run() does with
	//     p.model after the Panicked_Error return -- which is why callers
	//     should treat the model as suspect there rather than, say, persisting
	//     it to disk.
	step := Step(T){p = p, msg = msg, alloc = frame_allocator(fa)}
	info := guarded(proc(ud: rawptr) {
		s := cast(^Step(T))ud
		s.cmd = s.p.update(&s.p.model, s.msg, s.alloc)
	}, &step)

	if info.recovered {
		// longjmp ran no defers: reclaim the failed iteration wholesale.
		// Memory only -- p.model's CONTENT is not restored and cannot be
		// (see above).
		frame_reset(fa)
		return Panicked_Error{message = info.message}
	}

	if !cmd_is_nil(step.cmd) { dispatch(disp, step.cmd) }

	return guarded_render(p, fa, r, out, flush_fd)
}

// Shared state for the guarded View call, mirroring Step above -- longjmp
// discards the frame, so the view string produced (or not) lives outside it.
// `cur` is the same story for the optional cursor callback, which runs inside
// the SAME guarded body: it is written only if that body reaches it, so a
// panic in view leaves it at its zero value ("no cursor declared") and the
// diagnostic frame below places no cursor -- which is what you want when the
// app's own idea of where the caret goes is exactly what just crashed.
@(private="file")
View_Step :: struct($T: typeid) {
	p:     ^Program(T),
	alloc: mem.Allocator,
	view:  string,
	cur:   Cursor,
}

// Renders exactly one frame under guarded(): calls p.view, writes it through
// the Renderer, flushes, and reclaims the frame arena -- the same four steps
// apply()'s tail always performed, just now with p.view wrapped instead of
// called bare. Two call sites share this (run()'s initial paint above, and
// apply() just above this proc), which is the point: view has exactly one
// guarded code path, not two hand-maintained copies that could drift.
//
// STRUCTURE (constraint a, tier1-coverage-decision.md): this is a SEPARATE,
// SEQUENTIAL guarded() call, not one nested inside apply()'s update guard.
// apply()'s own guarded(update) call above has already returned (successfully
// or not) by the time this runs, so g_armed is back to false and this call is
// perfectly ordinary from guarded()'s point of view -- nesting is a same-
// thread, same-callstack hazard (an inner guarded() call from inside an outer
// one's still-active body), and update-then-view here are two calls in
// sequence on the same stack depth, not one nested in the other.
//
// WHAT A RECOVERED VIEW PANIC DISPLAYS (constraint d): a synthesized
// diagnostic frame -- "[view panicked: <message>]" -- rendered and flushed
// through the SAME Renderer the real frames use, then run() returns
// Panicked_Error (ending the session, exactly like an update panic). Three
// options were weighed:
//   - Last good frame (skip rendering, leave last_rows/output untouched):
//     silently hides the crash. The user's screen keeps showing stale
//     content with no indication anything went wrong -- worse for debugging
//     than an honest crash message, and indistinguishable from the app
//     simply being idle.
//   - Nothing (blank the screen / write nothing): actively worse than stale
//     content -- exactly the failure mode this constraint's own doc comment
//     calls out ("a TUI that goes blank on a transient view panic is worse
//     than one that shows a diagnostic").
//   - A diagnostic line -- ADOPTED. It costs nothing update-panic recovery
//     doesn't already pay (Panicked_Error already carries info.message for
//     the caller of run() to log/report), and it means the LAST thing on the
//     user's real terminal, after the deferred term_restore() in their own
//     main() runs, is a plain-text explanation of what happened rather than
//     silence or stale state. This does not try to keep the session running
//     past a view panic (see below) -- it exists purely so the one frame
//     run() DOES still produce before quitting is informative.
//
// TERMINATE, NOT CONTINUE: a view panic ends run() with Panicked_Error, the
// same as an update panic, rather than recovering in place and looping back
// to the next message. A model whose view panics on the CURRENT state will
// almost always panic again on the next call with the same (or barely
// different) state -- looping forever re-panicking and re-painting the same
// diagnostic every frame is a worse outcome than an honest, one-time,
// clearly-explained exit. This also keeps view's failure mode symmetric with
// update's: EITHER kind of user-code panic ends the run() session cleanly;
// neither is allowed to corrupt state and continue.
@(private="package")
guarded_render :: proc(p: ^Program($T), fa: ^Frame_Arena, r: ^Renderer, out: ^strings.Builder, flush_fd: posix.FD) -> Run_Error {
	// p.cursor runs INSIDE this same guarded body rather than in a second
	// guarded() call of its own. Two reasons. It is user code and must be
	// covered (an app that indexes a slice to find its caret can panic exactly
	// like a view can), and running it here costs nothing extra: it is a
	// sequential call at the same stack depth as p.view, not a nested one, so
	// the non-nesting constraint discussed below is untouched. It runs AFTER
	// view because that is the order the app itself reasons in -- the cursor
	// describes a position in the frame view just produced.
	vs := View_Step(T){p = p, alloc = frame_allocator(fa)}
	info := guarded(proc(ud: rawptr) {
		s := cast(^View_Step(T))ud
		s.view = s.p.view(s.p.model, s.alloc)
		if s.p.cursor != nil { s.cur = s.p.cursor(s.p.model, s.alloc) }
	}, &vs)

	if info.recovered {
		// longjmp ran no defers: reclaim whatever the failed view() call
		// allocated from the frame arena (a partially-built strings.Builder,
		// etc.) before building the diagnostic from a clean arena -- same
		// wholesale-reclaim move apply() already makes for a failed update().
		frame_reset(fa)
		diag := fmt.aprintf("[view panicked: %s]", info.message, allocator = frame_allocator(fa))
		renderer_render(r, diag)
		// A flush failure here is DELIBERATELY DISCARDED, and it is the only
		// place in this package that discards one. The session is already
		// ending with Panicked_Error, whose `message` the caller owns and must
		// free; replacing it with a Terminal_Error would leak that string and
		// would also report the less informative of the two failures -- the
		// diagnostic frame not reaching a terminal that has evidently gone away
		// is a consequence, the panic is the cause.
		_ = flush_frame(out, flush_fd)
		frame_reset(fa)
		return Panicked_Error{message = info.message}
	}

	renderer_render(r, vs.view, vs.cur)
	ferr := flush_frame(out, flush_fd)
	frame_reset(fa)
	return ferr
}
