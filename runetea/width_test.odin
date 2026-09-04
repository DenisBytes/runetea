#+private
// ^ Every declaration in this file is package-private, so that `odin doc
//   runetea` / `odin doc runegloss` -- the command README.md and docs/API.md
//   hand a newcomer for symbol discovery -- lists the library rather than the
//   test fixtures. Pinned by tools/doccheck/run.sh's `apidoc` check, which is
//   also where the argument for it is written out.
package runetea

import "core:testing"

@(test)
test_display_width_ascii_matches_byte_length :: proc(t: ^testing.T) {
	testing.expect_value(t, display_width("hello"), 5)
	testing.expect_value(t, display_width(""), 0)
}

@(test)
test_display_width_cjk_is_two_per_rune_not_byte_length :: proc(t: ^testing.T) {
	// "日本語" is 9 BYTES (3 runes x 3 bytes each) but 6 COLUMNS (3 runes x 2
	// columns each). A naive byte-length or rune-count measure gets both of
	// these wrong; this is also the exact string the design spec's defect 1
	// uses to describe grapheme.odin:155's byte-as-width slicing bug -- if
	// this test ever reads the iterator's buggy `text` field instead of the
	// byte-span reconstruction, it corrupts (invalid UTF-8) long before
	// reaching a wrong number.
	s := "日本語"
	testing.expect_value(t, len(s), 9)
	testing.expect_value(t, display_width(s), 6)
}

@(test)
test_display_width_vs16_forces_emoji_presentation_width_2 :: proc(t: ^testing.T) {
	// Defect 2: U+2764 HEAVY BLACK HEART alone measures 1 (its East Asian
	// Width table entry). Followed by U+FE0F VARIATION SELECTOR-16 it must
	// measure 2 -- every terminal and both Go width libraries render the
	// VS16 form as a full-width colored heart emoji, not a width-1 glyph.
	heart_only := "❤"           // HEAVY BLACK HEART, no selector
	heart_vs16 := "❤️"     // + VARIATION SELECTOR-16
	testing.expect_value(t, display_width(heart_only), 1)
	testing.expect_value(t, display_width(heart_vs16), 2)
}

@(test)
test_display_width_regional_indicator_pair_is_a_width_2_flag :: proc(t: ^testing.T) {
	// Defect 3: U+1F1EF U+1F1F5 (Regional Indicator J, Regional Indicator P)
	// is the Japan flag emoji "🇯🇵" -- one grapheme cluster, must measure 2.
	// tables.odin puts the whole RI block at east-asian-width 1, and the
	// grapheme iterator only ever adds width for the FIRST rune of a
	// cluster, so uncorrected this measures 1.
	flag := "\U0001F1EF\U0001F1F5"
	testing.expect_value(t, display_width(flag), 2)
}

@(test)
test_display_width_lone_regional_indicator_is_left_alone :: proc(t: ^testing.T) {
	// A single trailing RI (no pairing partner) is NOT a flag and must not
	// be force-corrected to 2 -- only genuine pairs are.
	lone := "\U0001F1EF"
	testing.expect_value(t, display_width(lone), 1)
}

@(test)
test_display_width_leading_combining_mark_is_zero_width :: proc(t: ^testing.T) {
	// Defect 4: normalized_east_asian_width(r) returns 1, not 0, for any
	// r <= 0x10FF (early-return bug), which includes combining marks. GB1
	// forces even a leading combining mark (nothing to combine with) to open
	// its own degenerate cluster, so an uncorrected leading mark measures 1.
	// U+0301 COMBINING ACUTE ACCENT.
	testing.expect_value(t, display_width("́"), 0)
}

@(test)
test_display_width_combining_mark_after_base_rune_stays_zero_width :: proc(t: ^testing.T) {
	// The common case (not the narrow defect-4 edge case): "e" + COMBINING
	// ACUTE ACCENT is one 2-rune cluster and was already correct going in --
	// the grapheme iterator only adds width for the rune that OPENS a
	// cluster, and an Extend rune (the combining mark) never opens one, so
	// its own (buggy) width-1 is structurally never added.
	testing.expect_value(t, display_width("é"), 1)
}

@(test)
test_display_width_ambiguous_defaults_to_narrow :: proc(t: ^testing.T) {
	// U+00B1 PLUS-MINUS SIGN is East_Asian_Width=Ambiguous. Default options
	// (ambiguous_is_wide=false) match core:unicode's own folding and xterm's
	// default: narrow.
	testing.expect_value(t, display_width("±"), 1)
}

@(test)
test_display_width_ambiguous_is_wide_opts_in_to_width_2 :: proc(t: ^testing.T) {
	testing.expect_value(t, display_width("±", Width_Options{ambiguous_is_wide = true}), 2)
	// A genuinely Narrow rune (not Ambiguous) must NOT be widened by the flag.
	testing.expect_value(t, display_width("a", Width_Options{ambiguous_is_wide = true}), 1)
}

@(test)
test_is_ambiguous_width_table_lookup :: proc(t: ^testing.T) {
	testing.expect(t, is_ambiguous_width(0x00B1), "PLUS-MINUS SIGN should be Ambiguous")
	testing.expect(t, !is_ambiguous_width('a'), "ASCII letter must not be Ambiguous")
}

// ---------------------------------------------------------------------------
// F25: how wide a multi-rune cluster is, is a property of the TERMINAL.
//
// The numbers in the first column below are a transcript, not a preference. A
// live VTE 2.91 (python3-gi Vte.Terminal, 60 columns, offscreen) was calibrated
// on "abcdefg" -> 7 and "中文" -> 4, then fed one cluster per frame with
// get_cursor_position() read back after each. Four of ten disagreed with this
// file's only answer, in BOTH directions -- so there is no single number to
// switch to, and the point of the fix is that the disagreement is now
// SELECTABLE and therefore DETECTABLE, not that it is resolved. See
// Emoji_Width.
// ---------------------------------------------------------------------------

@(private = "file")
Emoji_Case :: struct {
	s:       string,
	vte:     int,   // measured: VTE 2.91's cursor advance
	cluster: int,   // this file's default policy, .Grapheme_Cluster
}

@(private = "file")
EMOJI_CASES := [?]Emoji_Case{
	{"abc",                              3, 3},
	{"中文字",                            6, 6},
	{"\U0001F44D",                       2, 2},   // thumbs up, no modifier
	{"\U0001F44D\U0001F3FD",             4, 2},   // + skin-tone modifier
	{"\U0001F1EF\U0001F1F5",             2, 2},   // regional-indicator flag
	{"\U0001F468\u200D\U0001F4BB",       4, 2},   // ZWJ pair
	{"\U0001F468\u200D\U0001F469\u200D\U0001F467\u200D\U0001F466", 8, 2},   // ZWJ family
	{"1\uFE0F\u20E3",                    1, 2},   // keycap
	{"\u2764\uFE0F",                     1, 2},   // heart + VS16
	{"\u2764",                           1, 1},   // heart, no VS16
}

@(test)
test_display_width_legacy_wcwidth_matches_a_measured_vte :: proc(t: ^testing.T) {
	legacy := Width_Options{emoji_width = .Legacy_Wcwidth}
	for c in EMOJI_CASES {
		testing.expectf(t, display_width(c.s, legacy) == c.vte,
			"%q under .Legacy_Wcwidth: got %d, VTE 2.91 advances %d",
			c.s, display_width(c.s, legacy), c.vte)
	}
}

@(test)
test_display_width_emoji_policy_defaults_to_the_cluster_answer :: proc(t: ^testing.T) {
	// The zero value must be exactly what this file answered before the field
	// existed -- every application that pads correctly today does so BECAUSE it
	// pads to these numbers, and a default that moved would re-rag every box on
	// the terminals that were already right.
	explicit := Width_Options{emoji_width = .Grapheme_Cluster}
	for c in EMOJI_CASES {
		testing.expectf(t, display_width(c.s) == c.cluster,
			"%q under default options: got %d, want %d", c.s, display_width(c.s), c.cluster)
		testing.expect_value(t, display_width(c.s, explicit), c.cluster)
	}
	testing.expect_value(t, Width_Options{}.emoji_width, Emoji_Width.Grapheme_Cluster)
}

@(test)
test_legacy_wcwidth_zeroes_the_marks_east_asian_width_calls_narrow :: proc(t: ^testing.T) {
	// THE ONE THING A RAW SUM OF normalized_east_asian_width WOULD GET WRONG.
	// That proc early-outs `r <= 0x10FF -> 1` and knows nothing about combining
	// marks, so it answers 1 for U+FE0F and 1 for U+20E3; summing it unfiltered
	// would make the keycap 3 columns wide, worse than the policy it replaces.
	legacy := Width_Options{emoji_width = .Legacy_Wcwidth}
	testing.expect_value(t, display_width("1\uFE0F\u20E3", legacy), 1)   // Mn + Me both zero
	testing.expect_value(t, display_width("e\u0301", legacy), 1)         // ordinary combining acute
	testing.expect_value(t, display_width("\u200D", legacy), 0)          // ZWJ, already 0 from the table
}

@(test)
test_legacy_wcwidth_still_honours_ambiguous_is_wide :: proc(t: ^testing.T) {
	// The two policies are orthogonal: one says how a cluster is decomposed,
	// the other says what an Ambiguous rune costs. Under .Legacy_Wcwidth the
	// Ambiguous test is applied per rune, because the rune is what this policy
	// says the terminal is measuring.
	both := Width_Options{emoji_width = .Legacy_Wcwidth, ambiguous_is_wide = true}
	testing.expect_value(t, display_width("±", both), 2)
	testing.expect_value(t, display_width("±±", both), 4)
	testing.expect_value(t, display_width("a", both), 1)
	// And a rune that is NOT Ambiguous is untouched by it: U+2764 is Neutral,
	// so the heart stays 1 under both flags at once.
	testing.expect_value(t, display_width("\u2764\uFE0F", both), 1)
}

@(test)
test_cluster_next_reports_the_policy_width_over_an_unchanged_boundary :: proc(t: ^testing.T) {
	// THE BOUNDARY IS THE SAME UNDER BOTH POLICIES; only the total moves. That
	// is what lets RuneGloss ask the iterator where to cut and the options what
	// to pad to, without the two being able to disagree.
	fam :: "\U0001F468\u200D\U0001F469\u200D\U0001F467\u200D\U0001F466"
	for opts in ([]Width_Options{{}, {emoji_width = .Legacy_Wcwidth}}) {
		ci := cluster_iter_make(fam, opts)
		span, w, ok := cluster_next(&ci)
		testing.expect(t, ok, "the family emoji is one cluster")
		testing.expect_value(t, span, fam)
		testing.expect_value(t, w, opts.emoji_width == .Legacy_Wcwidth ? 8 : 2)
		testing.expect_value(t, ci.col, w)
		_, _, more := cluster_next(&ci)
		testing.expect(t, !more, "and there is no second cluster")
	}
}

@(test)
test_measure_line_wraps_by_the_emoji_policy :: proc(t: ^testing.T) {
	// The policy has to reach the ROW COUNT, not just the total, or an .Inline
	// frame's rewind goes out of step on exactly the terminals the policy is
	// selected for. Two skin-tone thumbs on a 4-column terminal: 2 columns each
	// under the default (one row, flush), 4 columns each under .Legacy_Wcwidth
	// (the second wraps).
	two :: "\U0001F44D\U0001F3FD\U0001F44D\U0001F3FD"
	legacy := Width_Options{emoji_width = .Legacy_Wcwidth}
	testing.expect_value(t, rows_for_line(two, 4), 1)
	testing.expect_value(t, rows_for_line(two, 4, legacy), 2)
	testing.expect_value(t, measure_line("\U0001F468\u200D\U0001F4BB", 10, legacy).end_col, 4)
	testing.expect_value(t, measure_line("\U0001F468\u200D\U0001F4BB", 10).end_col, 2)
}

// ---------------------------------------------------------------------------
// T2-A part 1: ANSI escape sequences are ZERO WIDTH.
//
// This was a live defect, not a missing feature: display_width counted an
// escape's bytes as content, so rows_for_line over-counted rows for any styled
// line, so Renderer.last_rows over-counted, so the NEXT frame's rewind ate
// rows it never painted. Exactly the failure class
// docs/superpowers/render-width-decision.md §1 reproduced under a pty, reached
// by a second route. Measured before the fix on this toolchain:
// display_width("\e[7mX\e[0m") == 7 (the two ESC bytes themselves already
// measured 0; the remaining seven printable bytes each measured 1).
// ---------------------------------------------------------------------------

@(test)
test_display_width_ignores_sgr_escapes :: proc(t: ^testing.T) {
	// The headline case. One visible glyph wrapped in reverse-video on/off.
	testing.expect_value(t, display_width("\e[7mX\e[0m"), 1)
	// A styled string must measure exactly the same as its unstyled twin --
	// stated as an equality so the expectation cannot drift from the plain
	// measurement it is supposed to match.
	testing.expect_value(t, display_width("\e[1;31mhello\e[0m"), display_width("hello"))
	// A parameterless CSI ("\e[m" -- SGR reset, no params at all) followed by
	// two ordinary letters. ECMA-48: params 0x30-0x3F, intermediates
	// 0x20-0x2F, final 0x40-0x7E, so 'm' here is the FINAL byte and "ax" is
	// content.
	testing.expect_value(t, display_width("\e[max"), 2)
	testing.expect_value(t, display_width("a\e[2Kb"), 2)
	testing.expect_value(t, display_width("a\e[?25lb"), 2)   // '?' is a private param byte
}

@(test)
test_display_width_ignores_nested_and_repeated_escapes :: proc(t: ^testing.T) {
	// Several sequences, adjacent and interleaved, including empty runs
	// between them -- the segment loop must not double-count or skip a
	// boundary byte when two escapes touch.
	s := "\e[1m\e[4m\e[38;5;196mred\e[39m\e[24m\e[22m"
	testing.expect_value(t, display_width(s), 3)
	testing.expect_value(t, display_width("\e[1m\e[1m\e[1m"), 0)
	testing.expect_value(t, display_width("a\e[1mb\e[0mc"), 3)
}

@(test)
test_display_width_ignores_osc_hyperlinks :: proc(t: ^testing.T) {
	// OSC 8 hyperlink: ESC ] 8 ; ; <uri> ST  <text>  ESC ] 8 ; ; ST.
	// The URI is inside the escape and must contribute nothing -- an OSC 8
	// link is the single worst case for the old code, because the URI is
	// arbitrarily long and entirely invisible.
	st_form  := "\e]8;;https://example.com\e\\link\e]8;;\e\\"
	bel_form := "\e]8;;https://example.com\alink\e]8;;\a"      // BEL-terminated, the other legal form
	testing.expect_value(t, display_width(st_form), 4)
	testing.expect_value(t, display_width(bel_form), 4)
	// A window-title OSC, the other common one.
	testing.expect_value(t, display_width("\e]0;my title\ax"), 1)
}

@(test)
test_display_width_escape_adjacent_to_a_wide_rune :: proc(t: ^testing.T) {
	// The escape must not disturb the grapheme iterator's byte-span
	// reconstruction (defect 1) for the runes around it. Note "日" is 3 bytes
	// / 2 columns, so a byte-length measure and a width measure differ on
	// BOTH sides of the escape.
	testing.expect_value(t, display_width("\e[7m日\e[0m"), 2)
	testing.expect_value(t, display_width("日\e[0m本"), 4)
	// And with a corrected cluster (defect 2's VS16 heart) straddling nothing:
	// the escape splits the string into segments, and each segment is measured
	// on its own, so a correction that keys off the FIRST rune of a segment
	// must still fire.
	testing.expect_value(t, display_width("\e[31m❤️\e[0m"), 2)
	testing.expect_value(t, display_width("\e[31m\U0001F1EF\U0001F1F5\e[0m"), 2)
}

@(test)
test_display_width_unterminated_escape_is_zero_width :: proc(t: ^testing.T) {
	// CHOICE, stated because it is a choice: an escape sequence that runs off
	// the end of the string is treated as ZERO WIDTH (everything from the ESC
	// to end-of-string is consumed and contributes nothing), not as literal
	// text. Rationale: an unterminated escape is a truncated one, and the
	// terminal will consume the missing tail from whatever is written NEXT --
	// it never renders those bytes as glyphs. Measuring them as content would
	// reintroduce exactly the over-count this whole fix removes, on the one
	// input where a mistake is most likely (a view truncated mid-style).
	testing.expect_value(t, display_width("ab\e[3"), 2)      // CSI, no final byte
	testing.expect_value(t, display_width("ab\e["), 2)
	testing.expect_value(t, display_width("ab\e"), 2)        // bare trailing ESC
	testing.expect_value(t, display_width("ab\e]8;;http://x"), 2)   // OSC, no ST/BEL
	// A MALFORMED CSI mid-string is NOT swallowed to the end: the scan stops
	// at the first byte that cannot belong to a CSI (here the 'y' is a final
	// byte, so that one terminates normally; the second case's 0x07 is not a
	// param, intermediate or final byte, so measurement resumes AT it).
	testing.expect_value(t, display_width("\e[1yZ"), 1)
	testing.expect_value(t, display_width("\e[1\aZ"), 1)     // BEL is not a CSI final; 'Z' still counts
}

@(test)
test_display_width_two_byte_and_string_escapes :: proc(t: ^testing.T) {
	// Two-byte Fe/Fs escapes: ESC M (reverse index), ESC 7 / ESC 8 (save /
	// restore cursor).
	testing.expect_value(t, display_width("a\eMb"), 2)
	testing.expect_value(t, display_width("\e7x\e8"), 1)
	// nF escapes carry intermediates before the final byte: ESC ( B selects
	// the ASCII charset and is THREE bytes. A strict "ESC + one byte" rule
	// would leave the 'B' behind and over-count by one.
	testing.expect_value(t, display_width("\e(Bx"), 1)
	// DCS/APC/PM/SOS are ST-terminated strings like OSC -- notably the Kitty
	// graphics protocol's APC payload, which is base64 and arbitrarily long.
	testing.expect_value(t, display_width("\e_Gf=100,a=T;AAAA\e\\x"), 1)
	testing.expect_value(t, display_width("\ePq#0;2;0;0;0\e\\x"), 1)
}

// THE REGRESSION TEST FOR THE ACTUAL BUG: the row count, not the width.
// A styled line and its unstyled twin must occupy the same number of physical
// rows. Before the fix the styled form measured 8 columns wider (the two SGR
// sequences' printable bytes) and tipped over the wrap boundary.
@(test)
test_rows_for_line_styled_line_matches_the_identical_unstyled_line :: proc(t: ^testing.T) {
	plain  := "0123456789012345678"                 // 19 columns -- 1 row at width 20
	styled := "\e[7m0123456789012345678\e[0m"        // same 19 columns, 27 bytes
	testing.expect_value(t, len(styled), 27)
	testing.expect_value(t, display_width(styled), display_width(plain))
	testing.expect_value(t, rows_for_line(styled, 20, {}), rows_for_line(plain, 20, {}))
	testing.expect_value(t, rows_for_line(styled, 20, {}), 1)   // NOT 2 -- the pre-fix answer

	// And at a width where the content genuinely DOES wrap, both still agree
	// -- the fix must not simply clamp everything to one row.
	long_plain  :: "0123456789012345678901234567890123456789"   // 40 columns
	long_styled :: "\e[1;32m" + long_plain + "\e[0m"
	testing.expect_value(t, rows_for_line(long_plain, 20, {}), 2)
	testing.expect_value(t, rows_for_line(long_styled, 20, {}), 2)
}

@(test)
test_rows_for_line_unknown_width_is_always_one_row :: proc(t: ^testing.T) {
	// term_width <= 0 means "unknown" and must never divide by zero or guess
	// -- it degrades to the renderer's pre-fix behavior (1 row per logical
	// line), regardless of how wide the content actually is.
	testing.expect_value(t, rows_for_line("a very long line that would wrap on any real terminal", 0, {}), 1)
	testing.expect_value(t, rows_for_line("", 0, {}), 1)
	testing.expect_value(t, rows_for_line("x", -5, {}), 1)
}

@(test)
test_rows_for_line_wraps_at_known_width :: proc(t: ^testing.T) {
	// "Hi. This program will exit on 'q'." is 34 columns (all ASCII, width ==
	// byte length). At 20 columns that is ceil(34/20) = 2 physical rows --
	// this is the exact string and width from the pty reproduction.
	line := "Hi. This program will exit on 'q'."
	testing.expect_value(t, len(line), 34)
	testing.expect_value(t, rows_for_line(line, 20, {}), 2)
	// Exactly one terminal width's worth of content is still 1 row (a
	// terminal defers the wrap until something MORE is written).
	testing.expect_value(t, rows_for_line("12345678901234567890", 20, {}), 1)
	// An empty line is still exactly 1 row, at any known width.
	testing.expect_value(t, rows_for_line("", 20, {}), 1)
}

@(test)
test_rows_for_line_wide_runes_wrap_earlier_than_byte_length_suggests :: proc(t: ^testing.T) {
	// 6 CJK runes = 18 bytes but 12 COLUMNS. At a 10-column terminal that is
	// ceil(12/10) = 2 rows -- a byte-length-based (or rune-count-based)
	// measure would both get this wrong in the OPPOSITE direction from the
	// ASCII case (undercounting rows for wide content, not overcounting).
	line := "日本語日本語"
	testing.expect_value(t, len(line), 18)
	testing.expect_value(t, rows_for_line(line, 10, {}), 2)
}

// ---------------------------------------------------------------------------
// F04: THE HORIZONTAL TAB, which used to measure zero.
//
// \t is a C0 control and normalized_east_asian_width returns 0 for every
// control, so a tab contributed nothing to display_width and therefore nothing
// to rows_for_line. Measured before the fix on this toolchain:
// display_width("id\tname\tstatus") == 12, against the 22 columns a terminal
// actually paints. Under .Inline -- the ZERO-VALUE mode, and the one four of
// the five shipped examples use -- that under-count became Renderer.last_rows,
// the next frame rewound one row too few, and the frame walked one row down the
// screen every frame forever with a complete stale copy left above it.
// ---------------------------------------------------------------------------

@(test)
test_display_width_tab_advances_to_the_next_tab_stop :: proc(t: ^testing.T) {
	// A tab at the left margin spans the whole first stop.
	testing.expect_value(t, display_width("\t"), 8)
	// ...and one at column 7 spans a single column: the width is a property of
	// WHERE the tab is, which is the whole reason start_col exists.
	testing.expect_value(t, display_width("1234567\t"), 8)
	// Exactly on a stop, the tab still moves -- HT is "advance to the NEXT
	// stop", not "align to a stop", so a tab at column 8 lands on 16 and never
	// on 8. Getting this wrong is a zero-width tab by another route.
	testing.expect_value(t, display_width("12345678\t"), 16)
	testing.expect_value(t, display_width("id\tname\tstatus"), 22)   // was 12
	// start_col says which column the measurement assumes.
	testing.expect_value(t, display_width("\t", Width_Options{start_col = 3}), 5)
	testing.expect_value(t, display_width("\t", Width_Options{start_col = 8}), 8)
	// Every OTHER C0 byte is still zero width and still a contract violation --
	// \t is the one with a defined column effect, not the thin end of a wedge.
	testing.expect_value(t, display_width("a\rb"), 2)
	testing.expect_value(t, display_width("a\x08b"), 2)
}

@(test)
test_display_width_tab_composition_holds_only_through_start_col :: proc(t: ^testing.T) {
	// THE LAW THAT NO LONGER HOLDS, asserted as an inequality so nobody
	// "restores" it by accident: a tab's width depends on its column, so
	// display_width is not additive over concatenation.
	whole := display_width("ab\tcd")
	naive := display_width("ab") + display_width("\tcd")
	testing.expect_value(t, whole, 10)
	testing.expect_value(t, naive, 12)
	testing.expect(t, whole != naive, "a tab makes display_width non-additive; that is the point of start_col")

	// THE LAW THAT DOES HOLD, and the one Width_Options.start_col documents.
	w1 := display_width("ab")
	w2 := display_width("\tcd", Width_Options{start_col = w1})
	testing.expect_value(t, w1 + w2, whole)
}

@(test)
test_display_width_tab_stop_is_configurable_and_can_be_disabled :: proc(t: ^testing.T) {
	// An app whose content uses 4-column tabs (examples/editor's TAB_WIDTH)
	// says so rather than pre-expanding.
	testing.expect_value(t, display_width("\t", Width_Options{tab_stop = 4}), 4)
	testing.expect_value(t, display_width("ab\t", Width_Options{tab_stop = 4}), 4)
	// NEGATIVE restores the pre-fix "a tab is a zero-width control" reading,
	// for a caller measuring a string whose tabs were already expanded.
	testing.expect_value(t, display_width("id\tname\tstatus", Width_Options{tab_stop = -1}), 12)
	// 0 is not "disabled", it is "unset" -> TAB_STOP_DEFAULT.
	testing.expect_value(t, display_width("\t", Width_Options{tab_stop = 0}), TAB_STOP_DEFAULT)
}

@(test)
test_display_width_tab_column_threads_across_an_escape :: proc(t: ^testing.T) {
	// The escape pre-pass measures segment by segment. If each segment restarted
	// its column at zero the escape would become VISIBLE to the measurement for
	// exactly one byte value: the tab below would answer 8 (a fresh margin)
	// instead of the 7 the terminal advances from column 1.
	//
	// "a" = 1, tab 1->8, "b" = 1  =>  9.
	testing.expect_value(t, display_width("a\e[0m\tb"), 9)
	// The unstyled twin must agree, which is the invariant T2-A established for
	// every other byte and which the tab must not be allowed to break.
	testing.expect_value(t, display_width("a\e[0m\tb"), display_width("a\tb"))
}

@(test)
test_rows_for_line_a_tabbed_line_no_longer_under_counts_its_rows :: proc(t: ^testing.T) {
	// THE F04 REGRESSION, at the width the audit reproduced it at. "id\tname\t
	// status" paints 22 columns on a 20-column terminal -- two physical rows.
	// Pre-fix it measured 12 and answered 1, so .Inline rewound one row too few
	// and slid down the screen one row per frame, forever.
	line :: "id\tname\tstatus"
	testing.expect_value(t, rows_for_line(line, 20), 2)   // was 1
	// Wide enough for the expansion and it is genuinely one row -- the fix must
	// not simply inflate every tabbed line.
	testing.expect_value(t, rows_for_line(line, 40), 1)
	// A styled tabbed line agrees with its unstyled twin, as every other line
	// does.
	testing.expect_value(t, rows_for_line("\e[1m" + line + "\e[0m", 20), 2)
}

@(test)
test_rows_for_line_a_tab_never_wraps_past_the_right_margin :: proc(t: ^testing.T) {
	// HT advances to the next tab stop but is CLAMPED to the right margin: it
	// never wraps and never takes a new row. Verified against pyte, the
	// emulator tools/difftest scores this package against:
	//   pyte(4 cols, "\tX")  -> 'X' at column 3, cursor (4, 0)
	// A tab modelled as an unconditional +8 would answer 2 rows here and make
	// .Inline rewind one row too MANY -- the opposite drift, equally permanent.
	testing.expect_value(t, rows_for_line("\tX", 4), 1)
	m := measure_line("\tX", 4)
	testing.expect_value(t, m.end_col, 4)

	// pyte(10 cols, "123456789\tX") -> cursor (10, 0): at column 9 there is no
	// stop left, so the tab does not move at all and 'X' overwrites nothing.
	testing.expect_value(t, rows_for_line("123456789\tX", 10), 1)
	testing.expect_value(t, measure_line("123456789\tX", 10).end_col, 10)

	// pyte(10 cols, "ab\tcd\tef") -> cursor (1, 1). The second tab arrives in
	// the pending-wrap state (column 10) and moves the cursor BACKWARDS to 9,
	// so 'e' overwrites 'd' and only 'f' wraps.
	m2 := measure_line("ab\tcd\tef", 10)
	testing.expect_value(t, m2.rows, 2)
	testing.expect_value(t, m2.end_col, 1)
}

// ---------------------------------------------------------------------------
// F32: measurement and PLACEMENT, which used to be two different rules.
//
// rows_for_line divided display_width by term_width; the text was placed by
// screen_put and by the terminal's own wrapping. Ceil division equals placement
// only when no cluster straddles the right margin, and a wide cluster straddling
// the right margin is exactly the case a terminal treats specially: it is
// written AT the last column with no continuation cell.
// ---------------------------------------------------------------------------

@(test)
test_measure_line_wide_cluster_on_the_right_margin_takes_one_row_not_two :: proc(t: ^testing.T) {
	// "abc界": display_width 5 at 4 columns, so ceil said 2 rows. screen_put
	// writes 界 AT column 3 and clamps the cursor to 4 -- ONE row. The audit's
	// consequence: at 4x2 the view "abc界\nXYZ" had XYZ judged not to fit and
	// never emitted, while "abcd\nXYZ" painted it.
	testing.expect_value(t, display_width("abc界"), 5)
	m := measure_line("abc界", 4)
	testing.expect_value(t, m.rows, 1)          // ceil division said 2
	testing.expect_value(t, m.end_col, 4)
	testing.expect(t, m.fills, "the line ends flush against the margin")
	testing.expect_value(t, rows_for_line("abc界", 4), 1)
	// The narrow twin is unchanged, so this is not a blanket one-row clamp.
	testing.expect_value(t, rows_for_line("abcd", 4), 1)
	testing.expect_value(t, rows_for_line("abcde", 4), 2)
}

@(test)
test_measure_line_caret_row_case_from_the_audit :: proc(t: ^testing.T) {
	// 40x8, line 0 = "x" + 20 CJK. display_width 41, ceil says 2 rows, and the
	// renderer emitted "\e[2;1H" for line 1 but "\e[3;1H" for the caret -- the
	// caret one row below the line it belongs to. The 20th CJK cluster is
	// written at column 39 and the cursor clamps to 40: ONE row.
	line := "x日日日日日日日日日日日日日日日日日日日日"
	testing.expect_value(t, display_width(line), 41)
	m := measure_line(line, 40)
	testing.expect_value(t, m.rows, 1)
	testing.expect_value(t, m.end_col, 40)
	testing.expect(t, m.fills, "a wide cluster at the last column still fills the row")
}

@(test)
test_measure_line_agrees_with_ceil_division_when_nothing_straddles :: proc(t: ^testing.T) {
	// The regression guard in the other direction: for every line with no tab
	// and no margin-straddling wide cluster, the new placement walk must return
	// exactly what the old ceil division returned. These are the cases the
	// existing render tests are pinned on.
	cases := []struct{ line: string, w: int, rows: int, fills: bool }{
		{"",                                   20, 1, false},
		{"Hi. This program will exit on 'q'.", 20, 2, false},
		{"12345678901234567890",               20, 1, true },
		{"123456789012345678901",              20, 2, false},
		{"日本語日本語",                          10, 2, false},
		{"日本語日本語",                          12, 1, true },
		{"\e[7m0123456789012345678\e[0m",      20, 1, false},
	}
	for c in cases {
		m := measure_line(c.line, c.w)
		testing.expectf(t, m.rows == c.rows, "%q at %d: rows %d, want %d", c.line, c.w, m.rows, c.rows)
		testing.expectf(t, m.fills == c.fills, "%q at %d: fills %v, want %v", c.line, c.w, m.fills, c.fills)
	}
}

@(test)
test_measure_line_unknown_width_reports_no_rows_and_no_fill :: proc(t: ^testing.T) {
	// Same "do not guess" rule rows_for_line has always stated: with no width
	// there is no wrapping and nothing to be flush with. end_col is still
	// useful (it is start_col + display_width), which is why it is not zeroed.
	m := measure_line("a very long line that would wrap on any real terminal", 0)
	testing.expect_value(t, m.rows, 1)
	testing.expect(t, !m.fills, "unknown width cannot be flush with a margin")
	testing.expect_value(t, m.end_col, display_width("a very long line that would wrap on any real terminal"))
}

// ---------------------------------------------------------------------------
// F46: the corrected cluster walk, now public.
//
// It was @(private = "package"), so the only public measure was whole-string
// display_width and the only correct truncation an application could write was
// an O(n^2) prefix rescan. The recipe people actually reach for -- slice at a
// rune boundary, measure runes -- corrupts every multi-rune cluster: it drops
// VS16, splits a flag pair in half, leaves a dangling ZWJ.
// ---------------------------------------------------------------------------

// The truncate-to-width loop from Cluster_Iter's doc comment, verbatim, so the
// documentation is executable rather than aspirational.
@(private = "file")
truncate_to_width :: proc(line: string, budget: int) -> string {
	ci  := cluster_iter_make(line)
	col := 0
	cut := 0
	for {
		span, w, ok := cluster_next(&ci)
		if !ok { break }
		if col + w > budget { break }
		col += w
		cut += len(span)
	}
	return line[:cut]
}

@(test)
test_cluster_iter_truncates_without_splitting_a_cluster :: proc(t: ^testing.T) {
	// A flag is ONE cluster of width 2 built from two 4-byte runes; a
	// rune-granular truncate at width 1 emits half a flag (which renders as a
	// bare letter-like symbol), and a byte-granular one emits invalid UTF-8.
	flag :: "\U0001F1EF\U0001F1F5"
	testing.expect_value(t, truncate_to_width("ab" + flag, 3), "ab")
	testing.expect_value(t, truncate_to_width("ab" + flag, 4), "ab" + flag)
	// VS16 must not be cut away from its base rune: "❤️" is width 2, "❤" is
	// width 1, and dropping the selector silently changes the glyph.
	testing.expect_value(t, truncate_to_width("a❤️b", 2), "a")
	testing.expect_value(t, truncate_to_width("a❤️b", 3), "a❤️")
	// A wide cluster never half-fits.
	testing.expect_value(t, truncate_to_width("日本語", 3), "日")
	testing.expect_value(t, truncate_to_width("日本語", 4), "日本")
	// A ZWJ family emoji is one cluster; cutting inside it leaves a dangling
	// joiner that renders as separate people.
	fam :: "\U0001F468‍\U0001F469‍\U0001F467"
	testing.expect_value(t, truncate_to_width("x" + fam, 2), "x")
	// Every result measures at most the budget, which is the property the loop
	// exists to guarantee.
	for budget in 0 ..= 8 {
		got := truncate_to_width("a❤️日" + flag, budget)
		testing.expectf(t, display_width(got) <= budget,
			"budget %d: %q measures %d", budget, got, display_width(got))
	}
}

@(test)
test_cluster_iter_col_is_writable_so_a_caller_can_wrap :: proc(t: ^testing.T) {
	// The iterator lays a string out on one unbounded row; a caller that wraps
	// assigns ci.col = 0 and the next tab is measured from the right place.
	// Without that, a tab on the second physical row of a wrapped line would be
	// measured from its column in the unwrapped one -- which is exactly what
	// measure_line's resync exists to prevent.
	ci := cluster_iter_make("\t")
	ci.col = 5
	_, w, ok := cluster_next(&ci)
	testing.expect(t, ok, "one cluster expected")
	testing.expect_value(t, w, 3)          // 5 -> 8
	testing.expect_value(t, ci.col, 8)     // and the column advanced with it
}
