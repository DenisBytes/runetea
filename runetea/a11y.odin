package runetea

import "core:os"

// ACCESSIBILITY PREFERENCES, READ FROM THE ENVIRONMENT BY THE LIBRARY ITSELF.
//
// WHY THIS FILE EXISTS. Before it, nothing in `runetea` consulted the
// environment for an accessibility preference at all: `term_enter_raw` read
// exactly one variable, TERM, and only to decide whether escape sequences were
// supported. There was no RUNETEA_NO_ALT, no reduced-motion flag, no anything.
// So an end user of an application built on RuneTea had NO LEVER -- not a bad
// default they could override, but no override at all -- unless that
// application's author had written one, and none of the five shipped examples
// had. LIMITATIONS 11.2 is that gap.
//
// THE LEVERS ARE THE END USER'S, NOT THE APPLICATION'S, and that is the whole
// design. `no_alt` is ENFORCED: term_enter_raw applies it after the application
// has stated its Term_Opts, so an app that asks for the alternate screen does
// not get it when the user has said no. An accessibility preference that an
// application can quietly ignore is not a preference, it is a suggestion, and
// the entire complaint in 11.2 is that suggestions were all that existed.
//
// `reduce_motion` is the exception and is ADVISORY, because it cannot honestly
// be anything else. RuneTea does not own the application's animation: a spinner
// is an app-scheduled `tick` reissued from `update`, and a clock, a progress bar
// and a live log tail are the same loop. Silently slowing or dropping timer
// fires would break a program that is COUNTING them (2.16 is explicit that
// `every` never bursts catch-up fires for exactly this reason) and would turn a
// correctness guarantee into a surprise. So the library reads the preference,
// exposes it, and uses it in its own examples; deciding what "less motion" means
// for a given animation stays with the code that wrote the animation.
//
// VALUE CONVENTION IS $NO_COLOR'S, deliberately: SET AND NON-EMPTY means on,
// whatever the value. RUNETEA_NO_ALT=0 therefore turns it ON. That reads wrong
// at first and is right on reflection -- it is the convention the ecosystem
// already has, users already know it, and the alternative (parsing "0"/"false"/
// "no") means a user who typed RUNETEA_NO_ALT=off gets the opposite of what they
// asked for. runegloss/color.odin's detect_profile_env makes the same choice for
// the same reason, and this file follows it rather than inventing a second rule
// one library-worth away.
A11y_Prefs :: struct {
	// $RUNETEA_NO_ALT. Never enter the alternate screen, whatever the
	// application asked for. ENFORCED in term_enter_raw.
	//
	// What it buys: the alternate screen is structurally opaque to assistive
	// technology (11.1) and it discards everything painted into it on exit, so
	// a user who wants to scroll back through what an application showed, copy
	// it, or read it with a tool that watches the scrollback has no way to. On
	// a normal screen the frames stay in the terminal's history like any other
	// program's output.
	no_alt: bool,

	// $RUNETEA_INLINE. Force Render_Mode.Inline, whatever the application
	// chose. ENFORCED, at renderer construction in both hosts.
	//
	// SEPARATE FROM no_alt ON PURPOSE, because suppressing the alternate screen
	// does NOT by itself stop a full-screen renderer from owning the terminal:
	// .Full_Screen and .Diff address rows absolutely and clear the screen, so
	// on the NORMAL buffer they overwrite the user's scrollback in place, which
	// is worse than the alternate screen rather than better. A user who wants
	// output that behaves like ordinary program output wants this one; a user
	// who only objects to losing their scrollback on exit wants no_alt. Setting
	// this implies no_alt, since an inline renderer on the alternate screen
	// would paint into a buffer that is discarded.
	inline_only: bool,

	// $RUNETEA_REDUCE_MOTION. ADVISORY -- see this file's header. Read it with
	// reduce_motion() and decide what it means for your own animation; the
	// library never acts on it by itself.
	//
	// WCAG 2.2.2 (Pause, Stop, Hide) asks that automatically-moving content
	// lasting more than five seconds be pausable. A spinner is arguably
	// decorative; the same reissue-from-`update` loop underneath a progress
	// bar, a live log tail or a clock is not.
	reduce_motion: bool,
}

// THE PURE HALF: the whole policy, as a function of three strings, so it can be
// tested without touching the process environment. Split from the lookup for
// exactly the reason runegloss/color.odin splits detect_profile_env from
// detect_profile -- a library whose behaviour depends on the ambient
// environment needs at least one seam where it does not.
a11y_from_env_values :: proc(no_alt, inline_only, reduce_motion: string) -> A11y_Prefs {
	p: A11y_Prefs
	p.no_alt        = no_alt        != ""
	p.inline_only   = inline_only   != ""
	p.reduce_motion = reduce_motion != ""
	// Stated as an implication rather than left to each call site to remember:
	// an .Inline frame painted onto the alternate screen is discarded whole on
	// exit, which is precisely what someone asking for inline output does not
	// want.
	if p.inline_only { p.no_alt = true }
	return p
}

// THE IMPURE HALF: reads the process environment and hands the values to
// a11y_from_env_values. Every string os.get_env returns is freed here.
a11y_from_env :: proc() -> A11y_Prefs {
	na := os.get_env("RUNETEA_NO_ALT",        context.allocator); defer delete(na, context.allocator)
	io := os.get_env("RUNETEA_INLINE",        context.allocator); defer delete(io, context.allocator)
	rm := os.get_env("RUNETEA_REDUCE_MOTION", context.allocator); defer delete(rm, context.allocator)
	return a11y_from_env_values(na, io, rm)
}

// Lazily detected on first read and cached, for the same two reasons
// runegloss's default_profile is: three getenv calls per frame would be absurd,
// and the environment cannot change under a running process in any way that
// matters here.
//
// PROCESS-WIDE MUTABLE STATE, and it is read from term_enter_raw, which is also
// reachable from guard.odin's SIGCONT handler -- where getenv(3) is NOT
// async-signal-safe. That is safe here only because the resume path goes through
// term_acquire with ALREADY-RESOLVED opts (see term_enter_raw), so no lookup
// happens in signal context; the cache is populated on the first, ordinary
// entry. Do not move the lookup below that line.
@(private)
g_a11y: A11y_Prefs
@(private)
g_a11y_known: bool

@(require_results)
a11y_prefs :: proc() -> A11y_Prefs {
	if !g_a11y_known {
		g_a11y = a11y_from_env()
		g_a11y_known = true
	}
	return g_a11y
}

// The override, for an application that offers its own flag -- `--no-alt` on a
// command line should be able to reach the same lever the environment does,
// rather than each application inventing a parallel one that only it honours.
// Also how tests avoid depending on the ambient environment.
set_a11y_prefs :: proc(p: A11y_Prefs) {
	g_a11y = p
	g_a11y_known = true
}

// Forgets the override, so the next a11y_prefs() re-detects.
clear_a11y_prefs :: proc() {
	g_a11y_known = false
}

// Does the user want less motion? ADVISORY -- see A11y_Prefs.reduce_motion.
//
// The pattern this is meant for, and the one examples/spinner now shows: keep
// the tick interval in your model rather than in a constant, seed it from this,
// and bind a key that stops reissuing. Stopping costs nothing -- `tick` hands
// back no handle precisely so that not reissuing it leaks nothing.
@(require_results)
reduce_motion :: proc() -> bool {
	return a11y_prefs().reduce_motion
}
