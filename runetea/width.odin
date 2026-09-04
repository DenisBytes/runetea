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
//
// AND ONE DEFECT THAT WAS THIS FILE'S OWN, not core:unicode's: the HORIZONTAL
// TAB. \t is a C0 control, normalized_east_asian_width returns 0 for every
// control, and so a tab used to measure ZERO COLUMNS. It does not occupy zero
// columns; it is the ONE C0 byte with a defined column effect (HT: advance to
// the next tab stop). The cost of pretending otherwise was not academic: a
// .Inline view containing one tab measured short, Renderer.last_rows recorded
// the under-count, and the next frame's rewind erased one row too few -- so the
// whole frame walked one row down the screen EVERY FRAME, forever, leaving a
// complete stale copy of the previous frame above it. Reproduced at 40 columns
// with a line that measured 37 and painted 44. Modelled here instead: see
// next_tab_stop, Width_Options.tab_stop, and measure_line's margin rule.
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

	// WHICH TERMINAL FAMILY'S CLUSTER RULE TO MEASURE BY -- see Emoji_Width
	// below (it sits with TAB_STOP_DEFAULT, the other constant a field of this
	// struct is defined in terms of) for the measured VTE transcript that makes
	// this a setting rather than a constant. The zero value is .Grapheme_Cluster, i.e. exactly what this file
	// answered before the field existed, so no existing measurement moves.
	emoji_width: Emoji_Width,

	// THE COLUMN THIS STRING STARTS AT, and the reason this field has to
	// exist at all: a horizontal tab's width is not a property of the tab, it
	// is a property of WHERE THE TAB IS. "\t" occupies 8 columns at column 0
	// and 1 column at column 7. So the moment \t is modelled (it must be --
	// see the file header), display_width stops being a homomorphism:
	//
	//     display_width(a) + display_width(b)  !=  display_width(a + b)
	//
	// for any `a` whose width is not a multiple of tab_stop and any `b`
	// beginning with a tab. That is a fact about terminals, not a wart in this
	// API, and the only honest thing to do with it is to say WHICH column the
	// measurement assumes. Zero -- "this string starts at the left margin" --
	// is the default, which is what every caller predating tabs meant and why
	// none of them had to change. The composition law that DOES hold, and the
	// one to reach for when concatenating:
	//
	//     w  := display_width(a, {start_col = c})
	//     w2 := display_width(b, {start_col = c + w})
	//     // w + w2 == display_width(concat(a, b), {start_col = c})
	//
	// REJECTED: a separate `display_width_at(s, col)` proc. It would have left
	// the plain `display_width` silently wrong for tabs (the status quo this
	// exists to end), and it would have needed a twin for every other measuring
	// proc in the file. REJECTED: expanding tabs to spaces before measuring.
	// That allocates, it changes the bytes the renderer writes (so the diff
	// model and the terminal would disagree about what was sent), and it still
	// needs the starting column to know how many spaces.
	//
	// Nothing but a tab reads this field. For a tab-free string, every result
	// in this file is exactly what it was before start_col existed.
	start_col: int,

	// Columns between tab stops. 0 means TAB_STOP_DEFAULT (8), which is what
	// every terminal ships with and what the DEC VT100 hard-wired; an app whose
	// content uses a different convention (examples/editor's TAB_WIDTH is 4)
	// says so here rather than pre-expanding.
	//
	// NEGATIVE MEANS "A TAB IS ZERO WIDTH", i.e. this file's pre-fix behaviour,
	// kept as an escape hatch rather than as a default: a caller measuring a
	// string that has ALREADY had its tabs expanded elsewhere, or one feeding a
	// terminal whose tab stops it has itself cleared, can ask for it. It is not
	// the default because the default has to be right for the caller who has
	// not thought about tabs at all, and for that caller a tab is 8 columns.
	tab_stop: int,
}

// The tab-stop interval of an unconfigured terminal, and of Width_Options with
// tab_stop left at 0. Every terminal emulator in circulation starts with stops
// every 8 columns (VT100 hardware default, preserved by xterm, kitty, Terminal
// .app, Windows Terminal and pyte alike). RuneTea never emits TBC/HTS, so it
// never invalidates this -- but an APPLICATION that does is on its own, which is
// what Width_Options.tab_stop is for.
TAB_STOP_DEFAULT :: 8

// HOW MANY COLUMNS A TERMINAL ADVANCES FOR A MULTI-RUNE CLUSTER. This is the
// second question in this file that has no universally correct answer and that
// the terminal never reports, and it gets the same treatment as the first one
// (Width_Options.ambiguous_is_wide): a policy the application selects, with the
// measurements that justify each choice written down next to it.
//
// THE TWO MEMBERS ARE NOT TWO GUESSES; THEY ARE THE TWO FAMILIES THAT WERE
// MEASURED. A live VTE 2.91 (python3-gi Vte.Terminal, 60 columns, offscreen,
// calibrated first on "abcdefg" -> 7 and "中文" -> 4) was fed one cluster per
// frame, with get_cursor_position() read back after each:
//
//     cluster                   VTE 2.91   .Grapheme_Cluster   .Legacy_Wcwidth
//     "abc"                          3            3                  3
//     "中文字"                        6            6                  6
//     U+1F44D                        2            2                  2
//     U+1F44D U+1F3FD (skin tone)    4            2  WRONG           4
//     U+1F1EF U+1F1F5 (RI flag)      2            2                  2
//     U+1F468 ZWJ U+1F4BB            4            2  WRONG           4
//     the 4-emoji ZWJ family         8            2  WRONG           8
//     "1" U+FE0F U+20E3 (keycap)     1            2  WRONG           1
//     U+2764 U+FE0F                  1            2  WRONG           1
//     U+2764 (no VS16)               1            1                  1
//
// Four of ten wrong on the terminal that ships with GNOME, in BOTH directions:
// two columns too few for the skin-tone and ZWJ clusters (RuneGloss's right
// border then hangs two columns outside the frame), one column too many for the
// keycap and the VS16 heart (the border sits one column inside it). This is not
// a bug that can be fixed by picking better numbers, because kitty, WezTerm,
// foot and Ghostty advance ONE cluster width for exactly the inputs VTE splits
// -- switching to VTE's numbers would simply move the raggedness to those
// terminals. What was actually missing was any way for an application that
// KNOWS which terminal it is on to say so, and any way for one that does not to
// detect that the question is open at all:
//
//     // Is this string's width a matter on which terminals disagree?
//     shaky := rt.display_width(s) !=
//              rt.display_width(s, rt.Width_Options{emoji_width = .Legacy_Wcwidth})
//
// REJECTED: the two independent bools the audit proposed
// (`emoji_presentation_is_wide` + `zwj_is_single_cluster`). They have four
// combinations, two of which describe no terminal anyone has measured, and they
// do not between them name the two clusters that actually moved the most --
// the skin-tone modifier and the keycap. The disagreement is not a set of
// separable rules; it is one coherent question -- "does this terminal advance
// per grapheme cluster, or per character?" -- and an enum keeps the
// unmeasurable combinations unrepresentable.
//
// REJECTED: making .Legacy_Wcwidth the default because it matches the most
// widely deployed Linux terminal. The default has to be the one that changes no
// existing frame, and every application that is correct today is correct
// BECAUSE it pads to these numbers; flipping the default would silently re-rag
// every box that currently lines up, on the terminals that were already right,
// in exchange for squaring the ones that are ragged today -- a lateral move
// made without asking. It is also the answer the UCD's own emoji-presentation
// rules give. That is the whole of the argument for it being the default: it is
// NOT a claim that it is right on your terminal.
Emoji_Width :: enum u8 {
	// One extended grapheme cluster advances the cursor once, by the width its
	// emoji presentation implies: VS16 anywhere forces 2, an RI pair is 2, and
	// everything else (ZWJ sequences, skin-tone modifiers, keycaps) takes the
	// width of the cluster's base rune. The zero value, and this file's
	// behaviour since before the option existed.
	//
	// Right for terminals that implement grapheme clustering: kitty, WezTerm,
	// foot, Ghostty, and anything that answers DEC mode 2027.
	Grapheme_Cluster = 0,

	// The cluster's width is the SUM of its runes' widths -- East_Asian_Width
	// F/W is 2, a Nonspacing_Mark or Enclosing_Mark is 0 (VS16 and the
	// combining enclosing keycap are both marks, which is why they add
	// nothing), ZWJ and the other zero-width formats are 0, everything else is
	// 1. No cluster folding of any kind: a skin-tone modifier is a second
	// wide glyph, a ZWJ sequence is N wide glyphs, and VS16 does not widen the
	// character it follows.
	//
	// Right for the per-character terminals, which is most of them: every
	// VTE-based one (GNOME Terminal, Tilix, Terminator, xfce4-terminal),
	// alacritty (it measures each char with the unicode-width crate and does
	// no cluster folding -- alacritty_terminal/src/term/mod.rs:1064), xterm,
	// tmux and screen.
	//
	// A CLUSTER'S WIDTH IS NO LONGER BOUNDED BY 2 under this policy -- the
	// 4-emoji ZWJ family measures 8 -- and two things follow that are worth
	// stating rather than leaving to be discovered.
	//
	// (1) measure_line still places a cluster as ONE ATOM: an 8-column family
	// starting 3 columns from the right margin advances to the margin and wraps
	// the NEXT cluster, where the terminal this policy models would have wrapped
	// in the MIDDLE of the family, after the second emoji. The row count is
	// therefore a lower bound in that corner. Placing per rune instead would
	// mean the iterator yielding sub-cluster spans, which is exactly what
	// RuneGloss's truncation must never be handed (see render.odin's cut rule),
	// so the atom stays and the corner is documented.
	//
	// (2) a caller that PLACES CELLS must be prepared for a width above 2:
	// screen.odin's cell model reserves one continuation cell for a width-2
	// cluster and would leave stale cells under a wider one. Unreachable today
	// -- the .Diff renderer drives screen_write with a default Width_Options{},
	// and nothing threads an application's policy into it.
	Legacy_Wcwidth,
}

// display_width returns the number of terminal columns `s` occupies WHEN LAID
// OUT STARTING AT opts.start_col (0 by default, i.e. the left margin), summing
// each extended grapheme cluster's corrected width. `s` may contain multiple
// clusters (letters, combining sequences, ZWJ emoji, flags); it must not
// contain "\n" if the caller wants per-physical-row semantics -- see
// rows_for_line, which splits on line boundaries itself.
//
// The starting column is part of the question rather than an optional extra
// only because of the tab; see Width_Options.start_col for what it costs and
// which composition law survives. For a string with no "\t" in it this proc is
// bit-for-bit what it always was.
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
// the untouched cluster loop (plain_advance below). This is sound on bytes, not
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
//
// TABS ARE MEASURED AGAINST AN INFINITELY WIDE TERMINAL. This proc knows no
// margin, so a tab here always advances to the next tab stop -- it never clamps
// and it never wraps. A real terminal's HT does both, at the right margin, and
// that is measure_line's job (it is the proc that knows term_width). The two
// therefore disagree, deliberately, for a tab whose stop lies past the margin;
// display_width is the answer to "how wide is this string", measure_line is the
// answer to "what does this line do to a 40-column screen", and only the second
// question has a margin in it. A tab-free string gets identical answers from
// both, which is every string the renderer saw before this existed.
//
// THE RUNNING COLUMN IS THREADED THROUGH THE SEGMENTS, not restarted at each
// one. It has to be: "a\e[0m\tb" is two segments, and a tab that began its
// segment's measurement at column 0 rather than at column 1 would answer 8
// where the terminal advances 7. The escape split must be invisible to the
// measurement -- that is the whole premise of the pre-pass -- and a per-segment
// column reset would have made it visible for exactly one byte value.
@(require_results)
display_width :: proc(s: string, opts := Width_Options{}) -> int {
	if len(s) == 0 { return 0 }

	// A NEGATIVE start_col is nonsense (there is no column left of the left
	// margin) and is clamped rather than propagated: an unclamped -3 would make
	// next_tab_stop's arithmetic answer a width larger than tab_stop.
	start := max(opts.start_col, 0)
	col   := start
	seg   := 0   // start of the current escape-free segment
	i     := 0
	for i < len(s) {
		if s[i] != ESC { i += 1; continue }
		col = plain_advance(s[seg:i], opts, col)
		i = skip_escape(s, i)   // always > i, so this loop always advances
		seg = i
	}
	return plain_advance(s[seg:], opts, col) - start
}

// PACKAGE-PRIVATE, not file-private (T3-A). The cell renderer walks a view line
// with EXACTLY display_width's own escape-vs-content split -- same ESC scan,
// same skip_escape, same segment boundaries -- because a cell grid that
// disagreed with display_width about where an escape ends would disagree with
// rows_for_line about how many rows a line takes, and the full-screen repaint
// (which the diff renderer must reproduce cell for cell) is driven by
// rows_for_line. One scanner, one answer.
@(private = "package")
ESC :: 0x1B
// PACKAGE-PRIVATE, not file-private (T3-C): screen.odin's OSC 8 parser has to
// recognise the same BEL terminator this scanner consumes, and two spellings of
// 0x07 in one package is one chance for them to disagree.
@(private = "package")
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
@(private = "package")
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

// plain_advance is display_width's original body over a segment GUARANTEED to
// contain no ESC. Split out only so the escape pre-pass above can call it once
// per segment without touching a line of the byte-span reconstruction below.
//
// RETURNS THE ENDING COLUMN, not the width. It used to return the width (it was
// called plain_width); it cannot any more, because a tab's width depends on the
// column the segment starts at, so the caller has to hand a column IN as well as
// take one back. `end - start` is still the width, and display_width is the one
// line that computes it.
@(private = "file")
plain_advance :: proc(s: string, opts: Width_Options, col: int) -> int {
	ci := cluster_iter_make(s, opts)
	ci.col = col
	for {
		// The widths are dropped on purpose: cluster_next has already added each
		// one to ci.col, and that running column -- not a separate sum -- is what
		// a tab in a LATER cluster has to be measured against.
		_, _, ok := cluster_next(&ci)
		if !ok { break }
	}
	return ci.col
}

// The column a tab at `col` advances to, given a tab-stop interval of `stop`.
//
// `stop <= 0` means "tabs are zero width" (Width_Options.tab_stop's documented
// negative case, and the arithmetic guard for a 0 that tab_stop_of has already
// mapped away): return `col` unchanged rather than divide by it.
@(private = "file")
next_tab_stop :: proc(col: int, stop: int) -> int {
	if stop <= 0 { return col }
	if col < 0   { return stop }
	return (col / stop + 1) * stop
}

@(private = "file")
tab_stop_of :: proc(opts: Width_Options) -> int {
	return TAB_STOP_DEFAULT if opts.tab_stop == 0 else opts.tab_stop
}

// A cluster is a tab iff it is the single byte 0x09. There is no need to decode:
// HT is GCB=Control, so GB4/GB5 force it to be a cluster of its own -- it can
// never be absorbed into a neighbour's cluster and never carries a combining
// mark. That is also why this is a byte compare and not a rune compare.
@(private = "file")
is_tab :: proc(span: string) -> bool {
	return len(span) == 1 && span[0] == '\t'
}

// THE CLUSTER LOOP plain_advance used to inline, lifted out verbatim (T3-A) so
// the cell renderer can walk the SAME clusters with the SAME corrected widths
// instead of re-deriving them. This is the single most delicate loop in this
// file -- the byte-span reconstruction defect 1 forces -- and having two copies
// of it was never an option: a cell grid that split clusters differently from
// display_width would put a caret in the wrong column and a diff in the wrong
// cell, silently.
//
// The span it yields is a byte-exact subslice of the ORIGINAL string, which is
// what the renderer needs: it stores those bytes in a cell and writes them back
// to the terminal unchanged.
//
// PUBLIC AS OF THE AUDIT SWEEP, and it was wrong to hide it. RuneGloss ships no
// wrap and no truncate, so every application has to write its own -- and the
// only correct grapheme walk in the tree (the one that applies the VS16, RI-pair
// and leading-mark corrections above) was @(private="package"). The public
// surface was whole-string display_width and nothing else, so the only correct
// truncation an application could write was an O(n^2) prefix rescan: measure
// s[:1], s[:2], ... until it exceeds the budget. The alternative people actually
// reach for -- slicing at a rune boundary and measuring runes -- corrupts every
// multi-rune cluster: it drops VS16, splits a flag pair in half, and leaves a
// dangling ZWJ. The library shipped the fix for all of that in the binary and
// refused to name it. TRUNCATE-TO-WIDTH, which is what this exists for:
//
//     // Longest prefix of `line` that fits in `budget` columns. O(n), and
//     // it never cuts a cluster in half.
//     truncate :: proc(line: string, budget: int) -> string {
//         ci  := rt.cluster_iter_make(line)
//         col := 0
//         cut := 0
//         for {
//             span, w, ok := rt.cluster_next(&ci)
//             if !ok { break }
//             if col + w > budget { break }
//             col += w
//             cut += len(span)      // spans are contiguous subslices of `line`
//         }
//         return line[:cut]
//     }
//
// Two things that loop is deliberately NOT doing, because they are the caller's
// policy and not this iterator's: it does not append an ellipsis (which costs
// columns of its own -- subtract them from `budget` first), and it does not
// re-open a style the cut discarded (a truncation that lands between "\e[31m"
// and "\e[0m" leaves the terminal red; append a reset, or truncate the styled
// string and re-close it yourself).
//
// `s` MUST NOT CONTAIN ESC. Callers split on escapes first (display_width's own
// pre-pass, and the renderer's identical one) -- see display_width for why the
// split is sound on bytes. An ESC handed to this iterator is measured as a
// zero-width control and its parameter bytes as content, which is the seven-
// columns-for-one-glyph over-count T2-A exists to have removed.
Cluster_Iter :: struct {
	s:          string,
	opts:       Width_Options,
	it:         utf8.Grapheme_Iterator,
	// One cluster is held back at a time: its END (and therefore its correct
	// byte span) is only known once the NEXT cluster's byte_index is read, or
	// the iterator is exhausted (end = len(s)). -1 means "nothing held back
	// yet"; -2 means "the held-back cluster was the last one and has already
	// been yielded", i.e. the iterator is finished.
	prev_start: int,
	prev_width: int,

	// THE COLUMN THE NEXT CLUSTER WILL BE PLACED AT. Seeded from
	// opts.start_col, advanced by each cluster yielded. Only a tab reads it --
	// for every other cluster it is bookkeeping the caller may ignore
	// entirely.
	//
	// WRITABLE ON PURPOSE. This iterator models a string laid out on one
	// unbounded row; it does not know about wrapping, because wrapping is a
	// function of a terminal width it is never told. A caller that DOES wrap
	// (measure_line below, or an application laying text into a box) assigns
	// `col = 0` after each wrap and the next tab is measured from the right
	// place. The alternative -- passing term_width into the iterator and
	// wrapping inside it -- was rejected because it would have made every
	// caller that only wants widths (display_width, screen_write_plain) supply
	// a width they do not have.
	col: int,
}

cluster_iter_make :: proc(s: string, opts := Width_Options{}) -> (ci: Cluster_Iter) {
	ci.s = s
	ci.opts = opts
	ci.it = utf8.decode_grapheme_iterator_make(s)
	ci.prev_start = -1
	ci.col = max(opts.start_col, 0)   // see display_width on why this is clamped
	return
}

// Yields the next cluster's byte span and its CORRECTED display width, and
// advances ci.col past it. ok=false once the string is exhausted.
//
// TWO CLUSTERS ESCAPE THE 0/1/2 RANGE this used to promise, both of them
// because the caller asked for it. A TAB is next_tab_stop(ci.col) - ci.col, 1
// to tab_stop columns, depending entirely on where the tab sits -- see
// Width_Options.start_col for what that costs the caller and why it is still
// the right model. And under opts.emoji_width == .Legacy_Wcwidth any cluster is
// the SUM of its runes' widths, which is 8 for the four-emoji ZWJ family; see
// Emoji_Width, including what a caller placing cells owes that case. Every
// cluster is still 0, 1 or 2 under the default options, which is what every
// caller predating either field is passing.
//
// NOTE FOR A CALLER THAT PLACES CELLS (screen_write_plain): keep ci.col in step
// with the cursor you are placing at, or a tab will be measured from the wrong
// column. screen.odin does not, because the .Diff cell model rejects tabs
// outright (contract.odin's Control_Byte) -- a tab is a MOVE, and a move is the
// one thing a cell grid cannot record. The debug-build assertion now fires on
// that in a plain `odin build`, which is where it belongs.
cluster_next :: proc(ci: ^Cluster_Iter) -> (span: string, width: int, ok: bool) {
	if len(ci.s) == 0 || ci.prev_start == -2 { return "", 0, false }
	for {
		_, g, more := utf8.decode_grapheme_iterate(&ci.it)
		if !more { break }
		if ci.prev_start >= 0 {
			sp := ci.s[ci.prev_start:g.byte_index]
			w  := cluster_width_at(sp, ci.prev_width, ci.col, ci.opts)
			ci.prev_start = g.byte_index
			ci.prev_width = g.width
			ci.col += w
			return sp, w, true
		}
		ci.prev_start = g.byte_index
		ci.prev_width = g.width
	}
	if ci.prev_start >= 0 {
		sp := ci.s[ci.prev_start:]
		w  := cluster_width_at(sp, ci.prev_width, ci.col, ci.opts)
		ci.prev_start = -2
		ci.col += w
		return sp, w, true
	}
	ci.prev_start = -2
	return "", 0, false
}

// The column-dependent layer over corrected_cluster_width: exactly one cluster
// in Unicode has a width that is a function of position, and this is where that
// fact is confined. Everything below this line is position-independent and can
// stay that way.
@(private = "file")
cluster_width_at :: proc(span: string, base_width: int, col: int, opts: Width_Options) -> int {
	if is_tab(span) { return next_tab_stop(col, tab_stop_of(opts)) - col }
	return corrected_cluster_width(span, base_width, opts)
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
//
// THE POLICY FORK IS THE FIRST LINE OF THE BODY, not a flag threaded through
// the three overrides, because the two policies do not share a step: under
// .Legacy_Wcwidth there is no such thing as a cluster-level width to correct --
// the terminal never formed the cluster in the first place -- so every one of
// the overrides below is not merely disabled but meaningless. See Emoji_Width
// for the measurements, and legacy_wcwidth_width for what replaces this.
@(private = "file")
corrected_cluster_width :: proc(span: string, base_width: int, opts: Width_Options) -> int {
	if opts.emoji_width == .Legacy_Wcwidth { return legacy_wcwidth_width(span, opts) }

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

// The .Legacy_Wcwidth half of corrected_cluster_width: the width a
// per-character terminal advances for this cluster, which is just the sum of
// its runes' widths. Named for what every such terminal is doing internally --
// a wcwidth() per character and no grapheme table anywhere -- rather than for
// any one emulator, because the family is large (see Emoji_Width).
//
// `base_width` IS DELIBERATELY NOT A STARTING POINT HERE. It is not the
// cluster's width under any rule: core:unicode's grapheme iterator adds
// normalized_east_asian_width for the rune that OPENED the cluster and for no
// other (grapheme.odin:149), so base_width is the FIRST TERM of exactly the sum
// below. Seeding with it and adding the rest would be the same arithmetic with
// one more way to get it wrong.
//
// MAX_INSPECTED_RUNES does not apply. That cap exists to bound a fixed stack
// array of runes for the three overrides; a running sum needs no array, so a
// pathological 400-rune cluster is summed rather than truncated -- which is
// what the terminal being modelled would do to it.
@(private = "file")
legacy_wcwidth_width :: proc(span: string, opts: Width_Options) -> int {
	total := 0
	b := span
	for len(b) > 0 {
		r, n := utf8.decode_rune(b)
		b = b[n:]   // decode_rune returns size 1 for an invalid byte, so this always advances
		total += legacy_rune_width(r, opts)
	}
	return total
}

// One rune's column cost to a per-character terminal.
//
// THE MARK CHECK CANNOT BE DELEGATED to normalized_east_asian_width, and that
// is the whole reason this proc exists rather than being one call. That proc
// early-outs `r <= 0x10FF -> 1` for speed and consults a table of
// East_Asian_Width above it, and neither branch knows about combining marks:
// it answers 1 for U+FE0F VARIATION SELECTOR-16 and 1 for U+20E3 COMBINING
// ENCLOSING KEYCAP (verified by calling it). Summing it raw would make the
// keycad "1" U+FE0F U+20E3 measure 3 columns where VTE advances 1 -- worse
// than the cluster policy it exists to correct. Nonspacing_Mark and
// Enclosing_Mark are therefore zeroed here first; ZWJ, ZWSP, ZWNJ, the word
// joiner and the C0/C1 controls already come back 0 from the proc itself.
//
// Spacing_Mark (Mc) is NOT zeroed: those combining marks are the ones that do
// occupy a column (Devanagari matras and their kin), which is why they are
// spacing.
@(private = "file")
legacy_rune_width :: proc(r: rune, opts: Width_Options) -> int {
	if unicode.is_nonspacing_mark(r) || unicode.is_enclosing_mark(r) { return 0 }
	w := unicode.normalized_east_asian_width(r)
	// Ambiguous is still the caller's policy, applied per rune here because
	// under this policy the rune, not the cluster, is what the terminal
	// measures. Same table and same condition as the cluster path's.
	if opts.ambiguous_is_wide && w == 1 && is_ambiguous_width(r) { return 2 }
	return w
}

// What a single LOGICAL line does to a term_width-column screen: how many
// physical rows it occupies, which column it leaves the cursor in, and whether
// it covered every cell of every row it touched.
//
// ONE FUNCTION, THREE ANSWERS, because the three used to be computed three
// different ways and disagreed with each other. rows_for_line divided
// display_width by term_width; line_fills_its_rows (render.odin) took
// display_width modulo term_width; the text itself was placed by screen_put and
// by the terminal's own wrapping. Ceil division is only equal to placement when
// no cluster straddles the right margin -- and a wide cluster straddling the
// right margin is exactly the case a terminal treats specially. Two measured
// consequences of that disagreement, both from the emitted bytes:
//
//   * 40x8, line 0 = "x" + 20 CJK, caret on line 1: display_width says 41, ceil
//     says 2 rows, screen_put places all of it on ONE row (the 20th CJK cluster
//     is written AT column 39 with no continuation cell and the cursor clamps to
//     40). The renderer wrote "\e[2;1H" for line 1 and "\e[3;1H" for the caret
//     -- the caret one row below the line it belongs to.
//   * 4x2, view "abc界\nXYZ": "abc界" measures 5, ceil says 2 rows, the height
//     budget is 2, so "XYZ" was judged not to fit and was never emitted. It
//     fits: "abc界" occupies one row. Replace 界 with "d" and XYZ paints.
//
// So this walks the clusters and places them, with screen_put's rule and the
// terminal's, instead of dividing:
//
//   * DECAWM PENDING WRAP. Filling the last column does NOT take a new row; the
//     NEXT printable cluster does. That is why `col` is allowed to equal
//     term_width and why the wrap test is at the top of the loop, not the
//     bottom.
//   * A WIDE CLUSTER AT THE LAST COLUMN IS WRITTEN THERE, with no continuation
//     cell, and the cursor clamps to term_width. (xterm-family terminals
//     instead blank that cell and wrap the whole cluster; screen.odin's header
//     documents this divergence and pyte -- the difftest oracle -- takes
//     screen_put's side. Changing it is a screen.odin decision, not a width.odin
//     one; what matters here is that measurement and placement finally agree.)
//   * A ZERO-WIDTH CLUSTER folds into the cell to its left and advances nothing.
//   * A TAB NEVER WRAPS. HT advances to the next tab stop but is clamped to the
//     right margin -- verified against pyte, which is the emulator the difftest
//     harness scores this package against: at 10 columns "\tX" puts X at column
//     8, at 4 columns it puts X at column 3, and at column 9 of a 10-column
//     screen a tab does not move at all. A tab arriving in the pending-wrap
//     state (col == term_width) moves the cursor BACKWARDS to term_width-1 and
//     clears the pending wrap, so the next glyph overwrites the last column
//     rather than wrapping; pyte does exactly this ("ab\tcd\tef" at 10 columns
//     ends at row 1 column 1, which this reproduces cluster for cluster).
//
// term_width <= 0 means "unknown" -- term_size() reports ok=false on a pty with
// no size ever set, and the golden harness and every unit test drive the
// renderer with no fd at all, so there is no width to query in the first place.
// Rather than guess, rows is 1: exactly the renderer's pre-fix behavior (one
// physical row assumed per logical line). That is the only sound default with
// zero information about the terminal, and it is what makes every existing
// byte-exact render test -- including the documented 14-byte single-line-frame
// baseline -- come out unchanged when no width is ever supplied (render_test
// .odin never calls renderer_set_width).
Line_Metrics :: struct {
	// Physical rows the line occupies. Always >= 1: an empty line still owns
	// its own row.
	rows:    int,
	// The column the cursor is left in, 0..=term_width. term_width itself is
	// the PENDING WRAP state, not "column term_width" -- there is no such
	// column -- and it is the one value that means "the next glyph starts a new
	// row". With an unknown width this is start_col + display_width, unclamped.
	end_col: int,
	// Whether the line covered every cell of every row it occupies, i.e. it
	// ended flush against the right margin. render_full_screen uses this to
	// decide whether an EL after the line could erase anything the line did not
	// itself write; emitting one from the pending-wrap position erases the
	// WRONG row. False when the width is unknown -- with no margin there is
	// nothing to be flush with, the same "do not guess" answer `rows` gives.
	fills:   bool,
}

@(require_results)
measure_line :: proc(line: string, term_width: int, opts := Width_Options{}) -> Line_Metrics {
	if term_width <= 0 {
		return Line_Metrics{
			rows    = 1,
			end_col = max(opts.start_col, 0) + display_width(line, opts),
			fills   = false,
		}
	}

	col  := clamp(opts.start_col, 0, term_width)
	rows := 1
	ts   := tab_stop_of(opts)

	// The same ESC pre-pass display_width runs, for the same reason: an escape
	// is zero width and must not be able to shift a wrap boundary. Sound on
	// bytes -- 0x1B never occurs inside a multi-byte UTF-8 sequence.
	seg := 0
	i   := 0
	for i < len(line) {
		if line[i] != ESC { i += 1; continue }
		measure_segment(line[seg:i], opts, &col, &rows, term_width, ts)
		i = skip_escape(line, i)   // always > i, so this loop always advances
		seg = i
	}
	measure_segment(line[seg:], opts, &col, &rows, term_width, ts)

	return Line_Metrics{rows = rows, end_col = col, fills = col == term_width}
}

// One escape-free segment of a line, placed cluster by cluster.
@(private = "file")
measure_segment :: proc(seg: string, opts: Width_Options, col: ^int, rows: ^int, term_width, ts: int) {
	if len(seg) == 0 { return }
	ci := cluster_iter_make(seg, opts)
	for {
		// RESYNC BEFORE EVERY CLUSTER, because wrapping is this proc's business
		// and not the iterator's: the iterator lays a string out on one
		// unbounded row, and col^ is the only thing that knows a wrap happened.
		// Without this a tab on the second physical row of a wrapped line would
		// be measured from its column in the UNWRAPPED one.
		ci.col = col^
		span, w, ok := cluster_next(&ci)
		if !ok { break }
		place_cluster(span, w, col, rows, term_width, ts)
	}
}

// screen_put's placement rule, plus the terminal's wrap and the tab's margin
// clamp, over one cluster. THE ONLY PLACE measure_line advances a column.
@(private = "file")
place_cluster :: proc(span: string, w: int, col: ^int, rows: ^int, term_width, ts: int) {
	if is_tab(span) {
		// Clamped to the last column, never past it, and never into a new row
		// -- see measure_line's header for the pyte transcript this reproduces.
		stop := next_tab_stop(col^, ts)
		if stop > term_width - 1 { stop = term_width - 1 }
		col^ = max(stop, 0)
		return
	}
	if w <= 0 { return }   // folds into the cell to its left; advances nothing
	if col^ >= term_width { col^ = 0; rows^ += 1 }   // the pending wrap resolves HERE
	col^ = min(col^ + w, term_width)
}

// rows_for_line returns how many physical terminal rows a single LOGICAL line
// (no embedded "\n" -- callers split on that first, as render.odin does)
// occupies once the terminal wraps it at term_width columns.
//
// KEPT, AND KEPT AT ITS ORIGINAL SIGNATURE, as the one-answer front door onto
// measure_line: it is what render.odin, examples/editor and the tests all call,
// the row count is what most of them want, and the audit's finding was that its
// ANSWER was wrong, not that its shape was. Callers needing end_col or fills
// call measure_line directly.
@(require_results)
rows_for_line :: proc(line: string, term_width: int, opts := Width_Options{}) -> int {
	return measure_line(line, term_width, opts).rows
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
