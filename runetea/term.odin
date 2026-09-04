package runetea

import "core:c/libc"
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
	// The COOKED settings, captured by the acquire that first put this terminal
	// into raw mode and never overwritten until term_restore_c has handed them
	// back. Guarded by raw_active for exactly that reason -- see term_acquire's
	// ALREADY OURS branch, and the bug it exists to prevent: an unguarded
	// tcgetattr on a second entry captures the RAW termios as the "cooked"
	// settings, and the next term_restore() then faithfully reinstates raw mode
	// on a clean, fully-paired, exit-0 run.
	saved:        posix.termios,
	raw_active:   bool,
	// True for exactly the interval in which ONE entry of ours could be on
	// the terminal's keyboard stack. See kitty_enable's second ordering
	// invariant and term_restore_c's POP-EXACTLY-ONCE comment -- this flag is
	// the whole mechanism that stops the normal teardown and the crash-signal
	// teardown from both popping.
	kitty_active: bool,
	// T1-L. Same guarded-flag shape as kitty_active, and required for the same
	// reason -- never undo something this process did not do -- but the hazard
	// it guards is genuinely milder; see term_restore_c's "SET/RESET, NOT
	// PUSH/POP" note for why, and for why the guard stays anyway.
	paste_active: bool,
	// T2-A. True from the first moment a "\e[?25l" could have reached this
	// terminal from this process. Two things set it and neither ever clears
	// it (only term_restore_c does): cursor_hide_enable, when the application
	// declared Term_Opts.cursor_hide and this file wrote the hide itself, and
	// cursor_hide_arm, when render.odin is about to write one into a frame.
	// One flag for both because the teardown's question is not "who hid it"
	// but "could this process have hidden it", and the answer drives exactly
	// one write. See term_restore_c's DECTCEM note for why this one is
	// deliberately STICKY where kitty_active is not.
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
	// What the application ASKED FOR, kept so that the terminal can be rebuilt
	// from nothing after a job-control stop -- guard.odin's SIGTSTP handler tears
	// the terminal all the way down before the process stops, and has to put
	// exactly this back on SIGCONT.
	//
	// NOT A GUARD, and deliberately not cleared by term_restore_c. Every field
	// above it answers "did WE set this, and is it still set?"; this one answers
	// "what did the caller want?", which survives a teardown by design. Reading
	// it as a guard would break the pairing discipline the six flags enforce, so
	// nothing in this file does: the only reader is the resume path, which gates
	// on the raw_active it captured BEFORE the teardown.
	opts:          Term_Opts,
	// The capability verdict from the acquire that entered raw mode, cached
	// rather than re-derived. Two reasons, and the second is the binding one:
	// TERM cannot meaningfully change under a running process, and getenv(3) is
	// NOT on POSIX's async-signal-safe list -- the SIGCONT resume path re-enters
	// term_acquire from a signal handler and must not consult the environment
	// there. See term_supports_escapes.
	escapes_ok:    bool,
}

// The terminal opt-ins, as ONE named-field struct rather than five trailing
// positional parameters. `Term_Opts{alt = true}` says at the call site which
// mode it is asking for; the signature this replaces could not.
//
// WHY THIS IS A BREAKING CHANGE AND NOT A DOC FIX. The old spelling was
// `term_enter_raw(fd, kb: Kitty_Flags = {}, paste: bool = false, mouse:
// Mouse_Mode = .None, focus: bool = false, alt: bool = false)` -- five trailing
// opt-ins, THREE OF THEM BARE BOOLS, two of those adjacent. Odin's type checker
// catches a transposition across the Kitty_Flags or Mouse_Mode slots, so the
// silent failure was confined to the bools and to any arg-count slip that
// shifted them: write `term_enter_raw(fd, {.Disambiguate}, true, .Normal, true)`
// meaning "alternate screen" and you get `?1004h` (focus reporting) on the wire
// where you wanted `?1049h` (alternate screen). It compiles, it returns true,
// the frame looks identical, and the only way to find it is to read DECSET
// numbers off the wire. Named arguments were the cheaper fix and were rejected:
// they are optional, and not one of the 48 mentions of this proc anywhere in
// the repository -- source, tests or docs -- had used one, including the two
// call sites a user copies from (examples/editor and docs/API.md, both passing
// all six positionally). A convention nobody follows is not a mitigation.
//
// THE ZERO VALUE MEANS EXACTLY WHAT THE OLD DEFAULTS MEANT: touch nothing.
// `kb == {}` writes no keyboard push and pushes nothing on the terminal's
// stack, `paste == false`/`focus == false`/`alt == false`/`cursor_hide ==
// false` write no DECSET, and `mouse == .None` writes no tracking mode -- and
// the paired teardown in term_restore_c stays silent for each. That is what
// makes `term_enter_raw(fd)` still mean "raw mode and not one byte more", which
// is what every tool under tools/ relies on.
Term_Opts :: struct {
	kb:    Kitty_Flags,
	paste: bool,
	mouse: Mouse_Mode,
	focus: bool,
	alt:   bool,
	// T2-A, and the newest of the six: HIDE THE HARDWARE CARET FOR THE WHOLE
	// SESSION. `CSI ? 25 l` on acquire, `CSI ? 25 h` from term_restore_c on
	// every exit path there is -- the orderly one, the crash handlers, and the
	// SIGTSTP stop.
	//
	// WHAT THIS FIXES, and it is a terminal left broken after exit rather than
	// a cosmetic. There was no supported way to say it. .Full_Screen and .Diff
	// hide the caret themselves because they own the viewport (render.odin's
	// Cursor), but .Inline does not and must not, and NO mode offered the
	// declaration to an application that simply does not want a blinking block
	// in its output: `Cursor{show = false}` is the zero value and reads as "no
	// opinion", and cursor_hide_arm is package-private. An app that wrote
	// "\e[?25l" itself therefore got NO paired show from term_restore, from the
	// crash handlers, or from the stop path -- measured on a pty as exit 0 with
	// hides=1 shows=0, i.e. the user's SHELL left with an invisible caret,
	// recoverable only by blind-typing `reset` or `tput cnorm`.
	//
	// WHY THIS AND NOT AN EXPORTED cursor_hide_arm, which is the smaller
	// change and was the obvious one. An arm-only export would still leave the
	// app writing the bytes, and the bytes are the half that cannot be
	// replayed: g_term.opts is what guard.odin's SIGCONT handler feeds back
	// into term_acquire to rebuild the terminal after a stop, so an opt-in
	// RECORDED here comes back automatically on resume while an app's own
	// write does not -- `fg` after a `Ctrl+Z` would show the caret again for
	// the rest of the session. Same reason the other five live here. It also
	// keeps the pairing where every other pairing in this file already is:
	// this file writes both halves, so there is exactly one place to get
	// wrong. cursor_hide_arm STAYS package-private, deliberately: it promises
	// a show for bytes it did not write and cannot replay, which is a promise
	// only render.odin -- which writes its hide into a frame this file never
	// sees -- has any business asking for.
	//
	// A PER-FRAME cursor still wins over it. A frame that declares
	// `Cursor{show = true}` shows the caret at that position and the next
	// frame hides it again; the declaration here is the session's default, not
	// a veto. An application that wants the caret gone for one frame does not
	// need this field at all -- it just declares no cursor.
	cursor_hide: bool,
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
kitty_push_seq :: proc "c" (kb: Kitty_Flags, buf: []u8) -> []u8 {
	v := transmute(u8)kb                  // == the protocol's flag word, see Kitty_Flag
	n := copy(buf, "\e[>")
	if v >= 10 { buf[n] = '0' + v / 10; n += 1 }
	buf[n] = '0' + v % 10; n += 1
	buf[n] = 'u'; n += 1
	n += copy(buf[n:], "\e[?u")           // RequestKittyKeyboard
	return buf[:n]
}

// Does this terminal understand escape sequences at all?
//
// FALSE for `TERM=dumb` and for a TERM that is unset or empty, TRUE otherwise.
// That is the whole rule, and it is deliberately not a terminfo lookup: the
// three values this returns false for are the three whose entire meaning is
// "this terminal has no capabilities", and everything else is a terminal that at
// minimum speaks ANSI. Reading terminfo to decide which of ?1049/?1000/?2004/
// CSI-u a given entry claims would be a much bigger machine answering a much
// finer question than any caller here asks.
//
// WHY THIS IS PUBLIC. Before it existed there was no way, anywhere in runetea or
// runegloss's caller-facing surface, to ask whether the terminal was capable:
// TERM was read in exactly one place (runegloss/color.odin's colour-profile
// detector) and for colour only. So on an Emacs comint/shell-mode pty -- the
// real-world TERM=dumb -- an application degraded its COLOUR correctly and then
// painted a wall of CUP/ED/SGR at a terminal that renders every byte of it
// literally. term_enter_raw now gates its own opt-ins on this (see term_acquire),
// which covers the keyboard push, bracketed paste, mouse tracking and the
// alternate screen.
//
// AND SO DOES THE RENDERER, which this comment used to say was out of reach.
// guarded_render (tea.odin) reads this proc once per frame into Renderer.plain,
// and a false verdict routes .Inline, .Full_Screen and .Diff alike through
// render_plain (render.odin) -- no CUP, no ED, no EL, no SGR, and the view's
// own escapes stripped on the way out. The advice that used to stand here --
// "the renderer's absolute addressing is not this file's to gate, so an
// application that wants to degrade THAT should consult this and pick its
// Render_Mode accordingly" -- is now both unnecessary and actively bad: no
// Render_Mode paints escapes at a terminal that says it has none, so choosing
// one on this basis buys nothing and gives up whatever the mode was picked for.
//
// WHICH LEAVES THE APPLICATION'S OWN OUTPUT as the reason this stays public: a
// hand-rolled SGR, a progress bar drawn with \r, anything written outside
// view() or after term_restore. The library cannot see those, and this is how
// an application asks the same question the library now asks itself.
//
// Not cached: one getenv per acquire is nothing, and a cached verdict is a
// second source of truth for a question the environment already answers. What IS
// cached is the verdict for the interval a terminal is held (g_term.escapes_ok),
// and that is for async-signal-safety, not for speed -- see its comment.
//
// libc.getenv rather than os.get_env: os.get_env ALLOCATES a copy, and this runs
// on the acquire path where the rest of the file is deliberately allocation-free.
@(require_results)
term_supports_escapes :: proc() -> bool {
	v := libc.getenv("TERM")
	if v == nil { return false }
	s := string(v)
	return s != "" && s != "dumb"
}

// `opts` defaults to Term_Opts{}, which means DO NOT TOUCH anything but the line
// discipline: no keyboard push, no bracketed paste, no mouse tracking, no focus
// reporting, no alternate screen, no DECTCEM, and a paired teardown in
// term_restore_c that stays a no-op for each. Opting in is the application's call, not the
// framework's -- unlike Bubble Tea, run() does not own the terminal here (the app
// calls term_enter_raw itself, and the golden tests drive run() with a plain
// pipe), so the layer that entered raw mode is the layer that gets to decide, and
// a terminal that never opted in must see zero sequences of any kind.
//
// Five of the six used to be trailing defaulted PARAMETERS. They are one struct
// now, and Term_Opts' own comment argues why that break was worth taking. The
// sixth, `cursor_hide`, was never a parameter and could not have been one: it
// exists because there was no supported way to ask for it at all, which left
// applications writing "\e[?25l" themselves and getting no paired show from any
// of this file's exit paths.
//
// `opts.alt` is the terminal half of render.odin's Render_Mode.Full_Screen, and
// the two are deliberately INDEPENDENT: entering the alt screen without a
// full-screen renderer is legal (an inline renderer would simply rewind inside
// the alt buffer), and a full-screen renderer without the alt screen is legal
// too (it repaints over the shell's output and clears below itself). Coupling
// them would mean this file knowing about the renderer, and would take the
// choice away from an application that has a reason to want one and not the
// other. Nothing in this package writes `?1049h` anywhere else, so this
// field is the ONE place the alt screen can be entered from.
term_enter_raw :: proc(fd: posix.FD, opts := Term_Opts{}) -> bool {
	// The ONE place TERM is consulted. Everything below this line runs in
	// signal context too (SIGCONT resume), where getenv(3) is not safe to call.
	return term_acquire(fd, opts, term_supports_escapes())
}

// The whole of term_enter_raw, minus the environment lookup, and callable from a
// signal handler: tcgetattr/tcsetattr/write are all on POSIX's async-signal-safe
// list, the only bytes written are static strings or a stack-built one, and
// nothing here allocates, formats or locks. That is what lets guard.odin's
// SIGTSTP handler rebuild the terminal on SIGCONT from the same code path that
// built it in the first place, rather than a second implementation that can
// drift.
//
// IDEMPOTENT ON A SECOND ENTRY, and this is a correctness fix, not a nicety.
// What this used to do was tcgetattr into g_term.saved UNCONDITIONALLY. Called a
// second time while the terminal was already raw -- by a library, by a
// re-acquire helper, by any second caller anywhere in the process, since g_term
// is process-global -- it captured the RAW termios as the "cooked" settings, and
// the subsequent term_restore() then faithfully reinstated raw mode. Measured on
// a real pty: two entries and one restore left the terminal with ECHO=0
// ICANON=0 ISIG=0 IEXTEN=0 OPOST=0 ICRNL=0, on a clean, fully-paired, exit-0
// run, recoverable only by blind-typing `reset`. It returned true and said
// nothing. The same call also pushed a SECOND Kitty stack entry that only one
// `\e[<1u` ever pops, leaving our Disambiguate entry on the terminal's keyboard
// stack after exit so the shell's own keys come back mis-encoded. (Note which
// half of the Kitty pairing that is: an unpaired PUSH. term_restore_c's
// POP-EXACTLY-ONCE rule guards the other direction, and the kitty_active
// boolean still enforces it correctly -- the pop count can never exceed one no
// matter how many times this is entered.)
//
// WHY IDEMPOTENT RATHER THAN A REFUSAL. Returning false on a second entry was
// the other candidate and is worse HERE, specifically because of the shape every
// call site in this repository (and in docs/API.md) uses: `if
// !rt.term_enter_raw(fd, ...) { eprintln("not a tty"); os.exit(1) }`, with the
// os.exit placed BEFORE the `defer rt.term_restore()`. A false from the second
// entry would therefore exit the process past its own teardown and strand
// exactly the terminal the guard exists to protect -- turning a recoverable
// programming error into the unrecoverable one. `false` keeps its single honest
// meaning: THIS PROCESS DOES NOT HAVE A RAW TTY. After a true, it does, whether
// this call is the one that acquired it or not.
//
// The one case that IS refused is a second entry naming a DIFFERENT fd, because
// g_term holds exactly one terminal's worth of state: accepting it would
// overwrite the first terminal's saved termios and every guard flag describing
// it, stranding a tty nothing can ever restore. Refusing leaves the first
// terminal intact and reports, accurately, that the second one was not acquired.
//
// A second entry can ADD opt-ins but cannot CHANGE one that is already on: the
// `!g_term.<flag>` guards below skip an enable whose mode this process already
// set, so nothing is pushed or DECSET twice. Asking for .Any_Event when .Normal
// is already on is therefore a no-op rather than two tracking modes with one
// reset; the way to change a mode is the release/re-acquire cycle
// (term_restore() then term_enter_raw()), which was already correct.
@(private="package")
term_acquire :: proc "c" (fd: posix.FD, opts: Term_Opts, escapes: bool) -> bool {
	first := !g_term.raw_active
	if first {
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
		g_term.escapes_ok = escapes
		g_term.opts = opts
	} else {
		// ALREADY OURS. No tcgetattr: g_term.saved already holds this terminal's
		// cooked settings and re-reading them now would capture raw mode as the
		// thing to restore. The escapes verdict of the acquire that took the
		// terminal stands too -- TERM cannot change under a running process, and
		// the resume path has no safe way to re-read it.
		if fd != g_term.fd { return false }
		g_term.opts.kb += opts.kb
		if opts.paste { g_term.opts.paste = true }
		if opts.focus { g_term.opts.focus = true }
		if opts.alt   { g_term.opts.alt   = true }
		if opts.cursor_hide { g_term.opts.cursor_hide = true }
		if g_term.opts.mouse == .None { g_term.opts.mouse = opts.mouse }
	}

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
		// Roll back, but ONLY if this call is the one that claimed the terminal:
		// the tty was never actually put into raw mode by it. On a re-entry the
		// tty IS still raw from the first acquire and g_term.saved still holds
		// the real cooked settings, so clearing raw_active here would silence the
		// teardown that terminal genuinely needs.
		if first { g_term.raw_active = false }
		return false
	}

	// TERM=dumb, or no TERM at all: raw mode is granted (it is kernel line
	// discipline, and works identically on a terminal that renders nothing), but
	// NOT ONE ESCAPE SEQUENCE goes out. Every one of the six below is a request
	// for a capability such a terminal is declaring it does not have, and an
	// Emacs comint pty answers a `\e[?1049h` by printing it. Skipping the enables
	// also means the flags stay false, so the paired teardown stays silent too --
	// the same "undo only what was actually set" rule that governs everything
	// else in this file, applied one level up.
	if !g_term.escapes_ok { return true }

	// Every opt-in is written from here down, and ALL OF THEM ONLY AFTER
	// tcsetattr SUCCEEDED. The Kitty block has its own (different, stronger)
	// reason, below; the reason common to all of them is the rollback path --
	// tcsetattr failing returns false, and every call site's failure branch is
	// `eprintln("not a tty"); os.exit(1)` placed BEFORE its `defer
	// term_restore()`, so anything already written to the terminal at that
	// point would never be undone. Writing after the last thing that can fail
	// means there is nothing stranded when it does.
	//
	// Each is additionally gated on its own flag being off, so a second acquire
	// (the SIGCONT resume, or a caller adding an opt-in) never pushes or sets a
	// mode this process already has on. See this proc's IDEMPOTENT note.
	if opts.kb != {} && !g_term.kitty_active         { kitty_enable(fd, opts.kb) }
	if opts.paste && !g_term.paste_active            { paste_enable(fd) }
	if opts.mouse != .None && g_term.mouse_mode == .None { mouse_enable(fd, opts.mouse) }
	if opts.focus && !g_term.focus_active            { focus_enable(fd) }
	if opts.alt && !g_term.alt_active                { alt_enable(fd) }
	// LAST, and after the alternate screen specifically. Some terminals track
	// DECTCEM per screen buffer; hiding after `?1049h` means the hide lands on
	// the buffer the application is about to paint, and term_restore_c's
	// worst-first order writes the show AFTER `?1049l`, i.e. on the normal
	// buffer the user is returning to. Being last also leaves the four existing
	// enable sequences byte-for-byte where they were.
	if opts.cursor_hide && !g_term.cursor_hidden     { cursor_hide_enable(fd) }
	return true
}

@(private="file")
kitty_enable :: proc "c" (fd: posix.FD, kb: Kitty_Flags) {
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
paste_enable :: proc "c" (fd: posix.FD) {
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
mouse_enable :: proc "c" (fd: posix.FD, mode: Mouse_Mode) {
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
focus_enable :: proc "c" (fd: posix.FD) {
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
alt_enable :: proc "c" (fd: posix.FD) {
	g_term.alt_active = true
	if posix.write(fd, raw_data(ALT_ON), len(ALT_ON)) <= 0 {
		// Nothing went out at all (EIO once the far end is gone), so the terminal
		// never switched buffers and never saved a cursor -- there is genuinely
		// nothing for restore to undo, and writing `?1049l` anyway would be the
		// unpaired reset term_restore_c's own comment warns about.
		g_term.alt_active = false
	}
}

// DECTCEM. Static strings, and CURSOR_SHOW is written from a signal handler,
// for exactly the reasons KITTY_POP and PASTE_OFF are static (write(2) is
// async-signal-safe, fmt and the allocator are not).
//
// THE HIDE HAS TWO EMITTERS AND THEY ARE NOT INTERCHANGEABLE. This file writes
// CURSOR_HIDE to the fd, once, for the session, when the application declared
// Term_Opts.cursor_hide. render.odin writes its own copy of the same six bytes
// into the frame BUILDER, interleaved with a frame's other output, and arms the
// paired show through cursor_hide_arm. Both spellings exist on purpose: the
// renderer's has to be ordered against the rest of its frame and this one has
// to reach a terminal held by an application that may never call the renderer
// at all (term_enter_raw + decode_keys with no run() is a supported shape).
// They cannot be folded, so render.odin keeps its own private CURSOR_HIDE
// constant and this one is not exported to it -- a shared constant would imply
// a shared writer.
@(private="file")
CURSOR_HIDE: string : "\e[?25l"
@(private="file")
CURSOR_SHOW: string : "\e[?25h"

// `CSI ? 25 l`, the session-long half. Ordering invariant identical in SHAPE to
// the four enables above -- the flag goes true BEFORE the write -- with one
// difference from every one of them: THIS ONE DOES NOT ROLL THE FLAG BACK WHEN
// THE WRITE FAILS. The four siblings do, because for them an enable that never
// left the process means there is genuinely nothing to undo and the undo itself
// is not free (an unpaired `\e[<1u` eats someone else's keyboard stack entry, an
// unpaired `\e[?1049l` jumps a cursor). cursor_hidden is the flag this file has
// already argued should err towards writing in every ambiguous case -- see
// cursor_hide_arm -- because the two outcomes are an idempotent extra six bytes
// versus a user's shell with no caret in it. A write that returns <= 0 is
// ambiguous in exactly that way, so it keeps the flag; if the fd is genuinely
// dead the paired show fails identically and nothing is lost either way.
@(private="file")
cursor_hide_enable :: proc "c" (fd: posix.FD) {
	g_term.cursor_hidden = true
	posix.write(fd, raw_data(CURSOR_HIDE), len(CURSOR_HIDE))
}

// Does the application want the caret hidden for the whole session? For
// render.odin, which has to stop UNDOING that at the end of a frame -- .Inline
// pairs its own hide with a show, and a session-long declaration it did not
// know about would be re-shown 60 times a second.
//
// ALL THREE TERMS ARE LOAD-BEARING. `opts.cursor_hide` is the declaration;
// `escapes_ok` is the TERM=dumb gate, so a terminal that got no `\e[?25l` is not
// modelled as hidden; and `raw_active` is what makes this false for a process
// that does not currently own a terminal at all. That last one also keeps
// g_term -- a process-global whose `opts` field deliberately survives
// term_restore_c -- from leaking one test's declaration into the next test's
// renderer output.
@(private="package")
cursor_hide_requested :: proc "contextless" () -> bool {
	return g_term.raw_active && g_term.escapes_ok && g_term.opts.cursor_hide
}

// Called by render.odin immediately BEFORE it writes a "\e[?25l" into a frame,
// to arm the paired show in term_restore_c. It is the RENDERER's half of the
// pairing; an application that wants the caret gone for the session declares
// Term_Opts.cursor_hide and this file writes both halves itself
// (cursor_hide_enable). Three things about this one are deliberate.
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
// because the bytes are not written by this proc -- they are BUFFERED, and the
// interval between the hide reaching the terminal and the show reaching it is
// not atomic.
//
// THE ORIGINAL JUSTIFICATION HAS BEEN FIXED AND THIS FLAG STILL HAS TO BE
// STICKY. What this comment used to say was that "flush_frame's posix.write is
// a single unlooped call, so a short write can deliver the hide and drop the
// show" -- one subsystem working around a bug in another. flush_frame now loops
// until the whole buffer is written (tea.odin, flush_frame/write_all), so a
// short write no longer truncates anything. Two independent reasons survive it,
// and neither is fixable from the writing side:
//
//   - A CRASH SIGNAL LANDING MID-FLUSH. The loop can be many write(2) calls, and
//     a SIGSEGV/SIGTERM can arrive between any two of them -- or inside one,
//     after the kernel has already accepted the leading "\e[?25l" and before it
//     accepts the trailing "\e[?25h". The dying process runs no `defer`s; the
//     only thing that shows the cursor again is guard.odin's crash_handler
//     calling term_restore_c, which reads THIS FLAG. A flag cleared at the end
//     of each frame would be false in exactly that window. This is not
//     hypothetical: test_cursor_shows_on_the_crash_path_after_a_truncated_frame
//     pins it, with a child that writes only the leading hide and then dies by
//     signal.
//   - AN UNRECOVERABLE WRITE ERROR MID-FLUSH. write_all gives up on EIO/EPIPE/
//     EBADF and returns a Terminal_Error, which unwinds run() into the caller's
//     `defer term_restore()`. If the hide had already gone out and the show had
//     not, the same asymmetry applies.
//
// Clearing the flag per frame would therefore still mean the one case where the
// show went missing is also the one case where restore stays silent. Sticky
// costs an idempotent extra "\e[?25h" at teardown; non-sticky costs an
// invisible cursor forever.
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
// is deliberately STICKY once armed -- see cursor_hide_arm for why (the
// renderer's hide is buffered into a frame this proc never sees, and the flush
// that carries it is interruptible by a crash signal and abortable on a write
// error, so "the show got dropped" and "the show landed" are indistinguishable
// from here; leaving a terminal with an invisible cursor is precisely the
// "actively wrong output" this comment's last paragraph warns about). The other
// setter, cursor_hide_enable, writes its hide straight to the fd and so has no
// such window -- but it shares the flag, because this proc's question is
// "could this process have hidden the caret", not "which of the two did".
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
//
// WHAT AN UNCATCHABLE SIGNAL STRANDS -- i.e. what this proc would have undone
// and never got the chance to. `kill -9` and `kill -STOP` run no handler, so the
// leak is exactly the set of opt-ins the application asked for, and it is worth
// stating precisely because docs/LIMITATIONS.md 6.1 currently says only "leaves
// the shell in raw mode and possibly in the alternate screen". Measured on
// examples/editor (Kitty .Disambiguate + paste + .Normal mouse + alt), FIVE
// things leak: raw mode; one Kitty keyboard-stack entry (the `\e[>1u` push, with
// its `\e[<1u` never written); the alternate screen (`?1049h`); mouse tracking
// with SGR coordinates (`?1000h` + `?1006h`); and bracketed paste (`?2004h`).
// Mouse tracking is the most user-visible of the four escape-level leaks -- it
// injects `\e[<0;12;7M`-style garbage into the shell's command line on every
// click and every scroll flick, which is why the ordering above ranks it where
// it does. Focus reporting (`?1004h`) leaks only for an application that enables
// it, and the cursor is normally left VISIBLE, not hidden: a frame ends by
// showing the cursor at the caret, so an invisible cursor is the narrow
// mid-frame race and not the normal outcome. Under TERM=dumb or no TERM the
// escape-level leaks cannot happen at all, because term_acquire never wrote the
// enables (see its capability gate) -- only raw mode leaks there. `reset` is
// still the recovery for every one of them.
//
// WHAT THIS PROC DELIBERATELY DOES NOT CLEAR: g_term.opts and g_term.escapes_ok.
// They are a RECORD of what the caller asked for and what the terminal can take,
// not guards for what is currently set, and guard.odin's SIGCONT resume needs
// both to survive the teardown that SIGTSTP performed. See their fields.
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
