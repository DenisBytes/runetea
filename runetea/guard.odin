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

@(private="file") g_guard:       libc.jmp_buf
@(private="file") g_panic_msg:   string
@(private="file") g_panic_alloc: mem.Allocator

@(private="file")
guard_assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	// MUST clone before jumping: `message` may live in a frame longjmp discards.
	g_panic_msg = strings.clone(message, g_panic_alloc)
	libc.longjmp(&g_guard, 1)
}

// Runs `body`, recovering panics, asserts, and failed type assertions.
//
// longjmp does NOT unwind and does NOT run `defer`. On recovery the caller must
// reset any state `body` owned -- free the frame arena, release held mutexes.
// The per-frame arena (Task 4) makes the memory half of that free.
//
// Bounds violations and nil derefs never reach here; install_crash_handlers
// covers those and they are NOT recoverable.
guarded :: proc(body: proc(ud: rawptr), ud: rawptr, allocator := context.allocator) -> Panic_Info {
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

// Tier 2. Bounds-check failure is the likeliest TUI crash -- indexing a cell
// buffer during render -- and it traps rather than calling assertion_failure_proc,
// so this is the primary net, not a backstop.
install_crash_handlers :: proc() {
	for sig in ([]posix.Signal{.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE, .SIGABRT, .SIGTRAP, .SIGHUP, .SIGQUIT}) {
		act := posix.sigaction_t{}
		act.sa_handler = crash_handler
		posix.sigaction(sig, &act, nil)
	}
}
