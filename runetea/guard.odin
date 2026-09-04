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

// JOB CONTROL, the half of the terminal contract that was missing entirely.
//
// SIGTSTP appeared nowhere in this codebase before this handler: an EXTERNAL
// job-control stop -- `kill -TSTP`, a supervisor, another terminal stopping the
// job -- stopped the process with ZERO teardown bytes emitted. Note that it is
// not the Ctrl+Z KEYSTROKE: term_acquire clears ISIG, so Ctrl+Z is delivered to
// a raw-mode app as an inert 0x1a byte and never becomes a signal at all. What
// the user got instead was the alternate screen still on, mouse tracking (1000 +
// 1006) still on, bracketed paste still on, one Kitty entry still pushed and the
// cursor wherever the last frame left it -- and then their shell printed its
// prompt and their next command's output INTO THE ALTERNATE BUFFER, on top of a
// frozen frame. On resume there was no SIGCONT handler either, so the app never
// re-entered raw mode: the tty stayed canonical (ECHO/ICANON/ISIG back on),
// every keystroke was echoed by the line discipline into the middle of the dead
// frame, and the app was deaf until a newline. With the .Diff renderer that
// damage is PERMANENT -- it patches only the cells it believes changed, so the
// shell's text stays on screen for the rest of the session.
//
// The contract implemented here is the one vim, less, htop, crossterm and Bubble
// Tea's ReleaseTerminal/RestoreTerminal all implement: restore on stop,
// re-acquire and repaint on continue.
//
// THE STOP-FOR-REAL DANCE, and why every step is needed. A handler that only
// restored would swallow the stop entirely and the job would keep running, which
// is worse than not handling it. So: tear the terminal down, set SIGTSTP back to
// SIG_DFL, UNBLOCK it (it is blocked inside its own handler -- no SA_NODEFER --
// so the re-raise would otherwise be deferred until the handler returned, i.e.
// until after the process had already carried on), and raise it. The process
// stops inside that raise, and resumes out of it when SIGCONT arrives.
//
// WHAT IT COSTS. Between the sigaction(SIG_DFL) and the reinstall on the far
// side, a SECOND SIGTSTP stops the process with no teardown. That window is the
// price of the SIG_DFL/raise idiom every program that does this pays, and it is
// bounded by two lines of straight-line code.
//
// THE RESUME IS THE SAME CODE PATH AS THE ACQUIRE, not a second implementation:
// term_acquire is async-signal-safe by construction (tcgetattr/tcsetattr/write,
// no allocation, no fmt, no locks) and g_term.opts/g_term.escapes_ok survive the
// teardown precisely so it can be replayed here. `was_raw` is captured BEFORE
// term_restore_c so that a stop arriving when this process does not own a
// terminal -- before term_enter_raw, after term_restore -- resumes without
// grabbing one.
//
// THE REPAINT IS TWO SIGNALS' WORTH OF WORK AND IT USED TO BE ONE. The
// synthetic SIGWINCH is what run()'s Signal_Watcher turns into a
// Window_Size_Msg, which is what makes the resumed app RENDER AT ALL -- without
// it nothing wakes the loop until the user's next keystroke. kill(getpid())
// rather than raise(): raise is thread-directed, and a blocked thread-directed
// signal is never seen by the watcher thread's sigwait.
//
// A Window_Size_Msg is not by itself a repaint, and this used to be the whole
// of the resume. It says the size MIGHT have changed, and renderer_set_width /
// renderer_set_height set .Diff's force_repaint only when it actually DID -- so
// `fg` after a `Ctrl+Z` at an UNCHANGED window size resumed into a diff against
// a cell model still describing the frame from before the stop, on a terminal
// the user's shell had since printed a prompt and a command's output onto. .Diff
// patches only the cells it believes changed, so the shell's text stayed on
// screen for the rest of the session: permanent corruption, from a clean
// suspend/resume, in the mode this file's own comment says makes the damage
// permanent. render.odin's request_repaint closes it, and closes .Inline's
// version of the same hole (a rewind over rows that now belong to the shell).
// It is the RIGHT half of this pairing to add, rather than reaching for the
// Renderer: this is signal context and run()'s Renderer is on run()'s stack.
@(private="file")
tstp_handler :: proc "c" (sig: posix.Signal) {
	was_raw := g_term.raw_active
	fd      := g_term.fd
	opts    := g_term.opts
	escapes := g_term.escapes_ok

	term_restore_c()

	act := posix.sigaction_t{}
	act.sa_handler = auto_cast posix.SIG_DFL
	posix.sigaction(.SIGTSTP, &act, nil)

	set, old: posix.sigset_t
	posix.sigemptyset(&set)
	posix.sigaddset(&set, .SIGTSTP)
	posix.pthread_sigmask(.UNBLOCK, &set, &old)

	posix.raise(.SIGTSTP)   // the process stops HERE, and resumes on SIGCONT

	posix.pthread_sigmask(.SETMASK, &old, nil)
	install_stop_handlers()
	if was_raw {
		term_acquire(fd, opts, escapes)
		request_repaint()
		posix.kill(posix.getpid(), SIGWINCH)
	}
}

// The other half, and it covers the stop this process CANNOT mediate: SIGSTOP is
// uncatchable, so nothing ran on the way down and every mode the app set is
// still set -- but the shell that had the terminal in the meantime will have put
// the line discipline back to cooked for its own use. So the job here is not a
// full rebuild, it is re-applying the TERMIOS half, and term_acquire's
// idempotence is what makes saying it that simply possible: with raw_active
// still true it re-applies raw mode and skips every opt-in whose flag is already
// set, so nothing is pushed or DECSET twice.
//
// Gated on raw_active, which is what makes this a no-op on the SIGTSTP path
// above: that handler restored before stopping, so raw_active is false when this
// runs, and the full re-acquire happens where it belongs -- on the far side of
// the raise, with the opts the stop captured.
@(private="file")
cont_handler :: proc "c" (sig: posix.Signal) {
	if !g_term.raw_active { return }
	term_acquire(g_term.fd, g_term.opts, g_term.escapes_ok)
	// Same pairing as the TSTP path's, and needed MORE here rather than less:
	// an uncatchable SIGSTOP means the shell had the terminal with none of our
	// teardown having run, so whatever it printed is sitting on top of a frame
	// the cell model still believes is intact. See request_repaint.
	request_repaint()
	posix.kill(posix.getpid(), SIGWINCH)
}

// Installed by install_crash_handlers, and separately callable for an
// application that wants job-control correctness without the crash net (or that
// re-installs its own handlers and needs to put these back).
//
// Dispositions are PROCESS-WIDE, so calling this more than once -- which the
// per-thread install_crash_handlers contract guarantees will happen -- is
// redundant and harmless. It is also what the SIGTSTP handler itself calls to
// re-arm on the far side of its own stop.
install_stop_handlers :: proc "c" () {
	tstp := posix.sigaction_t{}
	tstp.sa_handler = tstp_handler
	tstp.sa_flags = {.ONSTACK}
	posix.sigaction(.SIGTSTP, &tstp, nil)

	cont := posix.sigaction_t{}
	cont.sa_handler = cont_handler
	// SA_RESTART: SIGCONT interrupts every blocking read in the process, and the
	// input reader's read(2) on the tty is one of them. Without it a resume can
	// surface as a spurious EINTR in a layer that has no reason to expect one.
	cont.sa_flags = {.ONSTACK, .RESTART}
	posix.sigaction(.SIGCONT, &cont, nil)
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
// WHAT IT COVERS, in one place, because the list has grown twice: the fatal
// eleven (SIGSEGV BUS ILL FPE ABRT TRAP HUP QUIT TERM, plus INT and PIPE -- see
// the `sigs` literal for why those two and not every default-fatal signal), and
// job control (SIGTSTP/SIGCONT, via install_stop_handlers). Nothing can cover
// SIGKILL or SIGSTOP; term_restore_c's own comment enumerates exactly what those
// two strand.
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

	// SIGPIPE and SIGINT were the two default-fatal signals missing from this
	// list, and SIGPIPE is the load-bearing one. It is covered on NO other path:
	// a `kill -PIPE` to an app inside run() -- or, far more realistically, one
	// write to a pipe or to a child's stdin whose reader has gone -- killed the
	// process with the alternate screen, mouse tracking, bracketed paste and a
	// Kitty push all still on and the tty still -icanon (verified by running stty
	// in the same pty session afterwards; SIGTERM on the same binary restored
	// everything). SIGUSR1, SIGALRM and SIGXCPU strand a terminal the same way
	// and are deliberately NOT added: each has a legitimate application meaning
	// this library has no business overriding, whereas nothing wants the default
	// disposition of SIGPIPE.
	//
	// SIGINT is the narrower case and is added for the gaps, not the main path:
	// while run()'s Signal_Watcher is alive it blocks SIGINT process-wide, so
	// this handler is INERT there and the watcher's orderly Interrupt_Msg quit is
	// unaffected. What it covers is everything outside that window -- the startup
	// race between term_enter_raw's opt-in writes and signal_watcher_start
	// (reproduced 5/60 with randomised 0-30ms kills), the symmetric shutdown
	// window, and any app that uses term_enter_raw + decode_keys WITHOUT run(),
	// which docs/LIMITATIONS 6.9 presents as a supported shape.
	sigs := []posix.Signal{
		.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE, .SIGABRT, .SIGTRAP, .SIGHUP, .SIGQUIT, .SIGTERM,
		.SIGINT, .SIGPIPE,
	}
	for sig in sigs {
		act := posix.sigaction_t{}
		act.sa_handler = crash_handler
		act.sa_flags = {.ONSTACK}
		posix.sigaction(sig, &act, nil)
	}

	// Job control is not a crash, but it strands a terminal the same way and the
	// fix lives at the same level. Installed from here rather than left as a
	// separate opt-in for one reason: every example and tool in this repository
	// already calls install_crash_handlers, and a correctness fix nobody calls is
	// not a fix. See install_stop_handlers.
	install_stop_handlers()
}
