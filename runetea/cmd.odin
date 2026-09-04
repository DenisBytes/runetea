package runetea

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

// Go's `type Cmd func() Msg` is a closure. Odin has no closures at all, so the
// captured environment becomes explicit. This is the port's largest permanent
// ergonomic cost and it touches every user program.
//
// `procedure` takes a `^Cancel_Token` as its second argument -- see
// Cancel_Token's own doc comment below and docs/superpowers/
// cancellation-decision.md for the full design. This is a real, deliberate
// ergonomic cost too (every Cmd body's signature grows one parameter), chosen
// specifically so cancellation needs NO change to cmd_from's own call shape
// (still exactly `cmd_from(fn, env, alloc)`) and no per-Cmd env boilerplate --
// a Cmd that does not care about cancellation just ignores the parameter. The
// token is wired up automatically by dispatch()/run_cmd_task/run_cmd_detached
// below; callers never construct or pass one themselves.
Cmd :: struct {
	procedure: proc(env: rawptr, cancel: ^Cancel_Token) -> any,
	env:       rawptr,
	allocator: mem.Allocator,   // frees env after procedure returns
	detached:  bool,            // bypass the pool -- see dispatch

	// Non-nil ONLY for a Cmd produced by tick()/every() (timer.odin) --
	// dispatch() below special-cases these entirely, bypassing procedure/
	// env/allocator/detached above (left zeroed for such a Cmd) in favor of
	// the dedicated timer thread. See timer.odin's own top-of-file comment
	// for why registering a timer doesn't fit run_cmd_task/run_cmd_detached's
	// "exactly one result per dispatch" shape.
	timer: ^Timer_Handle,

	// Non-nil ONLY for a Cmd produced by batch()/sequence() (batch.odin) --
	// same bypass pattern as `timer` immediately above, for the same reason:
	// a batch/sequence Cmd doesn't run a single procedure/env pair at all, it
	// coordinates a whole heap-owned list of child Cmds, which doesn't fit
	// run_cmd_task/run_cmd_detached's "exactly one result per dispatch" shape
	// either. See batch.odin's own top-of-file comment and
	// docs/superpowers/batch-sequence-decision.md for why this couldn't be a
	// Msg (BatchMsg([]Cmd), Go's own shape) instead: box()'s MESSAGE
	// OWNERSHIP CONTRACT (arena.odin) rejects any Msg with a slice field, and
	// []Cmd is exactly that.
	compose: ^Compose_Spec,

	// SINGLE-USE ENFORCEMENT. Zero ({0, 0}) for a Cmd that owns no heap
	// memory at all -- cmd_nil() and quit_cmd(), which stay safe to build and
	// return as often as anyone likes. Non-zero for every constructor that
	// allocates: cmd_from (env), tick/tick_cancellable/every (Timer_Handle +
	// cloned fn env, timer.odin), batch/sequence (Compose_Spec + the cloned
	// child list, batch.odin). See the Cmd ledger below for what the two
	// numbers mean and why the flag CANNOT live inside the memory the Cmd
	// owns.
	ticket: Cmd_Ticket,
}

// ---------------------------------------------------------------------------
// A Cmd IS SINGLE-USE, AND RE-DISPATCH FAILS LOUDLY.
//
// WHAT USED TO HAPPEN. `Cmd` is a plain copyable struct with public fields,
// and in Bubble Tea a `tea.Cmd` is a func value you may hand back from Update
// as often as you like. Here every constructor heap-clones something
// (cmd_from's env, timer_new's handle, compose's spec + child list) and
// dispatch is what consumes it: run_cmd_guarded below frees cmd.env
// unconditionally after the body returns. So `m.saved := cmd_from(...)`
// returned twice -- or, with no stored state at all, the same Cmd value
// listed twice in one batch() -- ran the second dispatch's body against freed
// env and then freed the same pointer again. Measured, on this toolchain:
// SIGSEGV exit 139, 6/6 runs, with no diagnostic whatsoever; under
// mem.Tracking_Allocator, a hard "Bad free" abort. A reused batch()/sequence()
// Cmd was worse rather than louder -- three blocks double-freed (spec.cmds,
// spec, each child env), and because the freed 40-byte Compose_Spec slot holds
// an allocator freelist pointer where `kind` used to be, compose_procedure's
// `switch ce.spec.kind` read a garbage enum and matched NEITHER case: the
// re-dispatch silently did nothing at all, so the app's first symptom was a
// stale UI, not a crash.
//
// THE TRAP IN THE OBVIOUS FIX. "Give the Cmd a `spent: ^bool` and check it on
// the second dispatch" does not work, and it is worth writing down why,
// because it is the first thing anyone reaches for: the flag would live in a
// block the FIRST dispatch frees, so reading it on the second dispatch is
// exactly the use-after-free the guard exists to prevent -- it just reads one
// byte instead of running a whole Cmd body. Keeping that block alive instead
// trades a use-after-free for an unbounded leak: one allocation per Cmd, i.e.
// ~60/s for a 60fps spinner, forever. A fix that leaks unboundedly to detect a
// leak is not a fix.
//
// WHAT THIS DOES INSTEAD. A Cmd carries a {slot, generation} TICKET -- two
// integers, copied by value like every other field, pointing at nothing. The
// ledger below owns a slot table that is allocated once and NEVER freed or
// shrunk, so looking a ticket up is always a read of live memory no matter how
// long ago the Cmd was consumed. Claiming a slot bumps its generation and
// returns the slot to a free list for reuse, so a stale ticket compares
// unequal against every subsequent occupant of that slot -- there is no "was
// this pointer freed?" question to answer, only an integer comparison that is
// always safe to make.
//
// ITS OWN LIFETIME, STATED RATHER THAN IMPLIED. The table is two [dynamic]u32
// on runtime.heap_allocator() -- deliberately NOT context.allocator, because
// odin test rotates a fresh Tracking_Allocator per test and a
// process-lifetime table grown under test A's allocator and read under test
// B's is exactly the cross-allocator corruption cmd.odin's own
// init_context comment already documents for detached threads. Cost: 8 bytes
// per slot, and the table only ever grows to the HIGH-WATER MARK of tickets
// outstanding (issued, not yet claimed) at one instant -- a handful for any
// ordinary program, because dispatch claims a ticket back immediately.
// This is a bounded, one-off, process-lifetime allocation that no leak audit
// will ever see freed; it is charged honestly here rather than hidden.
// The one case that grows it without bound is a Cmd built and never
// dispatched and never handed to compose_free_unrun -- which already leaks
// its env today, so the ticket adds 8 bytes to an existing per-construction
// leak rather than creating a new class of one.
//
// THE HONEST LIMIT: generation is u32, so a ticket held across 2^32 claims of
// the SAME slot would alias again. At the ~60 dispatches/second a 60fps
// spinner produces, with the free list handing that slot back every time, that
// is roughly two years of continuous running before one specific stale Cmd
// value could be mistaken for live -- and the failure mode it degrades to is
// the pre-fix behaviour, not something worse.
Cmd_Ticket :: struct {
	slot: u32,   // 1-based index into the ledger; 0 means "this Cmd owns nothing" -- see Cmd.ticket
	gen:  u32,   // generation this ticket was issued at; never 0 for a live ticket
}

// Guards BOTH arrays. dispatch() is called from the loop thread, from pool
// workers, from detached Cmd bodies and from compose coordinator threads, and
// cmd_from()/tick()/batch() are called from any of those too -- so both
// operations below are genuinely concurrent and neither can be a plain
// non-atomic read-modify-write. The lock is uncontended in practice and costs
// one atomic per Cmd construction and one per dispatch, against a dispatch
// that already spawns a thread or queues a pool task.
@(private = "file") g_ledger_mu:   sync.Mutex
@(private = "file") g_ledger_gen:  [dynamic]u32   // g_ledger_gen[s-1] is the generation of the ticket currently outstanding for slot s
@(private = "file") g_ledger_free: [dynamic]u32   // slots whose ticket has been claimed and may be reissued

// Must be called with g_ledger_mu held. runtime.heap_allocator(), not
// context.allocator -- see the Cmd ledger comment above for why that choice
// is load-bearing and not incidental.
@(private = "file")
cmd_ledger_ensure :: proc() {
	if g_ledger_gen.allocator.procedure == nil {
		g_ledger_gen  = make([dynamic]u32, 0, 64, runtime.heap_allocator())
		g_ledger_free = make([dynamic]u32, 0, 64, runtime.heap_allocator())
	}
}

// Issues the ticket a heap-owning Cmd constructor stamps into Cmd.ticket.
// Returns the zero ticket if the table cannot grow -- which degrades that one
// Cmd to the pre-fix "unguarded" behaviour rather than failing the
// construction outright, because an allocator that cannot find 4 bytes here
// has already failed to clone the env one line earlier in every caller.
@(private = "package")
cmd_ticket_issue :: proc() -> Cmd_Ticket {
	sync.mutex_lock(&g_ledger_mu)
	defer sync.mutex_unlock(&g_ledger_mu)
	cmd_ledger_ensure()

	s: u32
	if n := len(g_ledger_free); n > 0 {
		s = g_ledger_free[n - 1]
		pop(&g_ledger_free)
	} else {
		// Generation starts at 1, never 0: a zero ticket already means "owns
		// nothing", so no live ticket may ever compare equal to one.
		if _, err := append(&g_ledger_gen, u32(1)); err != nil { return Cmd_Ticket{} }
		s = u32(len(g_ledger_gen))
	}
	return Cmd_Ticket{slot = s, gen = g_ledger_gen[s - 1]}
}

// Takes ownership of whatever `t` guards, exactly once. True means "this
// caller now owns the Cmd's heap memory and must free or consume it"; false
// means the Cmd was already dispatched (or already reclaimed by
// compose_free_unrun) and the caller must touch NOTHING it points at.
//
// The zero ticket always succeeds: cmd_nil() and quit_cmd() own nothing, and
// existing code returns those from update() on every keystroke.
@(private = "package")
cmd_ticket_claim :: proc(t: Cmd_Ticket) -> bool {
	if t.slot == 0 { return true }

	sync.mutex_lock(&g_ledger_mu)
	defer sync.mutex_unlock(&g_ledger_mu)

	i := int(t.slot) - 1
	if i < 0 || i >= len(g_ledger_gen) { return false }
	if g_ledger_gen[i] != t.gen        { return false }

	g_ledger_gen[i] += 1
	// If this append fails the slot is simply never reissued -- 8 bytes
	// stranded in a table that is already never freed, which is strictly
	// preferable to failing the claim and stranding the Cmd's whole env.
	_, _ = append(&g_ledger_free, t.slot)
	return true
}

cmd_nil :: proc() -> Cmd { return Cmd{} }

// c.timer == nil and c.compose == nil are part of this check, not just
// c.procedure == nil: a Cmd produced by tick()/every() (timer.odin) or by
// batch()/sequence() (batch.odin) has procedure == nil by construction (it
// never runs through run_cmd_task/run_cmd_detached at all -- see dispatch()'s
// own special cases below), so checking procedure alone would misreport
// every such Cmd as nil. That matters beyond symmetry: apply() and run()
// (tea.odin) both guard their dispatch() call with `if !cmd_is_nil(cmd)`, so
// a wrong answer here would silently drop every Tick/Every/batch/sequence
// before dispatch() ever saw it.
cmd_is_nil :: proc(c: Cmd) -> bool { return c.procedure == nil && c.timer == nil && c.compose == nil }

// ---------------------------------------------------------------------------
// THE FRAME ALLOCATOR IS NOT A Cmd ALLOCATOR, AND THE FRAMEWORK NOW SAYS SO
// OUT LOUD (F07).
//
// WHAT USED TO HAPPEN. update() is handed exactly one allocator and it is
// spelled `alloc`. Every Cmd constructor takes an allocator as its last
// argument. So `return cmd_from(fetch, env, alloc)` is the obvious move, it
// compiles clean, and it is a use-after-free every single time: the env is
// heap-cloned INTO the frame arena, apply_msg dispatches the Cmd, and
// guarded_render calls frame_reset(fa) at the end of the same frame -- almost
// always before the worker thread has touched the env. virtual.Arena zeroes
// reused blocks on .Alloc, so the Cmd body does not even read garbage it might
// notice; it reads a deterministically ZEROED env. Measured 3/3: a Cmd body
// that should have printed tag="PAYLOAD!" len=8 printed tag="" len=0, run()
// returned nil, the process exited 0, and nothing anywhere said a word. In a
// release build and in -debug alike.
//
// WHY THIS IS DETECTABLE AT ALL, which is the only reason this exists. The
// frame arena is not an abstract "wrong allocator" -- it is ONE specific
// mem.Allocator value that this package constructs (frame_allocator, arena.odin)
// and hands to user code at exactly two points (apply_msg's update call and
// guarded_render's view/cursor call, tea.odin). Its `procedure` is
// virtual.arena_allocator_proc and its `data` is that frame's own ^virtual.Arena.
// Both are values this package knows, so "did the caller pass us the allocator we
// just gave them?" is two pointer comparisons.
//
// WHY IT IS ARMED PER FRAME RATHER THAN ALWAYS ON. Comparing against
// virtual.arena_allocator_proc ALONE would refuse every virtual.Arena in the
// program, including an application's own long-lived one that outlives every
// frame and is a perfectly correct place to put a Cmd env. That is a false
// refusal of legal code, which is worse than the miss it prevents. So the
// `data` half is compared too, against the arena of the frame currently being
// processed -- tea.odin arms it around apply_msg and guarded_render and
// restores the previous value afterwards. A false positive would require an
// allocator over the SAME live frame arena, which is doomed for the same
// reason regardless of who made it.
//
// WHY NOT COMPILE-TIME GATED, like VIEW_STRICT/DIFF_STRICT. Those guard a
// per-LINE scan of every view; this is one load and up to two pointer
// compares per Cmd constructed, on a path that is already about to make a heap
// allocation and (usually) start a thread -- unmeasurable. And the failure it
// catches is a SILENT memory-corruption bug whose only symptom is a Cmd that
// answers with zeroes, which is precisely the class of bug you want caught in
// the -o:speed build your users are running, not only in the one you test
// with. A check that is off exactly where the consequences are worst is how
// the .Diff contract check (F27) came to be useless.
//
// WHAT IT DOES NOT CATCH, stated so nobody reads more into it than is there:
// the window is armed while a frame is being processed, so a Cmd constructed
// on a pool worker from a frame allocator that the app smuggled into its model
// is caught only if a frame happens to be in flight on the loop thread at the
// same moment. dispatch_ex's backstop below is what covers the stored-Cmd
// version of that. An allocator that is neither of these -- a scoped arena of
// the app's own that it frees on the next line -- is outside what this package
// can see at all, and remains the caller's contract to keep.
@(private = "package")
CMD_ALLOC_CONTRACT_PANIC :: "cmd(): "

// True iff `text` is the refusal this file raises for a frame-allocated Cmd
// env, so apply_msg (tea.odin) can escalate it the way it escalates box()'s
// own contract panic. Prefix, not substring, for the same reason
// is_box_contract_panic gives: an app may panic with any text it likes,
// including text quoting this one, and a report is only ours if OUR words
// come first.
@(private = "package")
is_cmd_alloc_contract_panic :: proc(text: string) -> bool {
	return len(text) >= len(CMD_ALLOC_CONTRACT_PANIC) && text[:len(CMD_ALLOC_CONTRACT_PANIC)] == CMD_ALLOC_CONTRACT_PANIC
}

// The ^virtual.Arena backing the frame allocator currently handed to user
// code, or nil between frames. A plain global, not thread-local: a Cmd body
// on a pool worker that constructs a Cmd from a smuggled frame allocator is
// making the same mistake as update() and should get the same answer, and a
// thread-local would be blind to it. Two concurrent run() sessions on
// different threads can overwrite each other's value, which can only ever
// cause a MISSED detection (the other session's arena pointer does not match
// this session's allocator), never a false one.
@(private = "package")
g_frame_arena_live: rawptr

// Arm/disarm around the two places this package hands `alloc` to user code.
// Save-and-restore rather than store-and-nil so the pair nests safely; today
// nothing nests, and a future guarded_render inside apply_msg would still be
// correct.
@(private = "package")
frame_guard_arm :: proc(a: mem.Allocator) -> rawptr {
	prev := sync.atomic_load(&g_frame_arena_live)
	sync.atomic_store(&g_frame_arena_live, a.data)
	return prev
}

@(private = "package")
frame_guard_disarm :: proc(prev: rawptr) {
	sync.atomic_store(&g_frame_arena_live, prev)
}

@(private = "package")
is_frame_allocator :: proc(a: mem.Allocator) -> bool {
	if a.procedure != virtual.arena_allocator_proc { return false }
	live := sync.atomic_load(&g_frame_arena_live)
	return live != nil && a.data == live
}

// PANICS rather than returning an error, and that is the same judgement box()
// makes for a non-POD Msg, for the same reason: this is a CONTRACT VIOLATION,
// not a runtime condition. There is nothing for the application to decide and
// nothing to recover -- that Cmd's result will never arrive, and it will never
// arrive on the next attempt either.
//
// The panic is raised inside update(), which apply_msg runs under guarded(),
// so it does not take the process down: it ends the session with
// Panicked_Error carrying this text, which run() returns and exit_code turns
// into status 1 (F31). That is the entire difference from the old behaviour --
// exit 0 with a zeroed env becomes a named failure at the exact call site.
//
// `loc` goes through the FORMAT STRING, not panic's own `loc` parameter, and
// that is not redundancy -- guard.odin's guard_assertion_failure clones only
// `message` and discards the runtime.Source_Code_Location it is handed, so a
// location passed the ordinary way never reaches the Panicked_Error. Both the
// constructor name and the location lead the text so they survive Msg_Text's
// 255-byte truncation on the paths that carry this through a Msg.
@(private = "package")
cmd_alloc_contract_check :: proc(what: string, alloc: mem.Allocator, loc: runtime.Source_Code_Location) {
	if !is_frame_allocator(alloc) { return }
	fmt.panicf(
		CMD_ALLOC_CONTRACT_PANIC + "%s at %v was given update()'s own frame allocator. The frame arena is reclaimed wholesale by frame_reset at the end of the frame -- before the Cmd body runs -- so this Cmd would read a zeroed env and answer with nothing. Pass context.allocator (or any allocator that outlives the frame). See arena.odin's LIFETIME CONTRACT and docs/API.md section 5.",
		what, loc)
}

// Heap-clones `env` so the Cmd can outlive the caller's frame.
//
// THE RETURNED Cmd IS SINGLE-USE. Dispatch consumes it (run_cmd_guarded frees
// the clone); dispatching the same Cmd VALUE a second time is refused and
// reported, not honoured -- see the Cmd ledger above. Store the ENV in your
// model and build a fresh Cmd each time, not the other way round.
//
// Set detached=true for a Cmd that itself dispatches and waits on other Cmds.
// Such coordinators must not occupy a pool worker: N coordinators on an N-wide
// pool leaves no worker for their children, which deadlocks. Detached is the
// deliberate equivalent of Go's leaked-goroutine-per-Cmd, used rarely.
//
// `alloc` MUST OUTLIVE THE FRAME. Passing update()'s own `alloc` is refused
// here, loudly, before anything is cloned into memory that is about to be
// reclaimed -- see THE FRAME ALLOCATOR IS NOT A Cmd ALLOCATOR above for what
// that used to cost. `loc` exists only so the refusal can name the call site;
// it is defaulted, so no existing call changes.
cmd_from :: proc(fn: proc(env: rawptr, cancel: ^Cancel_Token) -> any, env: $E, alloc: mem.Allocator, detached := false, loc := #caller_location) -> Cmd {
	cmd_alloc_contract_check("cmd_from", alloc, loc)
	p, err := new(E, alloc)
	if err != nil { return cmd_nil() }
	p^ = env
	return Cmd{procedure = fn, env = rawptr(p), allocator = alloc, detached = detached, ticket = cmd_ticket_issue()}
}

// COOPERATIVE cancellation flag, one per Dispatcher (i.e. one per run()/
// run_nbio() session -- see Dispatcher.cancel below). A Cmd polls it via
// cancel_requested to notice "the enclosing run() has started quitting" and
// return early instead of running to completion.
//
// THE HONEST LIMIT: this is polling, not preemption. Nothing about a
// Cancel_Token can interrupt a Cmd that is blocked inside a syscall it never
// returns from on its own -- time.sleep, net.recv_tcp with no timeout,
// waiting on a child process, etc. A Cmd that wants to be cancellable while
// doing I/O must combine this with a BOUNDED wait of its own (a socket
// timeout via net.set_option(.Receive_Timeout/.Send_Timeout), polled in a
// loop that checks cancel_requested between attempts -- see examples/http's
// check_server for a worked example) so it wakes up on its own periodically
// to check. See docs/superpowers/cancellation-decision.md for the full
// design, what core:net actually offers here, and why.
Cancel_Token :: struct {
	cancelled: bool,   // touched only via sync.atomic_load/store -- same pattern as Reader_Ctx.stop (tea.odin) and Signal_Watcher.stop (signals.odin)
}

// Safe to call with tok == nil -- always reports "not cancelled" in that
// case. That covers a Cmd invoked directly (not through dispatch()) in a
// test, and keeps this call unconditionally safe to sprinkle into any Cmd
// body regardless of how it was constructed.
cancel_requested :: proc(tok: ^Cancel_Token) -> bool {
	return tok != nil && sync.atomic_load(&tok.cancelled)
}

@(private = "file")
cancel_token_fire :: proc(tok: ^Cancel_Token) {
	sync.atomic_store(&tok.cancelled, true)
}

// PRECONDITION (mirrors mailbox.odin's mailbox_destroy contract): the caller
// must stop calling dispatch() before calling dispatcher_destroy, and must
// destroy the Dispatcher before destroying the Mailbox it was constructed
// with. dispatcher_destroy blocks until every pool worker AND every detached
// Cmd it ever dispatched has finished -- see the `inflight` field and the
// CRITICAL note on dispatcher_destroy below for why the latter needs its own
// tracking distinct from thread.Pool's built-in join.
Dispatcher :: struct {
	pool:      thread.Pool,
	mailbox:   ^Mailbox,
	inflight:  sync.Wait_Group,   // counts detached Cmds not yet finished
	cancel:    Cancel_Token,      // fired by dispatcher_destroy/dispatcher_reap; shared by every Cmd this Dispatcher ever runs

	// Every detached Cmd's `^Thread` that has not yet been joined and freed.
	// A detached Cmd is spawned with self_cleanup = FALSE (see dispatch_ex's
	// detached branch, and the long WHY self_cleanup = false comment below
	// dispatcher_reap for the race that forces it), which means core:thread
	// neither detaches the OS thread nor frees the `^Thread` struct for us --
	// so this package has to. detached_threads_sweep reclaims the finished
	// ones on every subsequent detached dispatch and detached_threads_drain
	// takes the rest inside dispatcher_destroy, which is what keeps the live
	// entries bounded by the number of detached Cmds running CONCURRENTLY
	// rather than by how many have ever run.
	//
	// Guarded by its own mutex rather than by any existing one: dispatch() is
	// legitimately reachable FROM a detached Cmd's own thread -- that is the
	// elastic-overflow shape test_detached_cmds_exceed_pool_width_without_
	// deadlock pins -- so two threads can be appending here at once, and the
	// only other lock in reach (the Mailbox's) is on the hot delivery path
	// and has nothing to do with thread lifetime.
	detached_mu:      sync.Mutex,
	detached_threads: [dynamic]^thread.Thread,

	// Lazily-started nbio timer thread backing tick()/every() (timer.odin).
	// Owned here, not by run()/run_nbio(), so it shares the Dispatcher's own
	// proven lifetime (started on demand, joined by dispatcher_destroy
	// before the Mailbox it feeds can be destroyed) instead of needing a
	// second set of teardown rules layered on top of run()'s. See
	// docs/superpowers/tick-every-decision.md §a.
	timers: Timer_Service,

	// Optional cross-thread notification, called after a Cmd result is
	// successfully handed to the mailbox (mailbox_send == .Ok) from whatever
	// worker thread produced it. nil for run()'s poll-thread path -- that
	// design's single wait point IS the mailbox's own semaphore
	// (mailbox_recv), so nothing else needs telling. run_nbio (loop_nbio.odin)
	// sets this to a wrapper around nbio.wake_up: nbio's blocking wait
	// (nbio.tick) knows nothing about the mailbox, so delivering a message
	// there does not by itself wake a loop thread parked in tick() -- this
	// hook is what closes that gap. Deliberately a plain proc(rawptr), not an
	// nbio type: keeps this file's proven, race-tested code free of an nbio
	// dependency for the (default, common) case where nothing is listening.
	wake:      proc(rawptr),
	wake_data: rawptr,
}

Task_Env :: struct {
	cmd:       Cmd,
	mailbox:   ^Mailbox,
	inflight:  ^sync.Wait_Group,  // detached only; nil for pool tasks
	wake:      proc(rawptr),      // copied from Dispatcher.wake at dispatch time
	wake_data: rawptr,
	cancel:    ^Cancel_Token,     // copied from &Dispatcher.cancel at dispatch time -- see Cancel_Token's own doc comment

	// Non-nil ONLY when this dispatch is itself a CHILD of a batch()/
	// sequence() coordinator (batch.odin's compose_dispatch) -- nil for every
	// top-level dispatch() call, which is the overwhelming majority. Signaled
	// (wait_group_done) exactly once, as one of this task's last actions,
	// regardless of outcome (delivered, orphaned, or panicked) -- this is how
	// a compose coordinator learns "this child is done" without round-
	// tripping the child's own result back through anything: the coordinator
	// only ever needs to know WHEN, never WHAT. See batch.odin's own doc
	// comment for the full design.
	done: ^sync.Wait_Group,
}

// Runs once per pool WORKER at pool startup (thread.Pool's own init_proc
// hook), not once per TASK -- a worker's OS thread is reused across many
// tasks, and sigaltstack only needs installing once per thread (FIX 2,
// final fix-wave report). Without this, a pool worker has no altstack at
// all: a stack-overflow SIGSEGV on one re-faults on its own exhausted stack
// and defeats Tier 2 for every Cmd that ever runs on the pool.
@(private="file")
pool_worker_install_crash_handlers :: proc(th: ^thread.Thread, user_data: rawptr) {
	install_crash_handlers()
}

dispatcher_init :: proc(d: ^Dispatcher, m: ^Mailbox, workers: int, wake: proc(rawptr) = nil, wake_data: rawptr = nil) {
	d.mailbox = m
	d.wake = wake
	d.wake_data = wake_data
	// Pinned to THIS thread's allocator up front rather than left to whichever
	// thread happens to make the first append. A [dynamic] records its
	// allocator in its own header, so one assignment here fixes it for every
	// later append, unordered_remove and delete -- and the appends do not all
	// come from here: a detached Cmd can call dispatch(). That thread inherits
	// this context today (dispatch_ex passes init_context = context, for the
	// heap-corruption reason spelled out there), so the two allocators are the
	// same value in practice; pinning it means this array does not silently
	// become the second place that has to stay true.
	d.detached_threads.allocator = context.allocator
	// THE ONE THREAD-CREATION FAILURE THIS PACKAGE CANNOT GUARD, recorded
	// because F15 is otherwise closed and the gap should not have to be
	// rediscovered. thread.pool_init does `t := create(pool_thread_runner)`
	// and then `t.user_index = i` with no nil check of its own
	// (core/thread/thread_pool.odin:117-120), so a failing pthread_create
	// segfaults INSIDE core:thread before this proc regains control. There is
	// nothing to check here: pool_init has no failure path, no return value
	// and no way to ask how many workers it actually got. Measured on this
	// machine (819 live threads for the user): `ulimit -u 822` fails the
	// reader thread and now returns a clean Terminal_Error, while `ulimit -u
	// 820` fails a POOL worker and dies at thread_pool.odin:120. core: is the
	// shared toolchain, not vendored into this repo, so the fix belongs
	// upstream; a pre-flight spawn here would prove nothing about the N
	// spawns pool_init is about to make.
	thread.pool_init(&d.pool, context.allocator, max(workers, 1), init_proc = pool_worker_install_crash_handlers)
	thread.pool_start(&d.pool)
}

// thread.pool_finish/pool_destroy genuinely join every pool worker -- that
// part was always correct. But a detached Cmd (see dispatch below) runs on
// its own thread, outside the pool, so thread.Pool's join says nothing about
// it. That thread's `^Thread` is now recorded in d.detached_threads and joined
// below, but joining it is NOT what this wait is for and cannot replace it:
// inflight counts the Cmd's BODY, and it is the body -- not the OS thread's
// eventual exit -- that touches d.mailbox. Without inflight, a
// detached Cmd still running -- or mid mailbox_send -- when this returns
// would let the caller's next line (typically mailbox_destroy, per its own
// documented precondition) free the mailbox out from under a live producer:
// a use-after-free on its buffer and mutex. wait_group_wait blocks until
// every dispatch(..., detached=true) call's matching wait_group_done has
// run, which happens as the LAST action in run_cmd_detached, after that
// Cmd's mailbox_send and its own cleanup free -- so by the time this
// procedure returns, nothing can still be touching d.mailbox.
//
// BLOCKS until every pool task AND every detached Cmd is done -- this is
// exactly the wait that makes a single slow Cmd stall run()'s quit by that
// Cmd's own duration (docs/superpowers/cancellation-decision.md). Fires
// d.cancel first so any polling Cmd gets the earliest possible notice, which
// can shorten but never eliminate that wait. run() itself no longer calls
// this directly -- see dispatcher_reap below, its non-blocking sibling, which
// runs this SAME sequence on a background thread instead. This procedure is
// kept, unchanged in its blocking contract, for callers that legitimately
// want to wait synchronously (direct unit tests below, and run_nbio, which
// deliberately keeps the synchronous path -- see loop_nbio.odin's own
// comment on why).
dispatcher_destroy :: proc(d: ^Dispatcher) {
	cancel_token_fire(&d.cancel)
	thread.pool_finish(&d.pool)
	thread.pool_destroy(&d.pool)
	sync.wait_group_wait(&d.inflight)
	// Every detached Cmd's body is finished now (that is exactly what the wait
	// above establishes), but its OS thread has not necessarily left
	// __unix_thread_entry_proc yet, and with self_cleanup = false nothing else
	// will ever reclaim it. This is what turns "the bodies are done" into "the
	// threads are gone", and it is why dispatcher_destroy's return is now a
	// stronger guarantee than it used to be. It cannot block for a Cmd's own
	// duration: every join here waits out only the handful of instructions
	// between run_cmd_detached's last statement and pthread_exit.
	detached_threads_drain(d)
	// LAST, after the pool and every detached Cmd are provably finished --
	// see timer_service_stop's own doc comment (timer.odin) for why that
	// ordering is load-bearing (a detached Cmd may itself call dispatch(),
	// including a fresh tick()/every()) and not just a convenient place to
	// put it. No-op if this Dispatcher never had a Tick/Every dispatched
	// through it.
	timer_service_stop(&d.timers)
}

// Joins and frees every detached-Cmd thread that has ALREADY finished, and
// only those. dispatch_ex's detached branch calls this immediately before it
// spawns another one, so the cost is paid by the feature that produces the
// garbage and a program that never dispatches a detached Cmd never walks this
// loop at all.
//
// thread.is_done(t) is `.Done in atomic_load(&t.flags)`, set by
// __unix_thread_entry_proc (core/thread/thread_unix.odin:58) after the Cmd
// body AND after the context teardown defers. It is used here as a PROBE for
// "joining this will not block", not as a synchronization edge -- the
// thread.destroy is what supplies the edge, and that distinction is the whole
// reason this sweep does not simply free(t):
//
//   THE REJECTED SHAPE was dispatcher_reap's exactly: pthread_detach at spawn
//   plus a bare free(t) here once is_done reports true. It reintroduces the
//   race this change removes, one statement further down the same entry proc.
//   After setting .Done the thread performs one more `atomic_load(&t.flags)`
//   to test .Self_Cleanup before it returns (thread_unix.odin:60). A sweeper
//   that frees t between those two lines is a free racing a read of the freed
//   struct -- the same free-vs-atomic-access pair ThreadSanitizer reported
//   for the self_cleanup path, with the two ends swapped. thread.destroy(t)
//   is thread.join(t) followed by that free, and pthread_join orders the
//   thread's entire exit before it, so there is nothing left to race. The
//   is_done gate is what makes the join free: it can only ever wait out the
//   instructions between .Done and pthread_exit.
//
// The gate doubles as the reason this can never join the CALLING thread: a
// detached Cmd that itself calls dispatch() is by definition not done, so its
// own `^Thread` is never a candidate. (thread.join short-circuits a self-join
// and thread.destroy would then free a live thread's struct, so this is worth
// stating rather than leaving to be rediscovered.)
//
// unordered_remove, not ordered_remove: nothing reads this array in order, and
// the ordered form is O(n) per removal, which would make sweeping a burst of
// finished threads quadratic for no gain.
//
// MEASURED, because "bounded" is a claim and not an argument. A probe shaped
// like tools/racecheck phase H -- 40 rounds x 40 coordinators against 3 pool
// workers, half of them plain detached Cmds and half batch(detached,
// sequence(pooled, detached)), each round drained before the next -- issued
// 1600 dispatch() calls and about 2600 detached threads. WITH this sweep: 43
// live `^Thread` peak, 3 live at the end, 0 after dispatcher_destroy, and the
// per-round number stays flat (8, 10, 6, 3, 18, 3) instead of climbing. With
// the sweep call commented out and nothing else changed: 4000 live at the end,
// growing by exactly one per detached Cmd for the whole run. That difference
// -- not the race -- is why step 4 of this design exists.
@(private = "file")
detached_threads_sweep :: proc(d: ^Dispatcher) {
	sync.mutex_lock(&d.detached_mu)
	defer sync.mutex_unlock(&d.detached_mu)
	i := 0
	for i < len(d.detached_threads) {
		t := d.detached_threads[i]
		if thread.is_done(t) {
			thread.destroy(t)   // join (already returned) + free(t, t.creation_allocator)
			unordered_remove(&d.detached_threads, i)
			continue            // i now indexes the element swapped in from the tail
		}
		i += 1
	}
}

// Records a freshly started detached-Cmd thread. Returns false ONLY when the
// append itself could not allocate -- see dispatch_ex's handling, which cannot
// unwind by then because the Cmd is already running.
@(private = "file")
detached_thread_track :: proc(d: ^Dispatcher, t: ^thread.Thread) -> bool {
	sync.mutex_lock(&d.detached_mu)
	defer sync.mutex_unlock(&d.detached_mu)
	_, err := append(&d.detached_threads, t)
	return err == nil
}

// The teardown half of the sweep: joins and frees EVERY remaining thread,
// finished or not, and releases the array. Called from dispatcher_destroy
// after its wait_group_wait, which is what makes the unconditional join cheap
// (every body has already returned) and what makes holding the mutex across
// the joins safe: a thread blocked on d.detached_mu would be one inside
// dispatch_ex, i.e. one whose body has not returned, and inflight already
// proves there are none of those left.
@(private = "file")
detached_threads_drain :: proc(d: ^Dispatcher) {
	sync.mutex_lock(&d.detached_mu)
	defer sync.mutex_unlock(&d.detached_mu)
	for t in d.detached_threads { thread.destroy(t) }
	delete(d.detached_threads)
	d.detached_threads = nil   // a dispatch() after dispatcher_destroy is already forbidden by this proc's own precondition
}

// Heap-owned bundle for run()'s non-blocking teardown path (dispatcher_reap,
// below). Both fields were stack locals in run()'s frame before this change,
// which is exactly why run() could not return until every in-flight Cmd
// finished: thread.Pool's own doc comment says its "memory address is not
// allowed to change until it is destroyed" while workers reference it, and
// mailbox_destroy documents the identical precondition for Mailbox. A Cmd
// still running when run() wants to quit may keep touching its Dispatcher's
// pool and its Mailbox for as long as it runs, so both must outlive run()'s
// own stack frame whenever run() returns before that Cmd finishes. Bundled
// into one struct so run() makes exactly one heap allocation up front and the
// reaper thread below frees exactly one block at the end.
Reap_Ctx :: struct {
	disp: Dispatcher,
	mbox: Mailbox,

	// Non-nil only when dispatcher_reap was called with grace > 0 -- see its
	// own doc comment. Deliberately a POINTER to a SEPARATELY allocated
	// object, not a Wait_Group/Sema embedded directly in Reap_Ctx: an
	// earlier version of this file put the wait target here and freed rc
	// immediately after signaling it, which ThreadSanitizer caught as a real
	// heap-use-after-free (sync/extended.odin:100, inside
	// wait_group_wait_with_timeout) -- a woken waiter can still be touching
	// the synchronization primitive's own memory for a brief window AFTER
	// the signaling call has already returned on the signaler's side (it has
	// to re-acquire a mutex, or re-check a loop condition, to actually
	// return from its own wait call), so freeing that memory right after
	// signaling it races the waiter's own in-progress wakeup. See
	// Grace_Signal's own comment for the fix.
	grace: ^Grace_Signal,
}

// Separate, refcounted handoff for dispatcher_reap's optional grace-period
// wait -- see Reap_Ctx.grace's comment for why this cannot simply live
// inside Reap_Ctx. A plain refcount of 2 (one held by the waiter, one by the
// reaper) sidesteps the signal-then-free race cleanly: whichever side
// finishes touching it LAST is the one whose release call actually frees it
// (grace_signal_release below), and each side's own release is always the
// LAST thing that side ever does with gs -- so gs can only be freed once
// BOTH sides have already finished every touch they were ever going to make,
// regardless of what sema_post/sema_wait_with_timeout do internally to
// hand off the wakeup.
@(private = "file")
Grace_Signal :: struct {
	sem:  sync.Sema,
	refs: int,   // starts at 2; touched only via sync.atomic_add/atomic_sub
}

@(private = "file")
grace_signal_release :: proc(gs: ^Grace_Signal) {
	// atomic_sub returns the value BEFORE the subtraction (verified against
	// this exact toolchain, not assumed -- LLVM atomicrmw's return convention
	// is not otherwise documented in core:sync/core:intrinsics). Old value 1
	// means this call's own decrement just brought it to 0, i.e. the OTHER
	// side already released -- this is provably the last touch, safe to free.
	if sync.atomic_sub(&gs.refs, 1) == 1 { free(gs) }
}

@(private = "file")
reap_thread :: proc(data: rawptr) {
	// Doesn't run any user Cmd code directly, but mirrors this package's own
	// "every thread we spawn installs crash handlers first" convention
	// (dispatch's detached branch, signal_watcher_start, tea.odin's reader
	// thread) for consistency -- cheap, and it does call into libc's
	// allocator via dispatcher_destroy/mailbox_destroy/free below.
	install_crash_handlers()

	rc := cast(^Reap_Ctx)data
	gs := rc.grace   // copy before free(rc) below invalidates rc itself; gs (if non-nil) is a SEPARATE allocation, unaffected by that free
	dispatcher_destroy(&rc.disp)   // the exact same blocking join dispatcher_destroy always did -- just off run()'s critical path now
	mailbox_destroy(&rc.mbox)      // safe: dispatcher_destroy's return is proof no pool/detached Cmd can still be touching rc.mbox, and the caller of dispatcher_reap already guaranteed every OTHER producer (reader thread, Signal_Watcher) was stopped and joined before handing rc off
	free(rc)
	if gs != nil {
		sync.sema_post(&gs.sem)   // wakes a waiter blocked in dispatcher_reap's own sema_wait_with_timeout, if grace hasn't already expired
		grace_signal_release(gs)   // this thread's own reference -- see Grace_Signal's comment
	}
}

// Non-blocking counterpart to dispatcher_destroy + mailbox_destroy called
// together -- the shape run()'s teardown actually needs. Fires rc.disp's
// cancellation token, closes rc.mbox (so a Cmd that finishes after this point
// gets .Closed on its very next mailbox_send and discards its result instead
// of retrying against a mailbox nobody drains anymore -- "orphaned results
// are discarded"), then hands rc off to a self-cleaning background thread
// that runs dispatcher_destroy + mailbox_destroy + free(rc) -- the SAME join
// and the SAME "nothing can still be touching rc.mbox" proof dispatcher_destroy
// always relied on -- just on a thread the caller does not have to wait for.
//
// `grace`, if positive, makes this wait -- WITH a timeout -- for the reaper
// to finish before returning, via a Grace_Signal (see its own comment for
// why that is a separate allocation rather than a field the caller could
// wait on directly). Returns whether the reaper actually finished within
// `grace` (always false for grace <= 0, which does not wait at all). This is
// NOT about correctness of rc.mbox/rc.disp -- dispatcher_reap is safe with
// grace=0 exactly as it was before this parameter existed. It is about a
// DIFFERENT hazard specific to a caller whose context.allocator has a
// lifetime shorter than "the rest of the process": odin test's own per-task
// allocator is rotated to a DIFFERENT test the moment a test proc returns,
// and rc (and everything rc.disp/rc.mbox ever allocated) was allocated
// through THAT allocator -- a reaper thread still freeing through it after
// rotation corrupts a different test's memory, observed empirically as
// spurious "bad free" reports when this was first tried with grace=0
// unconditionally (see docs/superpowers/cancellation-decision.md for the
// measurement). A short bounded wait makes the overwhelmingly common case --
// no Cmd in flight, or one that finishes quickly -- synchronous again (rc is
// fully torn down, including free(rc), before the caller's allocator can
// possibly be reused), while still bounding the worst case (a genuinely
// stuck Cmd) to `grace` instead of that Cmd's own duration, which is the
// actual fix this whole change exists to make. run() uses a short, fixed
// grace period for exactly this reason; a caller not exposed to a
// rotating-allocator hazard (or one that does not care about the
// difference) can pass 0.
//
// PRECONDITION, same as dispatcher_destroy's own: every OTHER producer into
// rc.mbox (a reader thread, a Signal_Watcher) must already be stopped and
// joined before calling this -- this call only accounts for rc.disp's own
// pool workers and detached Cmds, nothing else. Ownership of `rc` transfers
// to the reaper thread: the caller must not touch *rc again after this call
// returns, including via rc.disp or rc.mbox.
dispatcher_reap :: proc(rc: ^Reap_Ctx, grace: time.Duration = 0) -> (finished_in_time: bool) {
	cancel_token_fire(&rc.disp.cancel)
	mailbox_close(&rc.mbox)

	gs: ^Grace_Signal
	if grace > 0 {
		gserr: mem.Allocator_Error
		gs, gserr = new(Grace_Signal)
		if gserr == nil {
			gs.refs = 2   // one for the reaper thread, one for this waiter
			rc.grace = gs
		} else {
			// No signal means no bounded wait -- the teardown still happens
			// on the reaper thread exactly as before, this call just cannot
			// wait for it. Reported as "did not finish in time", which is
			// the truthful answer.
			gs = nil
		}
	}

	// Deliberately self_cleanup = FALSE -- see the long comment on this exact
	// choice below the function for why self_cleanup = true is UNSAFE here
	// specifically (a genuine core:thread race, not this package's).
	// Detaching the underlying OS thread ourselves, right here on the
	// CALLING thread rather than racily inside the spawned thread's own
	// entry proc, is what reclaims its kernel-level resources (stack, TCB)
	// without that race: posix.pthread_detach only touches pthread-library
	// bookkeeping for the OS thread itself, never the Odin ^Thread struct's
	// own memory, so it cannot race anything the spawned thread does with
	// that struct (t.start_ok included). What is NOT reclaimed is the small,
	// fixed-size Odin-level ^Thread struct itself (a few hundred bytes) --
	// thread.destroy(t) would reclaim that too, but it calls thread.join(t)
	// internally, which would block this call on the very Cmd this whole
	// change exists to stop waiting for. That struct is intentionally
	// leaked: one per dispatcher_reap call, bounded, one-shot -- not
	// proportional to anything this change is trying to bound, and reclaimed
	// by the OS at process exit regardless.
	t := thread.create_and_start_with_data(rawptr(rc), reap_thread, init_context = context, self_cleanup = false)
	if t == nil {
		// pthread_create failed -- nil, silently, per core/thread/
		// thread_unix.odin:122-125 (see dispatch_ex's detached branch for the
		// measured frequency under RLIMIT_NPROC). The pre-existing code
		// checked t only to decide whether to call pthread_detach, so on nil
		// it fell straight through to the grace wait: rc, rc.disp, rc.mbox
		// and gs were all leaked outright, the pool was never joined, and the
		// caller then blocked for the FULL grace period waiting for a reaper
		// that had never been created.
		//
		// Falling back to doing the reaper's work RIGHT HERE, synchronously,
		// is the honest remedy. It costs exactly what dispatcher_reap exists
		// to avoid -- this call now blocks for however long the slowest
		// in-flight Cmd takes -- but that is a bounded, correct teardown
		// instead of an unbounded leak plus a pointless wait, and it can only
		// be reached when the process has already run out of threads.
		gr := rc.grace
		rc.grace = nil   // nothing will read it: the reaper that would have does not exist
		dispatcher_destroy(&rc.disp)
		mailbox_destroy(&rc.mbox)
		free(rc)
		if gr != nil {
			// Both references are this thread's now (the reaper never took
			// its own), so release twice to actually free it.
			grace_signal_release(gr)
			grace_signal_release(gr)
		}
		return true   // the teardown really is finished, just not off-thread
	}
	posix.pthread_detach(t.unix_thread)

	if gs == nil { return false }
	ok := sync.sema_wait_with_timeout(&gs.sem, grace)
	grace_signal_release(gs)   // this call's own reference -- see Grace_Signal's comment
	return ok
}

// WHY self_cleanup = false ABOVE -- AND IN dispatch_ex's DETACHED BRANCH,
// WHICH IS THE ONLY OTHER PLACE THIS PACKAGE CREATES A THREAD.
// `thread.create_and_start_with_data(..., self_cleanup = true)` has its own
// genuine race, in core:thread itself, not in this package -- caught by
// ThreadSanitizer, reproducibly (roughly 1 in 5-8 runs of ./tools/test.sh
// race) with self_cleanup = true here:
//
//   thread.start(t) does `atomic_or(&t.flags, {.Started})` THEN
//   `sync.post(&t.start_ok)` (thread_unix.odin's `_start`) -- two SEPARATE
//   operations, not one atomic step. The newly created thread's own startup
//   loop is `for (.Started not_in atomic_load(&t.flags)) { sync.wait(&t.start_ok) }`
//   -- it can observe `.Started` already set (the atomic_or already ran) and
//   skip the wait ENTIRELY, before `_start`'s own `sync.post` call has
//   executed. If the thread's body then runs to completion fast enough --
//   and reap_thread, with no Cmd in flight, can finish in low microseconds,
//   far faster than most detached-Cmd bodies that do real work first -- it
//   reaches `.Self_Cleanup`'s `free(t, ...)` (thread_unix.odin's
//   `__unix_thread_entry_proc`) WHILE `_start`'s `sync.post(&t.start_ok)` is
//   still executing on the CALLING thread. That is a genuine
//   signal-then-free race on `t.start_ok`'s own memory -- structurally the
//   SAME class of bug Grace_Signal exists to avoid above, just living inside
//   core:thread's own self_cleanup implementation instead of this file's.
//   Not something this package can patch (out of scope: toolchain code, not
//   runetea's), and this task's own hard constraint is that a fast quit must
//   never corrupt memory -- so self_cleanup is not used for a thread whose
//   body can complete this fast. See docs/superpowers/cancellation-decision.md
//   for the full TSan report this comment summarizes.
//
// THE DETACHED-Cmd PATH IS NOW ON THE SAME FOOTING, AND THE CLAIM THAT USED TO
// STAND HERE HAS BEEN FALSIFIED. What this comment said, until the run below,
// was that the detached-Cmd path "uses the SAME self_cleanup = true API and is
// exposed to the identical underlying bug, just far less likely to trigger it
// empirically ... was not observed to fail under repeated race-gate runs".
// The mechanism half was right; the empirical half is dead. ./tools/test.sh
// race failed 2 times in 13 at exit 66 with a report whose two ends are `free`
// inside __unix_thread_entry_proc (thread_unix.odin:67 -- the self_cleanup
// free) and `sync.post(&t.start_ok)` inside _start (thread_unix.odin:135),
// reached from dispatch_ex's detached spawn: the exact pair described above,
// at the exact site this comment waved through. Baseline `main` was 0 in 12
// under the same load, which is far too weak to call it a regression in either
// direction (Fisher p ~ 0.24); what it establishes is that the site is
// reachable in practice, and "a Cmd body almost always takes longer than
// _start's own sync.post" is a probability, not a guarantee -- the framework
// itself dispatches bodies that do essentially nothing (batch.odin's
// coordinator, a Cmd that only reads a flag). Note also what did NOT reproduce
// it: 45 direct runs of the race binary on this branch and 45 on baseline, on
// an idle machine and under 16 processes of synthetic CPU load, were all
// clean. A green race gate is evidence of nothing here, which is why the
// argument for the fix is structural rather than a run count.
//
// WHY THE DETACHED PATH NEEDED MORE THAN A COPY OF THE THREE LINES ABOVE.
// dispatcher_reap runs ONCE PER SESSION, so it can pair self_cleanup = false
// with pthread_detach and simply leak its single `^Thread` struct for the life
// of the process. The detached branch runs once per detached Cmd, so that same
// trade would convert a race into heap growth proportional to how many
// detached Cmds have EVER run -- strictly worse than the bug it fixes, and
// exactly what tools/test.sh's leak audit exists to catch. It therefore keeps
// its threads JOINABLE (no pthread_detach) and records each `^Thread` on the
// Dispatcher; detached_threads_sweep joins and frees the finished ones on each
// subsequent detached dispatch and detached_threads_drain takes the remainder
// in dispatcher_destroy, so live `^Thread` structs are bounded by CONCURRENT
// detached Cmds. What that bounding costs, stated plainly: an exited thread's
// kernel stack is held until a sweep or the drain reaches it instead of being
// released at exit, so a burst of detached Cmds followed by silence holds its
// peak until the next dispatch or teardown. The peak is the peak concurrency
// either way -- it is released later, not raised. What it buys beyond closing
// the race is that dispatcher_destroy's return now means the OS threads are
// GONE, not merely that their bodies finished.

// Delivers a completed Cmd's result, retrying on a transient Full and
// giving up on a terminal Closed (FIX 1, final fix-wave report). A dropped
// result is not acceptable here: `_ = mailbox_send(...)` used to discard it
// outright whenever the mailbox happened to be full, which for
// examples/http meant the UI could sit on "Checking..." forever even
// though the network request had actually completed successfully -- the
// result was computed and then silently thrown away. run()'s main loop is
// the sole consumer and keeps draining concurrently while a pool worker or
// detached Cmd thread is blocked here, so Full is expected to clear; Closed
// means run() has already torn down and nothing sent from here on could
// ever be received anyway.
// Returns whether the message was actually handed to the mailbox (false only
// for Closed -- see the call sites' handling of a nil wake below).
//
// package-visible, not file-visible: timer.odin's timer_fire reuses this
// verbatim (same retry-on-Full/discard-on-Closed policy every producer in
// this codebase already follows) rather than duplicating it for a second,
// repeating-delivery code path that could drift from this one.
//
// BACK-PRESSURE IS A BOUNDED SPIN FOLLOWED BY A REAL SLEEP, not a bare
// thread.yield() loop, and that difference was measured rather than assumed.
// `case .Full: thread.yield()` on its own does not "block the timer thread"
// the way docs/LIMITATIONS.md 2.15 claimed -- it spins that thread at ~100%
// of a core issuing sched_yield(2) for exactly as long as the consumer stays
// behind, which for a TUI is the whole time the app is slow. Changing this one
// case and nothing else: every(50us) against a 2ms update went from 100% CPU
// (1.10s sys / 1.38s wall) to 6%, wall time and tick count unchanged; a far
// more ordinary every(16ms) 60fps spinner against a 60ms update went from 82%
// CPU (22.5s sys / 34.2s wall) to 3%, 34.1s wall, 567 vs 569 ticks. The spin
// is kept for the first BACKPRESSURE_SPINS attempts because the overwhelmingly
// common Full is a momentary one that clears within a few microseconds, and
// paying a syscall-grade sleep for that would add latency to the common case
// to fix the rare one.
//
// A sleeping producer still notices Closed within BACKPRESSURE_MAX_SLEEP,
// because mailbox_send re-checks m.closed on every attempt -- the sleep bounds
// teardown latency, it does not defeat it.
@(private="package")
deliver_result :: proc(m: ^Mailbox, msg: any) -> bool {
	spins   := 0
	backoff := BACKPRESSURE_MIN_SLEEP
	for {
		switch mailbox_send(m, msg) {
		case .Ok:     return true
		case .Closed: return false
		case .Full:
			if spins < BACKPRESSURE_SPINS {
				spins += 1
				thread.yield()
			} else {
				time.sleep(backoff)
				backoff = min(backoff * 2, BACKPRESSURE_MAX_SLEEP)
			}
		}
	}
}

// Tunables for deliver_result's Full handling above. BACKPRESSURE_SPINS is
// deliberately small: a yield is only worth issuing while there is a real
// chance the consumer drains within a scheduler quantum, and past a few dozen
// attempts that chance has already been disproven for this burst.
// BACKPRESSURE_MAX_SLEEP bounds the added latency of any single message to
// 1ms, which is under one frame at 60fps and therefore invisible next to the
// stall that made the mailbox full in the first place.
BACKPRESSURE_SPINS     :: 64
BACKPRESSURE_MIN_SLEEP :: 50 * time.Microsecond
BACKPRESSURE_MAX_SLEEP :: time.Millisecond

// Best-effort, BOUNDED delivery for a diagnostic the library itself produces
// (a refused re-dispatch, a Cmd thread that could not be spawned) -- never for
// a Cmd's own result.
//
// Deliberately NOT deliver_result above, and the difference is load-bearing
// rather than stylistic. deliver_result retries a Full mailbox forever, which
// is correct for a producer running on a pool worker or a timer thread: the
// loop thread is draining concurrently, so Full always clears. These reports
// are raised from dispatch_ex, which apply() (tea.odin) calls ON THE LOOP
// THREAD ITSELF -- the sole consumer. Retrying forever from there would wedge
// the very loop that would have made room, which is precisely the shape of
// the teardown deadlock this codebase already has one instance of. So the
// report gets a bounded number of attempts and is then dropped, freed rather
// than leaked. Dropping a diagnostic is a real cost and it is stated here, not
// hidden: it can only happen when the mailbox has been full for the whole
// attempt window, at which point the app is already in trouble for a
// different reason.
@(private = "file")
deliver_report :: proc(d: ^Dispatcher, msg: any) {
	if d == nil || d.mailbox == nil {
		box_free(msg, context.allocator)
		return
	}
	for _ in 0 ..< BACKPRESSURE_SPINS {
		switch mailbox_send(d.mailbox, msg) {
		case .Ok:
			if d.wake != nil { d.wake(d.wake_data) }
			return
		case .Closed:
			box_free(msg, context.allocator)
			return
		case .Full:
			thread.yield()
		}
	}
	box_free(msg, context.allocator)
}

// Delivered through the SAME mailbox path as any normal Cmd result, when a
// Cmd's own procedure panics -- run_cmd_guarded below is what makes that
// true. See its doc comment and docs/superpowers/tier1-coverage-decision.md
// for the full reasoning; short version: the only synchronization a pool
// worker or detached Cmd thread has with the main loop is already the
// mailbox, and one exploding background Cmd (of possibly several in flight)
// should not be allowed to force the whole run() session to end -- the app
// gets to decide how to react, the same choice it already has for any other
// Cmd-reported error (examples/http's Err_Msg is the existing precedent).
// A Panicked_Msg that reaches an update() with no matching case is simply
// unhandled, exactly like any other Msg type an app doesn't care about --
// not silently dropped, since it still reached update()'s switch, just not
// acted on.
//
// POD, per box()'s MESSAGE OWNERSHIP CONTRACT (arena.odin): Msg_Text, not a
// bare `string`, carries the panic text -- truncated past 255 bytes exactly
// like every other Msg_Text use (msg.odin). box() puts the offending type
// name and the box() call's own file:line FIRST in that text precisely so
// they survive the truncation.
//
// ALSO CARRIES FRAMEWORK-DETECTED Cmd MISUSE, not only a user panic, and that
// widening is deliberate rather than a shortcut. A refused re-dispatch
// (cmd_report_reuse below) and a Cmd thread that could not be spawned
// (dispatch_ex's detached branch) are the same KIND of event from the app's
// point of view -- "a Cmd you asked for will never produce a result, and here
// is why" -- reported through the one channel the app is already draining. A
// second Msg type would have meant a second `case` every app has to learn;
// README.md:282 and docs/API.md:182 already put `case rt.Panicked_Msg:` in
// the canonical update switch, so reusing it means an app that handles Cmd
// panics at all handles these too, for free. Timer_Unavailable_Msg
// (timer.odin) is the deliberate exception: it reports that the whole timer
// SUBSYSTEM is permanently dead, which is a different remedy, not a different
// spelling of the same one.
Panicked_Msg :: struct {
	message: Msg_Text,
}

// The loud half of "a Cmd is single-use, enforced". Reached only when
// cmd_ticket_claim refuses -- i.e. this exact Cmd value was already
// dispatched, or already reclaimed by batch.odin's compose_free_unrun.
//
// Reports through the mailbox, NOT to stderr, and that is the whole point of
// putting it here rather than behind a fmt.eprintln: by the time a Cmd is
// being dispatched the terminal is in raw mode on the alternate screen, so
// anything written to stderr is painted into a buffer that \e[?1049l throws
// away on exit -- the user sees nothing at all, which is the silence this fix
// exists to end. update() is the one place a diagnostic can actually be
// noticed.
//
// Names the KIND of Cmd because the three constructors fail differently and
// the fix differs with them: a re-dispatched cmd_from ran its body against
// freed env, a re-dispatched batch()/sequence() silently did nothing, and a
// re-dispatched tick()/every() double-released a refcounted handle.
@(private = "file")
cmd_report_reuse :: proc(d: ^Dispatcher, c: Cmd) {
	kind := "cmd_from"
	if c.timer   != nil { kind = "tick()/every()" }
	if c.compose != nil { kind = "batch()/sequence()" }
	deliver_report(d, box(Panicked_Msg{message = msg_text_fmt(
		"dispatch(): this %s Cmd was already dispatched and was NOT run again -- a Cmd value is SINGLE-USE; build a fresh one instead of storing and returning the same one twice",
		kind)}, context.allocator))
}

// Shared state for the guarded Cmd call, mirroring tea.odin's Step/View_Step
// -- longjmp discards the frame, so the result (or lack of one) lives
// outside it.
@(private = "file")
Cmd_Step :: struct {
	cmd:    Cmd,
	cancel: ^Cancel_Token,
	result: any,
}

// Runs a Cmd's procedure under guarded(), turning a panic into a boxed
// Panicked_Msg instead of taking down the whole pool worker or detached
// thread (T1, docs/superpowers/tier1-coverage-decision.md -- Tier 1
// previously wrapped update only; spike-findings.md §4/addendum item 7).
// Shared by run_cmd_task and run_cmd_detached below so both thread classes
// get identical panic handling from one place, not two copies that could
// drift.
//
// Also owns freeing cmd.env exactly once, regardless of outcome (constraint
// c: longjmp skips defer, so the free that used to sit right after the bare
// procedure call must now run unconditionally AFTER guarded() returns --
// which, by the time this code runs, is back to ordinary non-longjmp control
// flow either way, panic or not). This is a real improvement over the
// pre-guard code, not just a preserved behavior: before this change a
// panicking Cmd took the whole process down (see box()'s own non-POD panic
// path, which used to abort here unconditionally -- message-ownership-
// decision.md §2 Option B), so cmd.env was never freed on that path either;
// now it always is.
//
// "EXACTLY ONCE" IS NOW ENFORCED, not merely asserted by this comment.
// dispatch_ex claims the Cmd's ticket (see the Cmd ledger at the top of this
// file) before any thread can reach this proc, so no two calls can ever be
// handed the same cmd.env. Until that gate existed the claim here was simply
// false whenever a Cmd VALUE was dispatched twice -- returning one stored Cmd
// from update() on two keypresses reached this line twice and freed the same
// pointer twice, which is a SIGSEGV under the default allocator and a "Bad
// free" abort under mem.Tracking_Allocator.
//
// WHAT IS NOT RECLAIMED: any heap memory the Cmd body itself allocated
// (typically via context.allocator, since a Cmd's result must cross a thread
// boundary -- see arena.odin's LIFETIME CONTRACT) before panicking. Unlike
// apply()'s update/view guards, a Cmd has no frame-arena equivalent to
// wholesale-reclaim on the recovery path -- frame_allocator(fa) is
// per-run()-iteration and explicitly forbidden for anything crossing a
// thread boundary, which is exactly what a Cmd's own scratch allocations
// usually are not, but easily could be. A Cmd that panics after allocating
// its own scratch buffer leaks that buffer, the same as any non-guarded Odin
// code with no RAII would. This is a fundamental limit of setjmp/longjmp
// recovery, not something this change closes, and is recorded here rather
// than silently promised away.
run_cmd_guarded :: proc(cmd: Cmd, cancel: ^Cancel_Token) -> any {
	step := Cmd_Step{cmd = cmd, cancel = cancel}
	info := guarded(proc(ud: rawptr) {
		s := cast(^Cmd_Step)ud
		s.result = s.cmd.procedure(s.cmd.env, s.cancel)
	}, &step)

	if cmd.env != nil { free(cmd.env, cmd.allocator) }

	if info.recovered {
		// Msg types must be POD (message-ownership-decision.md): the panic
		// text -- an owned `string` cloned by guard_assertion_failure -- must
		// become a Msg_Text, not travel as-is. Unlike apply()'s update-panic
		// path (which hands info.message to the CALLER of run() via
		// Panicked_Error, so it cannot free it), nothing else ever holds a
		// reference to this particular copy once it's been copied into the
		// Msg_Text below -- there is no caller waiting on a Cmd's panic text
		// the way run()'s own caller waits on its return value -- so freeing
		// it immediately is correct, not merely convenient, and avoids adding
		// a second instance of guard.odin's already-documented
		// Panic_Info.message leak.
		defer delete(info.message, context.allocator)
		return box(Panicked_Msg{message = msg_text_from(info.message)}, context.allocator)
	}
	return step.result
}

@(private="file")
run_cmd_task :: proc(task: thread.Task) {
	te := cast(^Task_Env)task.data
	// Captured before free(te) below invalidates te itself -- same reason
	// run_cmd_detached's own `inflight := te.inflight` capture exists.
	done := te.done
	if te.cmd.procedure != nil {
		msg := run_cmd_guarded(te.cmd, te.cancel)
		// msg.id != nil, NOT msg != nil: Odin's `any == nil` compares by the
		// `data` field alone, and new() legitimately returns a nil pointer for
		// a zero-sized allocation -- which is exactly what box() does for any
		// zero-sized Msg (Quit_Msg is `struct {}`). `msg != nil` on such a
		// result is FALSE -- it silently discards the message, so a Cmd
		// returning Quit_Msg through this path would never reach the mailbox
		// and the program could never quit. Proven with a standalone repro
		// (`a: any = p^` for `p := new(Empty)` prints `a == nil: true` while
		// `a.id != nil: true`) and caught live: an init Cmd returning
		// Quit_Msg hung forever waiting on mailbox_recv, see
		// task-10-report.md. `.id` is nil ONLY for a genuinely absent message
		// (a real `nil` any, or box()'s own allocator-failure return), which
		// is what this check must key on instead.
		if msg.id != nil {
			if deliver_result(te.mailbox, msg) {
				if te.wake != nil { te.wake(te.wake_data) }
			} else {
				// Orphaned: the mailbox is already closed, which for the
				// pool/detached paths only ever happens once run() (or
				// run_nbio()) has quit and called dispatcher_reap/
				// dispatcher_destroy -- "orphaned results are discarded" is
				// the deliberate design (docs/superpowers/
				// cancellation-decision.md), but the box() allocation msg
				// itself still needs a home: freeing it here, rather than
				// leaking it, is safe because this runs on the SAME thread
				// that called box() to produce msg in the first place, so
				// context.allocator here is the SAME allocator instance that
				// made the allocation -- the identical convention apply()'s
				// own box_free call relies on (tea.odin/arena.odin).
				box_free(msg, context.allocator)
			}
		}
	}
	// Freed here, per-task, rather than accumulated in the Dispatcher and
	// freed only at dispatcher_destroy: a Dispatcher is meant to live for
	// the whole session of a long-running TUI, so retaining every completed
	// task's Task_Env until shutdown grows without bound across the run.
	free(te)
	// See Task_Env.done's own doc comment -- signaled after every other
	// action this task will ever take, so a compose coordinator waiting on
	// it never wakes early relative to this child's own delivery/cleanup.
	if done != nil { sync.wait_group_done(done) }
}

@(private="file")
run_cmd_detached :: proc(data: rawptr) {
	// Per-thread altstack (FIX 2, final fix-wave report), installed as the
	// first action. A detached Cmd gets a brand-new OS thread every single
	// dispatch (see dispatch's detached branch below) -- unlike the pool,
	// there is no reusable worker thread to amortize this over via an
	// init_proc hook, so it has to happen here, once per invocation.
	// Without it, a stack-overflow SIGSEGV on a detached Cmd's own thread
	// re-faults on its own exhausted stack and defeats Tier 2.
	install_crash_handlers()

	te := cast(^Task_Env)data
	inflight := te.inflight
	done := te.done   // captured before free(te) below, same reason as `inflight` above
	if te.cmd.procedure != nil {
		msg := run_cmd_guarded(te.cmd, te.cancel)
		// See run_cmd_task's comment: msg.id, not msg, distinguishes "a real
		// zero-sized Msg" from "genuinely nothing to send".
		if msg.id != nil {
			if deliver_result(te.mailbox, msg) {
				if te.wake != nil { te.wake(te.wake_data) }
			} else {
				// See run_cmd_task's identical comment for why this is safe
				// and not merely tolerated.
				box_free(msg, context.allocator)
			}
		}
	}
	free(te)
	// See Task_Env.done's own doc comment. Signaled BEFORE inflight below,
	// not after -- a compose coordinator waiting on `done` has no stake in
	// this Dispatcher's own inflight bookkeeping, so there is no ordering
	// requirement between the two beyond "both eventually happen"; inflight
	// keeps its documented "must be the LAST action" position regardless.
	if done != nil { sync.wait_group_done(done) }
	// Must be the LAST action: dispatcher_destroy's wait_group_wait treats
	// this as proof the Cmd is entirely done, including its mailbox_send and
	// its own te free, and unblocks a caller that may destroy the mailbox on
	// its very next line.
	sync.wait_group_done(inflight)
}

dispatch :: proc(d: ^Dispatcher, c: Cmd) {
	// The bool is deliberately discarded here and nowhere else that matters:
	// dispatch_ex has already freed everything a refused or failed dispatch
	// owned, and a top-level caller (apply(), run()'s init Cmd) holds nothing
	// else to reclaim. See dispatch_ex's own return-value comment.
	_ = dispatch_ex(d, c, nil)
}

// The real body of dispatch(), extended with one internal-only parameter:
// `done`, non-nil ONLY when this call is itself dispatching a CHILD of a
// batch()/sequence() coordinator (batch.odin's compose_dispatch). Every
// external call site (apply()/run() in tea.odin, loop_nbio.odin, every test
// in cmd_test.odin) goes through the plain `dispatch` wrapper above, which
// always passes nil -- ordinary top-level dispatch behavior is completely
// unchanged.
//
// `done`, when non-nil, is signaled (wait_group_done) EXACTLY once no matter
// which branch below runs, including the two immediate-return cases (timer,
// nil Cmd) that have no Task_Env of their own to carry it. This is what lets
// a compose coordinator dispatch an arbitrary child -- ordinary Cmd, nested
// batch()/sequence(), even a raw Tick/Every -- through this exact same
// proc, uniformly, and learn "this child is done" without needing a second,
// parallel dispatch path: see batch.odin's own top-of-file comment for the
// full design and docs/superpowers/batch-sequence-decision.md for why that
// uniformity is the point, not an incidental simplification.
//
// Returns whether the Cmd was actually taken on. FALSE means nothing was
// started AND this call has already performed every cleanup it owes --
// including signaling `done` and freeing c.env -- so a caller that holds
// state the Cmd was going to consume (compose_dispatch's Compose_Spec is the
// only one) knows to reclaim it and must not signal `done` itself. Only
// dispatch()'s own wrapper and the two compose runners ignore this, and they
// ignore it correctly: they own nothing beyond what this call already freed.
@(private = "package")
dispatch_ex :: proc(d: ^Dispatcher, c: Cmd, done: ^sync.Wait_Group) -> bool {
	// SINGLE-USE, CLAIMED HERE AND NOWHERE ELSE. This is the one funnel every
	// Cmd kind passes through -- timer, compose, detached, pooled and nil
	// alike -- so one claim at the top covers all of them, before any branch
	// below has read c.env, c.compose or c.timer. Doing it per-branch would
	// have meant four claims to keep in step, and doing it inside
	// run_cmd_guarded would have been too late: two concurrent dispatches of
	// the same Cmd would both already have spawned a thread by then.
	if !cmd_ticket_claim(c.ticket) {
		cmd_report_reuse(d, c)
		// Still signal a waiting coordinator. A refused child that never
		// signaled `done` would hang compose_run_sequence's wait_group_wait
		// forever on its own detached thread, turning a diagnosable misuse
		// into the unkillable hang this whole fix wave exists to remove.
		if done != nil { sync.wait_group_done(done) }
		return false
	}

	// THE FRAME-ALLOCATOR BACKSTOP (F07), placed at the same funnel and for
	// the same reason as the ticket claim above: every Cmd kind passes through
	// here exactly once, before any branch has read c.env.
	//
	// WHY BOTH HERE AND IN THE CONSTRUCTORS, since the constructors catch the
	// case the finding is actually about. The constructor check can only fire
	// while a frame is armed, which is when update() runs -- so it catches
	// `return cmd_from(fn, env, alloc)` and nothing else. This one catches the
	// Cmd that was BUILT somewhere unarmed (a pool worker, a helper called
	// before the first frame) from an allocator the app kept a copy of, and is
	// dispatched later while a frame is in flight. That is a smaller
	// population, but it is the population whose symptom is identical and
	// whose diagnosis is hardest.
	//
	// IT REPORTS, IT DOES NOT PANIC, and the difference is forced: dispatch()
	// is called from apply_msg AFTER guarded() has returned, so a panic here
	// is not caught by anything and would abort the process -- the exact
	// crash-instead-of-diagnostic trade F15 just spent this wave undoing. The
	// report carries CMD_ALLOC_CONTRACT_PANIC's prefix, which apply_msg
	// escalates to a session-ending Panicked_Error, so the outcome the caller
	// sees is the same as the constructor's; only the mechanism differs.
	//
	// c.env IS NOT FREED. It lives in the frame arena, which owns it and will
	// reclaim it wholesale; handing it to free() with an arena allocator would
	// at best be a no-op and at worst hand a Tracking_Allocator a pointer it
	// never issued. Only Cmds with an env of their own are visible here --
	// a Tick/Every's cloned fn env and a batch()'s child list are recorded on
	// the Timer_Handle and the Compose_Spec, not on c.allocator, so those two
	// kinds are covered by the constructor check alone.
	if c.env != nil && is_frame_allocator(c.allocator) {
		deliver_report(d, box(Panicked_Msg{message = msg_text_from(
			CMD_ALLOC_CONTRACT_PANIC + "dispatch(): this Cmd's env was allocated from update()'s frame allocator, which is reclaimed at the end of the frame -- it was NOT run, because it could only have read a zeroed env. Build it with context.allocator.")},
			context.allocator))
		if done != nil { sync.wait_group_done(done) }
		return false
	}

	// Tick/Every (timer.odin) bypass everything below: registering an nbio
	// timeout is a microsecond-fast, non-blocking call, so routing it
	// through a pool worker would only add latency and hold a worker slot
	// for no reason -- and a repeating Every delivers MANY results over its
	// lifetime, which doesn't fit run_cmd_task/run_cmd_detached's "exactly
	// one result per dispatch" shape at all (see cmd.odin's own msg.id-vs-msg
	// comment below in run_cmd_task). procedure/env/allocator/detached are
	// unused for such a Cmd (left zeroed by tick()/every()).
	if c.timer != nil {
		timer_dispatch(d, c.timer)
		// Fire-and-forget from a composing coordinator's point of view: a
		// Tick/Every nested inside batch()/sequence() is registered exactly
		// as if it had been returned directly from update(), but does NOT
		// gate the coordinator's own completion/ordering -- an Every in
		// particular never completes at all, so "wait for it" has no
		// sensible meaning here. See batch-sequence-decision.md's honest
		// accounting of this scope limit.
		if done != nil { sync.wait_group_done(done) }
		return true
	}

	// batch()/sequence() (batch.odin) bypass everything below too, for the
	// same class of reason: a compose Cmd has no single procedure/env pair
	// to run through run_cmd_task/run_cmd_detached, it coordinates a whole
	// list of children. compose_dispatch below always converts this into a
	// SYNTHETIC detached Cmd and recurses into this exact same proc, so it
	// still ultimately runs through the ordinary detached branch below --
	// see compose_dispatch's own doc comment (batch.odin) for why that reuse
	// is deliberate, not incidental.
	if c.compose != nil {
		return compose_dispatch(d, c.compose, done)
	}

	if cmd_is_nil(c) {
		if done != nil { sync.wait_group_done(done) }
		return true
	}

	if c.detached {
		// Elastic overflow: its own thread, joined and freed by this
		// Dispatcher (see below), never pool-bound.
		//
		// init_context MUST be passed. Left at its nil default, the new OS
		// thread runs under runtime.default_context() instead of inheriting
		// this one -- a DIFFERENT context.allocator value. `te` below is
		// allocated through *this* thread's context.allocator (whatever the
		// caller has configured, e.g. odin test's Tracking_Allocator), but
		// run_cmd_detached's closing `free(te)` has no explicit allocator
		// argument, so it resolves context.allocator on the *new* thread.
		// Without inheritance those are two different allocators backed by
		// the same real heap with no shared bookkeeping/locking between
		// them -- proven to heap-corrupt and SIGSEGV inside libc free()
		// under odin test's tracking allocator (reproduced with a minimal
		// core:thread-only repro, no cmd.odin/Dispatcher logic involved).
		// Passing context here makes the child inherit the SAME allocator
		// value the pool path already gets for free via task.allocator
		// (thread_pool.odin:363 sets context.allocator = task.allocator
		// before running a task) -- see thread.create_and_start_with_data's
		// own _select_context_for_thread, which special-cases temp_allocator
		// to still get a fresh per-thread instance so its state isn't shared.
		//
		// wait_group_add MUST happen before create_and_start_with_data, not
		// after: the detached thread can run to completion (including its
		// matching wait_group_done) before this call even returns, and
		// add-after-spawn would race dispatcher_destroy's wait_group_wait
		// seeing a zero count that was never incremented for this Cmd.
		//
		// BOTH ALLOCATIONS BELOW ARE CHECKED, and the thread spawn especially.
		// thread.create_and_start_with_data returns nil -- silently, without
		// faulting -- whenever pthread_create fails (core/thread/
		// thread_unix.odin:122-125), which is a real condition under
		// RLIMIT_NPROC, RLIMIT_AS or simply a loaded box: measured at 16-100
		// nil returns per 100 spawns under an RLIMIT_NPROC that perturbs
		// nothing else. This line used to DISCARD that return value, one line
		// after wait_group_add had already incremented d.inflight. The Cmd
		// then never ran, te and c.env leaked, and d.inflight (plus a compose
		// coordinator's `done`) stayed permanently +1 -- so
		// dispatcher_destroy's wait_group_wait never returned and run_nbio()
		// froze forever with the terminal still raw and no diagnostic of any
		// kind, even though the model had already returned quit_cmd. Adding
		// only this nil-check turned every observed hang into a clean exit.
		// dispatcher_reap above ALREADY nil-checks the identical API, so the
		// omission was local to this one line, not a policy.

		// Reclaim the threads earlier detached Cmds left behind, BEFORE
		// adding another one. Here rather than at the end of
		// run_cmd_detached because a thread cannot join and free itself, and
		// here rather than on a timer or a helper thread because this is the
		// one place that is guaranteed to run whenever the population can
		// grow. Costs one is_done load per outstanding thread, on the thread
		// that is about to make a pthread_create syscall anyway.
		detached_threads_sweep(d)

		te, terr := new(Task_Env)
		if terr != nil {
			if c.env != nil { free(c.env, c.allocator) }
			if done != nil { sync.wait_group_done(done) }
			cmd_report_spawn_failure(d, "out of memory allocating a detached Cmd's task env")
			return false
		}
		sync.wait_group_add(&d.inflight, 1)
		te^ = Task_Env{cmd = c, mailbox = d.mailbox, inflight = &d.inflight, wake = d.wake, wake_data = d.wake_data, cancel = &d.cancel, done = done}
		t: ^thread.Thread
		if !sync.atomic_load(&g_cmd_force_spawn_failure) {
			// self_cleanup = FALSE. This line read `true` until a
			// ThreadSanitizer failure of the race gate proved the free it
			// performs races _start's own sync.post -- the full argument, the
			// measurements and the sentence in this file that used to say
			// this path was safe are in the WHY self_cleanup = false comment
			// under dispatcher_reap. The consequence here is that nobody but
			// this package frees `t`, which is what the tracking and sweeping
			// below exist for.
			t = thread.create_and_start_with_data(rawptr(te), run_cmd_detached, init_context = context, self_cleanup = false)
		}
		if t == nil {
			// Unwind in the exact reverse of what was set up, so nothing is
			// left counted, owned or waited on. c.env gets the same free
			// run_cmd_guarded would have given it -- this is the one path
			// where nothing else ever will.
			free(te)
			if c.env != nil { free(c.env, c.allocator) }
			sync.wait_group_done(&d.inflight)
			if done != nil { sync.wait_group_done(done) }
			cmd_report_spawn_failure(d, "could not start a thread for a detached Cmd (pthread_create failed)")
			return false
		}
		if !detached_thread_track(d, t) {
			// The one allocation in this proc that cannot be unwound: the Cmd
			// is already running by the time this fails, so there is no
			// "return false" to take. Fall back to dispatcher_reap's trade
			// rather than dropping the thread on the floor -- pthread_detach
			// makes the KERNEL reclaim the stack and TCB at exit and touches
			// no field of `t` (so it cannot race the thread's own use of
			// t.flags, which is the property the whole comment under
			// dispatcher_reap turns on), leaving only the few-hundred-byte
			// `^Thread` struct unreclaimed. That is a leak, and deliberately
			// the SAME leak site tools/test.sh already allows for
			// dispatcher_reap (thread_unix.odin:_create): one small block per
			// allocation failure, against a whole thread's stack held to the
			// end of the session per allocation failure.
			posix.pthread_detach(t.unix_thread)
		}
		return true
	}

	te, terr := new(Task_Env)
	if terr != nil {
		if c.env != nil { free(c.env, c.allocator) }
		if done != nil { sync.wait_group_done(done) }
		cmd_report_spawn_failure(d, "out of memory allocating a pooled Cmd's task env")
		return false
	}
	te^ = Task_Env{cmd = c, mailbox = d.mailbox, wake = d.wake, wake_data = d.wake_data, cancel = &d.cancel, done = done}
	thread.pool_add_task(&d.pool, context.allocator, run_cmd_task, te)
	return true
}

// TEST-ONLY. When true, dispatch_ex's detached branch behaves exactly as
// though pthread_create had failed and thread.create_and_start_with_data had
// returned nil. Modelled on timer.odin's g_timer_force_start_failure, and here
// for the same reason: the real trigger is RLIMIT_NPROC exhaustion, which a
// test cannot induce without perturbing the whole test binary, and the
// pre-fix behaviour on this path was an unkillable hang rather than a
// failure -- a bug a test suite cannot observe by waiting for it. Nothing in
// the library ever writes it; cmd_test.odin sets and restores it, and
// ODIN_TEST_THREADS=1 means no two tests contend for it.
@(private = "package")
g_cmd_force_spawn_failure: bool

// The other half of dispatch_ex's failure paths (see Panicked_Msg's own
// comment for why this reuses that type rather than adding a third one).
//
// SAYING SO AT ALL is the fix. The pre-existing behaviour on a failed spawn
// was not a wrong message, it was NO message: the Cmd vanished, the
// dispatcher's in-flight count stayed permanently raised, and the first thing
// the user saw was a frozen UI that never came back. A resource-exhaustion
// failure the app could plausibly react to (shed work, retry later, quit
// cleanly) is exactly the sort of thing that must not be inferred from a
// hang.
@(private = "file")
cmd_report_spawn_failure :: proc(d: ^Dispatcher, what: string) {
	deliver_report(d, box(Panicked_Msg{message = msg_text_fmt("dispatch(): %s -- this Cmd will never produce a result", what)}, context.allocator))
}

// ---------------------------------------------------------------------------
// THE OTHER THREE THREADS THIS PACKAGE STARTS, AND THE CRASH THEY USED TO BE.
//
// tea.odin's input reader, signals.odin's Signal_Watcher and timer.odin's
// timer thread are not Cmds -- they never touch a Dispatcher's pool -- but
// they are started through the same core:thread API, which fails the same
// silent way: thread.create returns nil, without faulting and without an
// error value, whenever pthread_create fails (core/thread/
// thread_unix.odin:122-125 for the pthread_create arm, :92 for the `new`
// arm). All three call sites were written as
//
//     x := thread.create(body); x.data = ...; thread.start(x)
//
// so the nil return was dereferenced on the VERY NEXT LINE. F15's first fix
// wave nil-checked cmd.odin's own detached spawn and stopped there, which
// moved the failure rather than removing it: under exactly the RLIMIT_NPROC
// pressure the finding is about, the detached Cmd now reports and unwinds
// cleanly and then run() SIGSEGVs at tea.odin's `reader.data = &rd`. A hang
// became a segfault, which is not an improvement -- the terminal is left raw
// either way, and the second one takes the caller's process with it.
//
// WHY A WRAPPER AND NOT THREE OPEN-CODED NIL CHECKS. Two reasons, and the
// second is the load-bearing one. (1) The three sites now share one policy:
// nil means "this thread does not exist", stated once. (2) The failure is
// otherwise UNTESTABLE. The real trigger is process-wide resource exhaustion
// (RLIMIT_NPROC, RLIMIT_AS), which a test cannot induce without perturbing
// the whole test binary -- and the pre-fix symptom is a segfault, which a
// test cannot observe from inside the process it kills. Routing the three
// sites through one hookable call is what lets cmd_test/tea_test/signals_test/
// timer_test drive each recovery path deterministically. This is the same
// argument, and deliberately the same shape, as g_cmd_force_spawn_failure
// above and timer.odin's g_timer_force_start_failure.
//
// The hook is checked BEFORE the call rather than by nil-ing the result
// afterwards, so a forced failure allocates and starts nothing at all --
// otherwise the test would be leaking a real thread on every forced failure.
@(private = "package")
thread_create_checked :: proc(body: proc(^thread.Thread)) -> ^thread.Thread {
	if sync.atomic_load(&g_thread_force_create_failure) { return nil }
	return thread.create(body)
}

// TEST-ONLY. See thread_create_checked. Nothing in the library ever writes
// it; the *_test.odin files set and restore it, and ODIN_TEST_THREADS=1 means
// no two tests contend for it. Separate from g_cmd_force_spawn_failure because
// the two cover different core:thread entry points and different recovery
// paths, and a test that wants one almost never wants the other -- a single
// flag would make every forced reader-thread failure also break every Cmd
// dispatched by the same test.
@(private = "package")
g_thread_force_create_failure: bool
