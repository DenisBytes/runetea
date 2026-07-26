package runetea

import "base:runtime"
import "core:c/libc"
import "core:mem"
import "core:strings"
import "core:sys/posix"

Panic_Info :: struct {
	message:   string,  // caller owns; delete when done
	recovered: bool,
}

// thread_local: each thread gets its own jump target, panic message, and
// allocator, so concurrent guarded() calls on different threads (Task 5's
// pool, Task 7's signal-watcher thread) never clobber each other's state.
@(thread_local, private="file") g_guard:       libc.jmp_buf
@(thread_local, private="file") g_panic_msg:   string
@(thread_local, private="file") g_panic_alloc: mem.Allocator
// Debug-only re-entrancy guard, see guarded()'s doc comment. Compiled out
// with -disable-assert along with the assert that reads it.
@(thread_local, private="file") g_armed: bool

@(private="file")
guard_assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	// MUST clone before jumping: `message` may live in a frame longjmp discards.
	g_panic_msg = strings.clone(message, g_panic_alloc)
	libc.longjmp(&g_guard, 1)
}

// Runs `body`, recovering panics, asserts, and failed type assertions.
//
// Thread-safe: all guard state above is thread_local, so guarded() may be
// called concurrently from multiple threads with no interference -- each
// thread has its own jump target.
//
// NOT nestable on a single thread: g_guard holds exactly one jmp_buf per
// thread, so a nested guarded() call (body calling guarded() again on the
// same thread) would overwrite the outer call's jump target. When the inner
// call returned, g_guard would point at a dead stack frame, and a later
// panic in the remainder of the outer body would longjmp into it --
// corrupting the stack. Entry is guarded by an explicit `if g_armed { ...
// }` check below, NOT `assert(!g_armed, ...)` -- an assert is exactly the
// wrong tool here (FIX 3, final fix-wave report): -disable-assert is the
// obvious release-build flag, and under it every assert in the program,
// including this one, compiles out entirely. The nesting check would
// vanish with no symptom, and the jmp_buf corruption described above would
// return with nothing to signal it -- a release build silently reintroduces
// the exact bug this guard exists to prevent. The explicit check runs in
// every build, release or not.
//
// A rejected nested call does NOT run `body` and does NOT touch g_guard,
// context.assertion_failure_proc, or anything else the outer, still-active
// guarded() call owns -- it returns Panic_Info{recovered = true} directly
// to whichever code made the nested call (typically the outer body itself),
// leaving the outer call's own state completely undisturbed. Still a bug to
// fix in the caller, but an observable, contained one instead of silent
// stack corruption.
//
// longjmp does NOT unwind and does NOT run `defer`. On recovery the caller must
// reset any state `body` owned -- free the frame arena, release held mutexes.
// The per-frame arena (Task 4) makes the memory half of that free.
//
// Bounds violations and nil derefs never reach here; install_crash_handlers
// covers those and they are NOT recoverable.
guarded :: proc(body: proc(ud: rawptr), ud: rawptr, allocator := context.allocator) -> Panic_Info {
	if g_armed {
		return Panic_Info{
			message   = strings.clone("guarded() does not support nesting on the same thread", allocator),
			recovered = true,
		}
	}
	g_armed = true
	defer g_armed = false

	prev_proc  := context.assertion_failure_proc
	g_panic_alloc = allocator
	context.assertion_failure_proc = guard_assertion_failure
	defer context.assertion_failure_proc = prev_proc

	if libc.setjmp(&g_guard) == 0 {
		body(ud)
		return Panic_Info{recovered = false}
	}
	return Panic_Info{message = g_panic_msg, recovered = true}
}

@(private="file")
crash_handler :: proc "c" (sig: posix.Signal) {
	term_restore_c()
	// Re-raise with the default disposition so the exit status is honest and
	// core dumps still happen.
	act := posix.sigaction_t{}
	act.sa_handler = auto_cast posix.SIG_DFL
	posix.sigaction(sig, &act, nil)
	posix.raise(sig)
}

// Backing store for the alternate signal stack below. A static array, not a
// heap allocation: the commonest real-world SIGSEGV is stack exhaustion from
// runaway recursion, and that signal is delivered on the already-exhausted
// stack. Without an altstack, crash_handler's own calls (tcsetattr, write,
// sigaction, raise) run on that same exhausted stack and can fault again
// before term_restore_c() finishes -- silently defeating Tier 2. A package
// global sidesteps the allocator entirely, at process load time, long before
// any handler could run.
//
// thread_local, not a single shared instance (FIX 2, final fix-wave
// report): sigaltstack is PER-THREAD -- installing it only on the calling
// thread leaves every other thread (pool workers, detached Cmd threads, the
// signal watcher, the reader thread) with no altstack at all, so a
// stack-overflow SIGSEGV on any of them re-faults on its own exhausted
// stack and defeats Tier 2 there. Even calling install_crash_handlers() on
// every thread would not be enough on its own if this buffer stayed a
// single shared instance: two threads crashing concurrently would both be
// handed the SAME backing memory as their alternate stack, and their
// handler frames would corrupt each other. thread_local gives each thread
// that calls install_crash_handlers() its own private backing store.
@(thread_local, private="file") g_altstack_buf: [posix.SIGSTKSZ]byte

// Tier 2. Bounds-check failure is the likeliest TUI crash -- indexing a cell
// buffer during render -- and it traps rather than calling assertion_failure_proc,
// so this is the primary net, not a backstop. SIGTERM is included because
// it's the default signal from kill(1), systemd, and `docker stop` -- far
// more likely in practice than SIGBUS/SIGTRAP -- and arriving mid-raw-mode
// it would otherwise strand the user's shell until they blind-type `reset`.
//
// PER-THREAD: the sigaltstack half of this call only takes effect on the
// CALLING thread (g_altstack_buf is thread_local -- see its own comment).
// The sigaction half is process-wide and therefore redundant on a second
// call, but harmless and cheap, so the same procedure serves both jobs: any
// thread that could plausibly crash -- a Dispatcher pool worker, a detached
// Cmd's own thread, the Signal_Watcher thread, tea.odin's reader thread --
// must call this itself, as close to its first action as possible. Calling
// it once on the main thread and assuming it covers every thread the
// process later spawns is exactly the bug this call-per-thread contract
// fixes (FIX 2, final fix-wave report): 3 of 4 thread classes had no
// altstack at all before this, so a stack-overflow SIGSEGV on any of them
// re-faulted on its own exhausted stack and defeated Tier 2 there.
//
// ORDERING (FIX 4, final fix-wave report): on the thread that also calls
// term_enter_raw, call this BEFORE term_enter_raw, not after. term_enter_raw
// sets g_term.raw_active = true before tcsetattr has actually touched the
// tty (see its own ordering-invariant comment) so that ANY crash from that
// point on is recoverable -- but only if a handler already exists to catch
// it. Installing handlers afterward leaves that entire window (from
// raw_active flipping true through tcsetattr returning) with no handler at
// all: a crash there strands the terminal with no recovery. This is the
// pattern examples/simple and examples/http follow; copy it in new code
// that enters raw mode.
install_crash_handlers :: proc() {
	// Best-effort: if sigaltstack fails, SA_ONSTACK below has no effect and
	// the OS runs handlers on the normal stack (POSIX-defined fallback, not
	// fatal) -- still correct for every signal except a stack-overflow
	// SIGSEGV, which is the one case an altstack exists to cover.
	altstack := posix.stack_t{
		ss_sp   = raw_data(g_altstack_buf[:]),
		ss_size = len(g_altstack_buf),
	}
	posix.sigaltstack(&altstack, nil)

	sigs := []posix.Signal{
		.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE, .SIGABRT, .SIGTRAP, .SIGHUP, .SIGQUIT, .SIGTERM,
	}
	for sig in sigs {
		act := posix.sigaction_t{}
		act.sa_handler = crash_handler
		act.sa_flags = {.ONSTACK}
		posix.sigaction(sig, &act, nil)
	}
}
