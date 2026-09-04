#+private
// ^ Every declaration in this file is package-private, so that `odin doc
//   runetea` / `odin doc runegloss` -- the command README.md and docs/API.md
//   hand a newcomer for symbol discovery -- lists the library rather than the
//   test fixtures. Pinned by tools/doccheck/run.sh's `apidoc` check, which is
//   also where the argument for it is written out.
package runetea

import "core:c"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(test)
test_guard_recovers_panic :: proc(t: ^testing.T) {
	info := guarded(proc(ud: rawptr) { panic("boom in user update") }, nil)
	testing.expect(t, info.recovered, "expected recovery from panic")
	testing.expect_value(t, info.message, "boom in user update")
	delete(info.message)
}

@(test)
test_guard_recovers_bad_type_assertion :: proc(t: ^testing.T) {
	info := guarded(proc(ud: rawptr) {
		x: any = int(3)
		_ = x.(f64)   // wrong type -> runtime assertion
	}, nil)
	testing.expect(t, info.recovered, "expected recovery from bad type assertion")
	delete(info.message)
}

@(test)
test_guard_returns_normally_when_no_panic :: proc(t: ^testing.T) {
	hit := false
	info := guarded(proc(ud: rawptr) { (cast(^bool)ud)^ = true }, &hit)
	testing.expect(t, !info.recovered, "should not report recovery")
	testing.expect(t, hit, "body should have run")
}

@(test)
test_guard_restores_assertion_proc :: proc(t: ^testing.T) {
	before := context.assertion_failure_proc
	info := guarded(proc(ud: rawptr) { panic("x") }, nil)
	delete(info.message)
	testing.expect(t, context.assertion_failure_proc == before,
		"guarded must restore the previous assertion_failure_proc")
}

// Nesting isn't corruption-free -- see guarded()'s doc comment -- but it must
// still be an observable failure, not silent stack corruption. Since FIX 3
// (final fix-wave report) replaced the assert-based re-entrancy check with
// an explicit `if g_armed { return ... }`, the INNER guarded() call now
// returns its own Panic_Info directly to whoever called it (here, the
// outer body) instead of relying on assertion_failure_proc/longjmp to
// unwind into the outer call -- so this test captures the inner call's
// return value directly, rather than asserting on what the outer call
// propagates.
Nested_Probe :: struct { inner_ran: bool, inner_info: Panic_Info }

@(test)
test_guard_nested_call_is_rejected_without_running_body :: proc(t: ^testing.T) {
	probe: Nested_Probe
	outer := guarded(proc(ud: rawptr) {
		p := cast(^Nested_Probe)ud
		p.inner_info = guarded(proc(ud2: rawptr) {
			(cast(^Nested_Probe)ud2).inner_ran = true
		}, p)
	}, &probe)

	testing.expect(t, !outer.recovered, "the outer call's own state must be undisturbed by a rejected nested call")
	testing.expect(t, probe.inner_info.recovered, "a nested guarded() call must report recovered, not proceed")
	testing.expect_value(t, probe.inner_info.message, "guarded() does not support nesting on the same thread")
	delete(probe.inner_info.message)
	testing.expect(t, !probe.inner_ran, "the nested call's body must never run")

	// g_armed is file-private to guard.odin, so probe indirectly: a second,
	// ordinary (non-nested) guarded() call must still work normally after
	// the misuse above, proving g_armed was reset to false and not left
	// stuck true by the rejected nested call or the outer call's own defer.
	hit := false
	after := guarded(proc(ud: rawptr) { (cast(^bool)ud)^ = true }, &hit)
	testing.expect(t, !after.recovered, "guarded() must work normally after rejecting a nested call")
	testing.expect(t, hit, "body should have run on the post-rejection call")
}

// EVERY signal install_crash_handlers now touches. Kept in one place because
// two things depend on it being complete: the assertions below, and the
// save/restore that keeps this test from leaving handlers installed
// process-wide for the rest of the suite. SIGTSTP and SIGCONT are in the list
// because install_crash_handlers calls install_stop_handlers -- a test that
// saved only the fatal nine would leave a job-control handler armed for every
// test that ran after it.
@(private = "file")
HANDLED_SIGNALS :: [?]posix.Signal{
	.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE, .SIGABRT, .SIGTRAP, .SIGHUP, .SIGQUIT, .SIGTERM,
	.SIGINT, .SIGPIPE,
	.SIGTSTP, .SIGCONT,
}

// Query-only sigaction (act == nil) reads the current disposition into oact
// without changing it, so this test can inspect what install_crash_handlers
// did to SIGTERM without needing to trigger it. Saves and restores every
// signal install_crash_handlers touches, so this test doesn't leave crash
// handlers installed process-wide for the rest of the suite.
@(test)
test_install_crash_handlers_covers_sigterm :: proc(t: ^testing.T) {
	sigs := HANDLED_SIGNALS
	saved: [len(sigs)]posix.sigaction_t
	for sig, i in sigs {
		posix.sigaction(sig, nil, &saved[i])
	}
	defer for sig, i in sigs {
		posix.sigaction(sig, &saved[i], nil)
	}

	install_crash_handlers()

	got := posix.sigaction_t{}
	posix.sigaction(.SIGTERM, nil, &got)
	testing.expect(t, got.sa_handler != auto_cast posix.SIG_DFL,
		"install_crash_handlers must override the default SIGTERM disposition")
	testing.expect(t, .ONSTACK in got.sa_flags,
		"install_crash_handlers must run the SIGTERM handler on the alternate signal stack")
}

// The two default-fatal signals that used to be missing, plus the two
// job-control ones that were missing entirely. Disposition-only, because the
// end-to-end proof that the handler actually restores a terminal is
// test_a_fatal_signal_outside_runs_window_restores_the_terminal below and
// term_test's job-control test; what this pins is COVERAGE -- that the list in
// install_crash_handlers has not quietly lost a member again.
//
// Why these four and not every default-fatal signal: SIGPIPE is covered on no
// other path at all (a write to a dead pipe or a child's stdin killed the
// process with the alternate screen, mouse tracking, bracketed paste and a
// Kitty push all still on), and SIGINT is covered ONLY while run()'s
// Signal_Watcher is alive -- the startup and shutdown windows around it, and any
// app using term_enter_raw + decode_keys without run(), had nothing. SIGUSR1,
// SIGALRM and SIGXCPU strand a terminal identically and are deliberately absent:
// each has a legitimate application meaning this library has no business
// overriding, whereas nothing wants SIGPIPE's default disposition.
@(test)
test_install_crash_handlers_covers_sigpipe_sigint_and_job_control :: proc(t: ^testing.T) {
	sigs := HANDLED_SIGNALS
	saved: [len(sigs)]posix.sigaction_t
	for sig, i in sigs {
		posix.sigaction(sig, nil, &saved[i])
	}
	defer for sig, i in sigs {
		posix.sigaction(sig, &saved[i], nil)
	}

	install_crash_handlers()

	for sig in ([?]posix.Signal{.SIGPIPE, .SIGINT, .SIGTSTP, .SIGCONT}) {
		got := posix.sigaction_t{}
		posix.sigaction(sig, nil, &got)
		testing.expectf(t, got.sa_handler != auto_cast posix.SIG_DFL,
			"install_crash_handlers must override the default %v disposition -- left at SIG_DFL, every one of these four ends or suspends the process with whatever terminal modes the app opted into still on", sig)
		testing.expectf(t, .ONSTACK in got.sa_flags,
			"the %v handler must run on the alternate signal stack, like every other handler here", sig)
	}
}

// END TO END, at a real pty, for the two signals that had no handler.
//
// Forked for the reason every signal test in this package is: the process under
// test does not survive. The child deliberately has NO `defer rt.term_restore()`
// -- everything asserted here has to come from crash_handler or not at all --
// and it is killed by the signal directly rather than through run(), which is
// precisely the window the old list did not cover: SIGINT is blocked
// process-wide while run()'s Signal_Watcher is alive, so an app that never
// starts one (term_enter_raw + decode_keys, the shape LIMITATIONS 6.9 documents
// as supported) had no protection at all.
//
// The pty harness is term_test.odin's -- see its private="package" note.
@(test)
test_a_fatal_signal_outside_runs_window_restores_the_terminal :: proc(t: ^testing.T) {
	for sig in ([?]posix.Signal{.SIGPIPE, .SIGINT}) {
		pty, ok := open_test_pty()
		if !testing.expect(t, ok, "could not open a pty") { return }
		defer close_test_pty(pty)

		pid := posix.fork()
		if !testing.expect(t, pid >= 0, "fork failed") { return }

		if pid == 0 {
			// CHILD.
			posix.close(pty.master)
			install_crash_handlers()
			if !term_enter_raw(pty.slave, {kb = {.Disambiguate}, paste = true, mouse = .Normal, alt = true}) {
				posix._exit(1)
			}
			posix.raise(sig)
			posix._exit(1)   // NOT REACHED: crash_handler re-raises with SIG_DFL
		}

		// The opt-ins in the order term_acquire writes them, then their undos in
		// the order term_restore_c writes them (worst-first). Constants, because
		// Odin only concatenates strings at compile time.
		ENABLES  :: "\e[>1u\e[?u" + "\e[?2004h" + "\e[?1000h\e[?1006h" + "\e[?1049h"
		TEARDOWN :: "\e[<1u" + "\e[?1049l" + "\e[?1006l\e[?1000l" + "\e[?2004l"
		PAIRED   :: ENABLES + TEARDOWN

		status: c.int
		exited := false
		for _ in 0 ..< 200 {
			if posix.waitpid(pid, &status, {.NOHANG}) == pid { exited = true; break }
			time.sleep(5 * time.Millisecond)
		}
		if !exited {
			posix.kill(pid, posix.Signal.SIGKILL)
			testing.expectf(t, false, "%v: child did not die within 1s", sig)
			return
		}
		testing.expectf(t, posix.WIFSIGNALED(status),
			"%v: the child must die BY SIGNAL -- if it exited normally, crash_handler never ran", sig)

		buf: [256]u8
		got := drain_master(pty.master, buf[:], len(PAIRED))
		testing.expectf(t, got == PAIRED,
			"%v: the pty saw %q, want every opt-in paired with its undo %q", sig, got, PAIRED)

		after: posix.termios
		if !testing.expectf(t, posix.tcgetattr(pty.slave, &after) == .OK, "%v: tcgetattr after the kill", sig) { return }
		testing.expectf(t, .ECHO in after.c_lflag,   "%v: the tty must come back ECHOing", sig)
		testing.expectf(t, .ICANON in after.c_lflag, "%v: the tty must come back canonical", sig)
		testing.expectf(t, .ISIG in after.c_lflag,   "%v: the tty must come back with ISIG -- without it the shell has no Ctrl+C", sig)
		testing.expectf(t, .OPOST in after.c_oflag,  "%v: the tty must come back with OPOST -- without it every newline staircases", sig)
	}
}

// ---------------------------------------------------------------------------
// A RESUME HAS TO REPAINT, and under .Diff a Window_Size_Msg is not a repaint.
//
// The stop half of job control is pinned end-to-end in term_test's
// test_a_job_control_stop_restores_the_tty_and_a_resume_re_acquires_it, in a
// forked child under real job control, because a test runner cannot stop itself
// and still observe. This is the half that CAN be observed in-process: what the
// resume asks the RENDERER for.
//
// The old resume was one synthetic SIGWINCH, and the comment above tstp_handler
// used to call that "honestly partial". It was partial in a way that mattered:
// a Window_Size_Msg makes the app render, but renderer_set_width and
// renderer_set_height only invalidate .Diff's cell model when the size actually
// CHANGED. Resume at the same size and the model still described the pre-stop
// frame -- on a terminal the user's shell had, in the meantime, printed a
// prompt and a command's output onto. .Diff emits only the cells it believes
// changed, so the shell's text stayed on screen for the rest of the session.
// Permanent corruption, from a clean suspend and resume.
//
// SIGCONT is used here rather than SIGTSTP because delivering it does not stop
// the runner: cont_handler is the half that covers the stop this process cannot
// mediate (SIGSTOP is uncatchable), and it runs on delivery whether or not the
// process was ever stopped.
@(test)
test_a_resume_asks_the_next_diff_frame_to_repaint :: proc(t: ^testing.T) {
	sigs := HANDLED_SIGNALS
	saved: [len(sigs)]posix.sigaction_t
	for sig, i in sigs {
		posix.sigaction(sig, nil, &saved[i])
	}
	defer for sig, i in sigs {
		posix.sigaction(sig, &saved[i], nil)
	}

	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)

	install_stop_handlers()
	// cont_handler is gated on raw_active -- a stop arriving when this process
	// does not own a terminal must not have it grab one -- so the test has to
	// own one for the handler to do anything at all.
	if !testing.expect(t, term_enter_raw(pty.slave), "term_enter_raw failed") { return }
	defer term_restore()

	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 10, 3, .Diff)
	defer renderer_destroy(&r)

	renderer_render(&r, "hi")
	first := strings.clone(strings.to_string(b)); defer delete(first)

	strings.builder_reset(&b)
	renderer_render(&r, "hi")
	testing.expect_value(t, strings.to_string(b), "")

	// raise() and not kill(getpid()): raise is THREAD-directed and POSIX
	// requires the signal to be delivered before it returns, so the assertion
	// below is not racing the handler. A process-directed kill may be taken by
	// any thread that has SIGCONT unblocked -- the test runner's own main thread
	// among them -- and this test failed intermittently for exactly that reason
	// before the switch. guard.odin's handlers use kill() deliberately and for
	// the opposite reason (see tstp_handler: the watcher thread must see it).
	posix.raise(posix.Signal.SIGCONT)

	strings.builder_reset(&b)
	renderer_render(&r, "hi")
	testing.expectf(t, strings.to_string(b) == first,
		"the frame after a resume wrote %q, want a full repaint %q -- everything the shell printed over the frame while we were stopped stays on screen otherwise", strings.to_string(b), first)
}
