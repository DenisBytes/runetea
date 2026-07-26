package runetea

import "core:mem"
import "core:sync"
import "core:thread"

// Go's `type Cmd func() Msg` is a closure. Odin has no closures at all, so the
// captured environment becomes explicit. This is the port's largest permanent
// ergonomic cost and it touches every user program.
Cmd :: struct {
	procedure: proc(env: rawptr) -> any,
	env:       rawptr,
	allocator: mem.Allocator,   // frees env after procedure returns
	detached:  bool,            // bypass the pool -- see dispatch
}

cmd_nil :: proc() -> Cmd { return Cmd{} }

cmd_is_nil :: proc(c: Cmd) -> bool { return c.procedure == nil }

// Heap-clones `env` so the Cmd can outlive the caller's frame.
//
// Set detached=true for a Cmd that itself dispatches and waits on other Cmds.
// Such coordinators must not occupy a pool worker: N coordinators on an N-wide
// pool leaves no worker for their children, which deadlocks. Detached is the
// deliberate equivalent of Go's leaked-goroutine-per-Cmd, used rarely.
cmd_from :: proc(fn: proc(env: rawptr) -> any, env: $E, alloc: mem.Allocator, detached := false) -> Cmd {
	p, err := new(E, alloc)
	if err != nil { return cmd_nil() }
	p^ = env
	return Cmd{procedure = fn, env = rawptr(p), allocator = alloc, detached = detached}
}

// PRECONDITION (mirrors mailbox.odin's mailbox_destroy contract): the caller
// must stop calling dispatch() before calling dispatcher_destroy, and must
// destroy the Dispatcher before destroying the Mailbox it was constructed
// with. dispatcher_destroy blocks until every pool worker AND every detached
// Cmd it ever dispatched has finished -- see the `inflight` field and the
// CRITICAL note on dispatcher_destroy below for why the latter needs its own
// tracking distinct from thread.Pool's built-in join.
Dispatcher :: struct {
	pool:     thread.Pool,
	mailbox:  ^Mailbox,
	inflight: sync.Wait_Group,   // counts detached Cmds not yet finished
}

Task_Env :: struct {
	cmd:      Cmd,
	mailbox:  ^Mailbox,
	inflight: ^sync.Wait_Group,  // detached only; nil for pool tasks
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

dispatcher_init :: proc(d: ^Dispatcher, m: ^Mailbox, workers: int) {
	d.mailbox = m
	thread.pool_init(&d.pool, context.allocator, max(workers, 1), init_proc = pool_worker_install_crash_handlers)
	thread.pool_start(&d.pool)
}

// thread.pool_finish/pool_destroy genuinely join every pool worker -- that
// part was always correct. But a detached Cmd (see dispatch below) runs on
// its own self_cleanup thread that is tracked NOWHERE else, and core:thread
// explicitly forbids joining a self_cleanup thread. Without inflight, a
// detached Cmd still running -- or mid mailbox_send -- when this returns
// would let the caller's next line (typically mailbox_destroy, per its own
// documented precondition) free the mailbox out from under a live producer:
// a use-after-free on its buffer and mutex. wait_group_wait blocks until
// every dispatch(..., detached=true) call's matching wait_group_done has
// run, which happens as the LAST action in run_cmd_detached, after that
// Cmd's mailbox_send and its own cleanup free -- so by the time this
// procedure returns, nothing can still be touching d.mailbox.
dispatcher_destroy :: proc(d: ^Dispatcher) {
	thread.pool_finish(&d.pool)
	thread.pool_destroy(&d.pool)
	sync.wait_group_wait(&d.inflight)
}

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
@(private="file")
deliver_result :: proc(m: ^Mailbox, msg: any) {
	for {
		switch mailbox_send(m, msg) {
		case .Ok:     return
		case .Closed: return
		case .Full:   thread.yield()
		}
	}
}

@(private="file")
run_cmd_task :: proc(task: thread.Task) {
	te := cast(^Task_Env)task.data
	if te.cmd.procedure != nil {
		msg := te.cmd.procedure(te.cmd.env)
		if te.cmd.env != nil { free(te.cmd.env, te.cmd.allocator) }
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
		if msg.id != nil { deliver_result(te.mailbox, msg) }
	}
	// Freed here, per-task, rather than accumulated in the Dispatcher and
	// freed only at dispatcher_destroy: a Dispatcher is meant to live for
	// the whole session of a long-running TUI, so retaining every completed
	// task's Task_Env until shutdown grows without bound across the run.
	free(te)
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
	if te.cmd.procedure != nil {
		msg := te.cmd.procedure(te.cmd.env)
		if te.cmd.env != nil { free(te.cmd.env, te.cmd.allocator) }
		// See run_cmd_task's comment: msg.id, not msg, distinguishes "a real
		// zero-sized Msg" from "genuinely nothing to send".
		if msg.id != nil { deliver_result(te.mailbox, msg) }
	}
	free(te)
	// Must be the LAST action: dispatcher_destroy's wait_group_wait treats
	// this as proof the Cmd is entirely done, including its mailbox_send and
	// its own te free, and unblocks a caller that may destroy the mailbox on
	// its very next line.
	sync.wait_group_done(inflight)
}

dispatch :: proc(d: ^Dispatcher, c: Cmd) {
	if cmd_is_nil(c) { return }

	if c.detached {
		// Elastic overflow: its own thread, self-cleaning, never pool-bound.
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
		sync.wait_group_add(&d.inflight, 1)
		te := new(Task_Env)
		te^ = Task_Env{cmd = c, mailbox = d.mailbox, inflight = &d.inflight}
		thread.create_and_start_with_data(rawptr(te), run_cmd_detached, init_context = context, self_cleanup = true)
		return
	}

	te := new(Task_Env)
	te^ = Task_Env{cmd = c, mailbox = d.mailbox}
	thread.pool_add_task(&d.pool, context.allocator, run_cmd_task, te)
}
