package runegloss

import "core:math"
import "core:os"
import "core:strings"

// Colour, terminal colour profiles, and the down-conversion between them.
//
// THE WHOLE POINT OF THIS FILE is that an application names ONE colour --
// "#7D56F4" -- and gets the best thing the terminal in front of it can
// actually show, with no `if` in the application. The alternative (an app
// carrying a truecolour value and a 256 value and a 16 value) is what every
// pre-termenv Go TUI did, and it is why they all looked wrong somewhere.

// What a terminal can render, in ASCENDING capability order. The ordering is
// load-bearing, not cosmetic: degradation is expressed as "convert to at most
// this profile", and several comparisons below rely on `<`.
//
// .None is the ZERO VALUE, and that is deliberate for the same reason
// Render_Mode.Inline is runetea's: a zero-valued Style renders no colour at
// all, so nothing can accidentally emit an escape it was never configured to.
Profile :: enum u8 {
	None,        // no colour escapes at all ($NO_COLOR, TERM=dumb, a pipe)
	ANSI,        // the 16 SGR colours (30-37, 90-97 / 40-47, 100-107)
	ANSI256,     // + the xterm 256-colour palette (38;5;n)
	True_Color,  // + 24-bit RGB (38;2;r;g;b)
}

Color_Kind :: enum u8 {
	None,   // "no colour" -- emits nothing. THE ZERO VALUE.
	ANSI,   // a palette index, 0-255
	RGB,    // 24-bit
}

// POD by construction (no strings, no pointers), so a Color may be embedded in
// a Style, copied freely, and stored in an application's model. Both payload
// representations live side by side rather than in a union because a union
// would make Style's own POD-ness depend on Odin's union layout -- and because
// 4 bytes is not worth a variant tag.
Color :: struct {
	kind:    Color_Kind,
	idx:     u8,   // .ANSI
	r, g, b: u8,   // .RGB
}

// color("#7D56F4") and color(212). An Odin proc group rather than one
// overloaded parameter: Odin has no method chaining and no default-typed
// unions worth the trouble here, and two tiny procs read better at the call
// site than color_hex/color_ansi spelled out everywhere.
color :: proc{color_hex, color_ansi}

// Parses "#RRGGBB" or "#RGB" (the leading '#' optional, hex digits either
// case). ANYTHING ELSE IS "NO COLOUR", not black and not an error: a typo'd
// literal that rendered as black would be far harder to notice than one that
// renders unstyled, and this package has no error channel to report into that
// would not poison every call site.
@(require_results)
color_hex :: proc(hex: string) -> Color {
	s := hex
	if len(s) > 0 && s[0] == '#' { s = s[1:] }

	switch len(s) {
	case 3:
		// CSS nybble doubling: "F0A" is "FF00AA". Doubling (x*17, i.e. x*0x11)
		// rather than left-shifting is what keeps "FFF" pure white -- 0xF<<4
		// would give 0xF0.
		r := hex_nybble(s[0])
		g := hex_nybble(s[1])
		b := hex_nybble(s[2])
		if r < 0 || g < 0 || b < 0 { return Color{} }
		return Color{kind = .RGB, r = u8(r * 17), g = u8(g * 17), b = u8(b * 17)}
	case 6:
		r := hex_byte(s[0:2])
		g := hex_byte(s[2:4])
		b := hex_byte(s[4:6])
		if r < 0 || g < 0 || b < 0 { return Color{} }
		return Color{kind = .RGB, r = u8(r), g = u8(g), b = u8(b)}
	}
	return Color{}
}

// Palette index 0-255. Out of range is "no colour", for the same reason a bad
// hex literal is.
@(require_results)
color_ansi :: proc(idx: int) -> Color {
	if idx < 0 || idx > 255 { return Color{} }
	return Color{kind = .ANSI, idx = u8(idx)}
}

// -1 on a non-hex byte; every caller checks for it before widening to u8.
@(private = "file")
hex_nybble :: proc(c: u8) -> int {
	switch {
	case c >= '0' && c <= '9': return int(c - '0')
	case c >= 'a' && c <= 'f': return int(c - 'a') + 10
	case c >= 'A' && c <= 'F': return int(c - 'A') + 10
	}
	return -1
}

@(private = "file")
hex_byte :: proc(s: string) -> int {
	hi := hex_nybble(s[0])
	lo := hex_nybble(s[1])
	if hi < 0 || lo < 0 { return -1 }
	return hi * 16 + lo
}

// ---------------------------------------------------------------------------
// profile detection
// ---------------------------------------------------------------------------

// THE PURE HALF, and the only one any test ever calls. Detection reduced to a
// function of three strings so that the test suite never depends on the
// ambient environment -- a colour library whose tests pass on the author's
// terminal and fail in CI is the standard failure here, and it is entirely
// avoidable by not reading getenv inside the logic.
//
// THE RULES, in the order they are applied and with the reason each one is
// where it is:
//
//  1. $NO_COLOR non-empty -> .None. FIRST, unconditionally, because
//     https://no-color.org says "when present and not an empty string
//     (REGARDLESS OF ITS VALUE)". NO_COLOR=0 therefore disables colour; reading
//     it as a boolean is the classic misimplementation.
//  2. TERM empty or "dumb" -> .None. No terminal, or one that has told us it
//     understands nothing. Checked before COLORTERM so that a stale COLORTERM
//     inherited by a dumb child cannot promote it.
//  3. $COLORTERM in {truecolor, 24bit} (case-insensitive) -> .True_Color. The
//     de-facto standard flag; no TERM value reliably announces 24-bit.
//  4. TERM containing "256color" -> .ANSI256.
//  5. anything else -> .ANSI. A terminal that announced a name at all does 16
//     colours; there has not been one that did not since the 1980s.
//
// NOT CONSULTED, deliberately: isatty. Whether stdout is a pipe is the
// APPLICATION's business (runetea's own term_enter_raw already fails on a
// non-tty), and a library that silently stripped colour from a program
// deliberately capturing styled output to a file would be the wrong kind of
// clever. An app that wants that calls set_default_profile(.None).
@(require_results)
detect_profile_env :: proc(no_color, colorterm, term: string) -> Profile {
	if no_color != "" { return .None }
	if term == "" || term == "dumb" { return .None }
	if eq_fold(colorterm, "truecolor") || eq_fold(colorterm, "24bit") { return .True_Color }
	if strings.contains(term, "256color") { return .ANSI256 }
	return .ANSI
}

// ASCII case-insensitive compare. core:strings has equal_fold, but it is
// Unicode-aware and allocates in some paths; these are two fixed ASCII tokens.
@(private = "file")
eq_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if x >= 'A' && x <= 'Z' { x += 32 }
		if y >= 'A' && y <= 'Z' { y += 32 }
		if x != y { return false }
	}
	return true
}

// THE IMPURE HALF: reads the process environment once and hands the values to
// detect_profile_env. Every string os.get_env hands back is freed here --
// tools/test.sh's leak audit fails the whole run on any unallowlisted leak
// site, and "the colour library leaked three env strings per process" is
// exactly the kind of thing that would otherwise hide forever.
@(require_results)
detect_profile :: proc() -> Profile {
	nc := os.get_env("NO_COLOR",  context.allocator); defer delete(nc, context.allocator)
	ct := os.get_env("COLORTERM", context.allocator); defer delete(ct, context.allocator)
	tm := os.get_env("TERM",      context.allocator); defer delete(tm, context.allocator)
	return detect_profile_env(nc, ct, tm)
}

// The profile new_style() gives a fresh Style. Lazily detected on first read
// and cached -- getenv three times per Style would be absurd, and the
// environment cannot change under a running process in any way that matters
// here.
//
// PROCESS-WIDE MUTABLE STATE, and the only such state in this package. It is
// deliberately NOT what the render path reads: every Style carries its own
// `profile` field (a copy taken at construction), so a render is a pure
// function of the Style plus the text. This exists only so that the ergonomic
// `new_style()` does the right thing by default. Tests use
// new_style_profile(p) and never touch it.
@(private = "file")
g_profile: Profile
@(private = "file")
g_profile_known: bool

@(require_results)
default_profile :: proc() -> Profile {
	if !g_profile_known {
		g_profile = detect_profile()
		g_profile_known = true
	}
	return g_profile
}

// The override the brief requires: an application (or a test) forcing a
// profile regardless of what the environment says. Affects only Styles created
// AFTER it -- a Style already built keeps the profile it was built with,
// because a Style is a value and nothing else may reach in and change it.
set_default_profile :: proc(p: Profile) {
	g_profile = p
	g_profile_known = true
}

// Forgets the override, so the next default_profile() re-detects.
clear_default_profile :: proc() {
	g_profile_known = false
}

// ---------------------------------------------------------------------------
// the xterm 256 palette, and down-conversion
// ---------------------------------------------------------------------------

// The 16 system colours, as xterm's defaults. THESE ARE NOT FIXED IN REALITY:
// every terminal lets the user retheme 0-15, so the RGB values below are what
// the SPEC says, not necessarily what the user will see. That is why they are
// used for one thing only -- deciding WHICH of the 16 is nearest -- and never
// as a source of truth for the 256-colour step (see nearest_256).
@(private = "file")
BASE16 := [16][3]u8{
	{0x00, 0x00, 0x00}, {0x80, 0x00, 0x00}, {0x00, 0x80, 0x00}, {0x80, 0x80, 0x00},
	{0x00, 0x00, 0x80}, {0x80, 0x00, 0x80}, {0x00, 0x80, 0x80}, {0xC0, 0xC0, 0xC0},
	{0x80, 0x80, 0x80}, {0xFF, 0x00, 0x00}, {0x00, 0xFF, 0x00}, {0xFF, 0xFF, 0x00},
	{0x00, 0x00, 0xFF}, {0xFF, 0x00, 0xFF}, {0x00, 0xFF, 0xFF}, {0xFF, 0xFF, 0xFF},
}

// The 6x6x6 colour cube's per-channel levels. NOT evenly spaced -- the gap
// from 0 to 95 is deliberate in the xterm palette (it buys darker darks), and
// an implementation that used 51*i here would be wrong by up to 44 per channel
// on every single cube colour.
@(private = "file")
CUBE_LEVELS := [6]u8{0, 95, 135, 175, 215, 255}

// The RGB of palette entry `idx`, computed rather than tabulated: 16-231 is the
// cube in strict r,g,b major order, 232-255 is the 24-step grey ramp at
// 8 + 10*i. A 256-row table would be 768 hand-typed bytes with 768 chances to
// contain a typo that no test would ever catch.
@(private = "file")
palette_rgb :: proc(idx: u8) -> (r, g, b: u8) {
	if idx < 16 {
		c := BASE16[idx]
		return c[0], c[1], c[2]
	}
	if idx < 232 {
		i := int(idx) - 16
		return CUBE_LEVELS[i / 36], CUBE_LEVELS[(i / 6) % 6], CUBE_LEVELS[i % 6]
	}
	v := u8(8 + 10 * (int(idx) - 232))
	return v, v, v
}

// Down-converts `c` so that it can be rendered on profile `p`. A colour already
// representable is returned UNCHANGED (byte for byte -- see the pass-through
// tests), which is what keeps truecolour, the common case on any terminal
// written this decade, entirely free of the Lab arithmetic below.
@(require_results)
convert :: proc(c: Color, p: Profile) -> Color {
	// $NO_COLOR's whole contract, in one line and ahead of everything else.
	if p == .None { return Color{} }

	switch c.kind {
	case .None:
		return c
	case .ANSI:
		// 0-15 exist in every profile that has colour at all.
		if c.idx < 16 || p >= .ANSI256 { return c }
		r, g, b := palette_rgb(c.idx)
		return color_ansi(nearest_16(r, g, b))
	case .RGB:
		switch p {
		case .True_Color: return c
		case .ANSI256:    return color_ansi(nearest_256(c.r, c.g, c.b))
		case .ANSI:       return color_ansi(nearest_16(c.r, c.g, c.b))
		case .None:       return Color{}
		}
	}
	return c
}

// WHY CIE76 ΔE OVER CIELAB, and not the obvious alternatives.
//
// Euclidean distance in sRGB -- what a first implementation always reaches for
// -- is perceptually wrong in a way that shows up immediately on a 16-colour
// terminal: it treats a 60-unit shift in blue as the same error as a 60-unit
// shift in green, though the eye is several times more sensitive to green. It
// reliably picks the wrong swatch for mid-tone purples and teals, which is
// most of a modern TUI palette.
//
// CIELAB is designed so that Euclidean distance approximates perceived
// difference, and CIE76 is simply that Euclidean distance. It is a real,
// published, deterministic metric -- not a hand-tuned weighting -- and it needs
// nothing beyond a cube root.
//
// CIEDE2000 is more accurate still, and is NOT used: it is ~40 lines of
// trigonometry with several documented discontinuities, and its improvements
// over CIE76 are concentrated in near-neutral and high-chroma regions at
// separations far finer than the ~2000 ΔE² gaps between adjacent swatches of a
// 256-entry palette. It would change which swatch wins essentially never, and
// every place it did would be a coin-flip between two visually equivalent
// answers.
//
// COST, stated plainly: a 24-bit -> 256 conversion is 240 Lab conversions
// (~720 cube roots) and happens once per coloured Style per render() call. On
// .True_Color -- the default on any terminal that sets COLORTERM -- it happens
// ZERO times, because convert() returns early. If a future profile-degraded
// app ever measures this as hot, the fix is a precomputed Lab table, not a
// worse metric.
@(private = "file")
Lab :: [3]f64

@(private = "file")
to_lab :: proc(r8, g8, b8: u8) -> Lab {
	r := srgb_linear(r8)
	g := srgb_linear(g8)
	b := srgb_linear(b8)

	// sRGB primaries -> CIE XYZ, D65 white point.
	x := 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
	y := 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
	z := 0.0193339 * r + 0.1191920 * g + 0.9503041 * b

	fx := lab_f(x / 0.95047)
	fy := lab_f(y / 1.00000)
	fz := lab_f(z / 1.08883)
	return Lab{116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)}
}

// The sRGB transfer function's INVERSE. The piecewise linear segment near 0 is
// not a rounding detail -- dropping it (using a plain 2.2 gamma) shifts every
// dark colour enough to change which of the 24 grey-ramp entries wins.
@(private = "file")
srgb_linear :: proc(v: u8) -> f64 {
	c := f64(v) / 255.0
	if c <= 0.04045 { return c / 12.92 }
	return math.pow((c + 0.055) / 1.055, 2.4)
}

@(private = "file")
lab_f :: proc(t: f64) -> f64 {
	// 216/24389 and 841/108 are the exact rational forms of the CIE constants
	// (6/29)^3 and (1/3)*(29/6)^2. Spelled as fractions so they cannot be
	// mistyped as truncated decimals.
	if t > 216.0 / 24389.0 { return math.pow(t, 1.0 / 3.0) }
	return (841.0 / 108.0) * t + 4.0 / 29.0
}

@(private = "file")
lab_dist2 :: proc(a, b: Lab) -> f64 {
	dl := a[0] - b[0]
	da := a[1] - b[1]
	db := a[2] - b[2]
	return dl * dl + da * da + db * db
}

// Nearest entry in 16..255 -- the CUBE AND GREY RAMP ONLY, deliberately
// excluding 0-15. Entries 0-15 are whatever the user's colour scheme redefined
// them to (see BASE16), so choosing one would make the same #RRGGBB render as
// a different colour on two terminals that both claim 256-colour support. The
// cube and the ramp are fixed by the palette specification, so the answer is
// theme-independent. termenv makes the same choice for the same reason.
@(private = "file")
nearest_256 :: proc(r, g, b: u8) -> int {
	target := to_lab(r, g, b)
	best, best_d := 16, max(f64)
	for i in 16 ..= 255 {
		pr, pg, pb := palette_rgb(u8(i))
		if d := lab_dist2(target, to_lab(pr, pg, pb)); d < best_d {
			best, best_d = i, d
		}
	}
	return best
}

// Nearest of the 16, where there is no theme-independent option to prefer --
// 0-15 is all a 16-colour terminal has.
@(private = "file")
nearest_16 :: proc(r, g, b: u8) -> int {
	target := to_lab(r, g, b)
	best, best_d := 0, max(f64)
	for i in 0 ..< 16 {
		c := BASE16[i]
		if d := lab_dist2(target, to_lab(c[0], c[1], c[2])); d < best_d {
			best, best_d = i, d
		}
	}
	return best
}
