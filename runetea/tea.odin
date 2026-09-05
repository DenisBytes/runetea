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
	// called as `p.model, cmd = p.update(p.model, msg, alloc)` in apply_msg
	// (then called apply, and doing the render as well).
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
	// the update call from apply_msg moved 85 s to 0.7 s. `odin check` stayed at
	// 0.25 s throughout, so it is codegen, not the front end -- and it is not
	// generic Odin behaviour either: a control program passing and returning
	// the same struct by value in a hot loop compiles in 0.5 s flat at 64 KiB.
	// The full record is in docs/superpowers/specs/2026-07-25-runetea-design.md
	// ("DECISION REVERSED -- update takes ^T").
	//
	// WHAT IT COST: TIER-1 RECOVERY NO LONGER PROTECTS MODEL STATE.
	// With the by-value signature, a panicking update left p.model completely
	// untouched -- guarded()'s longjmp skipped the `p.model = ...` assignment
	// in apply_msg, so the model still held the LAST GOOD state and recovery
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
	// jumps straight out of update back into apply_msg, so no restore line, no
	// `defer`, and no error path inside update ever executes. The only
	// mitigation that actually holds is STRUCTURAL: do everything that can
	// fail FIRST (compute into locals, index-check, assert), and only write
	// into m^ once nothing further can panic. Then a panic leaves the model
	// exactly as it was, because nothing had been written yet.
	//
	// See docs/superpowers/tier1-coverage-decision.md §5 and apply_msg's own
	// comment at the guarded() call.
	update:   proc(model: ^T, msg: any, alloc: mem.Allocator) -> Cmd,

	// BY VALUE, AND THAT IS DELIBERATE -- but it has a cost the reader of this
	// struct was previously left to discover from a compiler error (F62). The
	// pointer argument two fields up is about `update`'s ROUND TRIP through
	// codegen and says nothing about a parameter nothing writes through; a
	// view is read-only, and a `^T` here would say the opposite, invite a
	// mutation the renderer would then paint from a model update() never saw,
	// and make the "view is a pure function of the model" rule the whole
	// coalescing design leans on a matter of convention rather than of type.
	//
	// WHAT IT COSTS: ODIN PROCEDURE PARAMETERS ARE NOT ADDRESSABLE. Not merely
	// immutable -- you cannot take the address of a field of one, and you
	// cannot slice a fixed-size array field of one:
	//
	//     strings.write_string(&b, string(m.rows[i].name[:m.rows[i].n]))
	//     // Error: Cannot slice array 'm.rows[i].name[:m.rows[i].n]',
	//     //        value is not addressable
	//
	// That is not an exotic shape. box()'s MESSAGE OWNERSHIP CONTRACT
	// (arena.odin) pushes every program here toward fixed-capacity arrays and
	// away from `string`, so the first list or table anybody writes has a
	// `[N]u8` plus a length in it, and the error lands on the first line of the
	// first view that draws one. examples/editor's own model is exactly that
	// shape (`Line :: struct { r: [MAX_COLS]rune, n: int }`) and its row_text
	// already pays the workaround -- `l := m.lines[i]` at editor.odin:1152 --
	// without anything in this struct having told it to.
	//
	// THE IDIOM THAT WORKS: one local copy at the top of the view.
	//
	//     view :: proc(m: Model, alloc: mem.Allocator) -> string {
	//         mm := m                                    // addressable, lives for the body
	//         b := strings.builder_make(alloc)
	//         for i in 0 ..< mm.n {
	//             strings.write_string(&b, string(mm.rows[i].name[:mm.rows[i].n]))
	//         }
	//         return strings.to_string(b)                // owned by `alloc`, not by mm
	//     }
	//
	// AND THE SHORTCUT THAT IS A USE-AFTER-RETURN: `mm := m; return
	// string(mm.rows[0].name[:n])` compiles clean and hands back a string
	// pointing into a dead stack frame -- measured, it comes back as
	// "\x00\x00\x00\x00\x00". The copy is good for the BODY; anything that
	// leaves the view must be written into storage from `alloc`. Hoist the
	// copy out of loops (it is the whole model), and for a model measured in
	// kilobytes reach for a smaller T holding a pointer to storage you own --
	// legal for a MODEL, illegal for a Msg (arena.odin's POD rule).
	//
	// Also in docs/LIMITATIONS.md 3.18 and worked in docs/API.md section 6.
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
	//
	// BY VALUE for the same reason `view` is, and with the same
	// non-addressable-parameter consequence and the same local-copy idiom --
	// see `view` above. A cursor proc that measures a prefix of a fixed-capacity
	// line field hits it exactly as a view does, and this one is where it hits
	// first, because measuring a prefix is the whole job.
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

	// OPTIONAL. How many messages the mailbox holds, and -- because the two are
	// the same number for the reason COALESCE_BUDGET's comment gives -- the most
	// messages either host applies to the model before it stops and paints.
	//
	// ZERO MEANS MAILBOX_CAP (256), so nothing written before this field existed
	// changes. Read ONCE, at mailbox construction; changing it mid-session does
	// nothing. Values below MAILBOX_CAP_MIN (8) are raised to it rather than
	// rejected: a mailbox of 1 turns every burst into a producer stall, and a
	// mailbox of 0 does not work at all, so silently honouring either would be
	// worse than the clamp. There is no upper clamp -- the memory is one
	// allocation of `cap` slots, and a caller who asks for a million knows.
	//
	// WHEN TO RAISE IT: a program whose producers legitimately burst wider than
	// 256 between paints -- a fast `every()` feeding an expensive `update`, or a
	// paste on a terminal that delivers more than 256 keys per read. The cost of
	// leaving it low is not lost messages (the back-pressure policy is
	// retry-forever, 2.15) but latency: the producer waits.
	//
	// WHEN TO LOWER IT: to bound the worst-case work of one coalesced batch, on
	// a program whose `update` is expensive and whose input can burst.
	mailbox_cap: int,

	init_cmd: Cmd,
	quit:     bool,

	// SET BY run() ON THE WAY OUT, never read by it. True means run() gave up
	// waiting for an in-flight Cmd and returned anyway, leaving a DETACHED
	// reaper thread behind that is still finishing the teardown -- freeing the
	// Dispatcher's pool, the Reap_Ctx, the mailbox buffer, the Task_Envs and
	// the Cmd's cloned env, all of them allocations made through the
	// context.allocator run() was called under.
	//
	// WHY THIS FIELD EXISTS. `defer dispatcher_reap(rc, QUIT_GRACE)` threw
	// that bool away, so the one thing a caller needed to know -- "is my
	// allocator still in use?" -- was structurally unobservable: run() returned
	// nil, docs said nothing, and the ~7 KiB across ~17 live allocations stayed
	// live for as long as the slowest in-flight Cmd took. An embedder that
	// scopes an allocator to the run() call and reclaims it on the next line
	// does not merely get a phantom leak report; it gets a deterministic
	// SIGSEGV, with a clean cliff at exactly QUIT_GRACE (a Cmd sleeping 90 ms
	// exits 0, one sleeping 150 ms exits 139) and it segfaults even for a Cmd
	// that allocates nothing at all, because what writes into the released
	// memory is runetea's OWN teardown running on the reaper thread.
	//
	// WHAT A CALLER MUST DO WITH IT. If this is true when run() returns, the
	// allocator run() was called under must stay valid until the process exits
	// (or at minimum well past the slowest Cmd the program can issue) -- do
	// not free an arena, do not tear down a Tracking_Allocator, do not return
	// from the scope that owns it. If it is false, teardown was fully
	// synchronous and nothing of run()'s survives the return.
	//
	// A bool rather than a new Run_Error variant, deliberately: the session
	// itself ENDED FINE, and a caller's `if err != nil` is the wrong place to
	// learn about an allocator-lifetime obligation -- turning a clean quit into
	// a non-nil error would make every correct program start reporting a
	// failure it did not have.
	//
	// BOTH HOSTS SET IT. This used to end "run_nbio() never sets it: it tears
	// the Dispatcher down synchronously (dispatcher_destroy, not
	// dispatcher_reap) and so has nothing outstanding when it returns" -- which
	// was true, and was the same sentence as LIMITATIONS 2.6's complaint that
	// run_nbio's quit was unbounded. Bounding it is what gives run_nbio the same
	// obligation to report, and this field is how it reports.
	reaper_pending: bool,

	// SET BY BOTH HOSTS ON THE WAY OUT, never read by them. How many frames
	// left at least one allocation behind on context.allocator inside view()
	// or cursor(), and how many blocks and (best-effort) bytes that came to.
	//
	// A NON-ZERO view_leak_frames MEANS THE VIEW LEAKED (docs/LIMITATIONS.md
	// 3.15): it called something whose allocator argument defaults to
	// context.allocator -- fmt.aprintf, strings.clone, strings.builder_make,
	// rg.render -- without passing the `alloc` it was handed, so the frame
	// arena never held the memory and the arena reset cannot reclaim it. The
	// fix is always the same: pass `alloc` explicitly at every allocating call
	// in view, in cursor, and in anything they call.
	//
	// READ THESE AFTER YOUR OWN term_restore(), which is the reliable way to
	// see them: the library also prints a summary to stderr on the way out
	// (view_leak_report), but a program on the alternate screen has its stderr
	// painted into a buffer `\e[?1049l` discards. The fields survive that; the
	// print may not.
	//
	// ONE FRAME IS NOT A LEAK REPORT -- see view_leak_report for why a lazily
	// initialised cache inside a view is filtered out and a per-frame leak
	// cannot be.
	view_leak_frames: int,
	view_leak_blocks: int,
	view_leak_bytes:  int,
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

// The DEFAULT capacity of the mailbox both hosts run on, used whenever
// `Program.mailbox_cap` is left at its zero value. Named rather than repeated
// as a literal in two files because the coalescing budget below is defined in terms
// of it.
@(private = "package")
MAILBOX_CAP :: 256

// The floor `Program.mailbox_cap` is clamped up to. A one-slot mailbox turns
// every burst into a producer stall and a zero-slot one cannot be constructed
// at all, so an application that asks for either gets this instead -- see
// Program.mailbox_cap for why a clamp rather than an error.
@(private = "package")
MAILBOX_CAP_MIN :: 8

// How long either host waits, at quit, for a Cmd that is still running before
// it returns anyway and leaves a detached reaper thread to finish the teardown.
// Package scope because BOTH hosts use it: run() always did, and run_nbio()
// does since it stopped blocking on `dispatcher_destroy` outright. The full
// argument for a SHORT bounded wait rather than grace=0 lives at run()'s own
// use of it below; the argument for it being the same number in both hosts is
// simply that "how long does quitting take" should not depend on which loop an
// application happens to have chosen.
@(private = "package")
QUIT_GRACE :: 100 * time.Millisecond

// Resolves Program.mailbox_cap to the number both hosts actually build the
// mailbox with, and bound their coalescing drain by. One proc so the two hosts
// cannot drift, and so the clamp is stated exactly once.
@(private = "package")
program_mailbox_cap :: proc(p: ^Program($T)) -> int {
	if p.mailbox_cap <= 0 { return MAILBOX_CAP }
	return max(p.mailbox_cap, MAILBOX_CAP_MIN)
}

// THE COALESCING BUDGET -- the most messages either host will apply to the
// model before it stops and paints -- is not a constant of its own: it is
// whatever program_mailbox_cap resolved to for this session, read into a local
// at the top of each host's loop. This comment is where the reasoning lives,
// because the number is the mailbox's own capacity and that identity is the
// whole argument.
//
// It is the mailbox's own capacity, and that number is not arbitrary:
// everything that was ALREADY QUEUED when a batch started is by construction
// at most MAILBOX_CAP messages, so this budget never truncates a batch that
// coalescing was supposed to fold into one frame. What it bounds is the other
// case -- a producer that refills the queue as fast as update() empties it --
// where an unbounded drain hands producers absolute, unlimited priority over
// everything the loop does after the drain: painting, and (in run_nbio) even
// reading the keyboard.
//
// That was not hypothetical. run_nbio's drain used to run to EMPTY, and
// nbio.tick() -- the only thing that ever completes a read -- sat below it, so
// a program whose sustained per-message cost exceeded its message arrival rate
// never reached tick() again and was deaf for the rest of the process's life
// while cheerfully repainting. Measured cliff: every(16 ms) with 12 ms of work
// per tick quits normally, every(16 ms) with 17 ms of work never sees another
// keystroke, 3/3. The budget converts "never" into "at most one queue's worth",
// which is the difference between a bug and a scheduling policy.
//
// Not a frame-rate cap and not a timer: nothing here waits for anything. A
// batch ends the moment the queue is empty, which for the single-keystroke
// case is after exactly one message -- so the interactive path costs one extra
// non-blocking mailbox_try_recv per frame and nothing else.
//
// (The identity holds for a caller-chosen capacity exactly as it did for the
// constant: whatever `cap` is, no more than `cap` messages can be queued when
// a batch starts, so the budget still never truncates a batch coalescing was
// meant to fold. That is why it is the SAME number and not a second knob.)

// Maps a finished session onto a process exit status, so that `os.exit` is one
// call rather than a switch every program has to write (and, as every example
// in this repository demonstrated, forgets to write).
//
// WHY THIS IS IN THE LIBRARY. Every shipped example ended with
//   if err := rt.run(...); err != nil { fmt.eprintln("error:", err) }
// and then fell off the end of main, so a session that died of Terminal_Error
// or Panicked_Error exited 0 -- indistinguishable, to any supervisor, CI job or
// shell, from a clean quit. Reporting a failure only on stderr is especially
// weak here because stderr may well have gone to the alternate screen, which
// the terminal discards on restore: the crash could be invisible to BOTH the
// human and the script. Handing back a status is the smallest thing that makes
// the right shape easy to write.
//
// THE MAPPING, and why each value:
//   nil                 0    the session ended because the program asked it to.
//   Interrupted_Error   130  128+SIGINT, the shell's convention for "killed by
//                            Ctrl+C". Not 1: an external SIGINT/SIGTERM is a
//                            request, not a fault, and a supervisor that
//                            restarts on 1 should not restart on this.
//   Panicked_Error      1    user code faulted; the session did not finish.
//   Terminal_Error      1    the terminal or a syscall went away mid-session.
//   Killed_Error        1    unreachable today (see its own comment), mapped so
//                            it cannot silently become 0 if it ever is produced.
//
// Deliberately NOT called by run(): run() is a library call and must never
// terminate its caller's process -- an embedder that runs a TUI as one phase of
// a longer program has to be able to keep going. The caller writes
// `os.exit(rt.exit_code(err))` when os.exit is what it wants.
exit_code :: proc(err: Run_Error) -> int {
	switch _ in err {
	case Interrupted_Error: return 130
	case Panicked_Error:    return 1
	case Terminal_Error:    return 1
	case Killed_Error:      return 1
	}
	return 0
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
	// Resolved ONCE here and used for both the mailbox's capacity and this
	// host's coalescing budget -- the two are the same number by construction
	// (see the coalescing-budget comment above Program.mailbox_cap's own).
	mbox_cap := program_mailbox_cap(p)

	rc := new(Reap_Ctx, context.allocator)
	if rc == nil {
		return Terminal_Error{detail = "dispatcher/mailbox allocation failed"}
	}
	if err := mailbox_init(&rc.mbox, mbox_cap); err != nil {
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
	//
	// THE RESULT IS CHECKED (F15). signal_watcher_start can only fail one way
	// -- thread.create returning nil under thread-creation pressure -- and it
	// used to report that by dereferencing the nil. A false return means the
	// watcher owns nothing and has already put the caller's signal mask back,
	// so the only thing left to reclaim here is what THIS proc has allocated
	// so far: rc and its mailbox. Everything else is still un-started.
	//
	// WHY THIS IS FATAL RATHER THAN A DEGRADED SESSION, when the same failure
	// for a Cmd is only a Panicked_Msg: without the watcher, the blocked-mask
	// premise in the comment above is what breaks. run()'s stated contract is
	// that it "returns an error rather than dying", and that holds for an
	// external SIGINT/SIGTERM only because a watcher exists to sigwait for it.
	// Carrying on would mean a session that dies outright on `kill -INT`,
	// leaving the terminal raw and on the alternate screen -- and one that
	// never learns its own size again either, since SIGWINCH is the only
	// resize notification there is.
	sw: Signal_Watcher
	if flush_fd >= 0 && !signal_watcher_start(&sw, &rc.mbox, flush_fd) {
		mailbox_destroy(&rc.mbox)
		free(rc, context.allocator)
		return Terminal_Error{detail = "could not start the signal watcher thread (pthread_create failed)"}
	}

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
	//
	// (QUIT_GRACE itself is declared at package scope, above, because
	// run_nbio() now bounds its own teardown with the SAME number -- see
	// loop_nbio.odin. It used to be a local here, and run_nbio's teardown used
	// to be unbounded, which is precisely what made the two hosts disagree
	// about how long quitting takes.)
	// The bool is RECORDED, not discarded. `defer dispatcher_reap(rc,
	// QUIT_GRACE)` threw away the one fact a caller cannot recover any other
	// way -- that this call is returning while a detached reaper thread still
	// owns and is about to free ~7 KiB of allocations made through the caller's
	// own context.allocator. See Program.reaper_pending for the measured
	// consequence (a deterministic SIGSEGV, not a phantom leak report, for an
	// embedder that reclaims a scoped allocator on the next line) and for what
	// a caller is expected to do about a `true`.
	defer { p.reaper_pending = !dispatcher_reap(rc, QUIT_GRACE) }
	// The view-leak summary, on the way out of every exit path this proc has
	// (there are several, and one of them is a recovered panic). Declared here
	// so LIFO puts it AFTER the loop and before nothing that matters.
	defer view_leak_report(p.view_leak_frames, p.view_leak_blocks, p.view_leak_bytes)
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

	// Initial paint, then the init Cmd -- in that order, so an app whose first
	// action is asynchronous still shows its loading state immediately.
	//
	// Guarded (T1, docs/superpowers/tier1-coverage-decision.md): this is a
	// real call to user code -- p.view -- happening before the mailbox loop,
	// the reader thread, or the dispatcher have processed anything, and a
	// panic here is exactly as real a crash as one from the loop's own
	// per-frame paint (guarded_render below is the SAME helper both call, so
	// there is only one guarded-view code path to reason about, not two that
	// could drift). Returning early on a panic here is correct, not merely
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
	// NIL-CHECKED, and this line is where F15's first fix wave left a
	// SIGSEGV. thread.create returns nil -- silently, no fault, no error
	// value -- whenever pthread_create fails (core/thread/
	// thread_unix.odin:122-125), which is the same real condition (RLIMIT_NPROC,
	// RLIMIT_AS, a loaded box) that cmd.odin's detached spawn already handles.
	// `reader.data = &rd` on the next line dereferenced that nil, so a machine
	// under thread pressure did not degrade, it died: measured as a segfault
	// right here once cmd.odin's own spawn failure stopped hanging first.
	//
	// A FAILED READER ENDS THE SESSION, it does not degrade it. The reader is
	// the ONLY producer of Key_Msg in this loop -- without it the program
	// paints its first frame and then blocks in mailbox_recv until something
	// external (a signal, an in-flight Cmd) happens to arrive, and no keypress
	// will ever quit it. A UI nobody can type into is not a running program, so
	// the honest outcome is a Terminal_Error the caller can print and turn into
	// a non-zero exit status via exit_code (F31), not a frozen screen.
	//
	// Returning HERE, before the teardown defer below is declared, is
	// deliberate and safe: that defer joins and destroys `reader`, which does
	// not exist. Everything that DOES exist by now -- the frame arena, the
	// renderer, the Signal_Watcher, the Dispatcher (and whatever p.init_cmd
	// dispatched into it) -- is already covered by defers declared further up.
	reader := thread_create_checked(reader_thread)
	if reader == nil {
		return Terminal_Error{detail = "could not start the input reader thread (pthread_create failed)"}
	}
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

	// THE COALESCING LOOP. Block for one message, then apply every message
	// that is ALREADY QUEUED behind it -- all of them, in order, to the model
	// -- and paint ONCE at the end. See apply_msg's own comment for the
	// measurements that forced the split, and COALESCE_BUDGET for why the inner
	// loop is bounded at all.
	//
	// COALESCING IS ABOUT PAINTS, NOT MESSAGES. Every message still reaches
	// update(), in arrival order, and every Cmd it returns is still dispatched
	// from inside apply_msg the instant that message is applied -- so nothing
	// about Cmd latency or message ordering changes. What disappears is the
	// N-1 intermediate frames nobody could have seen, because they were
	// overwritten within microseconds by the next one.
	//
	// `dirty` is what keeps the frame stream for an ordinary interactive
	// session byte-for-byte identical to the pre-coalescing one. A Quit_Msg or
	// an Interrupt_Msg is handled before update() and reports false, exactly as
	// the old per-message apply() painted no frame for either; so a lone quit
	// still produces no frame of its own, and a quit that arrives behind real
	// work paints that work once before the loop ends. That is also the answer
	// to "stay responsive on quit": the inner loop breaks the moment p.quit is
	// set rather than draining the rest of the queue first.
	//
	// AN ERROR ENDS THE BATCH WITHOUT PAINTING IT, deliberately. If message 3
	// of 5 panics, the frame that would have shown messages 1-2 is never
	// painted -- run() is returning Panicked_Error and the session is over.
	// Painting a batch that did not complete would be inventing a frame the
	// program never actually reached, and the frames in question are ones the
	// coalescing design says nobody sees anyway.
	for !p.quit {
		msg, ok := mailbox_recv(&rc.mbox)
		if !ok { break }   // closed and drained

		dirty := false
		for n := 0; ; n += 1 {
			e, updated := apply_msg(p, msg, &fa, &rc.disp, &r)
			if updated { dirty = true }
			if e != nil { return e }
			if p.quit { break }
			if n + 1 >= mbox_cap { break }
			next, more := mailbox_try_recv(&rc.mbox)
			if !more { break }
			msg = next
		}

		if dirty {
			if e := guarded_render(p, &fa, &r, out, flush_fd); e != nil { return e }
		}
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
		case .Closed:
			// NOTHING TOOK THE MESSAGE, so this proc still owns it. Dropping
			// the `any` on the floor here leaked exactly one box() allocation
			// per session -- 12 bytes for the Key_Msg this reader was holding
			// when run() closed the mailbox out from under it -- which is
			// small but unbounded in the only sense that matters to
			// tools/test.sh's leak audit: it is a real allocation with no
			// owner, and the audit allows exactly one site (the bounded
			// ^Thread in dispatcher_reap). cmd.odin's run_cmd_task and
			// run_cmd_detached already box_free on this identical outcome;
			// this is the third consumer that owed the same thing.
			box_free(msg, context.allocator)
			return true
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

// ONE guarded Update. No view, no render, no flush -- the caller paints, once,
// after it has applied everything it had.
//
// WHY THE PAINT IS NOT IN HERE ANY MORE. This proc used to be `apply`: update
// AND render AND write(2), and both hosts called it once per message. That made
// the frame count a function of the MESSAGE count rather than of how much had
// actually changed, and both hosts inherited it -- run_nbio drained the mailbox
// in a batch but still applied-and-painted per message, so it coalesced
// nothing either. The cost, and what the split bought, measured on a text
// field that echoes what it is given (scratchpad/scratch-frames/amp) with the
// payload delivered in a SINGLE write(2) exactly as a real terminal delivers a
// paste. Both columns are the same binary, the same renderer and the same pty;
// only this proc differs:
//
//     payload         before        after      write(2) calls
//       1 B            147 B        147 B      (unchanged)
//      10 B            806 B        167 B
//     200 B         34,673 B        557 B
//   1,332 B      1,045,721 B      7,389 B      1,338 -> 12
//
// A megabyte of escape sequences down the terminal link, over ~1,300 syscalls,
// for a paste that fits in one packet. The 1-byte row is deliberately
// UNCHANGED: a lone keystroke was already one frame and still is, and the
// single-keystroke round trip measures the same before and after (median
// 0.16 ms vs 0.17 ms, p90 0.20 vs 0.22, 60 samples each) -- coalescing what is
// ALREADY queued adds no latency, which is exactly why this is not a
// frame-rate cap. It is the same shape Bubble Tea's standardRenderer has:
// apply what has arrived, paint the result.
//
// A SPLIT, NOT A "should I render?" PARAMETER. Only the caller knows whether
// more messages are already waiting, so a flag would have meant each host
// deciding that for itself -- precisely the divergence this proc is shared
// (rather than copied into loop_nbio.odin) to make impossible. With the split
// the two hosts share BOTH halves: apply_msg here and guarded_render below.
//
// THE CRASH GUARDS ARE UNCHANGED AND STILL SEPARATE. The update guard is here;
// the view guard is in guarded_render, where it always was -- they were already
// two sequential guarded() calls rather than one nested pair (see
// guarded_render's STRUCTURE note), so moving the second one out to the caller
// changes nothing about either. A panicking update still returns
// Panicked_Error from here with the frame arena reclaimed; a panicking view
// still paints its diagnostic frame and returns Panicked_Error from there.
//
// `updated` reports whether the message reached the user's update() -- i.e.
// whether there is anything new to paint. Quit_Msg and Interrupt_Msg are
// handled before update() and report false, which is what makes a coalesced
// frame stream byte-for-byte identical to the old per-message one whenever
// messages arrive one at a time.
//
// package-visible, not file-visible: loop_nbio.odin's run_nbio shares this
// verbatim rather than duplicating it, so both event-loop hosts run IDENTICAL
// Update/quit/panic-recovery logic and can only differ in how a message
// reaches this call, not in what happens once it does.
@(private="package")
apply_msg :: proc(p: ^Program($T), msg: any, fa: ^Frame_Arena, disp: ^Dispatcher, r: ^Renderer) -> (err: Run_Error, updated: bool) {
	// Every msg reaching apply_msg came off the mailbox, which means it was
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

	// ARM THE FRAME-ALLOCATOR GUARD for the whole of this proc (F07). This is
	// one of the two places in the package where a frame allocator is handed to
	// user code, and the ONLY thing that makes "did you give us back the
	// allocator we just gave you?" answerable -- see cmd.odin's THE FRAME
	// ALLOCATOR IS NOT A Cmd ALLOCATOR for the two-pointer test and for why
	// arming (rather than comparing against virtual.arena_allocator_proc alone)
	// is what keeps an application's own long-lived arena legal.
	//
	// THE WHOLE PROC, not just the guarded() update call, deliberately: the
	// dispatch of whatever update() returned happens further down, OUTSIDE the
	// guard, and dispatch_ex's own backstop can only fire while a frame is
	// armed. Two atomic stores per message against an update() call and a
	// dispatch; the cost is not measurable.
	prev_frame_guard := frame_guard_arm(frame_allocator(fa))
	defer frame_guard_disarm(prev_frame_guard)

	if _, is_quit := msg.(Quit_Msg); is_quit { p.quit = true; return nil, false }
	if _, is_int := msg.(Interrupt_Msg); is_int { return Interrupted_Error{}, false }

	// F08. A MESSAGE-CONTRACT VIOLATION ENDS THE SESSION; AN ORDINARY Cmd PANIC
	// DOES NOT. Both arrive here as Panicked_Msg, and telling them apart is the
	// whole of this branch (arena.odin's BOX_CONTRACT_PANIC is the marker, and
	// carries the argument for why the two are different KINDS of event).
	//
	// WHAT THIS FIXES. `box()` refuses a non-POD Msg with a panic. That panic
	// is raised on a pool worker, recovered by run_cmd_guarded, and demoted to a
	// Panicked_Msg -- so a Cmd that returns, say, `box(Err_Msg{reason: string})`
	// produced NO result, NO diagnostic, and no error from run(). The Cmd simply
	// never answered. Every shipped example, and the canonical update switch in
	// README.md and docs/API.md, either has no `case rt.Panicked_Msg` at all or
	// has one with an empty body, so the single most likely first mistake a new
	// user makes -- putting a string in a Msg -- was reported into a switch arm
	// nobody had written and then dropped on the floor. Wave 1 made the text name
	// the offending type and the box() call site; this is what makes the text
	// arrive somewhere.
	//
	// WHY NOT STDERR, which is the fixlist's other suggestion. By the time a Cmd
	// is running, the terminal is in raw mode and quite possibly on the alternate
	// screen, so anything written to stderr is painted into a buffer that
	// `\e[?1049l` discards on exit: the user sees nothing at all. That is the
	// whole reason cmd.odin routes these reports through the mailbox in the first
	// place, and printing here would repeat the mistake one layer up.
	// Panicked_Error goes out through run()'s RETURN VALUE, which is the one
	// channel that outlives the alternate screen -- the caller prints it after
	// its own `defer term_restore()` has run, and exit_code turns it into a
	// non-zero status (F31).
	//
	// WHY IT DOES NOT MAKE AN ORDINARY Cmd PANIC NOISIER. The prefix test is the
	// gate. A Cmd whose body panics on its own account still delivers an
	// ordinary Panicked_Msg to update(), the session still continues, and the app
	// still decides -- pinned by test_program_survives_a_panicking_cmd, which
	// asserts `err == nil` for exactly that program. Nothing about that path
	// changes, and nothing new is printed on it.
	//
	// WHY BEFORE update() RATHER THAN AFTER. There is no way to observe whether
	// an app's `switch` matched a case, so "escalate only what update() ignored"
	// is not implementable; and handing this to update() first would mean
	// dispatching whatever Cmd it returned and then killing the session anyway,
	// which is a worse story than not asking. Quit_Msg and Interrupt_Msg are
	// already handled ahead of update() for the same reason -- some messages are
	// the loop's business, not the model's.
	//
	// SYMMETRY, not a special case: a panic in update() ends the session with
	// Panicked_Error and so does a panic in view() (guarded_render). A Cmd body
	// is user code too; what makes THIS report terminal is not that it came from
	// a Cmd but that it says the program broke a rule the framework enforces, so
	// the next attempt will break it identically.
	//
	// KNOWN GAP, and it is cmd.odin's to close, not this branch's: a report that
	// never reaches the mailbox never reaches here. deliver_report (cmd.odin)
	// box_frees and drops on .Closed, so a violation detected AFTER run() has
	// begun tearing the mailbox down is still silent. Verified with two probes:
	// the same program over a pty escalates, while one driven by
	// input_source_from_bytes -- where EOF closes the mailbox first -- does not.
	// It is a teardown-only window (the session is ending either way), but "fail
	// loudly" currently means "fail loudly while the loop runs".
	if pm, is_report := msg.(Panicked_Msg); is_report {
		text := msg_text_string(&pm.message)
		// TWO MARKERS, ONE POLICY. box()'s marker says "this Msg type can
		// never be delivered"; cmd.odin's says "this Cmd's env was allocated
		// from a frame arena and can never be read" (F07). Both are contract
		// violations that will recur identically on the next attempt, so both
		// end the session rather than being handed to a `case Panicked_Msg`
		// that the canonical update switch leaves empty. dispatch_ex cannot
		// panic its own refusal -- it runs outside guarded() -- so this is
		// where that half of the F07 check becomes visible to a caller.
		if is_box_contract_panic(text) || is_cmd_alloc_contract_panic(text) {
			// Cloned because Panicked_Error's caller owns `message` and must
			// delete() it (see the type's own doc comment), while `text` borrows
			// the fixed buffer inside a box the deferred box_free above is about
			// to reclaim.
			return Panicked_Error{message = strings.clone(text, context.allocator)}, false
		}
	}

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
		return Panicked_Error{message = info.message}, false
	}

	if !cmd_is_nil(step.cmd) { dispatch(disp, step.cmd) }

	// The frame arena is NOT reset here. It was, implicitly, by the render
	// this proc used to end with -- and that is exactly why the reset now
	// belongs to guarded_render alone: whatever update() allocated from the
	// frame allocator has to stay alive until the view that may read it has
	// run, which is now one or more messages later. guarded_render still
	// resets on every one of its own exit paths, so the arena is reclaimed
	// once per FRAME instead of once per message, which is what the arena's
	// LIFETIME CONTRACT (arena.odin) has always described.
	return nil, true
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
// the Renderer, flushes, and reclaims the frame arena. THREE call sites share
// this -- run()'s initial paint, run()'s per-batch paint, and run_nbio's
// per-batch paint (loop_nbio.odin) -- which is the point: view has exactly one
// guarded code path, not three hand-maintained copies that could drift.
//
// These four steps used to be the tail of apply(), which ran them once per
// MESSAGE. Splitting them out (see apply_msg above for the amplification this
// cost) is what lets a host apply a whole batch and paint the result once; the
// steps themselves, and their order, are unchanged.
//
// STRUCTURE (constraint a, tier1-coverage-decision.md): this is a SEPARATE,
// SEQUENTIAL guarded() call, not one nested inside apply_msg's update guard.
// apply_msg's own guarded(update) call has already returned (successfully or
// not) by the time a caller reaches this, so g_armed is back to false and this call is
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
	// F53. WHETHER THE TERMINAL CAN READ ESCAPES AT ALL is read here, on the one
	// paint path run() and run_nbio() share, and not inside renderer_init.
	//
	// term_enter_raw has gated its five opt-ins on term_supports_escapes() since
	// the term-guard wave, so a TERM=dumb session already got no Kitty push, no
	// bracketed paste, no mouse tracking, no focus reporting and no alternate
	// screen -- and then the renderer wrote \e[H, \e[2J, \e[K, CUP and SGR at it
	// anyway, which an Emacs comint pty answers by printing them. Renderer.plain
	// is what closes that half; render_plain is what it degrades to.
	//
	// HERE RATHER THAN IN renderer_init, deliberately. renderer_init is called
	// by every byte-exact test in this package and by tools/difftest, and making
	// its result depend on the ambient TERM would make those tests pass or fail
	// by shell. The environment belongs to the SESSION, so the host that owns
	// the session reads it. Once per frame rather than once per run because
	// term_supports_escapes is itself deliberately uncached (a copy of the
	// environment is a second source of truth) and the read costs 82 ns --
	// 5 us per second of wall clock at 60 frames, measured, versus the ~10 us
	// this proc is about to spend in strings.split_lines alone.
	r.plain = !term_supports_escapes()

	// The second of the two places this package hands a frame allocator to user
	// code, armed for the same reason apply_msg arms it (F07, cmd.odin). view()
	// and cursor() do not return Cmds, so nothing here is expected to trip it --
	// but "the app calls a helper from its view that builds a Cmd" is not a
	// shape the framework can rule out, and an armed guard that never fires
	// costs two atomic stores per frame.
	prev_frame_guard := frame_guard_arm(frame_allocator(fa))
	defer frame_guard_disarm(prev_frame_guard)

	// WATCH context.allocator ACROSS THE VIEW, and only across the view. This
	// is the whole of the leak detector 3.15 said could not exist -- see
	// viewleak.odin for why watching context.allocator is sound where watching
	// the ARENA is not, and for why it counts blocks rather than bytes.
	//
	// SCOPED TIGHTLY TO USER CODE. The renderer below this point legitimately
	// allocates from context.allocator (the .Diff cell grids), and the reader
	// thread and Dispatcher do too; none of that is a view leak and none of it
	// is inside these three lines. What IS inside them is p.view and p.cursor,
	// which is exactly the boundary the contract is about.
	//
	// RESTORED UNCONDITIONALLY, including on the panic path: guarded() recovers
	// internally and RETURNS rather than propagating, so the assignment below it
	// always runs. A longjmp that skipped the restore would leave the rest of
	// the loop allocating through a counter whose Program may outlive it.
	watch := View_Leak_Watch{backing = context.allocator}
	real_allocator := context.allocator
	context.allocator = view_leak_watch_allocator(&watch)

	vs := View_Step(T){p = p, alloc = frame_allocator(fa)}
	info := guarded(proc(ud: rawptr) {
		s := cast(^View_Step(T))ud
		s.view = s.p.view(s.p.model, s.alloc)
		if s.p.cursor != nil { s.cur = s.p.cursor(s.p.model, s.alloc) }
	}, &vs)

	context.allocator = real_allocator
	// A frame that left blocks behind on context.allocator leaked them: the
	// arena reset that follows cannot reclaim what the arena never held.
	// Counted, not acted on -- see view_leak_report for what is done with it
	// and why nothing is done for a single frame.
	if watch.blocks > 0 {
		p.view_leak_frames += 1
		p.view_leak_blocks += watch.blocks
		p.view_leak_bytes  += watch.bytes
	}

	if info.recovered {
		// longjmp ran no defers: reclaim whatever the failed view() call
		// allocated from the frame arena (a partially-built strings.Builder,
		// etc.) before building the diagnostic from a clean arena -- same
		// wholesale-reclaim move apply_msg already makes for a failed update().
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
