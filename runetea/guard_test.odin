package runetea

import "core:testing"
import "core:sys/posix"

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
// still be an observable failure, not silent stack corruption. The inner
// guarded() call's re-entrancy assert fires through whatever
// assertion_failure_proc is already installed on this thread, which at that
// point is still the OUTER call's -- so the violation is actually recovered
// by the OUTER invocation, never returning control to the inner call site.
@(test)
test_guard_nested_call_is_caught_by_outer_recovery :: proc(t: ^testing.T) {
	info := guarded(proc(ud: rawptr) {
		_ = guarded(proc(ud2: rawptr) {}, nil)  // never returns here; longjmps out to the outer frame
		panic("unreachable: nested guarded() should have longjmp'd past this")
	}, nil)
	testing.expect(t, info.recovered, "a nested guarded() call must be caught, not silently corrupt state")
	testing.expect_value(t, info.message, "guarded() does not support nesting on the same thread")
	delete(info.message)

	// g_armed is file-private to guard.odin, so probe indirectly: a second,
	// ordinary (non-nested) guarded() call must still work normally after
	// the misuse above, proving g_armed was reset to false and not left
	// stuck true by the outer call's own longjmp-driven recovery.
	hit := false
	after := guarded(proc(ud: rawptr) { (cast(^bool)ud)^ = true }, &hit)
	testing.expect(t, !after.recovered, "guarded() must work normally after recovering from a nesting violation")
	testing.expect(t, hit, "body should have run on the post-violation call")
}

// Query-only sigaction (act == nil) reads the current disposition into oact
// without changing it, so this test can inspect what install_crash_handlers
// did to SIGTERM without needing to trigger it. Saves and restores every
// signal install_crash_handlers touches, so this test doesn't leave crash
// handlers installed process-wide for the rest of the suite.
@(test)
test_install_crash_handlers_covers_sigterm :: proc(t: ^testing.T) {
	sigs := [?]posix.Signal{
		.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE, .SIGABRT, .SIGTRAP, .SIGHUP, .SIGQUIT, .SIGTERM,
	}
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
