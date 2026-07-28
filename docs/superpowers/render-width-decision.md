# Render width — reproduced, built, fixed

**Date:** 2026-07-26
**Status:** Fixed. Regression tests in place; pty-verified before/after.
**Toolchain:** Odin `dev-2026-07-nightly:819fdc7`. Linux only.
**Base commit:** `f7daf82` ("feat(T1): decide and implement message ownership")

This is T1 work: fix `renderer_render`'s rewind-count bug (spec §13.1 risk 1's
sibling — the naive renderer has no oracle either, but this particular defect
is visible byte-for-byte without one) and build the display-width layer spec
§11 budgets. Read `runetea/render.odin`, `runetea/width.odin`, and
`runetea/tea.odin`'s `apply()` for the actual code; this document is the
evidence trail and the design record.

---

## 1. The bug, reproduced first

`renderer_render` tracked `last_lines = len(lines)` (a **logical** line
count, one per `\n` in the view) and rewound that many `\e[1A\e[2K` pairs on
the next frame. Terminals wrap on **physical rows**: any view line wider
than the terminal's column count consumes 2+ physical rows, so the rewind
undershoots and leaves stale rows on screen. Reproduced before touching any
fix code, per instructions.

### Method

`examples/simple`'s view is:

```
Hi. This program will exit on 'q'.

Keys pressed: N
```

The first line is 34 bytes/columns (all ASCII, so byte length == display
width here) — wider than a 20-column terminal. Built the real binary
(`odin build examples/simple`), drove it under a **real pty** with
`pty.fork()` + `ioctl(TIOCSWINSZ)` set to 20×24 (Python: `fcntl`, `struct`,
`termios`, `select` — no terminal emulator involved, this is the actual
kernel pty subsystem), sent keypresses to trigger re-renders, and captured
the exact byte stream with `select()`-gated non-blocking reads. Then fed
those exact bytes into `pyte` (a real vt100 screen emulator) at the same
20×N geometry to render what a user's terminal would actually show.

### Captured bytes (before the fix, 20 columns)

```
frame 1 (initial paint):
  b"Hi. This program will exit on 'q'.\r\n\r\nKeys pressed: 0\r\n"
  rewind count: 0   (nothing to rewind yet)

frame 2 (after a keypress):
  b"\x1b[1A\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K" +
  b"Hi. This program will exit on 'q'.\r\n\r\nKeys pressed: 1\r\n"
  rewind count: 3

frame 3 (after another keypress):
  b"\x1b[1A\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K" +
  b"Hi. This program will exit on 'q'.\r\n\r\nKeys pressed: 2\r\n"
  rewind count: 3
```

`last_lines` was 3 (one per `\n`-delimited logical line: the blurb, the
blank line, the counter). But at 20 columns the 34-column blurb line wraps
into **2 physical rows**, so frame 1 actually painted **4** physical rows
(2 + 1 + 1). Every subsequent frame rewinds only 3, one row short.

### The corruption, rendered

Feeding the full captured stream (7 keypresses) through `pyte` at 20×10 and
printing the final screen:

```
 0 |Hi. This program wil|
 1 |Hi. This program wil|
 2 |Hi. This program wil|
 3 |Hi. This program wil|
 4 |Hi. This program wil|
 5 |Hi. This program wil|
 6 |l exit on 'q'.      |
 7 |                    |
 8 |Keys pressed: 6     |
 9 |                    |  <-- cursor
```

Six stacked, un-erased copies of the wrapped line's first row — exactly the
"each frame eats further into the scrollback above the view" failure the
task description predicted, and non-vacuous: this is a real pty, real
`pyte` VT100 emulation, real captured bytes from the real (pre-fix) binary.

**Control, same binary, 80 columns (no wrap):**

```
 0 |Hi. This program will exit on 'q'.  |
 1 |                                    |
 2 |Keys pressed: 6                     |
 3 |                                    |  <-- cursor
 4..9 | (blank)                         |
```

Clean. Confirms the bug is specifically about wrapping, not a general
renderer defect — the rewind count (`last_lines`, always 3 here too) happens
to be correct when nothing wraps, which is exactly why this shipped unnoticed.

**Second data point, `examples/http` (old binary, 20 columns):** its view is
a single line, `"Checking http://example.com ..."` (32 columns, wraps at
20 into 2 rows), followed by `"http://example.com -> 200"` (26 columns, also
wraps). Captured:

```
b'Checking http://example.com ...\r\n\x1b[1A\x1b[2Khttp://example.com -> 200\r\n'
rewind count: 1
```

`pyte` screen:

```
 0 |Checking http://exam|
 1 |http://example.com -|
 2 |> 200               |
 3 |                    |  <-- cursor
```

Same defect, second real program: the first row of the first frame's wrapped
line survives on screen, un-erased, behind the final content. This became
the regression test in `render_test.odin` (below) and confirms the bug is
general to any view line wider than the terminal, not specific to one
example's exact string.

---

## 2. The four catalogued grapheme/width defects — verified against THIS toolchain

Spec §11 lists four defects in `core:unicode/utf8/grapheme.odin`. Re-verified
by reading the actual installed source
(`/home/denisbytes/odin/core/unicode/utf8/grapheme.odin`,
`/home/denisbytes/odin/core/unicode/letter.odin`,
`/home/denisbytes/odin/core/unicode/tables.odin`) against the exact pinned
toolchain (`odin version` → `dev-2026-07-nightly:819fdc7`, matches).
**All four are still real. None has been fixed upstream since the spec was
written.**

1. **Byte-span-as-width-count, `grapheme.odin:155`.** Confirmed at the exact
   line: `text = it.str[byte_index:][:grapheme.width]`. For "日本語" (three
   3-byte runes, each width 2) this slices `[:2]` of a 3-byte-rune start —
   two bytes of a three-byte encoding: invalid UTF-8. **Fix:** `width.odin`
   never reads the iterator's `text` field. `display_width` buffers one
   cluster behind and derives byte spans from consecutive `grapheme.byte_index`
   values, closing the span on the NEXT cluster's start (or `len(s)` at EOF).

2. **VS16 ignored.** Traced the iterator's own logic: U+FE0F is GCB Extend
   (`is_gcb_extend_class`), so "❤️" (U+2764 U+FE0F) correctly clusters as ONE
   grapheme (U+FE0F absorbed under GB9) — segmentation is fine. But width is
   only added for the rune that OPENS a cluster (`it.width +=
   normalized_east_asian_width(this_rune)` fires only when `grapheme_count`
   just increased), and U+FE0F never opens a cluster, so its presence adds
   zero width. Base width = `normalized_east_asian_width(0x2764)` = 1 (table
   range `0x2758, 0x2794, 1` in `tables.odin`). Confirmed: `❤️` measures 1
   before correction, matching the spec's claim. **Fix:** `corrected_cluster_
   width` scans the cluster's (correctly byte-spanned) runes for U+FE0F
   anywhere and forces width 2 if found.

3. **Regional-indicator pairs measure 1, not 2.** Traced GB12/13 handling
   (`grapheme.odin`'s `regional_indicator_counter` logic): a valid RI pair
   (e.g. 🇯🇵, U+1F1EF U+1F1F5) does correctly merge into one cluster — only
   the FIRST RI increments `grapheme_count`/opens the cluster; the second is
   absorbed. Its width is `normalized_east_asian_width` of the first RI rune
   alone. Confirmed at the exact cited line, `tables.odin:3829`:
   `0x1F19B, 0x1F1FF, 1,` — the whole RI block (U+1F1E6–U+1F1FF) is table
   width 1. So a flag pair measures 1, not 2. **Fix:** if a cluster's byte
   span decodes to exactly 2 runes and both are `is_regional_indicator`,
   force width 2. A lone/unpaired trailing RI (`n==1`) is deliberately left
   alone — it isn't a flag.

4. **`normalized_east_asian_width` returns 1, not 0, for combining marks.**
   Confirmed at `letter.odin:530`: `else if r <= 0x10FF { return 1 }` — an
   unconditional early return before the function ever checks
   `is_nonspacing_mark`. Traced the actual impact: in the *common* case (a
   combining mark following a real base rune, e.g. "e" + U+0301) this defect
   is silently harmless, because the iterator only ever adds width for the
   rune that OPENS a cluster, and a following Extend rune never opens one —
   its buggy width-1 is structurally never added. It DOES leak through for
   the narrower case the spec flags: GB1 ("sot ÷ Any") forces even a
   *leading* combining mark — nothing before it to attach to — to open its
   own degenerate cluster, so a string starting mid-cluster gets width 1 for
   what should be a zero-width mark. Verified both cases with dedicated tests
   (`width_test.odin`). **Fix:** if a cluster's first rune is
   `unicode.is_nonspacing_mark` (the real Mn-category table, more accurate
   than `letter.odin`'s own hand-picked `is_combining`), force width 0.

None of the four required patching Odin core or vendoring a replacement —
each is a small, targeted override layered on top of the (correct)
segmentation, exactly as spec §11 intended.

### Bonus/fifth item actually in the budget line: the ambiguous-width flag

Spec §11's budget line groups five deliverables: "byte-span reconstruction,
VS16 → force 2, RI-pair → force 2, **an ambiguous-width flag**, and a
zero-width set from `nonspacing_mark_ranges`." The zero-width set is item 4
above (`unicode.is_nonspacing_mark`, backed by `unicode.nonspacing_mark_
ranges` exactly as named). The ambiguous-width flag needed its own
verification pass:

- **`core:unicode` has no Ambiguous-category data at all.** Grepped the
  whole package for "ambiguous"/"Ambiguous" — zero hits, in both the tables
  and the UCD table generator (`core/unicode/tools/ucd/generate_unicode.
  odin`). `normalized_east_asian_width` folds East_Asian_Width categories
  W/F → 2 and **everything else (A, Na, H, N) → 1**, with no way to ask
  afterward "was this specific rune Ambiguous, or genuinely Narrow/Neutral."
  That distinction is not recoverable from anything Odin ships.
- Hand-transcribing the ~180-range Ambiguous set from memory was rejected —
  it is exactly the kind of unverifiable, error-prone guess the task
  explicitly warns against ("verify each against the actual installed
  toolchain," not "recall from training"). Internet access turned out to be
  available (confirmed via `pip install pyte`), so instead: fetched the real,
  authoritative `https://www.unicode.org/Public/15.1.0/ucd/EastAsianWidth.txt`
  — UCD **15.1.0**, matching the exact version `core:unicode`'s own tables
  are pinned to (the file's own header confirms: `letter.odin` ends with
  `// End of Unicode 15.1.0 block.`) — parsed it, merged the `East_Asian_
  Width=Ambiguous` ("A") entries into 179 `[lo, hi]` ranges (138,739 code
  points total), and embedded that as `ambiguous_width_ranges` in
  `width.odin`, looked up with `unicode.binary_search` (already public in
  `core:unicode`, same idiom every other range table there uses).
- `Width_Options{ambiguous_is_wide: bool}` defaults `false` — matching both
  `core:unicode`'s own folding and xterm's own default (narrow). Set `true`
  only for a terminal/locale known to render Ambiguous-width runes (curly
  quotes, box-drawing, Greek/Cyrillic letters, circled digits, ...)
  double-wide.

This is real, sourced, version-consistent data, not a guess — but it is
still UCD 15.1.0 like the rest of `core:unicode`. Defect 4 in the spec's own
list ("tables pinned to UCD 15.1.0; Go's uax29 is on 17.0.0") is
**unaddressed by design**: full retable regeneration (grapheme break
properties, emoji-data, the works) is a `core:unicode`-wide undertaking, well
outside a 300–500 LOC T1 budget, and out of scope here. Noted, not fixed.

---

## 3. The width layer (`runetea/width.odin`)

363 lines total (182 logic/docs + 179 table lines) — inside the spec's
300–500 LOC budget for the whole layer. Public surface:

```odin
Width_Options :: struct { ambiguous_is_wide: bool }

display_width :: proc(s: string, opts := Width_Options{}) -> int
rows_for_line :: proc(line: string, term_width: int, opts := Width_Options{}) -> int
is_ambiguous_width :: proc(r: rune) -> bool
```

`display_width` sums corrected per-cluster widths over an arbitrary string
(no embedded `\n` assumed). `rows_for_line` is what the renderer actually
calls: given one logical line and a terminal column count, how many physical
rows does it occupy. 13 tests in `width_test.odin` cover all four defects
individually (ASCII, CJK byte-vs-width, VS16 present/absent, RI pair/lone RI,
leading/non-leading combining mark, ambiguous default/opt-in, table lookup,
and the wrap-math edge cases: zero-width unknown-width fallback, exact-width
boundary, wide-rune wrapping).

---

## 4. Plumbing the width into the renderer

### Where does the renderer get terminal width?

**Decision: the renderer is TOLD, not asked, and never owns an fd.**
`Renderer` gained a `term_width: int` field (0 = unknown), set two ways:

1. **At construction**, `run()` (`tea.odin`) and `run_nbio()`
   (`loop_nbio.odin`) each call `term_size(flush_fd)` once, before
   `renderer_init`, and pass the result through — but ONLY when `flush_fd >=
   0` (a real terminal is actually being written to; see `flush_frame`'s own
   doc comment for why `flush_fd < 0` means "accumulate in the builder,
   there is no live display"). On failure (`ok == false`) or no real fd at
   all, width stays 0.
2. **On resize**, `apply()` (shared by both loops) now intercepts
   `Window_Size_Msg` — which already arrives via `Signal_Watcher`'s SIGWINCH
   handling, no new plumbing needed there — calls `renderer_set_width`, and
   then **falls through** to the user's own `update()` (unlike `Quit_Msg`/
   `Interrupt_Msg`, which return early): a resize is not terminal to the
   loop, and Bubble Tea apps commonly want to react to it for their own
   layout. A `Window_Size_Msg{w:0}` (signals.odin's own "the ioctl lookup
   failed" sentinel) is ignored rather than clobbering a previously-known
   width with "unknown."

Why "told" and not "asks" (renderer holds the fd, calls `term_size` itself
inside `renderer_render`): that would tie `Renderer` to `posix.FD` and break
the golden harness outright — `golden_test.odin` drives `run()` with
`flush_fd` defaulting to `-1` (no fd of any kind), and the harness's whole
value (spec §10, §13.1) is running the renderer with **zero terminal
involvement**. The existing architecture already writes exclusively to a
`strings.Builder`, never an fd, for exactly this reason; the width source
had to respect the same boundary. "Told" also directly matches how
`Window_Size_Msg` already flows through the mailbox into `apply()` — no new
seam, just a new consumer of an existing one.

### Width 0 / unknown

`rows_for_line(line, term_width, opts)` returns exactly **1** whenever
`term_width <= 0` — no division, no guess. This is deliberately identical to
the OLD (pre-fix) behavior of "one row per logical line" for every case
where no real width has ever been observed: `term_size()` returning
`ok=false` on an unconfigured pty, the golden harness's `flush_fd = -1`, and
every existing unit test that constructs a bare `Renderer` and never calls
`renderer_set_width`. This is why **zero existing tests needed their
expected bytes changed** — see §5.

### Column positioning: does the rewind need `\e[G`/`\r` too?

**No — traced, not assumed.** `renderer_render` always terminates every
written line (wrapped or not) with `"\r\n"`, so the cursor is always at
column 1 the moment a rewind begins. `\e[1A` (cursor up) never changes
column. `\e[2K` is erase-mode **2** — "erase entire line," which the man
page and every terminal implement as column-independent — so it does not
matter that a middle `\e[1A` might otherwise land at an unexpected column;
mode 2 clears the whole physical row regardless. So the only thing that was
ever wrong is *how many* `\e[1A\e[2K` pairs to emit, never *where* the
cursor sits when emitting them — confirmed empirically by the pty+pyte
after-fix captures in §6 (clean screens, no leftover column artifacts), not
merely reasoned about. No cursor-column fix was added; none was needed.

### `last_rows` semantics (renamed from `last_lines`)

Renamed because the field's meaning changed: it must record **what the
previous `renderer_render` call actually painted, at whatever width was in
effect then** — not a function of the renderer's *current* width. This
matters directly for resize-mid-run: `renderer_set_width` deliberately never
touches `last_rows` retroactively (see its doc comment in `render.odin`), so
a resize landing between two renders doesn't corrupt the next rewind. Proven
by `test_resize_mid_run_rewind_matches_what_was_painted_at_old_width`
(§5below).

---

## 5. Tests added (all passing; full list of new/changed test files)

- `runetea/width_test.odin` (new, 13 tests) — `display_width`/`rows_for_line`/
  `is_ambiguous_width`, one test per defect plus edge cases.
- `runetea/render_test.odin` (+5 tests, existing 6 unchanged in assertion
  values, `last_lines` field references mechanically renamed to `last_rows`):
  - `test_regression_wide_line_rewinds_physical_rows_not_logical_lines` — the
    Step 1 reproduction as a byte-exact unit test: `examples/simple`'s exact
    view string at width 20, asserting `last_rows == 4` (not the old 3) and
    the exact 4×`\e[1A\e[2K` rewind on the next frame.
  - `test_wide_cjk_line_wraps_and_rewinds_correctly` — "日本語日本語" (18
    bytes, 12 columns) at 10-column width, `ceil(12/10) = 2` rows.
  - `test_emoji_with_vs16_wraps_and_rewinds_correctly` — "❤️" (defect-2
    corrected width 2) at 1-column width, `ceil(2/1) = 2` rows.
  - `test_resize_mid_run_rewind_matches_what_was_painted_at_old_width` —
    render at width 20 (2 rows), `renderer_set_width(80)`, render again;
    rewind is still 2×`\e[1A\e[2K` (what width-20 painted), and the NEW
    `last_rows` (1) reflects width 80 for the row after.
  - `test_unknown_width_falls_back_to_pre_fix_behavior_byte_for_byte` —
    `renderer_init` with no width argument, same wrapping-length line,
    asserts byte-for-byte identical output to the pre-fix renderer.

### The documented 14-byte baseline: UNCHANGED, and here is why

`test_identical_frame_costs_a_full_repaint` still asserts exactly
`"\e[1A\e[2K" + "same\r\n"`, 14 bytes. This test never calls `renderer_init`
with a width and never delivers a `Window_Size_Msg`, so `term_width` stays 0
(unknown) throughout — `rows_for_line` returns 1 for `"same"` at width 0 by
construction, identical to the old `len(lines) == 1`. Nothing about this
test's code path changed at all; it is included here because the task asked
for an explicit statement either way, not because anything moved.

### Full suite

```
$ ./tools/test.sh
Finished 77 tests in 343ms. All tests were successful.
```
(59 pre-existing + 18 new: 13 in `width_test.odin`, 5 in `render_test.odin` —
see the file list above.)

```
$ ./tools/test.sh race
=== racecheck: all phases completed without crashing (2.79s) ===
```
Unaffected — this change touches no concurrency-relevant code (no new
threads, locks, or shared mutable state beyond `Renderer`'s own fields,
which are only ever touched from the single loop thread that already owned
them).

---

## 6. Before/after, pty-verified, both examples

All four runs below are the real compiled binary under a real pty
(`pty.fork` + `ioctl(TIOCSWINSZ)`), captured with the harness in §1's Method,
screen-rendered with `pyte` at the matching geometry.

### `examples/simple`, AFTER the fix, 20 columns (was corrupted, §1)

```
frame 2 rewind: \e[1A\e[2K x4   (was x3)
```
```
 0 |Hi. This program wil|
 1 |l exit on 'q'.      |
 2 |                    |
 3 |Keys pressed: 6     |
 4 |                    |  <-- cursor
 5..9 | (blank)          |
```
Clean at every frame across 7 keypresses — no stale rows, no duplication.
Compare directly against §1's 6-row garbage stack for the identical input.

### `examples/simple`, AFTER the fix, 80 columns (regression check)

```
frame 2 rewind: \e[1A\e[2K x3   (unchanged from before the fix)
```
```
 0 |Hi. This program will exit on 'q'.  |
 1 |                                    |
 2 |Keys pressed: 6                     |
 3 |                                    |  <-- cursor
```
Byte-for-byte identical rewind count to the pre-fix binary at 80 columns —
confirms zero regression at a width where nothing wraps.

### `examples/http`, AFTER the fix, 20 columns

```
b'Checking http://example.com ...\r\n\x1b[1A\x1b[2K\x1b[1A\x1b[2Khttp://example.com -> 200\r\n'
rewind count: 2   (was 1, pre-fix — see §1's second data point)
```
```
 0 |http://example.com -|
 1 |> 200               |
 2 |                    |  <-- cursor
 3..9 | (blank)          |
```
Clean — no leftover "Checking http://exam" row (compare against §1's
pre-fix capture of the same program/width, which left exactly that row
behind).

### `examples/http`, AFTER the fix, 80 columns (regression check)

```
b'Checking http://example.com ...\r\n\x1b[1A\x1b[2Khttp://example.com -> 200\r\n'
rewind count: 1   (unchanged)
```
Identical to pre-fix at 80 columns.

---

## 7. Out of scope, confirmed not touched

Per the task's explicit exclusions: no cell buffer/diffing renderer (T3), no
alt-screen support, no horizontal scrolling or truncation policy — every
logical line is still written to the builder exactly once, whole; the
terminal does its own wrapping. The only thing that changed is how many
physical rows the renderer believes that wrapping produced, for rewind
counting.

---

## 8. Amendment (T2-A, 2026-07-28) — two statements above are now out of date

This document is T1's evidence trail and is otherwise left as written. Two of
its claims were overtaken by T2-A; the authoritative text is now the doc
comments in `runetea/width.odin` and `runetea/render.odin`.

1. **§3 / the width layer: escapes were counted as content.** `display_width`
   measured every byte of an ANSI escape except the `ESC` itself (which
   `normalized_east_asian_width` already returned 0 for, via `is_control`), so
   `display_width("\e[7mX\e[0m")` was **7**. That fed `rows_for_line` → 
   `last_rows` → the rewind, i.e. the *exact* defect class §1 reproduced under a
   pty, reached through styling instead of through wrapping. Now **1**: escapes
   are skipped by a byte pre-pass that splits the string at `ESC` boundaries and
   runs the (untouched) grapheme-cluster loop per escape-free segment. Covered:
   CSI, the ST-terminated string family (OSC/DCS/PM/APC/SOS), nF/Fe/Fp/Fs
   two-or-more-byte escapes, and unterminated escapes (zero width to
   end-of-string — a stated choice, see `skip_escape`).

2. **§4's "Column positioning" and §7's "no cursor positioning".** The rewind
   itself still needs no `\e[G`/`\r` fixup, and that reasoning is unchanged and
   still load-bearing. What changed is that apps can now *place* the cursor
   (`rt.Cursor` + `Program.cursor`), which necessarily leaves it somewhere other
   than home. The invariant is preserved by **restoring home first**: a frame
   that placed a cursor `n` rows up begins the next frame with `\e[<n>B\r`
   before any rewind byte, so the rewind loop and §4's proof are untouched. The
   two moves are symmetric by construction, which is why the placement clamps
   into the painted frame (CUU/CUD stop at the screen margins, so an overshoot
   would truncate on the way up but not on the way down). `examples/editor` no
   longer paints a `|` caret glyph.
