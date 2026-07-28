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
