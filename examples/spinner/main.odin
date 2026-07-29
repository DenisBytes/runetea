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
spin_tick_cmd :: proc() -> rt.Cmd {
	return rt.tick(FRAME_INTERVAL, spin_tick_fn, struct{}{}, context.allocator)
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
}

// `m` is a POINTER: mutate it in place, return only the Cmd. See
// rt.Program.update (runetea/tea.odin).
update :: proc(m: ^Model, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	switch v in msg {
	case rt.Key_Msg:
		if v.code == .Rune && (v.r == 'q' || (v.r == 'c' && .Ctrl in v.mods)) {
			return rt.quit_cmd()
		}
		if v.code == .Escape { return rt.quit_cmd() }
	case Spin_Tick_Msg:
		m.frame = (m.frame + 1) % len(FRAMES)
		return spin_tick_cmd() // reissue -- see spin_tick_cmd's own comment
	}
	return rt.cmd_nil()
}

view :: proc(m: Model, alloc: mem.Allocator) -> string {
	// LOCAL COPIES because rg.render takes a ^Style and `m` is a procedure
	// PARAMETER -- Odin parameters are immutable and not addressable, so `&m.spin`
	// does not compile. Two struct copies per frame, no allocation. (rg.render
	// takes a pointer rather than a value for the same reason its setters do: a
	// Style is ~200 bytes and copying it at every call site would be the one
	// avoidable cost in an otherwise allocation-free API.)
	spin, hint := m.spin, m.hint
	// EVERY string below comes from `alloc` -- the FRAME ARENA rt hands view() --
	// including the ones rg.render allocates, since RuneGloss allocates from the
	// allocator it is passed and from nothing else (runegloss/render.odin).
	// Nothing here is freed by hand because the arena is reclaimed wholesale after
	// the frame (arena.odin's LIFETIME CONTRACT). Note aprintf(allocator = alloc)
	// and NOT tprintf: the temp allocator is a different, process-lifetime arena
	// that this loop never resets.
	glyph := fmt.aprintf("%c", FRAMES[m.frame], allocator = alloc)
	return fmt.aprintf("%s %s\n",
		rg.render(&spin, glyph, alloc),
		rg.render(&hint, "Loading forever... press 'q' to quit", alloc),
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
	if !rt.term_enter_raw(fd, {.Disambiguate}) { fmt.eprintln("not a tty"); os.exit(1) }
	defer rt.term_restore()

	src, ok := rt.input_source_from_fd(fd)
	if !ok { fmt.eprintln("bad input source"); os.exit(1) }
	defer rt.input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	// THE ONLY PLACE THE ENVIRONMENT IS READ. rg.default_profile() inspects
	// $NO_COLOR/$TERM/$COLORTERM once and caches; every Style built afterwards
	// carries a COPY of the answer, so nothing downstream can be surprised by a
	// re-detection. On a terminal that reports nothing (or under $NO_COLOR) the
	// profile is .None and both Styles below render their input byte for byte --
	// this program degrades to exactly the output it had before RuneGloss, with
	// no `if` anywhere in view().
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
	rt.program_init(&p, m, update, view, spin_tick_cmd())

	// flush_fd = the tty, so each frame reaches the screen as it is rendered.
	if err := rt.run(&p, &src, &b, fd); err != nil { fmt.eprintln("error:", err) }
}
