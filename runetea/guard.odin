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
// corrupting the stack. Rather than let that happen, entry is guarded by
// `assert(!g_armed, ...)` (debug-only, stripped with -disable-assert like
// any other assert). Because that assert runs through whatever
// assertion_failure_proc is already installed on this thread, a misused
// nested call is actually caught and recovered by the OUTER guarded() call:
// the outer invocation returns Panic_Info{recovered = true} carrying a
// message about the nesting violation, instead of silently corrupting
// state. Still a bug to fix in the caller, but an observable one.
//
// longjmp does NOT unwind and does NOT run `defer`. On recovery the caller must
// reset any state `body` owned -- free the frame arena, release held mutexes.
// The per-frame arena (Task 4) makes the memory half of that free.
//
// Bounds violations and nil derefs never reach here; install_crash_handlers
// covers those and they are NOT recoverable.
guarded :: proc(body: proc(ud: rawptr), ud: rawptr, allocator := context.allocator) -> Panic_Info {
	assert(!g_armed, "guarded() does not support nesting on the same thread")
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
@(private="file") g_altstack_buf: [posix.SIGSTKSZ]byte

// Tier 2. Bounds-check failure is the likeliest TUI crash -- indexing a cell
// buffer during render -- and it traps rather than calling assertion_failure_proc,
// so this is the primary net, not a backstop. SIGTERM is included because
// it's the default signal from kill(1), systemd, and `docker stop` -- far
// more likely in practice than SIGBUS/SIGTRAP -- and arriving mid-raw-mode
// it would otherwise strand the user's shell until they blind-type `reset`.
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
