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
