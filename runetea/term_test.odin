#+private
// ^ Every declaration in this file is package-private, so that `odin doc
//   runetea` / `odin doc runegloss` -- the command README.md and docs/API.md
//   hand a newcomer for symbol discovery -- lists the library rather than the
//   test fixtures. Pinned by tools/doccheck/run.sh's `apidoc` check, which is
//   also where the argument for it is written out.
package runetea

import "core:c"
import "core:c/libc"
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

// private="package", not private="file", for one reason: guard_test.odin's
// job-control and SIGPIPE tests need the same real pty and the same observer,
// and a second copy of this harness in that file would be a second thing to
// keep correct. Nothing outside the test build sees these.
@(private = "package")
Test_Pty :: struct {
	master, slave: posix.FD,
	// The process's real $TERM, saved by open_test_pty and put back by
	// close_test_pty. See open_test_pty's TERM note.
	term_env:      string,
	term_env_set:  bool,
}

// TERM IS PINNED FOR THE LIFE OF THE PTY, and that is not incidental
// housekeeping. term_acquire now gates every escape-sequence opt-in on
// term_supports_escapes(), which is false for TERM=dumb and for a TERM that is
// unset or empty -- so a suite run from a harness with no TERM in its
// environment (CI, cron, a bare `sh -c`) would otherwise see every opt-in test
// in this file assert on bytes the framework was right not to send. Pinning a
// capable value here makes the escape tests independent of who ran them, and
// leaves the incapable case to the two tests that set TERM deliberately.
//
// Safe because the suite runs single-threaded (-define:ODIN_TEST_THREADS=1,
// which tools/test.sh passes on every invocation): the pin is process-global
// state, and overlapping tests would be able to see each other's.
@(private = "package")
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
	pty.term_env, pty.term_env_set = save_term_env()
	set_term_env("xterm-256color")
	return pty, true
}

@(private = "package")
close_test_pty :: proc(pty: Test_Pty) {
	restore_term_env(pty.term_env, pty.term_env_set)
	posix.close(pty.slave)
	posix.close(pty.master)
}

// libc.getenv hands back a pointer INTO the environment block, which the very
// next setenv is free to move or free, so the value has to be copied before
// anything else touches TERM. Cloned into the test's allocator and freed by
// restore_term_env -- tools/test.sh fails the run on any unallowlisted leak.
@(private = "file")
save_term_env :: proc() -> (val: string, had: bool) {
	v := libc.getenv("TERM")
	if v == nil { return "", false }
	return strings.clone(string(v)), true
}

@(private = "file")
set_term_env :: proc(v: string) {
	cv := strings.clone_to_cstring(v)
	defer delete(cv)
	posix.setenv("TERM", cv, true)
}

@(private = "file")
restore_term_env :: proc(val: string, had: bool) {
	if !had {
		posix.unsetenv("TERM")
		return
	}
	set_term_env(val)
	delete(val)
}

// Collects what the slave side wrote. `want` bytes is what we are waiting FOR,
// and want == 0 means "prove nothing arrives" -- which still waits a little,
// so a merely-late write cannot masquerade as no write at all.
@(private = "package")
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
	testing.expect(t, !g_term.alt_active, "no alt screen requested: alt_active must stay false")

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

		testing.expect(t, term_enter_raw(pty.slave, {kb = c.kb}), "term_enter_raw should succeed")
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
		if !term_enter_raw(pty.slave, {kb = {.Disambiguate}}) { posix._exit(1) }
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

	testing.expect(t, term_enter_raw(pty.slave, {paste = true}), "term_enter_raw should succeed")
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

	testing.expect(t, term_enter_raw(pty.slave, {kb = {.Disambiguate}, paste = true}), "term_enter_raw should succeed")
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
		if !term_enter_raw(pty.slave, {paste = true}) { posix._exit(1) }
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

		testing.expect(t, term_enter_raw(pty.slave, {mouse = c.mode}), "term_enter_raw should succeed")
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

	testing.expect(t, term_enter_raw(pty.slave, {mouse = .Any_Event}), "term_enter_raw should succeed")
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

	testing.expect(t, term_enter_raw(pty.slave, {focus = true}), "term_enter_raw should succeed")
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

	testing.expect(t, term_enter_raw(pty.slave, {kb = {.Disambiguate}, paste = true, mouse = .Button_Event, focus = true}),
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
		if !term_enter_raw(pty.slave, {mouse = .Any_Event, focus = true}) { posix._exit(1) }
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

// ---------------------------------------------------------------------------
// T2-C: the ALTERNATE SCREEN BUFFER's enter/leave pairing. Same pty technique
// and same test SHAPE as the four pairings above, because the invariant is the
// same one -- never leave the terminal in a state this process put it in.
//
// THE HAZARD, stated fresh rather than copied, because this one is the worst of
// the five and the reason it sits so high in term_restore_c's worst-first
// ordering. `\e[?1049h` / `l` are DECSET/DECRST like paste, mouse and focus --
// a boolean mode, no stack, no depth -- so the specific catastrophe
// POP-EXACTLY-ONCE guards against has no analogue. But the CONSEQUENCE of
// missing the reset is not mild at all: a terminal left in the alternate screen
// shows the dead TUI's last frame under the user's shell prompt, gives them a
// buffer with no scrollback, and hides the entire session that preceded the
// program. Nothing echoes wrong and nothing is mistyped -- the user simply
// cannot see their own terminal any more, and the only way back is to blind-type
// `reset` (or `printf '\e[?1049l'`).
//
// AND THE OTHER DIRECTION MATTERS TOO, which is what term_restore_c's old
// comment was written about. An UNPAIRED `\e[?1049l` -- one written by a process
// that never entered the alt screen -- makes an xterm-family terminal restore a
// cursor position that was never saved, i.e. actively wrong output rather than a
// harmless no-op. That is precisely why `alt_active` exists: it is the record
// that THIS process wrote the `h` that performed the save, so the `l` is only
// ever written against a save it is genuinely paired with.
// ---------------------------------------------------------------------------

@(test)
test_alt_screen_enter_and_leave_exactly_once :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)
	g_term = {}
	defer g_term = {}

	testing.expect(t, term_enter_raw(pty.slave, {alt = true}),
		"term_enter_raw should succeed")
	testing.expect(t, g_term.alt_active, "a successful enter must leave alt_active true")
	testing.expect(t, !g_term.kitty_active, "alt screen alone must not touch the keyboard stack")
	testing.expect(t, !g_term.paste_active, "alt screen alone must not touch bracketed paste")
	testing.expect(t, g_term.mouse_mode == .None, "alt screen alone must not enable mouse tracking")
	testing.expect(t, !g_term.focus_active, "alt screen alone must not enable focus reporting")

	buf: [64]u8
	got := drain_master(pty.master, buf[:], len("\e[?1049h"))
	testing.expectf(t, got == "\e[?1049h", "entered %q, want %q", got, "\e[?1049h")

	// Three teardowns: the orderly one, a redundant repeat, and the
	// signal-handler entry point. Exactly one leave must come out. A second
	// would be harmless on the wire (RESET is idempotent) but it would mean the
	// flag guard is not working -- and the guard is what stops us writing a
	// `?1049l` against a save that was never made.
	term_restore()
	testing.expect(t, !g_term.alt_active, "restore must clear alt_active")
	term_restore()
	term_restore_c()

	buf2: [64]u8
	got2 := drain_master(pty.master, buf2[:], len("\e[?1049l"))
	testing.expectf(t, got2 == "\e[?1049l",
		"teardown wrote %q, want exactly one leave %q", got2, "\e[?1049l")
	// ...AND NOTHING MORE -- see exactly_once_needs_a_second_drain above.
	buf3: [64]u8
	testing.expectf(t, drain_master(pty.master, buf3[:], 0) == "",
		"something arrived after the leave: %q", drain_master(pty.master, buf3[:], 0))
}

// ALL FIVE OPT-INS AT ONCE, and the ordering T2-C changed. This is the sibling
// of test_all_four_opt_ins_pair_independently above, which is deliberately left
// untouched (alt defaults to off, so it still passes byte for byte) -- the
// point of a second test rather than an edit is that both orderings stay
// pinned: the one every pre-T2-C program produces, and the one a full-screen
// program produces.
//
// TEARDOWN ORDER: termios, keyboard pop, ALT SCREEN LEAVE, mouse reset, focus
// reset, cursor show, paste reset. Worst-first, so a second fatal signal
// landing mid-teardown has already undone the most damaging state. Alt sits
// third for two reasons, both stated in term_restore_c: a stranded alt screen
// costs the user their entire visible terminal (worse than mouse's per-click
// garbage, which they can at least see and delete), but it still does not
// corrupt what the shell RECEIVES, which is what the keyboard pop above it
// prevents. It is also above the cursor show deliberately, so that the show
// lands on the PRIMARY screen the user is actually looking at.
@(test)
test_all_five_opt_ins_pair_independently :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)
	g_term = {}
	defer g_term = {}

	testing.expect(t, term_enter_raw(pty.slave, {kb = {.Disambiguate}, paste = true, mouse = .Button_Event, focus = true, alt = true}),
		"term_enter_raw should succeed")
	testing.expect(t, g_term.kitty_active && g_term.paste_active &&
		g_term.mouse_mode == .Button_Event && g_term.focus_active && g_term.alt_active,
		"all five opt-ins must be armed")

	// ENTER order: keyboard push+query, paste, mouse, focus, alt -- the order
	// term_enter_raw writes them, which is deliberately the same order the
	// parameters appear in.
	want_in := "\e[>1u\e[?u" + "\e[?2004h" + "\e[?1002h\e[?1006h" + "\e[?1004h" + "\e[?1049h"
	buf: [128]u8
	got := drain_master(pty.master, buf[:], len(want_in))
	testing.expectf(t, got == want_in, "enter wrote %q, want %q", got, want_in)

	term_restore()
	term_restore_c()

	// TEARDOWN order: worst-first, and NOT the reverse of the enter order.
	want_out := "\e[<1u" + "\e[?1049l" + "\e[?1006l\e[?1002l" + "\e[?1004l" + "\e[?2004l"
	buf2: [128]u8
	got2 := drain_master(pty.master, buf2[:], len(want_out))
	testing.expectf(t, got2 == want_out, "teardown wrote %q, want %q", got2, want_out)
}

// THE CRASH PATH, end to end and for real -- the exact shape of the four
// crash-path tests above, for the same reason: a process killed by a signal
// never runs its `defer`s, so the leave has to come out of guard.odin's
// crash_handler (which calls term_restore_c directly) or not at all.
//
// This is the pairing where forgetting hurts most, and it is why this test
// exists even though the in-process one above already covers term_restore_c: a
// crashed full-screen program that never leaves the alt screen leaves the user
// staring at its corpse, with their shell's entire scrollback inaccessible
// until they blind-type `reset`.
@(test)
test_alt_screen_leaves_on_the_crash_path :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)

	pid := posix.fork()
	if !testing.expect(t, pid >= 0, "fork failed") { return }

	if pid == 0 {
		// CHILD. No `defer term_restore()`: this proves the SIGNAL path leaves.
		posix.close(pty.master)
		install_crash_handlers()
		if !term_enter_raw(pty.slave, {alt = true}) { posix._exit(1) }
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
	want := "\e[?1049h\e[?1049l"
	got := drain_master(pty.master, buf[:], len(want))
	testing.expectf(t, got == want,
		"crash path wrote %q, want enter then exactly one leave %q", got, want)
}

// The FULL-SCREEN renderer's real bytes, at a real pty, inside a real alt
// screen -- the T2-C analogue of test_cursor_hide_and_show_exactly_once above,
// and for the same reason: render.odin buffers the frame, term.odin writes the
// teardown, and only a test that drives both can prove they compose.
@(test)
test_full_screen_frame_and_alt_screen_compose :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)
	g_term = {}
	defer g_term = {}

	testing.expect(t, term_enter_raw(pty.slave, {alt = true}),
		"term_enter_raw should succeed")
	buf0: [64]u8
	drain_master(pty.master, buf0[:], len("\e[?1049h"))

	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 20, 5, .Full_Screen)
	renderer_render(&r, "hi", Cursor{line = 0, col = 1, show = true})
	testing.expect(t, g_term.cursor_hidden,
		"a frame that hides the cursor must arm the paired show BEFORE its bytes are flushed")
	flush_frame(&b, pty.slave)

	frame := "\e[?25l" + "\e[H" + "hi\e[K" + "\r\n\e[J" + "\e[1;2H" + "\e[?25h"
	buf: [64]u8
	got := drain_master(pty.master, buf[:], len(frame))
	testing.expectf(t, got == frame, "frame was %q, want %q", got, frame)

	term_restore()
	term_restore_c()

	// Worst-first: the alt-screen leave comes BEFORE the cursor show, so the
	// show lands on the primary screen the user is actually looking at.
	want_out := "\e[?1049l" + "\e[?25h"
	buf2: [64]u8
	got2 := drain_master(pty.master, buf2[:], len(want_out))
	testing.expectf(t, got2 == want_out, "teardown wrote %q, want %q", got2, want_out)
}

// ---------------------------------------------------------------------------
// ACQUIRING A TERMINAL TWICE.
//
// g_term is process-global and holds exactly one terminal's worth of state, so
// "who calls term_enter_raw" is not a question this package can answer for its
// callers: a library, a re-acquire helper, guard.odin's own SIGCONT resume, or
// simply a second call site can all reach it while a terminal is already ours.
// The old code answered by re-running the whole acquire unconditionally, and
// the two things that broke are pinned separately below because they break in
// opposite directions -- one saves the wrong thing, the other writes one thing
// too many.
// ---------------------------------------------------------------------------

// THE ONE THAT LEAVES THE USER'S SHELL RAW. tcgetattr into g_term.saved used to
// run on every entry, so a second one captured the RAW termios as the "cooked"
// settings and the following term_restore() reinstated raw mode -- on a clean,
// fully-paired, exit-0 run, with no diagnostic, recoverable only by blind-typing
// `reset`. The assertion is deliberately made against the TTY ITSELF rather than
// against g_term: what matters is the state the user is handed back, and the
// six flags below are exactly the ones term_acquire clears.
@(test)
test_a_second_enter_raw_does_not_save_raw_as_the_cooked_settings :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)
	g_term = {}
	defer g_term = {}

	cooked: posix.termios
	if !testing.expect(t, posix.tcgetattr(pty.slave, &cooked) == .OK,
		"tcgetattr on a fresh pty slave should succeed") { return }
	testing.expect(t, .ECHO in cooked.c_lflag,
		"a fresh pty slave should start cooked -- this test proves nothing otherwise")

	testing.expect(t, term_enter_raw(pty.slave), "the first enter should succeed")
	testing.expect(t, term_enter_raw(pty.slave),
		"a second enter on the SAME fd must report success -- every call site's failure branch is os.exit(1) placed BEFORE its defer term_restore(), so a false here strands the terminal it was protecting")

	term_restore()

	after: posix.termios
	if !testing.expect(t, posix.tcgetattr(pty.slave, &after) == .OK, "tcgetattr after restore") { return }
	testing.expect(t, .ECHO in after.c_lflag,   "restore after a double enter must give ECHO back")
	testing.expect(t, .ICANON in after.c_lflag, "restore after a double enter must give ICANON back")
	testing.expect(t, .ISIG in after.c_lflag,   "restore after a double enter must give ISIG back -- without it the user's shell has no Ctrl+C")
	testing.expect(t, .IEXTEN in after.c_lflag, "restore after a double enter must give IEXTEN back")
	testing.expect(t, .OPOST in after.c_oflag,  "restore after a double enter must give OPOST back -- without it every newline staircases")
	testing.expect(t, .ICRNL in after.c_iflag,  "restore after a double enter must give ICRNL back")
}

// THE ONE THAT LEAVES THE SHELL'S KEYS MIS-ENCODED. `CSI > <flags> u` PUSHES,
// and a second entry used to push again while the single `kitty_active` boolean
// still allowed only one `CSI < 1 u` on the way out -- an unpaired PUSH, leaving
// our Disambiguate entry on the terminal's keyboard stack for whatever runs
// next. Note that this is the mirror image of the hazard
// test_kitty_push_and_pop_exactly_once pins: that one guards against an extra
// POP eating an entry above us, and the boolean was always sufficient for it.
@(test)
test_a_second_enter_raw_does_not_push_the_kitty_stack_twice :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)
	g_term = {}
	defer g_term = {}

	testing.expect(t, term_enter_raw(pty.slave, {kb = {.Disambiguate}}), "the first enter should succeed")
	buf: [64]u8
	push := "\e[>1u\e[?u"
	got := drain_master(pty.master, buf[:], len(push))
	testing.expectf(t, got == push, "first enter pushed %q, want %q", got, push)

	testing.expect(t, term_enter_raw(pty.slave, {kb = {.Disambiguate}}), "the second enter should succeed")
	buf2: [64]u8
	got2 := drain_master(pty.master, buf2[:], 0)
	testing.expectf(t, got2 == "",
		"the second enter wrote %q -- a second push is an entry on the terminal's keyboard stack that nothing will ever pop", got2)

	term_restore()
	buf3: [64]u8
	got3 := drain_master(pty.master, buf3[:], len("\e[<1u"))
	testing.expectf(t, got3 == "\e[<1u", "teardown wrote %q, want exactly one pop", got3)
}

// A second entry may ADD an opt-in that is not on yet -- that is what makes the
// SIGCONT resume a single code path -- but it must not enable a mode of the same
// kind twice, and it must not silently switch a tracking mode whose reset is
// already committed to one specific `l` sequence.
@(test)
test_a_second_enter_raw_adds_new_opt_ins_but_never_repeats_one :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)
	g_term = {}
	defer g_term = {}

	testing.expect(t, term_enter_raw(pty.slave, {mouse = .Normal}), "the first enter should succeed")
	buf: [64]u8
	on := "\e[?1000h\e[?1006h"
	testing.expectf(t, drain_master(pty.master, buf[:], len(on)) == on, "first enter should enable .Normal tracking")

	// .Any_Event on top of .Normal: refused, because mouse_mode is both the
	// guard and the value the teardown needs, and two tracking modes with one
	// reset is exactly the "undo only what was set" rule broken.
	testing.expect(t, term_enter_raw(pty.slave, {mouse = .Any_Event, paste = true}), "the second enter should succeed")
	paste_on := "\e[?2004h"
	buf2: [64]u8
	got2 := drain_master(pty.master, buf2[:], len(paste_on))
	testing.expectf(t, got2 == paste_on,
		"the second enter wrote %q, want only the NEW opt-in %q -- the already-on tracking mode must not be re-enabled", got2, paste_on)
	testing.expect(t, g_term.mouse_mode == .Normal,
		"a second entry must not switch a tracking mode that is already on")

	term_restore()
	buf3: [64]u8
	want := "\e[?1006l\e[?1000l" + "\e[?2004l"
	got3 := drain_master(pty.master, buf3[:], len(want))
	testing.expectf(t, got3 == want, "teardown wrote %q, want %q", got3, want)
}

// The ONE case that is refused rather than absorbed. g_term describes exactly
// one terminal, so accepting a second fd would overwrite the first terminal's
// saved termios and every guard flag describing it -- stranding a tty nothing
// could ever restore. `false` is honest here in a way it would not be for a
// repeat of the SAME fd: that terminal really was not acquired.
@(test)
test_enter_raw_refuses_a_second_terminal :: proc(t: ^testing.T) {
	a, ok_a := open_test_pty()
	if !testing.expect(t, ok_a, "could not open the first pty") { return }
	defer close_test_pty(a)
	b, ok_b := open_test_pty()
	if !testing.expect(t, ok_b, "could not open the second pty") { return }
	defer close_test_pty(b)
	g_term = {}
	defer g_term = {}

	testing.expect(t, term_enter_raw(a.slave), "the first terminal should be acquired")
	testing.expect(t, !term_enter_raw(b.slave),
		"a second, DIFFERENT terminal must be refused -- g_term holds one terminal's state and overwriting it strands the first")
	testing.expect(t, g_term.fd == a.slave,
		"a refused acquire must leave the first terminal's state untouched")

	second: posix.termios
	if !testing.expect(t, posix.tcgetattr(b.slave, &second) == .OK, "tcgetattr on the refused pty") { return }
	testing.expect(t, .ICANON in second.c_lflag, "a refused acquire must not have touched the second terminal")

	term_restore()
	first: posix.termios
	if !testing.expect(t, posix.tcgetattr(a.slave, &first) == .OK, "tcgetattr on the first pty") { return }
	testing.expect(t, .ICANON in first.c_lflag, "the first terminal must still restore correctly")

	// ...and the refusal must be about OVERLAP, not about the fd ever having
	// been different. Releasing the first terminal and then acquiring a second
	// is a legitimate sequence -- tools/ttycheck does exactly this, twice in one
	// process -- and must still work.
	testing.expect(t, term_enter_raw(b.slave),
		"a second terminal must be acquirable once the first has been released")
	testing.expect(t, g_term.fd == b.slave, "the released-then-reacquired state must name the new terminal")
	term_restore()
}

// ---------------------------------------------------------------------------
// TERM=dumb AND NO TERM AT ALL.
//
// Before term_supports_escapes, TERM was read in exactly one place in the whole
// project -- runegloss's colour-profile detector -- so `TERM=dumb` degraded
// COLOUR correctly and then the framework pushed the Kitty keyboard stack,
// enabled bracketed paste, enabled mouse tracking and entered the alternate
// screen at a terminal whose entire declared meaning is "I have no
// capabilities". The real-world case is an Emacs comint/shell-mode pty, which
// answers a `\e[?1049h` by printing it.
// ---------------------------------------------------------------------------

@(test)
test_a_dumb_terminal_gets_no_escape_sequences :: proc(t: ^testing.T) {
	Case :: struct { name, term: string, unset: bool }
	for c in ([?]Case{
		{"TERM=dumb",  "dumb", false},
		{"TERM empty", "",     false},
		{"no TERM",    "",     true},
	}) {
		pty, ok := open_test_pty()
		if !testing.expect(t, ok, "could not open a pty") { return }
		defer close_test_pty(pty)
		g_term = {}
		defer g_term = {}

		// open_test_pty pinned a capable TERM; override it for this case only.
		// close_test_pty puts the process's real value back either way.
		if c.unset { posix.unsetenv("TERM") } else { set_term_env(c.term) }
		testing.expectf(t, !term_supports_escapes(), "%s must not count as escape-capable", c.name)

		// Every opt-in there is, all at once.
		testing.expectf(t, term_enter_raw(pty.slave,
			{kb = {.Disambiguate}, paste = true, mouse = .Any_Event, focus = true, alt = true}),
			"%s: raw mode itself must still be granted -- it is line discipline, not an escape sequence", c.name)

		buf: [64]u8
		got := drain_master(pty.master, buf[:], 0)
		testing.expectf(t, got == "",
			"%s: term_enter_raw wrote %q -- a terminal that declares no capabilities must see no escape sequences at all", c.name, got)

		// The flags must be false too, so the paired teardown stays silent:
		// same "undo only what was actually set" rule, one level up.
		testing.expectf(t, !g_term.kitty_active, "%s: nothing was pushed, so kitty_active must be false", c.name)
		testing.expectf(t, !g_term.paste_active, "%s: paste_active must be false", c.name)
		testing.expectf(t, g_term.mouse_mode == .None, "%s: mouse_mode must be .None", c.name)
		testing.expectf(t, !g_term.focus_active, "%s: focus_active must be false", c.name)
		testing.expectf(t, !g_term.alt_active, "%s: alt_active must be false", c.name)

		// And the tty really is raw: the whole point is that the app still runs.
		raw: posix.termios
		if !testing.expectf(t, posix.tcgetattr(pty.slave, &raw) == .OK, "%s: tcgetattr", c.name) { return }
		testing.expectf(t, .ECHO not_in raw.c_lflag, "%s: the tty must still be in raw mode", c.name)

		term_restore()
		buf2: [64]u8
		got2 := drain_master(pty.master, buf2[:], 0)
		testing.expectf(t, got2 == "",
			"%s: teardown wrote %q -- an unpaired reset is exactly what the flag guards exist to prevent", c.name, got2)
	}
}

@(test)
test_term_supports_escapes_accepts_an_ordinary_terminal :: proc(t: ^testing.T) {
	saved, had := save_term_env()
	defer restore_term_env(saved, had)

	for name in ([?]string{"xterm-256color", "screen", "vt100", "dumb-emacs-ansi"}) {
		set_term_env(name)
		testing.expectf(t, term_supports_escapes(),
			"TERM=%s must count as escape-capable -- the rule is the three no-capability values, not a terminfo lookup", name)
	}
}

// F50's regression, stated as an assertion rather than as a signature. Each
// Term_Opts field must drive ITS OWN mode and no other: the failure the struct
// replaced was `term_enter_raw(fd, {.Disambiguate}, true, .Normal, true)` --
// one argument short of what the author meant -- putting `?1004h` (focus
// reporting) on the wire where `?1049h` (alternate screen) was wanted, with a
// frame that looked identical and a return value of true.
@(test)
test_each_term_opts_field_drives_only_its_own_mode :: proc(t: ^testing.T) {
	Case :: struct { name: string, opts: Term_Opts, want: string }
	for c in ([?]Case{
		{"kb",    {kb = {.Disambiguate}}, "\e[>1u\e[?u"},
		{"paste", {paste = true},         "\e[?2004h"},
		{"mouse", {mouse = .Normal},      "\e[?1000h\e[?1006h"},
		{"focus", {focus = true},         "\e[?1004h"},
		{"alt",   {alt = true},           "\e[?1049h"},
		{"cursor_hide", {cursor_hide = true}, "\e[?25l"},
	}) {
		pty, ok := open_test_pty()
		if !testing.expect(t, ok, "could not open a pty") { return }
		defer close_test_pty(pty)
		g_term = {}
		defer g_term = {}

		testing.expectf(t, term_enter_raw(pty.slave, c.opts), "%s: term_enter_raw should succeed", c.name)
		buf: [64]u8
		got := drain_master(pty.master, buf[:], len(c.want))
		testing.expectf(t, got == c.want, "Term_Opts{{%s = ...}} wrote %q, want %q and nothing else", c.name, got, c.want)

		term_restore()
		buf2: [64]u8
		drain_master(pty.master, buf2[:], 1)
	}
}

// ---------------------------------------------------------------------------
// JOB CONTROL, end to end, in a forked child under a real pty.
//
// Forked for the same reason the crash-path tests are: the behaviour under test
// is what happens to a process that STOPS, and the test runner cannot stop
// itself and still observe. The child touches nothing that allocates or locks
// between fork and its first stop (install_crash_handlers is
// sigaltstack/sigaction, term_enter_raw is tcgetattr/tcsetattr/write), which is
// what makes forking a multi-threaded runner safe here.
//
// The pty is opened O_NOCTTY and the child never claims it, so it is nobody's
// CONTROLLING terminal -- which is why the child's writes from the handler
// cannot raise SIGTTOU no matter which process group the runner is in.
// ---------------------------------------------------------------------------

@(test)
test_a_job_control_stop_restores_the_tty_and_a_resume_re_acquires_it :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)

	pid := posix.fork()
	if !testing.expect(t, pid >= 0, "fork failed") { return }

	if pid == 0 {
		// CHILD. Deliberately no `defer term_restore()`: everything asserted
		// below has to come from the SIGTSTP/SIGCONT handlers or not at all.
		posix.close(pty.master)
		install_crash_handlers()
		if !term_enter_raw(pty.slave, {kb = {.Disambiguate}, paste = true, mouse = .Normal, alt = true}) {
			posix._exit(1)
		}
		for { posix.pause() }   // parent drives us with signals and kills us at the end
	}

	defer {
		posix.kill(pid, posix.Signal.SIGKILL)
		status: c.int
		posix.waitpid(pid, &status, {})
	}

	// The child's opt-ins, in the order term_acquire writes them.
	enables := "\e[>1u\e[?u" + "\e[?2004h" + "\e[?1000h\e[?1006h" + "\e[?1049h"
	buf: [128]u8
	got := drain_master(pty.master, buf[:], len(enables))
	if !testing.expectf(t, got == enables, "child's enables were %q, want %q", got, enables) { return }

	before: posix.termios
	if !testing.expect(t, posix.tcgetattr(pty.slave, &before) == .OK, "tcgetattr before the stop") { return }
	testing.expect(t, .ECHO not_in before.c_lflag, "the child should have the tty in raw mode before the stop")

	// --- STOP -------------------------------------------------------------
	posix.kill(pid, posix.Signal.SIGTSTP)

	status: c.int
	stopped := false
	for _ in 0 ..< 200 {
		if posix.waitpid(pid, &status, {.UNTRACED, .NOHANG}) == pid && posix.WIFSTOPPED(status) {
			stopped = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	if !testing.expect(t, stopped, "the child must actually STOP -- a handler that restores and returns swallows the stop, which is worse than not handling it") { return }
	testing.expect(t, posix.WSTOPSIG(status) == .SIGTSTP, "stopped by SIGTSTP")

	// term_restore_c's worst-first order: keyboard pop, alt leave, mouse reset,
	// paste reset. No focus (never enabled) and no cursor show (no frame ran).
	teardown := "\e[<1u" + "\e[?1049l" + "\e[?1006l\e[?1000l" + "\e[?2004l"
	buf2: [128]u8
	got2 := drain_master(pty.master, buf2[:], len(teardown))
	testing.expectf(t, got2 == teardown,
		"the stop wrote %q, want the full teardown %q -- a stop with the alternate screen still on puts the user's shell prompt and command output on top of a frozen frame", got2, teardown)

	during: posix.termios
	if !testing.expect(t, posix.tcgetattr(pty.slave, &during) == .OK, "tcgetattr while stopped") { return }
	testing.expect(t, .ECHO in during.c_lflag,
		"a stopped app must leave the tty ECHOing -- the shell the user drops back to is unusable otherwise")
	testing.expect(t, .ICANON in during.c_lflag, "a stopped app must leave ICANON on")
	testing.expect(t, .ISIG in during.c_lflag,   "a stopped app must leave ISIG on")

	// --- RESUME -----------------------------------------------------------
	posix.kill(pid, posix.Signal.SIGCONT)

	buf3: [128]u8
	got3 := drain_master(pty.master, buf3[:], len(enables))
	testing.expectf(t, got3 == enables,
		"the resume wrote %q, want the same opt-ins back %q", got3, enables)

	after_raw := false
	for _ in 0 ..< 200 {
		after: posix.termios
		if posix.tcgetattr(pty.slave, &after) == .OK && .ECHO not_in after.c_lflag {
			after_raw = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, after_raw,
		"a resumed app must put the tty BACK into raw mode -- otherwise the line discipline echoes every keystroke into the middle of the dead frame and the app is deaf until a newline")
}

// ---------------------------------------------------------------------------
// DECLARING "HIDE THE CARET FOR THIS PROGRAM" (F24's residual).
//
// The renderer's own hide covers .Full_Screen and .Diff, which own the
// viewport. It covers nothing else, and there was NO supported way for an
// application to ask: Cursor{show = false} is the zero value and reads as "no
// opinion", and cursor_hide_arm is package-private. So an app that wanted no
// caret wrote "\e[?25l" itself and got no paired show from term_restore, from
// the crash handlers, or from the SIGTSTP stop -- measured on a pty as a clean
// exit 0 with hides=1, shows=0, i.e. the USER'S SHELL left with an invisible
// caret and no way back but `reset` or `tput cnorm`. Terminal state surviving
// process exit is the worst class of defect this package has, and this one was
// reachable from a correct-looking three-line program.
//
// Term_Opts.cursor_hide is the declaration, and the three tests below pin the
// three exits it has to survive: the orderly one, the signal one, and the stop.
// ---------------------------------------------------------------------------

@(test)
test_a_declared_cursor_hide_writes_the_hide_and_term_restore_writes_the_show :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)

	if !testing.expect(t, term_enter_raw(pty.slave, {cursor_hide = true}), "term_enter_raw failed") { return }

	buf: [32]u8
	got := drain_master(pty.master, buf[:], len("\e[?25l"))
	testing.expectf(t, got == "\e[?25l",
		"acquire wrote %q, want exactly the hide %q -- the declaration is the whole point", got, "\e[?25l")
	testing.expect(t, g_term.cursor_hidden,
		"the acquire must arm the paired show; without the flag term_restore_c stays silent and the caret never comes back")

	term_restore()

	buf2: [32]u8
	got2 := drain_master(pty.master, buf2[:], len("\e[?25h"))
	testing.expectf(t, got2 == "\e[?25h",
		"teardown wrote %q, want exactly one show %q", got2, "\e[?25h")
	testing.expect(t, !g_term.cursor_hidden, "restore must clear cursor_hidden")
}

// ORDERING, both ways round, and it is not cosmetic. Some terminals track
// DECTCEM per screen buffer, so the hide has to land AFTER "?1049h" (inside the
// buffer the app paints) and the show has to land AFTER "?1049l" (on the normal
// buffer the user's shell is about to use). term_acquire writes the hide last
// and term_restore_c's worst-first order already put the show after the alt
// leave; this pins the pair against a reordering of either list.
@(test)
test_a_declared_cursor_hide_is_written_inside_the_alt_screen_and_shown_outside_it :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)

	if !testing.expect(t, term_enter_raw(pty.slave, {alt = true, cursor_hide = true}), "term_enter_raw failed") { return }

	want := "\e[?1049h" + "\e[?25l"
	buf: [64]u8
	got := drain_master(pty.master, buf[:], len(want))
	testing.expectf(t, got == want,
		"acquire wrote %q, want %q -- the hide belongs to the buffer the app is about to paint", got, want)

	term_restore()

	want2 := "\e[?1049l" + "\e[?25h"
	buf2: [64]u8
	got2 := drain_master(pty.master, buf2[:], len(want2))
	testing.expectf(t, got2 == want2,
		"teardown wrote %q, want %q -- the show belongs to the buffer the user is returning to", got2, want2)
}

// THE CRASH PATH. Same shape and same reason as
// test_cursor_shows_on_the_crash_path_after_a_truncated_frame, one layer down:
// there the hide came from a frame, here it comes from the acquire itself, and
// the child runs no renderer at all. A process killed by a signal runs no
// `defer`s, so the show has to come out of guard.odin's crash_handler calling
// term_restore_c or the user's shell keeps the invisible caret.
@(test)
test_a_declared_cursor_hide_is_shown_again_when_the_process_dies_by_signal :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)

	pid := posix.fork()
	if !testing.expect(t, pid >= 0, "fork failed") { return }

	if pid == 0 {
		// CHILD. No `defer term_restore()`: this proves the SIGNAL path shows.
		posix.close(pty.master)
		install_crash_handlers()
		if !term_enter_raw(pty.slave, {cursor_hide = true}) { posix._exit(1) }
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

	want := "\e[?25l\e[?25h"
	buf: [64]u8
	got := drain_master(pty.master, buf[:], len(want))
	testing.expectf(t, got == want,
		"crash path wrote %q, want the declared hide and exactly one show %q", got, want)
}

// THE STOP. This is the reason the declaration lives in Term_Opts rather than
// in an exported cursor_hide_arm: g_term.opts is a RECORD that deliberately
// survives term_restore_c, and guard.odin's SIGTSTP handler feeds it straight
// back into term_acquire on the far side of the stop. The two calls below are
// what that handler does, verbatim and in order. An application that wrote
// "\e[?25l" itself has nothing to replay here, so `fg` would bring the caret
// back for the rest of the session.
@(test)
test_a_declared_cursor_hide_comes_back_on_the_resume_path :: proc(t: ^testing.T) {
	pty, ok := open_test_pty()
	if !testing.expect(t, ok, "could not open a pty") { return }
	defer close_test_pty(pty)

	if !testing.expect(t, term_enter_raw(pty.slave, {cursor_hide = true}), "term_enter_raw failed") { return }
	buf: [32]u8
	drain_master(pty.master, buf[:], len("\e[?25l"))

	// What tstp_handler captures before it tears down...
	fd      := g_term.fd
	opts    := g_term.opts
	escapes := g_term.escapes_ok
	term_restore_c()
	buf2: [32]u8
	drain_master(pty.master, buf2[:], len("\e[?25h"))

	// ...and what it replays on the far side of the raise.
	testing.expect(t, term_acquire(fd, opts, escapes), "the resume must re-acquire the terminal")
	defer term_restore()

	buf3: [32]u8
	got := drain_master(pty.master, buf3[:], len("\e[?25l"))
	testing.expectf(t, got == "\e[?25l",
		"the resume wrote %q, want the declared hide back %q -- an opt-in this file does not RECORD cannot be replayed", got, "\e[?25l")
}
