package runetea

import "core:unicode"
import "core:unicode/utf8"

// Display width over core:unicode/utf8's grapheme clustering (dev-2026-07-
// nightly:819fdc7, UAX#29 tables pinned to UCD 15.1.0). Segmentation itself
// is correct and verified (spec §11) -- everything here is narrowly working
// around four verified measurement defects, not re-deriving clustering.
// See docs/superpowers/render-width-decision.md for the verification
// evidence behind each one.
//
//  1. grapheme.odin:155 slices the returned cluster by DISPLAY WIDTH USED AS
//     A BYTE COUNT ("it.str[byte_index:][:grapheme.width]"), corrupting any
//     cluster whose rune(s) are >1 byte. The iterator's `text` field is
//     therefore never read anywhere in this file; byte spans are derived
//     from consecutive `byte_index` values instead (see display_width).
//  2. VS16 (U+FE0F) is correctly merged into its base rune's cluster (it is
//     GCB Extend, absorbed under GB9) but contributes no width of its own,
//     so "❤️" (U+2764 U+FE0F) measures 1 -- every terminal and both Go
//     width libraries say 2.
//  3. A regional-indicator PAIR (a flag, e.g. "🇯🇵") is correctly merged
//     into one cluster under GB12/GB13, but only the first RI rune's table
//     width (1, from tables.odin's 0x1F19B-0x1F1FF,1 entry) is ever added,
//     so a flag measures 1 instead of 2. An unpaired trailing RI is left
//     alone -- it is not part of a flag and terminals render it as a plain
//     width-1 letter-like symbol.
//  4. normalized_east_asian_width(r) returns 1, not 0, for a combining mark
//     when that mark is itself the FIRST rune the grapheme iterator ever
//     sees (r <= 0x10FF early-return bug in core:unicode/letter.odin) --
//     GB1 forces even a leading combining mark to open its own (degenerate)
//     cluster, so this is narrow but real for a string that starts mid-
//     cluster. A combining mark following a real base rune never hits this:
//     the iterator only adds width for the rune that OPENS a cluster, and a
//     following Extend rune never opens one.
Width_Options :: struct {
	// East_Asian_Width=Ambiguous runes (curly quotes, box-drawing, Greek,
	// Cyrillic, circled digits, ...) are 1 or 2 columns depending on the
	// terminal/locale -- there is no universally correct answer. Odin's
	// normalized_east_asian_width already folds Ambiguous into the narrow
	// (1) case with no way to ask "was this Ambiguous or genuinely
	// Narrow/Neutral" -- that distinction isn't kept anywhere in
	// core:unicode. ambiguous_width_ranges below is RuneTea's own table,
	// generated from the real UCD 15.1.0 EastAsianWidth.txt (the version
	// core:unicode's own tables are pinned to, for internal consistency),
	// not guessed. Leave false (the default, matching core:unicode and
	// xterm's own default) unless the target terminal/locale is known to
	// render Ambiguous-width runes double-wide.
	ambiguous_is_wide: bool,
}

// display_width returns the number of terminal columns `s` occupies, summing
// each extended grapheme cluster's corrected width. `s` may contain multiple
// clusters (letters, combining sequences, ZWJ emoji, flags); it must not
// contain "\n" if the caller wants per-physical-row semantics -- see
// rows_for_line, which splits on line boundaries itself.
//
// ANSI ESCAPE SEQUENCES ARE ZERO WIDTH (T2-A). This was a LIVE DEFECT, fixed
// here, not a feature that was merely missing: every byte of "\e[7mX\e[0m" but
// the two ESCs used to be measured as content (7 columns for one visible
// glyph; the ESCs themselves already measured 0 because core:unicode's
// normalized_east_asian_width returns 0 for is_control runes). That fed
// rows_for_line, which fed Renderer.last_rows, which drives the rewind -- so
// ANY styled line inflated the row count and desynchronised the next frame's
// rewind. Identical failure class to the one
// docs/superpowers/render-width-decision.md §1 reproduced under a pty, reached
// by a different route.
//
// WHY A BYTE PRE-PASS RATHER THAN A CHECK INSIDE THE CLUSTER LOOP. The
// grapheme iterator's byte-span reconstruction (defect 1 above) is the
// delicate part of this file: it depends on consecutive byte_index values
// closing each other's spans, and inserting a "was that cluster an escape?"
// branch into that loop would mean recomputing spans around skipped regions --
// the one thing this file must not get wrong. Instead the string is split at
// ESC boundaries into escape-free SEGMENTS, and each segment is measured by
// the untouched cluster loop (plain_width below). This is sound on bytes, not
// just on runes, because 0x1B can never occur inside a multi-byte UTF-8
// sequence (every continuation byte is >= 0x80), so a byte-level scan for ESC
// can never split a rune. It is also allocation-free: segments are subslices,
// nothing is copied or stripped into a buffer.
//
// The one behavioural consequence of measuring per segment: a grapheme cluster
// SPLIT BY an escape ("e" + "\e[0m" + U+0301) is measured as two clusters
// rather than one. That is the right answer anyway here -- the second segment
// opens with a nonspacing mark, which defect 4's correction forces to 0, so
// "e\e[0mU+0301" still measures 1, same as "é".
@(require_results)
display_width :: proc(s: string, opts := Width_Options{}) -> int {
	if len(s) == 0 { return 0 }

	total := 0
	seg   := 0   // start of the current escape-free segment
	i     := 0
	for i < len(s) {
		if s[i] != ESC { i += 1; continue }
		total += plain_width(s[seg:i], opts)
		i = skip_escape(s, i)   // always > i, so this loop always advances
		seg = i
	}
	return total + plain_width(s[seg:], opts)
}

@(private = "file")
ESC :: 0x1B
@(private = "file")
BEL :: 0x07

// skip_escape returns the index one past the escape sequence beginning at
// s[start] (which the caller has already checked is ESC). Everything it
// consumes is zero width.
//
// UNTERMINATED ESCAPE AT END OF STRING -> ZERO WIDTH TO THE END, and that is a
// choice. An escape running off the end of the string is a TRUNCATED escape:
// the terminal will consume its missing tail from whatever bytes are written
// next and will never paint those bytes as glyphs, so counting them as content
// would reintroduce exactly the over-count this fix exists to remove -- on the
// input where it is most likely to happen (a view truncated mid-style). The
// opposite choice (measure the fragment as literal text) is only "safer" if
// you believe the terminal will print "\e[3"; it will not.
//
// A MALFORMED escape MID-string is NOT swallowed to the end, though: the CSI
// scan below stops at the first byte that cannot legally belong to a CSI and
// resumes ordinary measurement AT that byte, so one stray "\e[" cannot silently
// zero out the whole rest of a line.
@(private = "file")
skip_escape :: proc(s: string, start: int) -> int {
	i := start + 1
	if i >= len(s) { return len(s) }   // bare trailing ESC

	switch s[i] {
	case '[':
		// CSI: ESC [ P...P I...I F, per ECMA-48 -- parameter bytes 0x30-0x3F,
		// intermediate bytes 0x20-0x2F, final byte 0x40-0x7E. The two ranges
		// are contiguous, so one scan over 0x20-0x3F covers both.
		i += 1
		for i < len(s) && s[i] >= 0x20 && s[i] <= 0x3F { i += 1 }
		if i < len(s) && s[i] >= 0x40 && s[i] <= 0x7E { return i + 1 }
		return i   // truncated (i == len) or malformed: resume measuring here

	case ']', 'P', '^', '_', 'X':
		// The ST-terminated string family: OSC (]), DCS (P), PM (^), APC (_)
		// and SOS (X), all closed by ST ("\e\\") or, by long-standing xterm
		// convention, by BEL. DELIBERATELY WIDER THAN THE OSC-ONLY CASE: the
		// payload of any of these is arbitrary text (an OSC 8 hyperlink's URI,
		// a Kitty-graphics APC base64 blob, a DCS sixel), and measuring THAT as
		// content is the largest over-count this proc can possibly produce --
		// far worse than an SGR's few bytes. Treating them as plain two-byte
		// escapes instead would leave the entire payload to be counted.
		i += 1
		for i < len(s) {
			if s[i] == BEL { return i + 1 }
			if s[i] == ESC {
				if i + 1 < len(s) && s[i + 1] == '\\' { return i + 2 }   // ST
				return i   // a bare ESC inside: end this string here and let
				           // the caller's loop re-dispatch on it
			}
			i += 1
		}
		return len(s)   // unterminated

	case:
		// Everything else: nF escapes (ESC + intermediates 0x20-0x2F + a final
		// byte, e.g. "\e(B" to select ASCII -- THREE bytes, which is why this
		// is not a flat "ESC plus one byte" rule; that would leave the 'B'
		// behind to be counted as content) and the plain two-byte Fe/Fp/Fs
		// escapes ("\eM", "\e7", "\e8"), which simply have no intermediates.
		for i < len(s) && s[i] >= 0x20 && s[i] <= 0x2F { i += 1 }
		if i < len(s) { return i + 1 }
		return len(s)   // unterminated
	}
}

// plain_width is display_width's original body, unchanged, over a segment
// GUARANTEED to contain no ESC. Split out only so the escape pre-pass above
// can call it once per segment without touching a line of the byte-span
// reconstruction below.
@(private = "file")
plain_width :: proc(s: string, opts: Width_Options) -> int {
	if len(s) == 0 { return 0 }

	it := utf8.decode_grapheme_iterator_make(s)
	total := 0

	// One cluster held back at a time: its END (and therefore its correct
	// byte span) is only known once the NEXT cluster's byte_index is read,
	// or the iterator is exhausted (end = len(s)). This is the byte-span
	// reconstruction defect 1 requires -- consecutive byte_index values,
	// never it.text.
	prev_start := -1
	prev_width := 0
	for {
		_, g, ok := utf8.decode_grapheme_iterate(&it)
		if !ok { break }
		if prev_start >= 0 {
			total += corrected_cluster_width(s[prev_start:g.byte_index], prev_width, opts)
		}
		prev_start = g.byte_index
		prev_width = g.width
	}
	if prev_start >= 0 {
		total += corrected_cluster_width(s[prev_start:], prev_width, opts)
	}
	return total
}

// Cap on runes inspected per cluster for the VS16/RI/leading-mark checks
// below. Ordinary text is 1 rune per cluster; even large ZWJ family-emoji
// sequences (e.g. "👨‍👩‍👧‍👦") stay under a dozen. A cluster longer than this
// still gets `base_width` (the iterator's own, already-correct-for-that-
// case total) -- it only loses the defect corrections, which all key off
// runes near the start of the cluster in every real-world case (VS16
// immediately follows its base rune; RI pairs are exactly 2 runes; a
// leading combining mark is rune 0).
@(private = "file")
MAX_INSPECTED_RUNES :: 16

// corrected_cluster_width applies the three targeted overrides (VS16, RI
// pair, leading nonspacing mark) on top of `base_width` -- the width the
// grapheme iterator itself already computed for this cluster (correct for
// every case except these three). `span` is a byte-exact cluster slice from
// display_width's byte-span reconstruction, never the iterator's `text`.
@(private = "file")
corrected_cluster_width :: proc(span: string, base_width: int, opts: Width_Options) -> int {
	runes: [MAX_INSPECTED_RUNES]rune
	n := 0
	has_vs16 := false

	b := span
	for len(b) > 0 && n < MAX_INSPECTED_RUNES {
		r, w := utf8.decode_rune(b)
		if r == 0xFE0F { has_vs16 = true }   // VARIATION SELECTOR-16
		runes[n] = r
		n += 1
		b = b[w:]
	}
	if n == 0 { return base_width }   // truncated multi-byte rune; nothing to inspect, trust the iterator

	// Defect 2: VS16 anywhere in the cluster forces emoji presentation.
	if has_vs16 { return 2 }

	// Defect 3: exactly two regional indicators is a flag pair. A single
	// trailing RI (n==1) is left at its natural table width.
	if n == 2 && utf8.is_regional_indicator(runes[0]) && utf8.is_regional_indicator(runes[1]) {
		return 2
	}

	// Defect 4: a cluster that OPENS with a nonspacing mark (only reachable
	// when the mark is the very first rune the iterator ever saw -- GB1
	// forces it to start its own cluster) must be width 0, not the buggy
	// early-return 1 that produced base_width.
	if unicode.is_nonspacing_mark(runes[0]) { return 0 }

	if opts.ambiguous_is_wide && base_width == 1 && is_ambiguous_width(runes[0]) {
		return 2
	}

	return base_width
}

// rows_for_line returns how many physical terminal rows a single LOGICAL
// line (no embedded "\n" -- callers split on that first, as render.odin
// does) occupies once the terminal wraps it at term_width columns.
//
// term_width <= 0 means "unknown" -- term_size() reports ok=false on a pty
// with no size ever set, and the golden harness and every unit test drive
// the renderer with no fd at all, so there is no width to query in the first
// place. Rather than guess, this returns 1: exactly the renderer's pre-fix
// behavior (one physical row assumed per logical line). That is the only
// sound default with zero information about the terminal, and it is what
// makes every existing byte-exact render test -- including the documented
// 14-byte single-line-frame baseline -- come out unchanged when no width is
// ever supplied (render_test.odin never calls renderer_set_width).
@(require_results)
rows_for_line :: proc(line: string, term_width: int, opts := Width_Options{}) -> int {
	if term_width <= 0 { return 1 }
	w := display_width(line, opts)
	if w <= 0 { return 1 }   // an empty (or all-zero-width) line still occupies its own row
	rows := (w + term_width - 1) / term_width   // ceil division
	if rows < 1 { rows = 1 }
	return rows
}

// is_ambiguous_width reports whether r has East_Asian_Width=Ambiguous per
// UCD 15.1.0. Backing data: ambiguous_width_ranges below.
@(require_results)
is_ambiguous_width :: proc(r: rune) -> bool #no_bounds_check {
	c := i32(r)
	p := unicode.binary_search(c, ambiguous_width_ranges[:], len(ambiguous_width_ranges)/2, 2)
	if p >= 0 && ambiguous_width_ranges[p] <= c && c <= ambiguous_width_ranges[p+1] {
		return true
	}
	return false
}

// East_Asian_Width=Ambiguous, UCD 15.1.0 (the version core:unicode's own
// tables are pinned to -- see the "moving target" note in
// docs/superpowers/render-width-decision.md re: UCD 17.0.0 being out of
// budget for T1). Generated 2026-07-26 from the real, authoritative
// https://www.unicode.org/Public/15.1.0/ucd/EastAsianWidth.txt (field
// "A"), merged into [lo, hi] pairs -- NOT hand-transcribed or guessed.
// 179 ranges, 138739 code points total.
@(private = "file")
ambiguous_width_ranges := [?]i32 {
	0x00A1, 0x00A1,
	0x00A4, 0x00A4,
	0x00A7, 0x00A8,
	0x00AA, 0x00AA,
	0x00AD, 0x00AE,
	0x00B0, 0x00B4,
	0x00B6, 0x00BA,
	0x00BC, 0x00BF,
	0x00C6, 0x00C6,
	0x00D0, 0x00D0,
	0x00D7, 0x00D8,
	0x00DE, 0x00E1,
	0x00E6, 0x00E6,
	0x00E8, 0x00EA,
	0x00EC, 0x00ED,
	0x00F0, 0x00F0,
	0x00F2, 0x00F3,
	0x00F7, 0x00FA,
	0x00FC, 0x00FC,
	0x00FE, 0x00FE,
	0x0101, 0x0101,
	0x0111, 0x0111,
	0x0113, 0x0113,
	0x011B, 0x011B,
	0x0126, 0x0127,
	0x012B, 0x012B,
	0x0131, 0x0133,
	0x0138, 0x0138,
	0x013F, 0x0142,
	0x0144, 0x0144,
	0x0148, 0x014B,
	0x014D, 0x014D,
	0x0152, 0x0153,
	0x0166, 0x0167,
	0x016B, 0x016B,
	0x01CE, 0x01CE,
	0x01D0, 0x01D0,
	0x01D2, 0x01D2,
	0x01D4, 0x01D4,
	0x01D6, 0x01D6,
	0x01D8, 0x01D8,
	0x01DA, 0x01DA,
	0x01DC, 0x01DC,
	0x0251, 0x0251,
	0x0261, 0x0261,
	0x02C4, 0x02C4,
	0x02C7, 0x02C7,
	0x02C9, 0x02CB,
	0x02CD, 0x02CD,
	0x02D0, 0x02D0,
	0x02D8, 0x02DB,
	0x02DD, 0x02DD,
	0x02DF, 0x02DF,
	0x0300, 0x036F,
	0x0391, 0x03A1,
	0x03A3, 0x03A9,
	0x03B1, 0x03C1,
	0x03C3, 0x03C9,
	0x0401, 0x0401,
	0x0410, 0x044F,
	0x0451, 0x0451,
	0x2010, 0x2010,
	0x2013, 0x2016,
	0x2018, 0x2019,
	0x201C, 0x201D,
	0x2020, 0x2022,
	0x2024, 0x2027,
	0x2030, 0x2030,
	0x2032, 0x2033,
	0x2035, 0x2035,
	0x203B, 0x203B,
	0x203E, 0x203E,
	0x2074, 0x2074,
	0x207F, 0x207F,
	0x2081, 0x2084,
	0x20AC, 0x20AC,
	0x2103, 0x2103,
	0x2105, 0x2105,
	0x2109, 0x2109,
	0x2113, 0x2113,
	0x2116, 0x2116,
	0x2121, 0x2122,
	0x2126, 0x2126,
	0x212B, 0x212B,
	0x2153, 0x2154,
	0x215B, 0x215E,
	0x2160, 0x216B,
	0x2170, 0x2179,
	0x2189, 0x2189,
	0x2190, 0x2199,
	0x21B8, 0x21B9,
	0x21D2, 0x21D2,
	0x21D4, 0x21D4,
	0x21E7, 0x21E7,
	0x2200, 0x2200,
	0x2202, 0x2203,
	0x2207, 0x2208,
	0x220B, 0x220B,
	0x220F, 0x220F,
	0x2211, 0x2211,
	0x2215, 0x2215,
	0x221A, 0x221A,
	0x221D, 0x2220,
	0x2223, 0x2223,
	0x2225, 0x2225,
	0x2227, 0x222C,
	0x222E, 0x222E,
	0x2234, 0x2237,
	0x223C, 0x223D,
	0x2248, 0x2248,
	0x224C, 0x224C,
	0x2252, 0x2252,
	0x2260, 0x2261,
	0x2264, 0x2267,
	0x226A, 0x226B,
	0x226E, 0x226F,
	0x2282, 0x2283,
	0x2286, 0x2287,
	0x2295, 0x2295,
	0x2299, 0x2299,
	0x22A5, 0x22A5,
	0x22BF, 0x22BF,
	0x2312, 0x2312,
	0x2460, 0x24E9,
	0x24EB, 0x254B,
	0x2550, 0x2573,
	0x2580, 0x258F,
	0x2592, 0x2595,
	0x25A0, 0x25A1,
	0x25A3, 0x25A9,
	0x25B2, 0x25B3,
	0x25B6, 0x25B7,
	0x25BC, 0x25BD,
	0x25C0, 0x25C1,
	0x25C6, 0x25C8,
	0x25CB, 0x25CB,
	0x25CE, 0x25D1,
	0x25E2, 0x25E5,
	0x25EF, 0x25EF,
	0x2605, 0x2606,
	0x2609, 0x2609,
	0x260E, 0x260F,
	0x261C, 0x261C,
	0x261E, 0x261E,
	0x2640, 0x2640,
	0x2642, 0x2642,
	0x2660, 0x2661,
	0x2663, 0x2665,
	0x2667, 0x266A,
	0x266C, 0x266D,
	0x266F, 0x266F,
	0x269E, 0x269F,
	0x26BF, 0x26BF,
	0x26C6, 0x26CD,
	0x26CF, 0x26D3,
	0x26D5, 0x26E1,
	0x26E3, 0x26E3,
	0x26E8, 0x26E9,
	0x26EB, 0x26F1,
	0x26F4, 0x26F4,
	0x26F6, 0x26F9,
	0x26FB, 0x26FC,
	0x26FE, 0x26FF,
	0x273D, 0x273D,
	0x2776, 0x277F,
	0x2B56, 0x2B59,
	0x3248, 0x324F,
	0xE000, 0xF8FF,
	0xFE00, 0xFE0F,
	0xFFFD, 0xFFFD,
	0x1F100, 0x1F10A,
	0x1F110, 0x1F12D,
	0x1F130, 0x1F169,
	0x1F170, 0x1F18D,
	0x1F18F, 0x1F190,
	0x1F19B, 0x1F1AC,
	0xE0100, 0xE01EF,
	0xF0000, 0xFFFFD,
	0x100000, 0x10FFFD,
}
