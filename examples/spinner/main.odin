package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import rg "../../runegloss"
import rt "../../runetea"

// T1's iconic deliverable: an animated spinner, driven entirely by rt.tick --
// no keypress ever advances a frame. Mirrors Bubble Tea's own bubbles/spinner
// component, which is itself built on tea.Tick reissued from Update, not a
// fire-and-forget repeating timer -- see rt.tick's own doc comment
// (runetea/timer.odin) for why Tick keeps that exact shape (fires once, the
// model reissues it) while rt.every exists for the "auto-repeats on its own"
// case Tick deliberately doesn't cover.
FRAMES := []rune{'⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'}

FRAME_INTERVAL :: 100 * time.Millisecond

// The hint, and the width it needs: one column of spinner, one space, and the
// hint itself. A named constant so view()'s guard cannot drift from the string
// it is guarding.
// TWO hints, because the program now has two states and a hint that lies about
// which one you are in is worse than no hint. WCAG 2.2.2 (Pause, Stop, Hide)
// asks that automatically-moving content lasting more than five seconds be
// pausable; a control nobody can find is not one, so the key is named on screen
// in both states rather than documented in a README.
//
// HINT_COLS is measured from the LONGER of the two, so view()'s width guard
// cannot pass in one state and wrap in the other -- under .Inline a frame that
// wraps costs a physical row the rewind does not know about.
HINT       :: "Loading... 'p' pauses, 'q' quits"
HINT_PAUSE :: "Paused.    'p' resumes, 'q' quits"
HINT_COLS  :: 2 + max(len(HINT), len(HINT_PAUSE))

// Go: `type spinTickMsg time.Time` -- a closure-friendly single-field wrapper.
// RuneTea: time.Tick, per spec §9 (CLOCK_MONOTONIC_RAW, not CLOCK_REALTIME --
// never time.Time/time.now here), and POD by construction (arena.odin's
// MESSAGE OWNERSHIP CONTRACT) since time.Tick is just an i64 offset.
Spin_Tick_Msg :: struct { t: time.Tick }

// Go: `func() tea.Msg { return spinTickMsg(t) }` -- a closure over nothing.
// RuneTea: an explicit named proc, since Odin has no closures (rt.Timer_Fn's
// own doc comment) -- env is unused here (struct{}{}) because this Tick
// carries no per-firing state of its own.
spin_tick_fn :: proc(env: rawptr, t: time.Tick) -> any {
	return rt.box(Spin_Tick_Msg{t = t}, context.allocator)
}

// Plain rt.tick, not rt.tick_cancellable: this Tick is a one-shot,
// always-reissued animation frame with nothing that ever needs to cancel it
// early (quitting ends the whole Program, which tears the Dispatcher -- and
// its timer thread -- down on its own). tick() therefore hands back no
// Timer_Handle and the caller owes nothing: the frame's handle and fn env are
// freed by the timer subsystem the instant it fires. That is what makes this
// two-line proc, called ~12 times a second for the whole session, allocation-
// neutral -- see timer.odin's own comment on tick() for what it looked like
// when it wasn't.
// THE INTERVAL IS A PARAMETER, NOT A CONSTANT, and that is the shape
// docs/LIMITATIONS.md 11.3 asks an animated program to have: an app that hard-
// codes its frame interval has no way to offer a slower one, and "slow it down"
// is the accommodation most people actually want when "stop it" is too much.
// Model.interval is what is passed here, seeded from rt.reduce_motion().
spin_tick_cmd :: proc(interval: time.Duration) -> rt.Cmd {
	return rt.tick(interval, spin_tick_fn, struct{}{}, context.allocator)
}

// THE STYLES LIVE IN THE MODEL, and that is the point of writing them here
// rather than rebuilding them in view(). rg.Style is a PLAIN VALUE TYPE --
// rt.is_pod_type(rg.Style) is true and runegloss asserts it in its own tests, so
// there is no string, pointer or slice inside one -- which means it obeys exactly
// the rule this Model already had to obey (see arena.odin's MESSAGE OWNERSHIP
// CONTRACT and examples/editor's Model): copying it copies the whole truth, with
// nothing shared behind it. A styling library whose handle was a pointer into a
// registry could not be put here at all.
//
// It also means the terminal is sniffed ONCE, in main, instead of on every one of
// the ~10 frames a second this program paints.
Model :: struct {
	frame: int,
	spin:  rg.Style,   // the braille glyph
	hint:  rg.Style,   // "press 'q' to quit"
	// F47. The window's width, so view() can drop the hint rather than let a
	// 37-column line wrap onto a second row on a narrow terminal -- which under
	// .Inline means the renderer's rewind and the terminal's row count disagree
	// and the frame walks down the screen. Seeded in main from rt.term_size,
	// kept live from Window_Size_Msg; 0 is "unknown" and never trips the guard.
	term_w: int,

	// F47's HEIGHT half, and the note that used to sit here -- "this program's
	// view is ONE ROW, so there is no minimum HEIGHT to guard: a one-row frame
	// fits any terminal that exists" -- was FALSE, measured rather than
	// reasoned about. See MIN_ROWS.
	term_h: int,

	// Whether the 100 ms animation Tick is still being reissued. See MIN_ROWS
	// for why a height that can show nothing stops it: false is the state a
	// one-row terminal puts this program into, and a resize back up is the
	// only thing that clears it.
	animating: bool,

	// PAUSED BY THE USER, which is a different fact from `animating` and must
	// not share a field with it. `animating` is the animation's own invariant
	// -- "exactly one Tick is outstanding" -- and the height guard clears it
	// for a reason the user did not choose. If the two were one flag, a resize
	// would silently restart an animation the user had deliberately stopped,
	// which is the specific way a Pause control usually breaks.
	paused: bool,

	// The frame interval, in the model rather than in a constant, so it can be
	// slowed without an edit. See spin_tick_cmd.
	interval: time.Duration,
}

// THE MINIMUM HEIGHT IS TWO ROWS FOR A ONE-ROW VIEW, and the extra row is not
// slack -- it is where .Inline's line terminator lands.
//
// render_inline (runetea/render.odin) writes every line of the frame followed
// by "\r\n", INCLUDING the last one, because the next frame's rewind counts
// \e[1A\e[2K pairs from a cursor it needs at column 1 of the row below the
// frame. So a frame of R logical rows needs R+1 terminal rows: the R it paints
// plus the one the terminal's cursor sits on afterwards. Paint R rows into
// exactly R and the terminal scrolls, the top row goes to scrollback, and
// r.last_rows clamps to term_height-1 so the rewind can never reach it again.
//
// MEASURED, under a real pty at 60 columns (pyte replay, three animation
// frames each):
//   rows = 1  the screen is BLANK for the whole session -- the spinner line is
//             written, scrolled off, and the erase lands on the empty row that
//             replaced it. This is exactly F47's "at one terminal row every
//             example paints a blank screen", and it is unfixable HERE: at one
//             row there is no .Inline frame of any shape that survives its own
//             terminator. See docs/LIMITATIONS.md 3.20.
//   rows = 2  correct, and every taller terminal is correct too.
//
// So the guard cannot make the screen better at one row; what it can do is
// stop this program from writing 44 bytes and burning a timer wakeup ten times
// a second into a window that shows none of it. That is what `animating` is.
MIN_ROWS :: 2

// `m` is a POINTER: mutate it in place, return only the Cmd. See
// rt.Program.update (runetea/tea.odin).
update :: proc(m: ^Model, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	switch v in msg {
	case rt.Window_Size_Msg:
		// w == 0 / h == 0 is rt's "the ioctl failed" sentinel; ignore it rather
		// than clobbering a known-good size.
		if v.w > 0 { m.term_w = v.w }
		if v.h > 0 { m.term_h = v.h }
		// THE ONLY WAY OUT OF THE PAUSED STATE. A paused program has no timer
		// in flight, so nothing else will ever call update() except a keypress
		// -- and a user whose window is one row tall cannot see the prompt to
		// press anything. The resize is the wake-up, and it must issue EXACTLY
		// ONE Tick: the animation's invariant is one Spin_Tick_Msg outstanding
		// at a time (each firing reissues its own successor), so an unguarded
		// restart here would double the frame rate on every SIGWINCH.
		// `!m.paused` is the new half: a resize must not restart an animation
		// the USER stopped, only one the height guard stopped.
		if !m.animating && !m.paused && m.term_h >= MIN_ROWS {
			m.animating = true
			return spin_tick_cmd(m.interval)
		}
	case rt.Key_Msg:
		// PASTED TEXT IS NOT KEYSTROKES (F37). main enables bracketed paste, so
		// a paste arrives as runes with `pasted` set; without this branch a
		// pasted 'q' would quit a program the user only meant to paste into.
		if v.pasted { return rt.cmd_nil() }
		if v.code == .Rune && (v.r == 'q' || (v.r == 'c' && .Ctrl in v.mods)) {
			return rt.quit_cmd()
		}
		if v.code == .Escape { return rt.quit_cmd() }
		// THE PAUSE CONTROL (WCAG 2.2.2). Space is bound alongside 'p' because
		// it is what a media control is expected to be, and 'p' because space
		// is easy to hit by accident; both are cheap.
		//
		// PAUSING IS FREE AND LEAKS NOTHING: rt.tick hands back no handle
		// precisely so that not reissuing it is the whole of stopping. There is
		// no timer to cancel, no handle to get wrong, and nothing outstanding
		// once the last Tick has fired.
		if v.code == .Rune && (v.r == 'p' || v.r == ' ') {
			m.paused = !m.paused
			if m.paused {
				// Do NOT clear m.animating here. The Tick that is already in
				// flight will still arrive; the Spin_Tick_Msg branch below is
				// what declines to reissue it, and it is also what sets
				// animating = false, so the "exactly one outstanding" invariant
				// is maintained in one place rather than two.
				return rt.cmd_nil()
			}
			// Resuming issues exactly one Tick, and only if the height guard
			// is not independently holding the animation down.
			if !m.animating && (m.term_h == 0 || m.term_h >= MIN_ROWS) {
				m.animating = true
				return spin_tick_cmd(m.interval)
			}
		}
	case Spin_Tick_Msg:
		// F47's height half. Stop reissuing rather than animate into a window
		// that provably shows nothing (MIN_ROWS). Checked HERE and not in
		// view(), because view() cannot decline to be called: the frame is
		// what update() has already made inevitable, and the cost this saves
		// is the timer wakeup and the write, not the string.
		//
		// The frame counter is deliberately NOT advanced on the way out, so a
		// resize back up resumes the glyph where it stopped instead of
		// jumping.
		if m.term_h > 0 && m.term_h < MIN_ROWS {
			m.animating = false
			return rt.cmd_nil()
		}
		// The user asked it to stop. Same shape as the height guard directly
		// above, and deliberately so: both are "stop reissuing", and the frame
		// counter is NOT advanced on the way out either, so resuming picks the
		// glyph up where it stopped instead of jumping.
		if m.paused {
			m.animating = false
			return rt.cmd_nil()
		}
		m.frame = (m.frame + 1) % len(FRAMES)
		return spin_tick_cmd(m.interval) // reissue -- see spin_tick_cmd's own comment
	}
	return rt.cmd_nil()
}

view :: proc(m: Model, alloc: mem.Allocator) -> string {
	// THE LOCAL COPIES ARE GONE. This used to be `spin, hint := m.spin, m.hint`
	// with a six-line note explaining that rg.render took a ^Style and `m` is a
	// procedure PARAMETER, which Odin makes immutable and non-addressable, so
	// `&m.spin` did not compile. rg.render is a proc group now (runegloss's
	// F49/F52 fix) and `rg.render(m.spin, ...)` takes the Style by value, so
	// the copy happens at the one call site that needs it instead of being
	// written out as two named locals per frame.
	// EVERY string below comes from `alloc` -- the FRAME ARENA rt hands view() --
	// including the ones rg.render allocates, since RuneGloss allocates from the
	// allocator it is passed and from nothing else (runegloss/render.odin).
	// Nothing here is freed by hand because the arena is reclaimed wholesale after
	// the frame (arena.odin's LIFETIME CONTRACT). Note aprintf(allocator = alloc)
	// and NOT tprintf: the temp allocator is a different, process-lifetime arena
	// that this loop never resets.
	glyph := fmt.aprintf("%c", FRAMES[m.frame], allocator = alloc)
	// F47, the width half. The spinner plus the hint is 38 columns; below that
	// the hint is dropped rather than wrapped, because under .Inline a frame
	// that wraps costs a physical row the renderer's rewind does not know about
	// and the frame slides down the screen one row per tick -- ten times a
	// second here. The GLYPH always survives: it is the whole program.
	//
	// There is deliberately NO matching height branch. Below MIN_ROWS there is
	// no shorter frame to fall back to -- this view is already one row, and
	// under .Inline one row does not fit a one-row terminal (see MIN_ROWS for
	// the measurement). A `if too short { return "need 2 rows" }` here would
	// paint a string nobody can see and would read as a fix; the height guard
	// that does something is in update(), where it stops the Tick.
	if m.term_w > 0 && m.term_w < HINT_COLS {
		return fmt.aprintf("%s\n", rg.render(m.spin, glyph, alloc), allocator = alloc)
	}
	// The hint names the control AND reports the state, so "is it paused or is
	// it just slow?" is answerable from the screen. Colour is not carrying that
	// distinction -- the words are (LIMITATIONS 11.5: never carry meaning in
	// colour alone).
	hint := HINT_PAUSE if m.paused else HINT
	return fmt.aprintf("%s %s\n",
		rg.render(m.spin, glyph, alloc),
		rg.render(m.hint, hint, alloc),
		allocator = alloc)
}

main :: proc() {
	fd := posix.FD(os.fd(os.stdin))
	// install_crash_handlers BEFORE term_enter_raw, not after: term_enter_raw
	// flips raw_active = true before tcsetattr has actually touched the tty,
	// so a crash landing in that window is only recoverable if a handler
	// already exists to catch it (see install_crash_handlers' doc comment).
	rt.install_crash_handlers()
	// Opt IN to the Kitty keyboard protocol's disambiguation flag. The default
	// is {} -- touch nothing -- because the application owns the terminal here,
	// not the framework (rt.run() never enters raw mode itself). With
	// .Disambiguate the terminal stops collapsing Ctrl+I onto Tab, Ctrl+M onto
	// Enter and Ctrl+[ onto Escape, so those become distinguishable keypresses
	// instead of a Legacy_Key_Encoding coin-flip; a terminal that does not
	// speak the protocol ignores the sequence and everything keeps working on
	// the legacy encoding.
	//
	// Deliberately NOT .Report_Event_Types: with event types on, every key
	// arrives twice (press and release), and this update() -- like most
	// straightforward Bubble Tea-shaped apps -- does not filter on
	// Key_Msg.kind, so it would count each keystroke twice. Opting into that
	// is a decision an app makes together with the matching `if key.kind !=
	// .Press { ... }` check.
	//
	// The matching pop is written by rt.term_restore() below, and by the
	// crash-signal path -- exactly once between them, whichever runs.
	//
	// `paste = true` is DECSET 2004, bracketed paste -- the only thing that
	// makes a paste DISTINGUISHABLE from typing, so that update()'s `v.pasted`
	// branch can refuse to run this program's quit binding on pasted text.
	// Bubble Tea enables it by default; RuneTea makes the application own the
	// terminal, so the opt-in belongs here.
	if !rt.term_enter_raw(fd, {kb = {.Disambiguate}, paste = true}) { fmt.eprintln("not a tty"); os.exit(1) }
	defer rt.term_restore()

	src, ok := rt.input_source_from_fd(fd)
	// term_restore BEFORE os.exit: os.exit does not run defers, so the line
	// above never fires on this path and the terminal is left in raw mode with
	// one entry pushed on its Kitty keyboard stack.
	if !ok { rt.term_restore(); fmt.eprintln("bad input source"); os.exit(1) }
	defer rt.input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	// THE ONLY PLACE THE ENVIRONMENT IS READ. rg.default_profile() inspects
	// $NO_COLOR/$TERM/$COLORTERM once and caches; every Style built afterwards
	// carries a COPY of the answer, so nothing downstream can be surprised by a
	// re-detection.
	//
	// WHAT .None ACTUALLY DOES, because this comment used to claim that under
	// it "both Styles below render their input byte for byte" and that is true
	// of exactly ONE of them. .None strips COLOUR; it does not strip
	// ATTRIBUTES (docs/LIMITATIONS.md 7.11). m.spin is colour only, so under
	// $NO_COLOR it really does come out as the bare glyph. m.hint is
	// rg.faint(), which is SGR 2 -- an attribute, not a colour -- and it
	// survives. Captured on a real pty with NO_COLOR=1 set, every frame:
	//     ⠋ \e[2mLoading... 'p' pauses, 'q' quits\e[0m
	// That is 8 bytes of SGR per frame, ~10 times a second, on a terminal that
	// was asked for no styling. It is the documented behaviour rather than a
	// bug -- an app that wants genuinely plain text must not set attributes --
	// but the previous claim would have had a reader believe $NO_COLOR is a
	// plain-text switch, and it is not.
	m: Model
	m.spin = rg.new_style()
	rg.fg(&m.spin, rg.color("#7D56F4"))
	m.hint = rg.new_style()
	rg.faint(&m.hint, true)

	p: rt.Program(Model)
	// The FIRST tick, fired before any keypress -- exactly the same "an app
	// whose first action is asynchronous must still show its loading state
	// immediately" property init_cmd exists for (examples/http's own
	// comment), here animating from frame 0 the instant the program starts
	// rather than waiting for a keypress to kick off the first frame.
	// `animating` is set to match: the init Cmd IS the first outstanding Tick,
	// so a Model that said false here would let the very first
	// Window_Size_Msg issue a second one and double the frame rate.
	m.animating = true

	// THE USER'S MOTION PREFERENCE, honoured before the first frame rather than
	// after it. $RUNETEA_REDUCE_MOTION is advisory -- rt cannot know what less
	// motion means for a given animation (see rt.A11y_Prefs) -- so this program
	// decides, and it decides the strongest reading: START PAUSED, at a quarter
	// of the frame rate if resumed. Nothing moves until the user asks it to,
	// which is what WCAG 2.2.2 is actually about, and the hint on screen tells
	// them the key.
	//
	// NOTE that the init Cmd is issued either way. It fires once, the
	// Spin_Tick_Msg branch sees m.paused and declines to reissue, and the
	// program settles at frame 1 having moved exactly one step. Suppressing the
	// init Cmd instead would leave the program with NOTHING outstanding and no
	// first paint until a keypress, which is worse.
	m.interval = FRAME_INTERVAL
	if rt.reduce_motion() {
		m.paused   = true
		m.interval = 4 * FRAME_INTERVAL
	}

	rt.program_init(&p, m, update, view, spin_tick_cmd(m.interval))
	// A Window_Size_Msg only ever arrives on a SIGWINCH, so without this seed a
	// program that is never resized would never learn its own size.
	if w, h, ok := rt.term_size(fd); ok { p.model.term_w, p.model.term_h = w, h }

	// flush_fd = the tty, so each frame reaches the screen as it is rendered.
	err := rt.run(&p, &src, &b, fd)
	// term_restore FIRST, then the message, then a real exit status: printing
	// before the restore writes the diagnostic into whatever mode the program
	// left the terminal in, and falling off the end of main after an error
	// exits 0, which makes a crash indistinguishable from a clean quit.
	if err != nil {
		rt.term_restore()
		fmt.eprintln("error:", err)
		os.exit(rt.exit_code(err))
	}
}
