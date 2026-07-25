package runetea

import "core:testing"
import "core:sys/posix"

// CS8 is 0x30 (multi-bit). posix.CControl_Flags is defined as log2(CS8), which
// truncates to bit 5 -- exactly CS7 (0x20). This test pins the workaround so a
// future refactor cannot silently reintroduce a 7-bit tty.
@(test)
test_cs8_bit_set_is_a_trap :: proc(t: ^testing.T) {
	via_bit_set := transmute(posix.tcflag_t)posix.CControl_Flags{.CS8}
	via_cs7     := transmute(posix.tcflag_t)posix.CControl_Flags{.CS7}
	testing.expect(t, via_bit_set == via_cs7,
		"if this now differs, Odin fixed the bug -- simplify term_enter_raw")

	correct := posix.tcflag_t(posix.CS8)
	testing.expect(t, correct != via_bit_set,
		"the transmute workaround must differ from the bit_set spelling")
}

@(test)
test_term_size_reports_failure_on_non_tty :: proc(t: ^testing.T) {
	// fd 0 under the test runner is not guaranteed to be a tty; the contract is
	// that term_size never panics and reports ok=false when it cannot measure.
	_, _, ok := term_size(posix.FD(-1))
	testing.expect(t, !ok, "term_size on an invalid fd must report ok=false")
}

@(test)
test_restore_is_noop_when_not_raw :: proc(t: ^testing.T) {
	g_term = {}
	term_restore()  // must not crash or touch any fd
	testing.expect(t, !g_term.raw_active, "restore should leave raw_active false")
}

// Pins the rollback path: term_enter_raw sets raw_active = true before the
// tty is actually modified (see the ordering-invariant comment above the
// g_term.fd/raw_active assignment in term_enter_raw), so a failed attempt
// must roll raw_active back to false rather than leaving it stuck true. An
// invalid fd fails at tcgetattr, before any tty is ever touched, so this is
// an end-to-end check of the observable contract -- on failure, raw_active
// is false and a subsequent term_restore() is a safe no-op -- not a probe of
// the internal tcgetattr-vs-tcsetattr branch.
@(test)
test_failed_enter_raw_leaves_raw_active_false :: proc(t: ^testing.T) {
	g_term = {}
	ok := term_enter_raw(posix.FD(-1))
	testing.expect(t, !ok, "term_enter_raw on an invalid fd must report failure")
	testing.expect(t, !g_term.raw_active,
		"a failed term_enter_raw must not leave raw_active true")

	term_restore()  // must not crash or touch any fd
	testing.expect(t, !g_term.raw_active,
		"restore after a failed enter_raw should remain a no-op")
}
