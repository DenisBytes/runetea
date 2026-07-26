package runetea

import "core:mem"
import "core:sync"

// batch() and sequence() -- see docs/superpowers/batch-sequence-decision.md
// for the full design rationale (three real tensions, walked in depth). Short
// version of what lives in THIS file:
//
//   - Go's tea.Batch/tea.Sequence return a Cmd whose EXECUTION produces a
//     BatchMsg([]Cmd)/sequenceMsg([]Cmd) value, which the runtime's event
//     loop (tea.go: `case BatchMsg: go p.execBatchMsg(msg)`) specially
//     intercepts and dispatches. That shape does not port: box()'s MESSAGE
//     OWNERSHIP CONTRACT (arena.odin) panics on any Msg with a slice field,
//     and []Cmd is exactly that -- a Msg carrying a list of Cmds is not
//     POD, full stop. So batch()/sequence() here do not produce a Msg at
//     all. Like tick()/every() (timer.odin), they attach an opaque handle --
//     `compose: ^Compose_Spec` -- to a Cmd that dispatch() (cmd.odin)
//     recognizes and routes DIRECTLY, entirely bypassing the mailbox for the
//     coordination step itself. Each CHILD Cmd's own result still reaches
//     the mailbox exactly as if update() had returned it directly -- only
//     the "which Cmds, in what order/concurrency" bookkeeping is kept off
//     the wire. This is the direct answer to tension 1.
//
//   - OWNERSHIP (tension 2): batch()/sequence() heap-clone the caller's
//     `cmds` slice into a fresh, exactly-sized allocation (Compose_Spec.cmds)
//     the instant they're called -- the same "heap-clone so the Cmd can
//     outlive the caller's frame" move cmd_from already makes for a single
//     Cmd's env (cmd.odin). Each element of that clone is a COPY of a Cmd
//     struct, not a pointer into the caller's original slice -- copying a
//     Cmd is cheap and never aliases anything the caller might reclaim
//     (their frame arena, their stack), because a Cmd's only owned resource
//     is `env`, reached through a pointer that survives the copy unchanged.
//     Every child Cmd's env is freed EXACTLY once: by run_cmd_guarded, if
//     that child actually runs (cmd.odin, unchanged) -- or by
//     compose_free_unrun below, if it never gets the chance to (cancelled
//     mid-fan-out, or the whole compose Cmd was abandoned before ever being
//     dispatched due to an allocation failure). See compose_free_unrun's own
//     doc comment for the one deliberate exception (a never-started
//     Tick/Every child) and why it is a bounded, already-accepted class of
//     leak rather than a new one.
//
//   - THE POOL DEADLOCK (tension 3): a batch/sequence coordinator dispatches
//     children and then WAITS for them -- exactly the shape `detached`
//     (cmd.odin) exists to keep off the pool. compose_dispatch below always
//     converts a compose Cmd into a synthetic Cmd with detached = true
//     before handing it to dispatch_ex, unconditionally, with no way for a
//     caller to opt out -- so no matter how deeply batch()/sequence() nest,
//     only LEAF Cmds (ordinary, non-compose, non-timer) ever occupy a pool
//     worker. This reuses the EXACT machinery
//     test_detached_cmds_exceed_pool_width_without_deadlock (cmd_test.odin)
//     already pins, rather than inventing a second "elastic overflow"
//     mechanism alongside it.
//
//   - COMPLETION TRACKING, not result routing: a coordinator only ever needs
//     to know WHEN a child is done, never WHAT it produced -- Task_Env.done
//     (cmd.odin) is a `^sync.Wait_Group` threaded through dispatch_ex
//     alongside the Dispatcher and Cancel_Token, signaled exactly once by
//     run_cmd_task/run_cmd_detached (an ordinary Cmd), by the timer branch
//     (fire-and-forget, see dispatch_ex's own comment), or by
//     compose_dispatch itself (a nested compose child, once ITS OWN
//     children are entirely done). Nesting batch-in-batch, sequence-in-
//     batch, batch-in-sequence all fall out of this uniform mechanism with
//     no separate nested-coordination code path to keep in sync.
//
//   - CANCELLATION: compose_run_batch checks cancel_requested before
//     dispatching each remaining child; compose_run_sequence checks it
//     before starting each remaining step. Either way, once noticed,
//     whatever hasn't been dispatched yet is abandoned (compose_free_unrun)
//     rather than started -- a Cmd already dispatched before cancellation
//     was noticed still runs to completion (cooperative, same honest limit
//     as Cancel_Token itself, cmd.odin). This bounds a sequence's remaining
//     steps from running after quit, which is what keeps run()'s own
//     QUIT_GRACE bound meaningful even with a long sequence in flight -- see
//     the decision doc's measured numbers.

Compose_Kind :: enum { Batch, Sequence }

// Owns `cmds` (a heap clone of the caller's filtered slice, see `compose`
// below) and `alloc` (the SAME allocator used to free that slice and this
// struct itself, exactly once, from whichever of compose_run_batch/
// compose_run_sequence/compose_free_unrun/compose_dispatch actually reaches
// it -- there is exactly one such reader per Compose_Spec, so there is no
// double-free hazard to design around here the way Timer_Handle's refcount
// exists for).
Compose_Spec :: struct {
	kind:  Compose_Kind,
	cmds:  []Cmd,
	alloc: mem.Allocator,
}

// batch(cmds, alloc) -> a Cmd that, once dispatched, runs every Cmd in
// `cmds` CONCURRENTLY. Results arrive at the mailbox in whatever order the
// children finish in -- there is no ordering guarantee between them, exactly
// matching Bubble Tea's own Batch (commands.go's own doc comment: "no
// ordering guarantees about the results").
//
// A slice, not a variadic parameter (contrast Go's `Batch(cmds ...Cmd)`):
// Odin variadics must be the last parameter, and `alloc` needs to be
// explicit (this package's convention throughout, see cmd_from/tick/every)
// -- `batch([]Cmd{a, b}, context.allocator)` is the resulting shape at a
// call site. A small, real ergonomic cost of the port, not an oversight.
batch :: proc(cmds: []Cmd, alloc: mem.Allocator) -> Cmd {
	return compose(cmds, .Batch, alloc)
}

// sequence(cmds, alloc) -> a Cmd that, once dispatched, runs every Cmd in
// `cmds` ONE AT A TIME, in order -- each starting only after the previous
// one has entirely finished (a nested batch()/sequence() child counts as
// "finished" only once ALL of ITS OWN children are done, see this file's own
// top comment). Contrast batch() above, which runs them concurrently.
sequence :: proc(cmds: []Cmd, alloc: mem.Allocator) -> Cmd {
	return compose(cmds, .Sequence, alloc)
}

// Shared construction path for batch()/sequence() -- filters nil Cmds
// (mirrors Go's own compactCmds, commands.go), then heap-clones what's left.
//
// EMPTY AND SINGLE-ELEMENT CASES, both deliberate, both matching Go's own
// compactCmds exactly: zero non-nil Cmds returns cmd_nil() (nothing to
// coordinate); exactly one returns that Cmd directly, completely
// unwrapped -- no Compose_Spec, no coordinator thread, no detached-Cmd
// overhead for what is, at that point, just an ordinary single Cmd. Only
// n >= 2 ever allocates a Compose_Spec and therefore ever costs a
// coordinator thread (compose_dispatch, below) at all.
@(private = "file")
compose :: proc(cmds: []Cmd, kind: Compose_Kind, alloc: mem.Allocator) -> Cmd {
	n := 0
	only: Cmd
	for c in cmds {
		if cmd_is_nil(c) { continue }
		if n == 0 { only = c }
		n += 1
	}

	switch n {
	case 0: return cmd_nil()
	case 1: return only
	}

	owned, oerr := make([]Cmd, n, alloc)
	if oerr != nil {
		// Can't take ownership of the list at all -- free every child now,
		// exactly the cleanup each one WOULD have gotten had it actually
		// been dispatched, since none of them ever will be.
		// compose_free_unrun is nil-Cmd-safe (a genuine cmd_nil() has
		// env == nil, so its `if c.env != nil` is simply a no-op for those),
		// so it's safe to hand it the original, unfiltered `cmds` here.
		compose_free_unrun(cmds)
		return cmd_nil()
	}
	i := 0
	for c in cmds {
		if cmd_is_nil(c) { continue }
		owned[i] = c
		i += 1
	}

	spec, serr := new(Compose_Spec, alloc)
	if serr != nil {
		compose_free_unrun(owned)
		delete(owned, alloc)
		return cmd_nil()
	}
	spec^ = Compose_Spec{kind = kind, cmds = owned, alloc = alloc}
	return Cmd{compose = spec, allocator = alloc}
}

// Frees every CHILD Cmd in `cmds` that will never be dispatched --
// cancellation fired mid-fan-out (compose_run_batch) or before starting the
// next step (compose_run_sequence), or the whole Compose_Spec was abandoned
// before ever reaching a coordinator thread (compose() and compose_dispatch's
// own allocation-failure paths above/below). Mirrors run_cmd_guarded's own
// `if cmd.env != nil { free(cmd.env, cmd.allocator) }` -- the exact cleanup
// each of these Cmds would have gotten had it actually run, performed here
// instead since nothing else ever will.
//
// A nested, never-started compose child (c.compose != nil) gets the SAME
// treatment applied recursively to its own cmds/spec, since nobody else will
// ever reach it either -- this proc calls itself rather than duplicating
// that recursion at every call site.
//
// A never-started Tick/Every child (c.timer != nil) is deliberately left
// alone: correctly releasing it needs timer.odin's own file-private
// timer_handle_release, and the resulting leak -- Timer_Handle's own few
// dozen bytes plus its cloned fn env, and ONLY if the caller also never
// calls timer_stop on the handle they got back from tick()/every() -- is
// the EXACT bounded, already-accepted cost Timer_Handle's own doc comment
// (timer.odin) signs off on for a plain discarded Tick/Every ("discarding it
// instead is fine and leaks nothing MORE than the bytes of the handle
// itself"). Composing that Cmd into a batch/sequence that then gets
// abandoned before ever starting it does not make this worse -- see
// docs/superpowers/batch-sequence-decision.md for the full accounting.
@(private = "file")
compose_free_unrun :: proc(cmds: []Cmd) {
	for c in cmds {
		if c.compose != nil {
			compose_free_unrun(c.compose.cmds)
			delete(c.compose.cmds, c.compose.alloc)
			free(c.compose, c.compose.alloc)
			continue
		}
		if c.timer != nil { continue }
		if c.env != nil { free(c.env, c.allocator) }
	}
}

// env for the synthetic Cmd compose_dispatch below builds -- `d` is what
// lets compose_run_batch/compose_run_sequence call back into dispatch_ex for
// each child, which a plain Cmd.procedure's (env, cancel) signature has no
// room for otherwise. This is exactly why `compose` above can only build a
// Compose_Spec at construction time (batch()/sequence() are called from
// user update() code, which never has a ^Dispatcher in hand) and why the
// actual coordination has to wait until dispatch_ex sees c.compose != nil,
// mirroring timer_dispatch's identical split (timer.odin).
@(private = "file")
Compose_Env :: struct {
	d:    ^Dispatcher,
	spec: ^Compose_Spec,
}

// Runs entirely on the synthetic Cmd's own detached thread (see
// compose_dispatch below), inside run_cmd_guarded's guarded() call --  a
// genuine panic anywhere in the coordination logic below is caught there
// exactly like a panic in any ordinary Cmd body, and reported as this
// compose Cmd's own Panicked_Msg. Returns a genuine nil `any` -- a compose
// Cmd delivers nothing of its own to the mailbox, ever; only its children's
// own results do (run_cmd_detached's `msg.id != nil` check, cmd.odin, treats
// this exactly like "nothing to send", not like a zero-sized Msg -- see that
// check's own comment for the distinction this relies on).
@(private = "file")
compose_procedure :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	ce := cast(^Compose_Env)env
	switch ce.spec.kind {
	case .Batch:    compose_run_batch(ce.d, ce.spec, cancel)
	case .Sequence: compose_run_sequence(ce.d, ce.spec, cancel)
	}
	return nil
}

// `wg` is heap-allocated here, deliberately NOT a stack local of
// compose_run_batch/compose_run_sequence, even though a stack local would
// work in the ordinary case. Reason: these procs run inside run_cmd_guarded's
// guarded() call (via compose_procedure above), and guarded()'s recovery
// path is longjmp -- which discards the current stack frame WITHOUT running
// any defer and without any other code in this file getting a chance to run
// first. If a bug ever made compose_run_batch/compose_run_sequence panic
// partway through their own fan-out loop, a STACK-local Wait_Group would
// have its memory considered dead the instant longjmp unwinds past it, while
// children already dispatched with `&wg` as their `done` target might still
// be running on other threads and would later call wait_group_done into
// memory this thread has since reused for something else -- a genuine
// stack-corruption hazard, not a hypothetical one, and structurally the
// EXACT class of bug Reap_Ctx/Grace_Signal (cmd.odin) are heap-allocated to
// avoid for run()'s own teardown path. Heap-allocating `wg` here closes it
// the same way: if a panic is ever recovered mid-fan-out, `wg` (and, on that
// same rare path, `spec`/`spec.cmds`, and anything compose_free_unrun would
// otherwise have reclaimed) simply leaks -- accepted, not floated as free of
// cost, and consistent with run_cmd_guarded's own already-documented "does
// not reclaim a Cmd body's own scratch allocations on panic" limitation
// (cmd.odin). The ordinary, non-panicking path always frees `wg` itself,
// below.
@(private = "file")
compose_run_batch :: proc(d: ^Dispatcher, spec: ^Compose_Spec, cancel: ^Cancel_Token) {
	wg, werr := new(sync.Wait_Group, context.allocator)
	if werr != nil {
		compose_free_unrun(spec.cmds)
		delete(spec.cmds, spec.alloc)
		free(spec, spec.alloc)
		return
	}

	started := 0
	for c in spec.cmds {
		if cancel_requested(cancel) { break }
		sync.wait_group_add(wg, 1)
		started += 1
		dispatch_ex(d, c, wg)
	}
	// Anything past `started` never got dispatched -- cancellation fired
	// mid-fan-out. Free those children's envs now; nothing else ever will.
	compose_free_unrun(spec.cmds[started:])

	// spec.cmds itself is safe to reclaim now, not only after the wait
	// below: every entry has already been either dispatched (copied by
	// value into its own Task_Env/Compose_Env, independent memory from this
	// point on) or handed to compose_free_unrun just above. Nothing holds a
	// pointer into spec.cmds past this line.
	delete(spec.cmds, spec.alloc)
	free(spec, spec.alloc)

	// Blocks THIS thread (the coordinator's own dedicated detached thread,
	// never a pool worker -- see compose_dispatch) until every DISPATCHED
	// child has signaled done, however long that takes. This is exactly the
	// wait tension 3 is about: safe here only because compose_dispatch
	// guarantees this proc never runs anywhere but its own thread.
	sync.wait_group_wait(wg)
	free(wg, context.allocator)
}

// See compose_run_batch's own doc comment for why `wg` is heap-allocated.
// The SAME Wait_Group is reused across every step (add, dispatch, wait,
// repeat) rather than one per step -- safe per sync.Wait_Group's own
// documented contract (core:sync/extended.odin): each wait_group_wait call
// here fully returns (counter provably back to 0) before the NEXT
// wait_group_add call on the same wg, strictly sequentially, on this one
// thread -- never concurrent add-during-wait, which is the one pattern that
// contract forbids.
@(private = "file")
compose_run_sequence :: proc(d: ^Dispatcher, spec: ^Compose_Spec, cancel: ^Cancel_Token) {
	wg, werr := new(sync.Wait_Group, context.allocator)
	if werr != nil {
		compose_free_unrun(spec.cmds)
		delete(spec.cmds, spec.alloc)
		free(spec, spec.alloc)
		return
	}

	i := 0
	for i < len(spec.cmds) {
		// Checked at the top of EVERY iteration, including the first -- not
		// just once cancellation has raced a specific step's own duration.
		// This is what keeps a sequence's remaining steps from running after
		// quit: the currently in-flight step (if any) still runs to
		// completion below (cooperative, same limit as Cancel_Token
		// everywhere else), but nothing FURTHER ever starts once this
		// observes the flag.
		if cancel_requested(cancel) { break }
		c := spec.cmds[i]
		sync.wait_group_add(wg, 1)
		dispatch_ex(d, c, wg)
		sync.wait_group_wait(wg)   // exactly what makes this a SEQUENCE: the next iteration cannot start until this one's child has fully signaled done
		i += 1
	}
	compose_free_unrun(spec.cmds[i:])
	delete(spec.cmds, spec.alloc)
	free(spec, spec.alloc)
	free(wg, context.allocator)
}

// Called from dispatch_ex (cmd.odin) when c.compose != nil. Converts the
// compose Cmd into a SYNTHETIC ordinary Cmd (procedure = compose_procedure,
// env = a freshly heap-allocated Compose_Env) with detached FORCED true --
// unconditionally, with no parameter for a caller to override -- and hands
// it back to dispatch_ex, which then runs it through the EXACT SAME detached
// branch (cmd.odin) any other detached Cmd takes: wait_group_add(&d.inflight,
// 1) before spawning, a dedicated self-cleaning OS thread, run_cmd_guarded
// for panic safety, and wait_group_done(&d.inflight) as that thread's own
// last action. This is the whole answer to tension 3 (the pool deadlock):
// reusing that exact, already race-tested machinery instead of inventing a
// second thread-spawning path alongside it. `done` (nil for a top-level
// batch()/sequence(), non-nil for a nested one) rides along unchanged --
// dispatch_ex's own contract already covers signaling it exactly once no
// matter which branch handles the synthetic Cmd.
@(private = "package")
compose_dispatch :: proc(d: ^Dispatcher, spec: ^Compose_Spec, done: ^sync.Wait_Group) {
	ce, err := new(Compose_Env, context.allocator)
	if err != nil {
		// Can't even start the coordinator -- abandon every child now rather
		// than leave them un-freed forever with nothing left to reach them.
		compose_free_unrun(spec.cmds)
		delete(spec.cmds, spec.alloc)
		free(spec, spec.alloc)
		if done != nil { sync.wait_group_done(done) }
		return
	}
	ce^ = Compose_Env{d = d, spec = spec}
	synthetic := Cmd{procedure = compose_procedure, env = rawptr(ce), allocator = context.allocator, detached = true}
	dispatch_ex(d, synthetic, done)
}
