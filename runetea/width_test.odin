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
