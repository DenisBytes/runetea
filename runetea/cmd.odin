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

Dispatcher :: struct {
	pool:    thread.Pool,
	mailbox: ^Mailbox,
	tasks:   [dynamic]^Task_Env,
	mutex:   sync.Mutex,
}

Task_Env :: struct {
	cmd:     Cmd,
	mailbox: ^Mailbox,
}

dispatcher_init :: proc(d: ^Dispatcher, m: ^Mailbox, workers: int) {
	d.mailbox = m
	d.tasks = make([dynamic]^Task_Env)
	thread.pool_init(&d.pool, context.allocator, max(workers, 1))
	thread.pool_start(&d.pool)
}

dispatcher_destroy :: proc(d: ^Dispatcher) {
	thread.pool_finish(&d.pool)
	thread.pool_destroy(&d.pool)
	sync.mutex_lock(&d.mutex)
	for te in d.tasks { free(te) }
	delete(d.tasks)
	sync.mutex_unlock(&d.mutex)
}

@(private="file")
run_cmd_task :: proc(task: thread.Task) {
	te := cast(^Task_Env)task.data
	if te.cmd.procedure == nil { return }
	msg := te.cmd.procedure(te.cmd.env)
	if te.cmd.env != nil { free(te.cmd.env, te.cmd.allocator) }
	if msg != nil { _ = mailbox_send(te.mailbox, msg) }
}

@(private="file")
run_cmd_detached :: proc(data: rawptr) {
	te := cast(^Task_Env)data
	if te.cmd.procedure != nil {
		msg := te.cmd.procedure(te.cmd.env)
		if te.cmd.env != nil { free(te.cmd.env, te.cmd.allocator) }
		if msg != nil { _ = mailbox_send(te.mailbox, msg) }
	}
	free(te)
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
		te := new(Task_Env)
		te^ = Task_Env{cmd = c, mailbox = d.mailbox}
		thread.create_and_start_with_data(rawptr(te), run_cmd_detached, init_context = context, self_cleanup = true)
		return
	}

	te := new(Task_Env)
	te^ = Task_Env{cmd = c, mailbox = d.mailbox}
	sync.mutex_lock(&d.mutex)
	append(&d.tasks, te)
	sync.mutex_unlock(&d.mutex)
	thread.pool_add_task(&d.pool, context.allocator, run_cmd_task, te)
}
