package runetea

import "core:sys/linux"
import "core:sys/posix"

Winsize :: struct {
	ws_row, ws_col, ws_xpixel, ws_ypixel: u16,
}

// The Kitty keyboard protocol's progressive-enhancement flags, one bit each.
// The comment on each member is its PROTOCOL VALUE, and the enum's numeric
// order is what makes `transmute(u8)Kitty_Flags{...}` equal that value --
// member n is bit n is 1<<n, exactly the protocol's own numbering (see
// x/ansi's KittyDisambiguateEscapeCodes .. KittyReportAssociatedKeys). That
// identity is load-bearing in both directions (kitty_push_seq encodes with
// it, input.odin's kitty_flags_reply decodes with it), so members must never
// be reordered or inserted mid-block; test_kitty_flag_values_match_the
// _protocol pins it.
Kitty_Flag :: enum u8 {
	Disambiguate,        // 1  -- the whole point: resolves the C0 collisions
	Report_Event_Types,  // 2  -- press/repeat/release
	Alternate_Keys,      // 4
	All_Keys_As_Escapes, // 8
	Associated_Text,     // 16
}
Kitty_Flags :: bit_set[Kitty_Flag; u8]

Term_State :: struct {
	fd:           posix.FD,
	saved:        posix.termios,
	raw_active:   bool,
	// True for exactly the interval in which ONE entry of ours could be on
	// the terminal's keyboard stack. See term_enter_raw's second ordering
	// invariant and term_restore_c's POP-EXACTLY-ONCE comment -- this flag is
	// the whole mechanism that stops the normal teardown and the crash-signal
	// teardown from both popping.
	kitty_active: bool,
	// T1-L. Same guarded-flag shape as kitty_active, and required for the same
	// reason -- never undo something this process did not do -- but the hazard
	// it guards is genuinely milder; see term_restore_c's "SET/RESET, NOT
	// PUSH/POP" note for why, and for why the guard stays anyway.
	paste_active: bool,
	// T2-A. True from the first moment the renderer could have written a
	// "\e[?25l" to this terminal. Set by cursor_hide_arm below (never
	// cleared except by term_restore_c), so the paired "\e[?25h" is written
	// on every teardown path -- see term_restore_c's DECTCEM note for why
	// this one is deliberately STICKY where kitty_active is not.
	cursor_hidden: bool,
	// T2-B. The guarded flag AND the value the teardown needs: .None means "we
	// never enabled mouse reporting", anything else names the tracking mode
	// that is on, and therefore which `l` sequence undoes it. One field rather
	// than a bool plus a mode because the two can never legitimately disagree,
	// and a pair that can drift is a pair that eventually will.
	mouse_mode:    Mouse_Mode,
	// T2-B. Same guarded-flag shape as paste_active, same DECSET/DECRST hazard
	// class -- see term_restore_c.
	focus_active:  bool,
	// T2-C. The alternate screen buffer. Same guarded-flag SHAPE as the three
	// above and the same DECSET/DECRST hazard class -- but the consequence of a
	// MISSED reset is the most severe of the five, which is why it sits third in
	// term_restore_c's worst-first ordering rather than down with paste. See
	// term_restore_c's ALTERNATE SCREEN note for both directions of the hazard:
	// what a missed `l` costs the user, and what an unpaired `l` (one written by
	// a process that never wrote the `h`) does to a terminal.
	alt_active:    bool,
}

// Which mouse events the terminal should report. SELECTABLE rather than
// hardcoded because the three modes have genuinely different costs: .Any_Event
// makes the terminal send a report for EVERY cell the pointer crosses, which is
// a flood of wakeups an app that only wants clicks has no use for.
//
// .None is the ZERO VALUE and means "do not touch the terminal's mouse state at
// all" -- nothing is written, and the paired teardown stays silent -- exactly
// like `kb == {}` for Kitty and `paste == false` for bracketed paste.
//
// DECSET 9 (X10 press-only) has deliberately no member here; see decode_keys'
// documented-limitations list for why.
Mouse_Mode :: enum u8 {
	None,          // do not enable mouse reporting
	Normal,        // DECSET 1000 -- press and release only
	Button_Event,  // DECSET 1002 -- the above, plus motion while a button is held (drag)
	Any_Event,     // DECSET 1003 -- all motion, even with no button down
}

// Process-global: signal handlers take no arguments and must reach this.
g_term: Term_State

// CSI < 1 u -- pop ONE entry from the terminal's keyboard stack.
//
// A static string, not a formatted one, because term_restore_c writes it from
// a signal handler: write(2) is async-signal-safe, fmt and the allocator are
// not. The explicit "1" is redundant (the protocol's default count is 1) and
// kept anyway: this is the sequence whose count MUST be exactly one, and a
// reader should not have to know the default to see that. Typed `string`
// rather than an untyped literal so raw_data() can take its (static,
// read-only) data pointer.
@(private="file")
KITTY_POP: string : "\e[<1u"

// DECSET/DECRST 2004 -- bracketed paste on/off. Static strings for the same
// reason KITTY_POP is one: PASTE_OFF is written from a signal handler, where
// write(2) is safe and fmt/the allocator are not. PASTE_ON is static too so the
// pair reads as a pair.
@(private="file")
PASTE_ON:  string : "\e[?2004h"
@(private="file")
PASTE_OFF: string : "\e[?2004l"

// T2-B. Six static strings, three pairs, for exactly the reason KITTY_POP and
// PASTE_OFF are static: the OFF half is written from a signal handler, where
// write(2) is safe and fmt/the allocator are not. Building "\e[?100%dl" at
// teardown would need a buffer and a formatter; a switch over three constants
// needs neither.
//
// EACH ON STRING CARRIES TWO SEQUENCES, and their order is the pairing:
// tracking mode first, then `?1006h` for SGR EXTENDED COORDINATES. The SGR
// request is not optional -- the legacy encoding packs a coordinate into one
// byte as coordinate+32, so it cannot express a column past 223 and simply
// wraps (see input.odin's x10_mouse). Every OFF string undoes EXACTLY the two
// modes its partner set, in reverse order, so nothing else on the terminal's
// mode table is touched. (ultraviolet's MouseModeNone resets all four tracking
// modes and all three encodings unconditionally; that would turn off modes this
// process never set, which is the one thing this file's whole pairing
// discipline exists to prevent.)
@(private="file")
MOUSE_ON_NORMAL:  string : "\e[?1000h\e[?1006h"
@(private="file")
MOUSE_ON_BUTTON:  string : "\e[?1002h\e[?1006h"
@(private="file")
MOUSE_ON_ANY:     string : "\e[?1003h\e[?1006h"
@(private="file")
MOUSE_OFF_NORMAL: string : "\e[?1006l\e[?1000l"
@(private="file")
MOUSE_OFF_BUTTON: string : "\e[?1006l\e[?1002l"
@(private="file")
MOUSE_OFF_ANY:    string : "\e[?1006l\e[?1003l"

// DECSET/DECRST 1004 -- focus in/out reporting. Static for the same reason.
@(private="file")
FOCUS_ON:  string : "\e[?1004h"
@(private="file")
FOCUS_OFF: string : "\e[?1004l"

// DECSET/DECRST 1049 -- the ALTERNATE SCREEN BUFFER (T2-C). Static for the same
// reason every OFF string above is: ALT_OFF is written from a signal handler,
// where write(2) is safe and fmt/the allocator are not.
//
// 1049 AND NOT 47 OR 1047: `?1049h` saves the cursor, switches to the alternate
// buffer AND clears it, in one atomic mode set, and `?1049l` clears the alt
// buffer, switches back and restores the saved cursor. The older 47/1047 do not
// save the cursor at all (the caller has to bracket them with DECSC/DECRC), and
// 1047 famously does not clear on entry -- meaning the previous alt-screen
// tenant's contents would show through the first frame. 1049 is what every
// terminal emulator written this century implements and what every TUI uses.
//
// NOTE WHAT THIS PAIR IS AND IS NOT. It is DECSET/DECRST -- a boolean mode, no
// stack, no depth, exactly like paste/mouse/focus and not at all like Kitty's
// push/pop. But `?1049h` has a SIDE EFFECT the other three do not: it saves a
// cursor position that `?1049l` later restores. That is what makes an UNPAIRED
// `?1049l` actively wrong rather than a no-op, and it is the whole reason
// alt_active exists -- see term_restore_c.
@(private="file")
ALT_ON:  string : "\e[?1049h"
@(private="file")
ALT_OFF: string : "\e[?1049l"

// Builds "CSI > <flags> u" (push) followed by "CSI ? u" (query) into `buf`,
// returning the filled prefix. Hand-formatted rather than fmt.bprintf'd: this
// runs while the tty is already raw and half-configured, and the whole
// keyboard path is meant to stay allocation-free so it reads the same on both
// sides (the pop, which is signal-context, cannot allocate at all).
//
// The push is FIRE-AND-FORGET by design: a terminal with no Kitty support
// ignores an unknown CSI, keys keep arriving in the legacy encoding, and
// input.odin decodes those exactly as before. The query is how the
// application finds out which of the two it got -- the reply (CSI ? <flags> u)
// comes back through the ordinary input path as a Keyboard_Enhancements_Msg.
@(private="file")
kitty_push_seq :: proc(kb: Kitty_Flags, buf: []u8) -> []u8 {
	v := transmute(u8)kb                  // == the protocol's flag word, see Kitty_Flag
	n := copy(buf, "\e[>")
	if v >= 10 { buf[n] = '0' + v / 10; n += 1 }
	buf[n] = '0' + v % 10; n += 1
	buf[n] = 'u'; n += 1
	n += copy(buf[n:], "\e[?u")           // RequestKittyKeyboard
	return buf[:n]
}

// `kb` defaults to {}, which means DO NOT TOUCH the terminal's keyboard mode:
// nothing is written, nothing is pushed, and the paired teardown in
// term_restore_c stays a no-op. `paste` defaults to false and means the same
// thing for bracketed paste; `mouse` defaults to .None and `focus` to false
// (T2-B) and `alt` to false (T2-C) and mean the same thing again. Opting in is
// the application's call, not the framework's -- unlike Bubble Tea, run() does
// not own the terminal here (the app calls term_enter_raw itself, and the golden
// tests drive run() with a plain pipe), so the layer that entered raw mode is the
// layer that gets to decide, and a terminal that never opted in must see zero
// sequences of any kind. All five are trailing defaulted parameters so that every
// call site written before they existed keeps compiling and keeps behaving
// identically.
//
// `alt` is the terminal half of render.odin's Render_Mode.Full_Screen, and the
// two are deliberately INDEPENDENT: entering the alt screen without a
// full-screen renderer is legal (an inline renderer would simply rewind inside
// the alt buffer), and a full-screen renderer without the alt screen is legal
// too (it repaints over the shell's output and clears below itself). Coupling
// them would mean this file knowing about the renderer, and would take the
// choice away from an application that has a reason to want one and not the
// other. Nothing in this package writes `?1049h` anywhere else, so this
// parameter is the ONE place the alt screen can be entered from.
term_enter_raw :: proc(
	fd:     posix.FD,
	kb:     Kitty_Flags = {},
	paste:  bool        = false,
	mouse:  Mouse_Mode  = .None,
	focus:  bool        = false,
	alt:    bool        = false,
) -> bool {
	if posix.tcgetattr(fd, &g_term.saved) != .OK { return false }

	// ORDERING INVARIANT: raw_active must be true for the entire interval in
	// which the tty could possibly be in raw mode, and g_term.saved must be
	// valid before raw_active is ever true. g_term.saved holds valid
	// cooked-mode settings as of the line above, so it is safe to flip
	// raw_active on now, before tcsetattr below has actually touched the
	// terminal. A crash signal landing anywhere from here through the
	// tcsetattr call sees raw_active == true and calls term_restore_c(),
	// which re-applies g_term.saved -- correct and harmless whether the tty
	// is still cooked or has just become raw. Setting raw_active only after
	// tcsetattr succeeds would leave a window where the tty is already raw
	// but term_restore_c() no-ops, stranding the terminal with no recovery.
	g_term.fd = fd
	g_term.raw_active = true

	raw := g_term.saved

	raw.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
	raw.c_oflag -= {.OPOST}
	raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}

	// Do NOT write CControl_Flags{.CS8}: the enum member is log2(CS8) and CS8
	// (0x30) is multi-bit, so it truncates to bit 5 == CS7 (0x20), silently
	// running the tty at 7-bit character size.
	raw.c_cflag -= transmute(posix.CControl_Flags)posix.tcflag_t(posix.CSIZE)
	raw.c_cflag += transmute(posix.CControl_Flags)posix.tcflag_t(posix.CS8)

	raw.c_cc[.VMIN]  = 1
	raw.c_cc[.VTIME] = 0

	if posix.tcsetattr(fd, .TCSAFLUSH, &raw) != .OK {
		// Roll back: the tty was never actually put into raw mode.
		g_term.raw_active = false
		return false
	}

	// Every opt-in is written from here down, and ALL OF THEM ONLY AFTER
	// tcsetattr SUCCEEDED. The Kitty block has its own (different, stronger)
	// reason, below; the reason common to all of them is the rollback path --
	// tcsetattr failing returns false, and every call site's failure branch is
	// `eprintln("not a tty"); os.exit(1)` placed BEFORE its `defer
	// term_restore()`, so anything already written to the terminal at that
	// point would never be undone. Writing after the last thing that can fail
	// means there is nothing stranded when it does.
	if kb != {}        { kitty_enable(fd, kb) }
	if paste           { paste_enable(fd) }
	if mouse != .None  { mouse_enable(fd, mouse) }
	if focus           { focus_enable(fd) }
	if alt             { alt_enable(fd) }
	return true
}

@(private="file")
kitty_enable :: proc(fd: posix.FD, kb: Kitty_Flags) {
	// THE KEYBOARD PUSH MUST COME AFTER tcsetattr, not before. TCSAFLUSH
	// DISCARDS pending input, and the query below asks the terminal to send
	// some: push+query written first would race the mode change, and a reply
	// that arrived in the meantime would be thrown away by the very flush that
	// puts us in raw mode. Nothing would break -- the reply is informational --
	// but the app would silently never learn what it got, on exactly the fast
	// terminals that answer quickest.
	//
	// SECOND ORDERING INVARIANT, the mirror of raw_active's above:
	// kitty_active must be true for the entire interval in which an entry of
	// ours could be on the terminal's keyboard stack, so it goes true BEFORE
	// the write, not after. A crash signal landing between the two calls sees
	// kitty_active == true and pops -- possibly popping an entry that was
	// never pushed. That is the right way round to be wrong here, for two
	// reasons. Popping an entry we did not push is only harmful if some OTHER
	// program's entry is underneath, and at this instant we know the process
	// above us is a shell that has not pushed anything (shells do not use this
	// protocol; a parent TUI would have popped before spawning us) -- and the
	// protocol makes popping an empty stack a no-op. Setting the flag after
	// the write instead would leave the opposite window, in which the push
	// HAS landed but restore no-ops: the terminal is stranded in a keyboard
	// mode nothing will ever undo, which is permanent, user-visible, and
	// exactly the failure this pairing exists to prevent.
	g_term.kitty_active = true

	buf: [16]u8   // max "\e[>31u\e[?u" == 11 bytes
	seq := kitty_push_seq(kb, buf[:])
	if posix.write(fd, raw_data(seq), len(seq)) <= 0 {
		// Roll back: NOTHING went out (EIO once the far end of the pty is gone
		// is the realistic case), so there is nothing for restore to pop.
		//
		// A SHORT write deliberately does NOT roll back. The push is the first
		// six bytes of `seq` and the query the rest, so a write that moved
		// anything at all most likely moved the push -- and the asymmetry from
		// the ordering invariant above applies unchanged: a pop against a stack
		// we never pushed to is a no-op, while a push that restore skips is
		// permanent. Assume pushed whenever it is not certain we did not.
		//
		// Either way this still returns TRUE, because raw mode itself
		// SUCCEEDED. Returning false here would be the worse bug by far: every
		// call site's failure branch is `eprintln("not a tty"); os.exit(1)`,
		// placed BEFORE the `defer term_restore()`, so it would exit leaving
		// the tty raw. The keyboard push is an enhancement; raw mode is the
		// contract, and the terminal's reply (or its absence) is how an
		// application learns which it got.
		g_term.kitty_active = false
	}
}

// `CSI ? 2004 h`. Ordering invariant identical in SHAPE to kitty_enable's --
// the flag goes true BEFORE the write, so a crash signal landing between the
// two resets a mode we may not have set rather than stranding one we did --
// but the two sides of that trade are much less lopsided here, because RESET
// is idempotent and stack-free. See term_restore_c for the full comparison.
//
// Unlike the Kitty block there is no reply to wait for, so TCSAFLUSH's
// input-discarding has nothing to race; the reason this still runs after
// tcsetattr is the rollback one stated at the call site.
@(private="file")
paste_enable :: proc(fd: posix.FD) {
	g_term.paste_active = true
	if posix.write(fd, raw_data(PASTE_ON), len(PASTE_ON)) <= 0 {
		// Nothing went out at all (EIO once the far end is gone), so there is
		// nothing for restore to turn off. A short write is not a case worth
		// splitting here the way it is for the Kitty push: this is one eight-byte
		// sequence rather than two independent ones, so a partial write leaves
		// the terminal mid-sequence either way, and "assume set whenever it is
		// not certain we did not" is the safe direction.
		g_term.paste_active = false
	}
}

// `CSI ? <tracking> h` + `CSI ? 1006 h`. Ordering invariant identical in SHAPE
// to kitty_enable's and paste_enable's -- the flag (here `mouse_mode`, which is
// both the flag and the value the teardown needs) is set BEFORE the write, so a
// crash signal landing between the two RESETS a mode we may not have set rather
// than STRANDING one we did.
//
// The two sides of that trade are as mild here as they are for paste, and for
// the same structural reason: these are DECSET/DECRST, not a stack push/pop.
// Resetting twice is idempotent and there is no depth to get wrong. See
// term_restore_c for the full comparison and for why mouse still sits high in
// the restore ordering despite the low pairing hazard.
@(private="file")
mouse_enable :: proc(fd: posix.FD, mode: Mouse_Mode) {
	seq: string
	switch mode {
	case .Normal:       seq = MOUSE_ON_NORMAL
	case .Button_Event: seq = MOUSE_ON_BUTTON
	case .Any_Event:    seq = MOUSE_ON_ANY
	case .None:         return   // unreachable: the caller gates on mode != .None
	}
	g_term.mouse_mode = mode
	if posix.write(fd, raw_data(seq), len(seq)) <= 0 {
		// Nothing went out at all (EIO once the far end is gone), so there is
		// nothing for restore to turn off. A SHORT write deliberately does not
		// roll back -- the same "assume set whenever it is not certain we did
		// not" direction paste_enable takes, and here it matters slightly more:
		// a partial write most likely landed the TRACKING mode (it is first in
		// the string), which is the half whose absence from the teardown would
		// leave the user's shell taking mouse reports as keyboard input.
		g_term.mouse_mode = .None
	}
}

// `CSI ? 1004 h`. Same ordering invariant, same DECSET/DECRST hazard class, and
// a single eight-byte sequence like paste_enable's -- so a partial write is not
// a case worth splitting: it leaves the terminal mid-sequence either way.
@(private="file")
focus_enable :: proc(fd: posix.FD) {
	g_term.focus_active = true
	if posix.write(fd, raw_data(FOCUS_ON), len(FOCUS_ON)) <= 0 {
		g_term.focus_active = false
	}
}

// `CSI ? 1049 h`. Ordering invariant identical in SHAPE to the four enables
// above -- alt_active goes true BEFORE the write -- but the two sides of that
// trade are not symmetric here, and it is worth being precise about which way
// they lean.
//
// Flag-before-write means a crash signal landing between the two writes an
// `?1049l` for an `h` that may never have landed. On an xterm-family terminal
// that restores a cursor position that was never saved: one jump of the cursor,
// on a screen the user is about to get a shell prompt on anyway. Flag-after-
// write would leave the opposite window, in which the `h` HAS landed and the
// restore no-ops: the user is left inside the alternate screen with their
// terminal's entire scrollback inaccessible and no way out but `reset`. That is
// permanent and it is the worst outcome this file can produce, so the same
// "assume set whenever it is not certain we did not" direction every other
// enable takes is, if anything, more strongly justified here than anywhere else.
//
// A short write is not a case worth splitting (as it is for the Kitty push,
// which is two independent sequences): this is one eight-byte sequence, so a
// partial write leaves the terminal mid-sequence either way.
@(private="file")
alt_enable :: proc(fd: posix.FD) {
	g_term.alt_active = true
	if posix.write(fd, raw_data(ALT_ON), len(ALT_ON)) <= 0 {
		// Nothing went out at all (EIO once the far end is gone), so the terminal
		// never switched buffers and never saved a cursor -- there is genuinely
		// nothing for restore to undo, and writing `?1049l` anyway would be the
		// unpaired reset term_restore_c's own comment warns about.
		g_term.alt_active = false
	}
}

// DECTCEM show. Static, and written from a signal handler, for exactly the
// reasons KITTY_POP and PASTE_OFF are static (write(2) is async-signal-safe,
// fmt and the allocator are not). Deliberately NOT paired here with a
// CURSOR_HIDE constant: the hide is emitted by the renderer, into the frame
// BUILDER, alongside the rest of a frame's bytes -- see cursor_hide_arm.
@(private="file")
CURSOR_SHOW: string : "\e[?25h"

// Called by render.odin immediately BEFORE it writes a "\e[?25l" into a frame,
// to arm the paired show in term_restore_c. Three things about it are
// deliberate.
//
// GATED ON raw_active. This is the "did WE do it" check, and it has to be
// something the renderer cannot answer itself: the renderer writes to a
// strings.Builder and has no idea whether those bytes ever reach a terminal
// (with flush_fd < 0 -- the golden harness, every unit test -- they never do).
// raw_active is true exactly when this process has a tty it configured and
// still owns, and g_term.fd is that tty. Without the gate, a golden-harness
// render would arm a show against g_term.fd == 0, i.e. an unpaired "\e[?25h"
// written to the test runner's own stdin.
//
// STICKY, unlike kitty_active/paste_active, which are cleared the moment their
// undo is written. A frame contains its own hide AND its own show, so in the
// happy path the terminal ends every frame with the cursor visible and this
// flag is describing a state that no longer exists. It stays set anyway
// because the bytes are not written by this proc -- they are BUFFERED, and
// flush_frame's posix.write is a single unlooped call, so a short write can
// deliver the hide and drop the show. Clearing the flag per frame would mean
// the one case where the show went missing is also the one case where restore
// stays silent. Sticky costs an idempotent extra "\e[?25h" at teardown;
// non-sticky costs an invisible cursor forever.
//
// WHY THAT TRADE IS SAFE HERE AND WOULD NOT BE FOR KITTY. `\e[?25h` is
// DECSET -- one boolean mode, no stack, no depth -- so writing it when the
// cursor is already visible is a true no-op, and writing it unpaired can at
// worst reveal a cursor some other program hid (bounded, immediately visible,
// and trivially re-hidden by that program). `CSI < 1 u` is a stack POP: an
// extra one silently eats an entry belonging to whoever is above us, from a
// stack nobody can inspect. Same guard SHAPE, genuinely different hazard --
// which is why kitty_active must be exact and this one is allowed to err
// towards writing.
@(private="package")
cursor_hide_arm :: proc() {
	if g_term.raw_active { g_term.cursor_hidden = true }
}

term_restore :: proc() {
	term_restore_c()
}

// Async-signal-safe: tcsetattr(2) and write(2), both on POSIX's own list. No
// allocation, no fmt, no locks, and the only bytes written are a STATIC string
// (KITTY_POP) -- a formatted sequence would need a buffer and a formatter, and
// neither is safe to reach from a signal handler that may have interrupted the
// allocator mid-update.
//
// THE SINGLE TEARDOWN POINT. term_restore() is a one-line wrapper around this,
// and guard.odin's crash_handler calls it directly, so the orderly path and
// the crash-signal path share one implementation rather than two that can
// drift. That is what makes the flag checks below sufficient.
//
// POP EXACTLY ONCE. `CSI > <flags> u` PUSHES onto the terminal's keyboard
// stack and `CSI < 1 u` POPS one entry, so an unpaired pop is not a harmless
// no-op -- it eats an entry belonging to whoever is above us (the shell, a
// parent TUI), leaving THAT program's keyboard mode silently wrong. Exactly
// the hazard the alt-screen note below describes, with a stack behind it. The
// guard is `kitty_active`: popped if and only if we pushed, and cleared
// immediately, so a crash handler that pops and a `defer term_restore()` that
// runs afterwards cannot both pop.
//
// PASTE IS SET/RESET, NOT PUSH/POP -- the difference from the Kitty pairing
// above, stated rather than copied. `CSI ? 2004 h` / `l` are DECSET/DECRST:
// one boolean mode, no stack, no depth. Resetting twice is idempotent, so the
// specific catastrophe the POP-EXACTLY-ONCE rule exists to prevent -- eating an
// entry that belongs to a program above us, from a stack nobody can inspect --
// simply has no analogue here. The `paste_active` guard is still required, for
// the general form of the same rule (never undo something this process did not
// do): an unpaired `?2004l` turns bracketed paste OFF for whatever program had
// it on, which is a real regression for that program. But the blast radius is
// bounded and observable (that program stops seeing paste brackets) rather
// than unbounded and invisible, so the guard is protecting against a smaller
// hazard, and a bug in it would be correspondingly less destructive.
//
// THE CURSOR IS DECTCEM -- ALSO SET/RESET, AND DELIBERATELY BIASED TOWARDS
// WRITING. `\e[?25h` is DECSET 25, the same shape as bracketed paste and not
// the Kitty stack's shape at all, so the reasoning is stated fresh rather than
// copied: showing an already-visible cursor is a genuine no-op, and showing one
// unpaired can at worst reveal a cursor another program hid -- bounded,
// immediately visible to the user, and trivially undone by that program. The
// guard (`cursor_hidden`) therefore exists to keep a process that never touched
// the cursor silent, NOT to prevent a catastrophe, and unlike the other two it
// is deliberately STICKY once armed -- see cursor_hide_arm for why (the hide is
// buffered into a frame this proc never sees, and flush_frame's write is not
// looped, so "the show got dropped" and "the show landed" are indistinguishable
// from here; leaving a terminal with an invisible cursor is precisely the
// "actively wrong output" this comment's last paragraph warns about).
//
// MOUSE AND FOCUS ARE DECSET/DECRST TOO (T2-B), so the pairing hazard is the
// mild one, not the Kitty one, and that is stated rather than inherited:
// `?1000h`/`?1002h`/`?1003h`, `?1006h` and `?1004h` are boolean modes with no
// stack and no depth, so resetting one twice is a genuine no-op and the
// specific catastrophe POP-EXACTLY-ONCE exists to prevent -- eating an entry
// belonging to a program above us, from a stack nobody can inspect -- has no
// analogue. `mouse_mode` and `focus_active` are still required for the general
// form of the rule (never undo something this process did not do): an unpaired
// `?1000l` turns mouse reporting off for whatever program above us had it on.
// Bounded and observable, like paste's, rather than unbounded and invisible.
//
// Note what mouse_mode buys beyond a bool: it names WHICH tracking mode is on,
// so the reset undoes exactly that one. Resetting all four tracking modes
// unconditionally (which is what ultraviolet's MouseModeNone does) would turn
// off modes this process never set -- the same rule, broken.
//
// THE ALTERNATE SCREEN IS DECSET/DECRST TOO (T2-C), so the pairing hazard is
// again the mild one and not the Kitty one -- `?1049h`/`l` is a boolean mode
// with no stack and no depth, and resetting it twice is a genuine no-op. But
// this is the one of the five where BOTH directions of getting it wrong are
// severe, which is why it is the only one whose guard is argued in both
// directions here:
//
//   MISSING THE RESET is the worst single outcome in this proc after raw mode
//   itself. The user is left inside the alternate buffer: their shell prompt
//   draws over the dead TUI's last frame, their scrollback is gone (the alt
//   buffer has none, and the primary buffer's is inaccessible until they leave),
//   and the entire session that preceded the program is invisible. Nothing is
//   mistyped and nothing is mis-reported -- they simply cannot see their own
//   terminal, and the only way back is to blind-type `reset`.
//
//   AN UNPAIRED RESET is actively wrong output, not a no-op, and this is the
//   warning the last paragraph of this comment has carried since FIX 5.
//   `?1049h` does not merely switch buffers: it SAVES THE CURSOR POSITION, which
//   `?1049l` later restores. A process that never wrote the `h` and writes the
//   `l` anyway makes the terminal restore a position nobody ever saved -- the
//   cursor jumps to wherever some earlier program's DECSC happened to leave it,
//   in the middle of output that is still being written.
//
// What changed since that warning was written is exactly one thing, and it is
// the thing the warning was waiting for: SOMETHING NOW ENTERS THE ALT SCREEN.
// `alt_active` is true if and only if this process wrote the `h` that performed
// the save, so the `l` below is only ever written against a save it is genuinely
// paired with -- which is what turns the old unconditional write (an alt-screen
// exit the framework never entered) into a correct one. The rule did not change;
// the write finally satisfies it.
//
// ORDERING: termios FIRST, then the keyboard pop, then the ALT-SCREEN LEAVE,
// then the mouse reset, then the focus reset, then the cursor show, then the
// paste reset. The seven are independent layers (kernel line discipline vs six
// separate pieces of terminal-emulator state) so none depends on another, which
// leaves two tie-breakers, and both point the same way. (1) This runs from a
// crash handler; the only thing that can stop it half-way is a SECOND fatal
// signal, so restorations go WORST-FIRST:
//   - a tty stranded in RAW MODE has no echo, no line editing and no Ctrl+C --
//     the user must blind-type `reset`;
//   - a tty stranded with an extra KEYBOARD-STACK entry still echoes and still
//     line-edits, but it can mis-report EVERY subsequent keystroke to the shell.
//     Above the alt screen deliberately: this one corrupts what the shell
//     RECEIVES, so it can make even the recovery command untypable, while the
//     alt screen leaves input perfectly intact;
//   - a tty stranded in the ALTERNATE SCREEN echoes and reports everything
//     correctly, but costs the user their entire visible terminal: no
//     scrollback, no history of the session, a shell prompt drawn over a dead
//     TUI, and no way back but `reset`. That is a total, persistent loss of
//     CONTEXT rather than intermittent noise, which is why T2-C put it ABOVE
//     mouse -- and above the cursor show too, so that the show lands on the
//     PRIMARY screen the user is actually looking at rather than on a buffer
//     that is about to be discarded;
//   - a tty stranded with MOUSE REPORTING on injects escape-sequence garbage
//     into the shell's command line on every click and every scroll flick (and,
//     under 1003, on every pointer movement across the window). That is the
//     same class of damage as the keyboard mis-report -- input the user did not
//     type -- and it fires constantly rather than only when a key is pressed,
//     which is why T2-B put it ABOVE the cursor rather than next to paste. It
//     stays BELOW the alt screen because the user can see every character of it
//     and delete it;
//   - a tty stranded with FOCUS REPORTING on does the same thing, injecting
//     "\e[I"/"\e[O" into the command line, but only when the user switches
//     windows -- the same kind of damage at a far lower rate;
//   - a tty stranded with an INVISIBLE CURSOR reports and echoes everything
//     correctly, but the user is left typing at a shell with no caret at all --
//     disorienting on every subsequent command, though nothing is mistyped;
//   - a tty stranded in BRACKETED-PASTE mode reports every keystroke correctly
//     and only wraps PASTES in literal "[200~"/"[201~" -- annoying, and
//     invisible until the user next pastes, the smallest of the seven.
// (2) tcsetattr cannot block, write CAN (a full tty output queue), and blocking
// mid-crash before the line discipline is back would be the worst of both.
// Writing the six sequences after the TCSAFLUSH also means none is at risk
// from that flush.
//
// The write targets a real tty by construction -- kitty_active can only be
// true if tcgetattr succeeded on this fd -- so it can only fail with EIO once
// the far end is gone, never SIGPIPE the way a pipe would.
//
// STILL emits no other escape sequences, and the rule that produced that has
// not moved (FIX 5, final fix-wave report). This used to unconditionally write
// "\e[?1049l\e[?25h" -- leave alt screen, show cursor -- on every exit path,
// while nothing in this package or its examples ever wrote the corresponding
// ENTRY sequences: render.odin was a naive INLINE rewind renderer (cursor-up +
// erase-line, see renderer_render) and nothing else. That unconditional write
// was an alt-screen EXIT the framework never entered: on xterm-family terminals
// an unpaired "\e[?1049l" restores a cursor position that was never saved,
// which is actively wrong output, not merely a harmless no-op. The rule it was
// replaced with -- undo only what was actually set -- is what the flags below
// enforce, and it is why each write returned only when something real paired
// with it: T2-A gave render.odin a "\e[?25l" (Cursor / renderer_render), T2-B
// gave the mouse and focus enables theirs, and T2-C has now given "\e[?1049l"
// its "\e[?1049h" (term_enter_raw's `alt`, render.odin's
// Render_Mode.Full_Screen). Each time the restore grew by EXACTLY that and
// nothing more, each time behind its own flag set where the entry sequence is
// actually emitted. Nothing else is written here, and nothing should be added
// without the same pairing.
//
// The seven flags are checked INDEPENDENTLY rather than nested under one
// early return, so that no restoration can ever be skipped because of
// another's state.
term_restore_c :: proc "c" () {
	if g_term.raw_active {
		posix.tcsetattr(g_term.fd, .TCSAFLUSH, &g_term.saved)
		g_term.raw_active = false
	}
	if g_term.kitty_active {
		posix.write(g_term.fd, raw_data(KITTY_POP), len(KITTY_POP))
		g_term.kitty_active = false
	}
	if g_term.alt_active {
		posix.write(g_term.fd, raw_data(ALT_OFF), len(ALT_OFF))
		g_term.alt_active = false
	}
	if g_term.mouse_mode != .None {
		// A switch over static strings, not a formatted sequence: this is signal
		// context. One write, no allocation, no locks.
		off: string
		switch g_term.mouse_mode {
		case .Normal:       off = MOUSE_OFF_NORMAL
		case .Button_Event: off = MOUSE_OFF_BUTTON
		case .Any_Event:    off = MOUSE_OFF_ANY
		case .None:         off = ""   // unreachable: guarded above
		}
		if len(off) > 0 { posix.write(g_term.fd, raw_data(off), len(off)) }
		g_term.mouse_mode = .None
	}
	if g_term.focus_active {
		posix.write(g_term.fd, raw_data(FOCUS_OFF), len(FOCUS_OFF))
		g_term.focus_active = false
	}
	if g_term.cursor_hidden {
		posix.write(g_term.fd, raw_data(CURSOR_SHOW), len(CURSOR_SHOW))
		g_term.cursor_hidden = false
	}
	if g_term.paste_active {
		posix.write(g_term.fd, raw_data(PASTE_OFF), len(PASTE_OFF))
		g_term.paste_active = false
	}
}

// core:sys/posix exposes neither ioctl nor a winsize struct; only the per-OS
// TIOCGWINSZ constant exists. Go through the raw Linux syscall layer.
//
// linux.ioctl returns uintptr, NOT an Errno -- errors are negative returns.
term_size :: proc(fd: posix.FD) -> (w: int, h: int, ok: bool) {
	ws := Winsize{}
	res := linux.ioctl(linux.Fd(fd), linux.TIOCGWINSZ, uintptr(rawptr(&ws)))
	if int(res) < 0 { return 0, 0, false }
	if ws.ws_col == 0 || ws.ws_row == 0 { return 0, 0, false }
	return int(ws.ws_col), int(ws.ws_row), true
}
