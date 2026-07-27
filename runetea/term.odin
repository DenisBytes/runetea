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
// thing for bracketed paste. Opting in is the application's call, not the
// framework's -- unlike Bubble Tea, run() does not own the terminal here (the
// app calls term_enter_raw itself, and the golden tests drive run() with a
// plain pipe), so the layer that entered raw mode is the layer that gets to
// decide, and a terminal that never opted in must see zero sequences of either
// kind. Both are trailing defaulted parameters so that every call site written
// before they existed keeps compiling and keeps behaving identically.
term_enter_raw :: proc(fd: posix.FD, kb: Kitty_Flags = {}, paste: bool = false) -> bool {
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

	// Both opt-ins are written from here down, and BOTH ONLY AFTER tcsetattr
	// SUCCEEDED. The Kitty block has its own (different, stronger) reason,
	// below; the reason common to both is the rollback path -- tcsetattr
	// failing returns false, and every call site's failure branch is
	// `eprintln("not a tty"); os.exit(1)` placed BEFORE its `defer
	// term_restore()`, so anything already written to the terminal at that
	// point would never be undone. Writing after the last thing that can fail
	// means there is nothing stranded when it does.
	if kb != {} { kitty_enable(fd, kb) }
	if paste    { paste_enable(fd) }
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
// ORDERING: termios FIRST, then the keyboard pop, then the paste reset. The
// three are independent layers (kernel line discipline vs two separate pieces
// of terminal-emulator state) so none depends on another, which leaves two
// tie-breakers, and both point the same way. (1) This runs from a crash
// handler; the only thing that can stop it half-way is a SECOND fatal signal,
// so restorations go WORST-FIRST. A tty stranded in raw mode has no echo, no
// line editing and no Ctrl+C -- the user must blind-type `reset`. A tty
// stranded with an extra keyboard-stack entry still echoes and still
// line-edits, but it can mis-report EVERY subsequent keystroke to the shell. A
// tty stranded in bracketed-paste mode reports every keystroke correctly and
// only wraps PASTES in literal "[200~"/"[201~" -- annoying, and invisible until
// the user next pastes, but the smallest of the three. (2) tcsetattr cannot
// block, write CAN (a full tty output queue), and blocking mid-crash before the
// line discipline is back would be the worst of both. Writing both sequences
// after the TCSAFLUSH also means neither is at risk from that flush.
//
// The write targets a real tty by construction -- kitty_active can only be
// true if tcgetattr succeeded on this fd -- so it can only fail with EIO once
// the far end is gone, never SIGPIPE the way a pipe would.
//
// Emits no OTHER escape sequences (FIX 5, final fix-wave report). This used to
// unconditionally write "\e[?1049l\e[?25h" -- leave alt screen, show
// cursor -- on every exit path, but nothing in this package or its
// examples ever writes the corresponding entry sequences ("\e[?1049h",
// "\e[?25l"): render.odin is a naive INLINE rewind renderer (cursor-up +
// erase-line, see renderer_render), not an alt-screen renderer, and the
// cursor is never hidden. Restore must undo only what was actually set --
// right now that is termios raw mode, nothing else. The old unconditional
// write was an alt-screen EXIT the framework never entered: on
// xterm-family terminals an unpaired "\e[?1049l" restores a cursor
// position that was never saved, which is actively wrong output, not
// merely a harmless no-op. T2/T3 may start hiding the cursor and/or
// entering the alt screen; this restore must grow to match exactly that
// when it does, and no more in the meantime. The Kitty pop above is the
// first thing to meet that bar: it is written ONLY when this process
// actually pushed.
//
// The three flags are checked INDEPENDENTLY rather than nested under one
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
