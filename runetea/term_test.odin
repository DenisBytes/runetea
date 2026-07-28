package runetea

import "core:c"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

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

// ---------------------------------------------------------------------------
// T1-K: the Kitty keyboard protocol's push/pop pairing.
//
// These drive a REAL pty (posix_openpt/grantpt/unlockpt/ptsname/open -- the
// same technique tools/ttycheck and tools/tier1check use), not a pipe, because
// the sequences under test are only ever written to something term_enter_raw
// accepted, and term_enter_raw needs tcgetattr to succeed. The pty MASTER is
// then the observer: whatever the framework writes to the slave shows up there
// byte for byte, which is exactly what a real terminal emulator would see.
// ---------------------------------------------------------------------------

@(private = "file")
Test_Pty :: struct { master, slave: posix.FD }

@(private = "file")
open_test_pty :: proc() -> (pty: Test_Pty, ok: bool) {
	// NONBLOCK on the master so drain_master can say "nothing arrived" instead
	// of hanging forever when the answer is that nothing SHOULD arrive.
	pty.master = posix.posix_openpt({.RDWR, .NOCTTY, .NONBLOCK})
	if pty.master < 0 { return {}, false }
	if posix.grantpt(pty.master) != .OK  { posix.close(pty.master); return {}, false }
	if posix.unlockpt(pty.master) != .OK { posix.close(pty.master); return {}, false }
	name := posix.ptsname(pty.master)
	if name == nil { posix.close(pty.master); return {}, false }
	pty.slave = posix.open(name, {.RDWR, .NOCTTY})
	if pty.slave < 0 { posix.close(pty.master); return {}, false }
	return pty, true
}

@(private = "file")
close_test_pty :: proc(pty: Test_Pty) {
	posix.close(pty.slave)
	posix.close(pty.master)
}

// Collects what the slave side wrote. `want` bytes is what we are waiting FOR,
// and want == 0 means "prove nothing arrives" -- which still waits a little,
// so a merely-late write cannot masquerade as no write at all.
@(private = "file")
drain_master :: proc(fd: posix.FD, buf: []u8, want: int) -> string {
	n := 0
	attempts := 100 if want > 0 else 4        // 500ms cap when waiting, 20ms when proving a negative
	for _ in 0 ..< attempts {
		if n < len(buf) {
			room := len(buf) - n
			r := posix.read(fd, raw_data(buf[n:]), c.size_t(room))
			if r > 0 { n += int(r) }
		}
		if n >= want && n > 0 { break }
		time.sleep(5 * time.Millisecond)
	}
	return string(buf[:n])
}

// The enum's numeric order IS the protocol's flag word. kitty_push_seq encodes
// with that identity and input.odin's kitty_flags_reply decodes with it, so a
// reordered or mid-block-inserted member would silently push the wrong flags
// AND misread the terminal's reply, with nothing else to catch it.
@(test)
test_kitty_flag_values_match_the_protocol :: proc(t: ^testing.T) {
	testing.expect_value(t, transmute(u8)Kitty_Flags{},                    u8(0))
	testing.expect_value(t, transmute(u8)Kitty_Flags{.Disambiguate},       u8(1))
	testing.expect_value(t, transmute(u8)Kitty_Flags{.Report_Event_Types}, u8(2))
	testing.expect_value(t, transmute(u8)Kitty_Flags{.Alternate_Keys},     u8(4))
	testing.expect_value(t, transmute(u8)Kitty_Flags{.All_Keys_As_Escapes},u8(8))
	testing.expect_value(t, transmute(u8)Kitty_Flags{.Associated_Text},    u8(16))
	all := Kitty_Flags{.Disambiguate, .Report_Event_Types, .Alternate_Keys,
	                   .All_Keys_As_Escapes, .Associated_Text}
	testing.expect_value(t, transmute(u8)all, u8(31))
}

// A terminal that never opted in must see ZERO bytes -- no keyboard push, no
// query, no bracketed-paste enable, no mouse tracking, no focus reporting, and
// above all nothing on the way out. All four opt-ins default to off
// (`kb: Kitty_Flags = {}`, `paste: bool = false`, `mouse: Mouse_Mode = .None`,
// `focus: bool = false`) precisely so that every call site that predates them
// (all 24 programs under examples/ and tools/, plus the golden harness) keeps
// behaving exactly as it did.
@(test)
test_no_opt_ins_write_nothing :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)
	g_term = {}
	defer g_term = {}

	testing.expect(t, term_enter_raw(pty.slave), "term_enter_raw on a pty slave should succeed")
	testing.expect(t, !g_term.kitty_active, "no flags requested: kitty_active must stay false")
	testing.expect(t, !g_term.paste_active, "no paste requested: paste_active must stay false")
	testing.expect(t, g_term.mouse_mode == .None, "no mouse requested: mouse_mode must stay .None")
	testing.expect(t, !g_term.focus_active, "no focus requested: focus_active must stay false")

	buf: [64]u8
	testing.expectf(t, drain_master(pty.master, buf[:], 0) == "",
		"term_enter_raw(fd) with no opt-in wrote %q -- it must write nothing at all",
		drain_master(pty.master, buf[:], 0))

	term_restore()
	testing.expectf(t, drain_master(pty.master, buf[:], 0) == "",
		"term_restore after an opt-out enter wrote something -- an unpaired pop eats another program's stack entry, an unpaired ?2004l turns paste reporting off for whoever DID enable it, and an unpaired ?1000l/?1004l does the same for mouse and focus")
}

// THE INVARIANT OF THIS TASK. Push once on the way in, pop EXACTLY once on the
// way out, no matter how many times the teardown is entered. Both the orderly
// path (term_restore) and the crash-signal path (term_restore_c, what
// guard.odin's crash_handler calls) are exercised here in sequence, which is
// the realistic double-teardown shape: a handler fires, and the `defer
// rt.term_restore()` the app already had runs too.
//
// A double pop is not a cosmetic bug -- `CSI < 1 u` pops one entry off a
// STACK, so the second one eats an entry belonging to whatever program is
// above us, silently leaving the shell (or a parent TUI) in a keyboard mode it
// never asked for and cannot know about.
@(test)
test_kitty_push_and_pop_exactly_once :: proc(t: ^testing.T) {
	Case :: struct { kb: Kitty_Flags, push: string }
	for c in ([?]Case{
		{{.Disambiguate}, "\e[>1u\e[?u"},
		{{.Disambiguate, .Report_Event_Types}, "\e[>3u\e[?u"},
		// Two digits: the hand-rolled formatter in kitty_push_seq has a
		// tens branch, and 31 is the only value that exercises it fully.
		{{.Disambiguate, .Report_Event_Types, .Alternate_Keys,
		  .All_Keys_As_Escapes, .Associated_Text}, "\e[>31u\e[?u"},
	}) {
		pty, ok := open_test_pty()
		if !testing.expect(t, ok, "could not open a pty") { return }
		defer close_test_pty(pty)
		g_term = {}
		defer g_term = {}

		testing.expect(t, term_enter_raw(pty.slave, c.kb), "term_enter_raw should succeed")
		testing.expect(t, g_term.kitty_active, "a successful push must leave kitty_active true")

		buf: [64]u8
		got := drain_master(pty.master, buf[:], len(c.push))
		testing.expectf(t, got == c.push, "%v: pushed %q, want %q", c.kb, got, c.push)

		// Three teardowns: the orderly one, a redundant repeat, and the
		// signal-handler entry point. Exactly one pop must come out.
		term_restore()
		testing.expect(t, !g_term.kitty_active, "restore must clear kitty_active")
		term_restore()
		term_restore_c()

		buf2: [64]u8
		got2 := drain_master(pty.master, buf2[:], len("\e[<1u"))
		testing.expectf(t, got2 == "\e[<1u",
			"%v: teardown wrote %q, want exactly one pop %q", c.kb, got2, "\e[<1u")
		// ...AND NOTHING MORE. See exactly_once_needs_a_second_drain below for
		// why this line exists even though the assertion above already catches
		// every stacked-pop bug reachable today.
		buf3: [64]u8
		testing.expectf(t, drain_master(pty.master, buf3[:], 0) == "",
			"%v: something arrived after the pop: %q", c.kb, drain_master(pty.master, buf3[:], 0))
	}
}

// The crash path, end to end and for real: a forked child enters raw mode with
// the protocol on and is then killed by a signal. guard.odin's crash_handler
// runs term_restore_c() from signal context and re-raises with the default
// disposition, so the child dies BY SIGNAL and its `defer`s never run -- the
// pop has to come from the handler or not at all.
//
// Forked rather than done in-process for the obvious reason: the process under
// test does not survive. The child touches nothing that allocates or locks
// between fork and death (term_enter_raw is tcgetattr/tcsetattr/write,
// install_crash_handlers is sigaltstack/sigaction), which is what makes
// forking a multi-threaded test runner safe here.
@(test)
test_kitty_pops_exactly_once_on_the_crash_path :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)

	pid := posix.fork()
	if !testing.expect(t, pid >= 0, "fork failed") { return }

	if pid == 0 {
		// CHILD. Deliberately no `defer term_restore()`: this mode proves the
		// SIGNAL path pops, not an orderly teardown.
		posix.close(pty.master)
		install_crash_handlers()
		if !term_enter_raw(pty.slave, {.Disambiguate}) { posix._exit(1) }
		posix.raise(posix.Signal.SIGTERM)
		posix._exit(1)   // NOT REACHED: crash_handler re-raises with SIG_DFL
	}

	status: c.int
	exited := false
	for _ in 0 ..< 200 {
		if posix.waitpid(pid, &status, {.NOHANG}) == pid { exited = true; break }
		time.sleep(5 * time.Millisecond)
	}
	if !exited {
		posix.kill(pid, posix.Signal.SIGKILL)
		testing.expect(t, false, "child did not die within 1s")
		return
	}
	testing.expect(t, posix.WIFSIGNALED(status),
		"the child must die BY SIGNAL -- if it exited normally, crash_handler never ran")

	buf: [64]u8
	want := "\e[>1u\e[?u\e[<1u"
	got := drain_master(pty.master, buf[:], len(want))
	testing.expectf(t, got == want,
		"crash path wrote %q, want push+query then exactly one pop %q", got, want)
}

// ---------------------------------------------------------------------------
// T1-L: bracketed paste's set/reset pairing. Same pty technique as the Kitty
// tests above, and deliberately the same SHAPE of test, because the invariant
// is the same one: never undo something this process did not do.
//
// What differs is the HAZARD, and it is worth being precise about rather than
// copying the Kitty reasoning across. `CSI ? 2004 h` / `l` are DECSET/DECRST
// -- a mode SET and RESET, not a stack PUSH and POP. Resetting twice is
// idempotent, and resetting a mode we never set cannot consume some other
// program's stack entry the way an unpaired `CSI < 1 u` can, because there is
// no stack and no depth to get wrong. The flag guard is still required -- an
// unpaired `?2004l` turns bracketed paste OFF for whatever program above us
// had it on, which is a real regression for that program -- but the blast
// radius is bounded and observable (that program stops seeing paste brackets)
// rather than unbounded and invisible (some unknown entry disappears from a
// stack nobody can inspect).
// ---------------------------------------------------------------------------

@(test)
test_paste_set_and_reset_exactly_once :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)
	g_term = {}
	defer g_term = {}

	testing.expect(t, term_enter_raw(pty.slave, {}, true), "term_enter_raw should succeed")
	testing.expect(t, g_term.paste_active, "a successful enable must leave paste_active true")
	testing.expect(t, !g_term.kitty_active, "paste alone must not touch the keyboard stack")

	buf: [64]u8
	got := drain_master(pty.master, buf[:], len("\e[?2004h"))
	testing.expectf(t, got == "\e[?2004h", "enabled %q, want %q", got, "\e[?2004h")

	// Three teardowns: the orderly one, a redundant repeat, and the
	// signal-handler entry point. Exactly one reset must come out. A second
	// reset would be harmless on the wire (RESET is idempotent) but it would
	// mean the flag guard is not working, and the guard is what stops us
	// resetting a mode we never set at all.
	term_restore()
	testing.expect(t, !g_term.paste_active, "restore must clear paste_active")
	term_restore()
	term_restore_c()

	buf2: [64]u8
	got2 := drain_master(pty.master, buf2[:], len("\e[?2004l"))
	testing.expectf(t, got2 == "\e[?2004l",
		"teardown wrote %q, want exactly one reset %q", got2, "\e[?2004l")
	// ...AND NOTHING MORE -- see exactly_once_needs_a_second_drain below.
	buf3: [64]u8
	testing.expectf(t, drain_master(pty.master, buf3[:], 0) == "",
		"something arrived after the reset: %q", drain_master(pty.master, buf3[:], 0))
}

// The two opt-ins are independent layers and must pair independently. This
// also pins the RESTORE ORDERING: termios, then the keyboard pop, then the
// paste reset -- worst-first, so a second fatal signal landing mid-teardown
// has already undone the most damaging state. See term_restore_c.
@(test)
test_kitty_and_paste_pair_independently :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)
	g_term = {}
	defer g_term = {}

	testing.expect(t, term_enter_raw(pty.slave, {.Disambiguate}, true), "term_enter_raw should succeed")
	testing.expect(t, g_term.kitty_active && g_term.paste_active, "both opt-ins must be armed")

	want_in := "\e[>1u\e[?u\e[?2004h"
	buf: [64]u8
	got := drain_master(pty.master, buf[:], len(want_in))
	testing.expectf(t, got == want_in, "enter wrote %q, want %q", got, want_in)

	term_restore()
	term_restore_c()

	want_out := "\e[<1u\e[?2004l"
	buf2: [64]u8
	got2 := drain_master(pty.master, buf2[:], len(want_out))
	testing.expectf(t, got2 == want_out, "teardown wrote %q, want %q", got2, want_out)
}

// ---------------------------------------------------------------------------
// T2-A: DECTCEM's hide/show pairing. Same pty technique and same test SHAPE as
// the two pairings above, because the invariant is the same one -- never leave
// the terminal in a state this process put it in.
//
// What differs, again stated rather than copied. `\e[?25l` / `\e[?25h` are
// DECSET/DECRST 25: a mode set and reset, not a stack push and pop, so an
// extra show is a genuine no-op and an UNPAIRED show can at worst reveal a
// cursor some other program hid -- visible instantly and trivially re-hidden.
// The hazard is entirely on the other side: a terminal left with an INVISIBLE
// cursor after a crash leaves the user typing at a shell with no caret, which
// is exactly the "actively wrong output" term_restore_c's own comment was
// written about. So `cursor_hidden` is biased towards writing, and is STICKY
// once armed, unlike kitty_active and paste_active -- see cursor_hide_arm.
//
// The other structural difference: the hide is not written by term.odin at
// all. render.odin buffers it into a frame, so these tests drive the REAL
// renderer and flush its REAL bytes at the pty, rather than asserting on a
// sequence this file emits.
// ---------------------------------------------------------------------------

@(test)
test_cursor_hide_and_show_exactly_once :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)
	g_term = {}
	defer g_term = {}

	testing.expect(t, term_enter_raw(pty.slave), "term_enter_raw should succeed")
	testing.expect(t, !g_term.cursor_hidden, "entering raw mode alone must not arm the cursor show")

	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)
	renderer_render(&r, "hi", Cursor{line = 0, col = 1, show = true})
	testing.expect(t, g_term.cursor_hidden,
		"a frame that hides the cursor must arm the paired show BEFORE its bytes are flushed")
	flush_frame(&b, pty.slave)

	frame := "\e[?25l" + "hi\r\n" + "\e[1A\e[2G" + "\e[?25h"
	buf: [64]u8
	got := drain_master(pty.master, buf[:], len(frame))
	testing.expectf(t, got == frame, "frame was %q, want %q", got, frame)

	// Three teardowns: the orderly one, a redundant repeat, and the
	// signal-handler entry point. Exactly ONE show must come out -- the frame
	// already ended with one, so this is the redundant-but-cheap insurance
	// described in cursor_hide_arm, and a SECOND one here would mean the flag
	// guard is not working at all.
	term_restore()
	testing.expect(t, !g_term.cursor_hidden, "restore must clear cursor_hidden")
	term_restore()
	term_restore_c()

	buf2: [64]u8
	got2 := drain_master(pty.master, buf2[:], len("\e[?25h"))
	testing.expectf(t, got2 == "\e[?25h",
		"teardown wrote %q, want exactly one show %q", got2, "\e[?25h")
	// ...AND NOTHING MORE -- see exactly_once_needs_a_second_drain below.
	buf3: [64]u8
	testing.expectf(t, drain_master(pty.master, buf3[:], 0) == "",
		"something arrived after the show: %q", drain_master(pty.master, buf3[:], 0))
}

// Why every exactly-once test above ends with a second, want == 0 drain.
//
// T2-B flagged drain_master as too weak for these assertions, on the grounds
// that it "stops the moment it has `want` bytes" and so would read exactly one
// reset out of three stacked ones. That reading is wrong, and it was worth
// checking rather than acting on: drain_master's read asks for `room` -- the
// WHOLE remaining buffer -- not `want`, so a single read drains everything the
// pty already holds, and `n >= want` then breaks with all of it in hand.
// Verified by injecting two separate bugs into term_restore_c: three pops in
// one call, and a never-cleared kitty_active so all three restore calls pop.
// The original one-drain assertion caught BOTH ("\e[<1u\e[<1u\e[<1u" and eight
// stacked pops respectively).
//
// The second drain is therefore hardening, not a bug fix, and is kept for one
// reason: it closes the one case the first drain genuinely cannot see -- bytes
// written strictly AFTER the read that satisfied `want`. Nothing in the
// teardown path writes asynchronously today, which is exactly why the first
// drain suffices today; this line is what keeps these tests honest if that ever
// changes. All six exactly-once tests now assert the invariant the same way,
// which matters more than the marginal coverage: an assertion that reads
// "exactly one" should not quietly mean "one, followed by anything".
@(private = "file")
exactly_once_needs_a_second_drain :: 0

// A program that never declares a cursor must never arm the show -- the opt-in
// property, checked at the terminal rather than at the renderer.
@(test)
test_a_frame_without_a_cursor_arms_nothing :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)
	g_term = {}
	defer g_term = {}

	testing.expect(t, term_enter_raw(pty.slave), "term_enter_raw should succeed")

	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)
	renderer_render(&r, "hi")
	renderer_render(&r, "ho")
	flush_frame(&b, pty.slave)

	frame := "hi\r\n" + "\e[1A\e[2K" + "ho\r\n"
	buf: [64]u8
	got := drain_master(pty.master, buf[:], len(frame))
	testing.expectf(t, got == frame, "frame was %q, want %q (no DECTCEM at all)", got, frame)
	testing.expect(t, !g_term.cursor_hidden, "a cursor-less frame must not arm the show")

	term_restore()
	buf2: [64]u8
	testing.expectf(t, drain_master(pty.master, buf2[:], 0) == "",
		"teardown after a cursor-less session wrote something -- an unpaired \\e[?25h reveals a cursor another program hid")
}

// THE CRASH PATH, and the case the sticky flag exists for. The child renders a
// real frame, then writes only its LEADING HIDE to the tty before dying by
// signal -- which is exactly what flush_frame's single, unlooped posix.write
// does under a short write: the hide lands, the trailing show does not. The
// child's `defer`s never run (it dies BY SIGNAL), so the show has to come from
// guard.odin's crash_handler calling term_restore_c, or the terminal is left
// with no cursor at all.
//
// This is the scenario that makes cursor_hidden sticky rather than per-frame.
// A flag cleared at the end of every frame would be false right here -- in the
// one situation where the terminal really is left hidden.
@(test)
test_cursor_shows_on_the_crash_path_after_a_truncated_frame :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)

	pid := posix.fork()
	if !testing.expect(t, pid >= 0, "fork failed") { return }

	if pid == 0 {
		// CHILD. No `defer term_restore()`: this proves the SIGNAL path shows.
		posix.close(pty.master)
		install_crash_handlers()
		if !term_enter_raw(pty.slave) { posix._exit(1) }

		// No `defer strings.builder_destroy`: this scope ends in a diverging
		// _exit (and, before that, in death by signal), so Odin rejects the
		// defer as unreachable -- correctly. Nothing here is freed, on purpose.
		b := strings.builder_make()
		r: Renderer
		renderer_init(&r, &b)
		renderer_render(&r, "hi", Cursor{line = 0, col = 0, show = true})
		// Emulate flush_frame's unlooped write delivering only the head of the
		// frame. Six bytes is exactly "\e[?25l".
		s := strings.to_string(b)
		posix.write(pty.slave, raw_data(s), 6)

		posix.raise(posix.Signal.SIGTERM)
		posix._exit(1)   // NOT REACHED: crash_handler re-raises with SIG_DFL
	}

	status: c.int
	exited := false
	for _ in 0 ..< 200 {
		if posix.waitpid(pid, &status, {.NOHANG}) == pid { exited = true; break }
		time.sleep(5 * time.Millisecond)
	}
	if !exited {
		posix.kill(pid, posix.Signal.SIGKILL)
		testing.expect(t, false, "child did not die within 1s")
		return
	}
	testing.expect(t, posix.WIFSIGNALED(status),
		"the child must die BY SIGNAL -- if it exited normally, crash_handler never ran")

	buf: [64]u8
	want := "\e[?25l\e[?25h"
	got := drain_master(pty.master, buf[:], len(want))
	testing.expectf(t, got == want,
		"crash path wrote %q, want a hide then exactly one show %q", got, want)
}

// The crash path, end to end and for real -- the exact shape of
// test_kitty_pops_exactly_once_on_the_crash_path, for the same reason: a
// process killed by a signal never runs its `defer`s, so the reset has to come
// out of guard.odin's crash_handler (which calls term_restore_c directly) or
// not at all. Leaving a terminal in bracketed-paste mode after a crash means
// every subsequent paste into the user's shell arrives wrapped in literal
// "[200~"/"[201~" garbage.
@(test)
test_paste_resets_on_the_crash_path :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)

	pid := posix.fork()
	if !testing.expect(t, pid >= 0, "fork failed") { return }

	if pid == 0 {
		// CHILD. No `defer term_restore()`: this proves the SIGNAL path resets.
		posix.close(pty.master)
		install_crash_handlers()
		if !term_enter_raw(pty.slave, {}, true) { posix._exit(1) }
		posix.raise(posix.Signal.SIGTERM)
		posix._exit(1)   // NOT REACHED: crash_handler re-raises with SIG_DFL
	}

	status: c.int
	exited := false
	for _ in 0 ..< 200 {
		if posix.waitpid(pid, &status, {.NOHANG}) == pid { exited = true; break }
		time.sleep(5 * time.Millisecond)
	}
	if !exited {
		posix.kill(pid, posix.Signal.SIGKILL)
		testing.expect(t, false, "child did not die within 1s")
		return
	}
	testing.expect(t, posix.WIFSIGNALED(status),
		"the child must die BY SIGNAL -- if it exited normally, crash_handler never ran")

	buf: [64]u8
	want := "\e[?2004h\e[?2004l"
	got := drain_master(pty.master, buf[:], len(want))
	testing.expectf(t, got == want,
		"crash path wrote %q, want enable then exactly one reset %q", got, want)
}

// ---------------------------------------------------------------------------
// T2-B: mouse tracking and focus reporting, both DECSET/DECRST pairs. Same pty
// technique and same test SHAPE as the three pairings above, because the
// invariant is the same one -- never leave the terminal in a state this process
// put it in.
//
// THE HAZARD, stated fresh rather than copied. `?1000h`/`?1002h`/`?1003h`,
// `?1006h` and `?1004h` are DECSET/DECRST: boolean modes, no stack, no depth.
// Resetting twice is idempotent, so the specific catastrophe POP-EXACTLY-ONCE
// exists to prevent -- eating an entry belonging to a program above us, from a
// stack nobody can inspect -- simply has no analogue here, exactly as it has
// none for bracketed paste. The guards (`mouse_mode`, `focus_active`) are still
// required for the general form of the rule: an unpaired `?1000l` turns mouse
// reporting off for whatever program above us had it on.
//
// What is NOT milder is the consequence of FORGETTING the reset, which is why
// mouse sits high in term_restore_c's worst-first ordering: a terminal left in
// mouse-reporting mode injects escape-sequence garbage into the user's shell on
// every click and every scroll flick. That is the same class of damage as a
// mis-reported keystroke, and it fires far more often.
// ---------------------------------------------------------------------------

@(test)
test_mouse_set_and_reset_exactly_once :: proc(t: ^testing.T) {
	Case :: struct { mode: Mouse_Mode, on, off: string }
	// Each ON string is the tracking mode followed by `?1006h` -- SGR extended
	// coordinates, which is NOT optional: the legacy encoding cannot express a
	// column past 223 (input.odin's x10_mouse). Each OFF string undoes exactly
	// those two modes and nothing else.
	for c in ([?]Case{
		{.Normal,       "\e[?1000h\e[?1006h", "\e[?1006l\e[?1000l"},
		{.Button_Event, "\e[?1002h\e[?1006h", "\e[?1006l\e[?1002l"},
		{.Any_Event,    "\e[?1003h\e[?1006h", "\e[?1006l\e[?1003l"},
	}) {
		pty, ok := open_test_pty()
		if !testing.expect(t, ok, "could not open a pty") { return }
		defer close_test_pty(pty)
		g_term = {}
		defer g_term = {}

		testing.expect(t, term_enter_raw(pty.slave, {}, false, c.mode), "term_enter_raw should succeed")
		testing.expectf(t, g_term.mouse_mode == c.mode,
			"%v: a successful enable must record the mode, got %v", c.mode, g_term.mouse_mode)
		testing.expect(t, !g_term.kitty_active, "mouse alone must not touch the keyboard stack")
		testing.expect(t, !g_term.paste_active, "mouse alone must not touch bracketed paste")
		testing.expect(t, !g_term.focus_active, "mouse alone must not touch focus reporting")

		buf: [64]u8
		got := drain_master(pty.master, buf[:], len(c.on))
		testing.expectf(t, got == c.on, "%v: enabled %q, want %q", c.mode, got, c.on)

		// Three teardowns: the orderly one, a redundant repeat, and the
		// signal-handler entry point. Exactly one reset must come out. A second
		// would be harmless on the wire (RESET is idempotent) but it would mean
		// the flag guard is not working, and the guard is what stops us
		// resetting a mode we never set at all.
		term_restore()
		testing.expectf(t, g_term.mouse_mode == .None, "%v: restore must clear mouse_mode", c.mode)
		term_restore()
		term_restore_c()

		buf2: [64]u8
		got2 := drain_master(pty.master, buf2[:], len(c.off))
		testing.expectf(t, got2 == c.off,
			"%v: teardown wrote %q, want exactly one reset %q", c.mode, got2, c.off)
		// AND NOTHING MORE. drain_master stops the moment it has `want` bytes,
		// so the assertion above alone would happily pass against three stacked
		// resets -- it would only ever look at the first one. This second drain
		// (want == 0, i.e. "prove a negative", which still waits) is what makes
		// "exactly once" mean exactly once rather than "at least once".
		buf3: [64]u8
		testing.expectf(t, drain_master(pty.master, buf3[:], 0) == "",
			"%v: teardown wrote MORE after the first reset -- the mouse_mode guard is not working", c.mode)
	}
}

// THE POINT OF STORING THE MODE rather than a bare bool: the reset must undo
// EXACTLY the tracking mode that was set. Resetting all three unconditionally
// (which is what ultraviolet's MouseModeNone does) would turn off modes this
// process never set -- the same rule the flag guard exists to enforce, broken a
// different way. Asserted here by proving that a `.Any_Event` session's
// teardown mentions 1003 and never mentions 1000 or 1002.
@(test)
test_mouse_reset_names_only_the_mode_that_was_set :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)
	g_term = {}
	defer g_term = {}

	testing.expect(t, term_enter_raw(pty.slave, {}, false, .Any_Event), "term_enter_raw should succeed")
	buf: [64]u8
	drain_master(pty.master, buf[:], len("\e[?1003h\e[?1006h"))

	term_restore()
	buf2: [64]u8
	got := drain_master(pty.master, buf2[:], len("\e[?1006l\e[?1003l"))
	testing.expectf(t, got == "\e[?1006l\e[?1003l",
		"teardown wrote %q, want only the 1003 reset -- 1000 and 1002 were never set", got)
	testing.expect(t, !strings.contains(got, "1000"), "teardown must not reset a mode we never set")
	testing.expect(t, !strings.contains(got, "1002"), "teardown must not reset a mode we never set")
}

@(test)
test_focus_set_and_reset_exactly_once :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)
	g_term = {}
	defer g_term = {}

	testing.expect(t, term_enter_raw(pty.slave, {}, false, .None, true), "term_enter_raw should succeed")
	testing.expect(t, g_term.focus_active, "a successful enable must leave focus_active true")
	testing.expect(t, g_term.mouse_mode == .None, "focus alone must not enable mouse tracking")

	buf: [64]u8
	got := drain_master(pty.master, buf[:], len("\e[?1004h"))
	testing.expectf(t, got == "\e[?1004h", "enabled %q, want %q", got, "\e[?1004h")

	term_restore()
	testing.expect(t, !g_term.focus_active, "restore must clear focus_active")
	term_restore()
	term_restore_c()

	buf2: [64]u8
	got2 := drain_master(pty.master, buf2[:], len("\e[?1004l"))
	testing.expectf(t, got2 == "\e[?1004l",
		"teardown wrote %q, want exactly one reset %q", got2, "\e[?1004l")
	// ...and nothing more; see the same assertion in
	// test_mouse_set_and_reset_exactly_once for why the first drain alone is
	// not enough to prove "exactly once".
	buf3: [64]u8
	testing.expectf(t, drain_master(pty.master, buf3[:], 0) == "",
		"teardown wrote MORE after the first reset -- the focus_active guard is not working")
}

// ALL FOUR OPT-INS AT ONCE. They are independent layers and must pair
// independently, and this also pins the RESTORE ORDERING that T2-B changed:
// termios, then the keyboard pop, then the MOUSE reset, then the FOCUS reset,
// then the cursor show, then the paste reset -- worst-first, so a second fatal
// signal landing mid-teardown has already undone the most damaging state. The
// cursor is absent from the expected bytes because nothing here renders a
// frame; the other four are all present, in order. See term_restore_c.
@(test)
test_all_four_opt_ins_pair_independently :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)
	g_term = {}
	defer g_term = {}

	testing.expect(t, term_enter_raw(pty.slave, {.Disambiguate}, true, .Button_Event, true),
		"term_enter_raw should succeed")
	testing.expect(t, g_term.kitty_active && g_term.paste_active &&
		g_term.mouse_mode == .Button_Event && g_term.focus_active, "all four opt-ins must be armed")

	// ENTER order: keyboard push+query, paste, mouse, focus -- the order
	// term_enter_raw writes them, which is deliberately the same order the
	// parameters appear in.
	want_in := "\e[>1u\e[?u" + "\e[?2004h" + "\e[?1002h\e[?1006h" + "\e[?1004h"
	buf: [128]u8
	got := drain_master(pty.master, buf[:], len(want_in))
	testing.expectf(t, got == want_in, "enter wrote %q, want %q", got, want_in)

	term_restore()
	term_restore_c()

	// TEARDOWN order: worst-first, and NOT the reverse of the enter order.
	want_out := "\e[<1u" + "\e[?1006l\e[?1002l" + "\e[?1004l" + "\e[?2004l"
	buf2: [128]u8
	got2 := drain_master(pty.master, buf2[:], len(want_out))
	testing.expectf(t, got2 == want_out, "teardown wrote %q, want %q", got2, want_out)
}

// The crash path, end to end and for real -- the exact shape of
// test_kitty_pops_exactly_once_on_the_crash_path and
// test_paste_resets_on_the_crash_path, for the same reason: a process killed by
// a signal never runs its `defer`s, so the reset has to come out of guard.odin's
// crash_handler (which calls term_restore_c directly) or not at all.
//
// This is the pairing where forgetting hurts most. A terminal left in
// mouse-reporting mode after a crash turns every subsequent click and every
// scroll flick in the user's shell into escape-sequence garbage typed at the
// command line, and a terminal left in focus-reporting mode does the same on
// every window switch.
@(test)
test_mouse_and_focus_reset_on_the_crash_path :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)

	pid := posix.fork()
	if !testing.expect(t, pid >= 0, "fork failed") { return }

	if pid == 0 {
		// CHILD. No `defer term_restore()`: this proves the SIGNAL path resets.
		posix.close(pty.master)
		install_crash_handlers()
		if !term_enter_raw(pty.slave, {}, false, .Any_Event, true) { posix._exit(1) }
		posix.raise(posix.Signal.SIGTERM)
		posix._exit(1)   // NOT REACHED: crash_handler re-raises with SIG_DFL
	}

	status: c.int
	exited := false
	for _ in 0 ..< 200 {
		if posix.waitpid(pid, &status, {.NOHANG}) == pid { exited = true; break }
		time.sleep(5 * time.Millisecond)
	}
	if !exited {
		posix.kill(pid, posix.Signal.SIGKILL)
		testing.expect(t, false, "child did not die within 1s")
		return
	}
	testing.expect(t, posix.WIFSIGNALED(status),
		"the child must die BY SIGNAL -- if it exited normally, crash_handler never ran")

	buf: [128]u8
	want := "\e[?1003h\e[?1006h" + "\e[?1004h" + "\e[?1006l\e[?1003l" + "\e[?1004l"
	got := drain_master(pty.master, buf[:], len(want))
	testing.expectf(t, got == want,
		"crash path wrote %q, want enable then exactly one reset of each %q", got, want)
}
