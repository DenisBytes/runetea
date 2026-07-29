# RuneTea — Known Limitations

**Read this before adopting RuneTea.** Everything below is something RuneTea
does not do, does not do fully, or does differently from what you would
reasonably expect. It is written to be *accurate*, not reassuring; an entry you
disagree with is a bug report.

### Where this document lives, and why

`docs/LIMITATIONS.md` — beside the code, versioned with it, one directory above
`docs/superpowers/`, which holds the *maintainer-facing* decision records. Those
records contain the reasoning; this file contains the consequences. Every entry
here cross-references the source comment or decision doc that argues the case
rather than restating it, so there is exactly one place for each argument to
rot.

The reason it exists at all is a rule this codebase applies to itself: **silent
degradation is unacceptable in a library other people build on.** Where a
limitation could be fixed, it was. Where it could be made loud (an assertion, an
explicit error, an observable flag), it was. What is left is the residue that
can only be written down — and a limitation documented only in a source comment
is a limitation documented for maintainers, not for users.

### How to read the labels

| Label | Meaning |
|---|---|
| **INTRINSIC** | Cannot be fixed without changing the design or the protocol. Plan around it. |
| **NOT-YET-BUILT** | A real gap with a known shape. Could be closed; has not been. |
| **TOOLCHAIN** | Caused by Odin's `core:` libraries or by the compiler, not by RuneTea. |

---

## 1. Platform

### 1.1 Linux only, in practice — **NOT-YET-BUILT** (Darwin/BSD) / **INTRINSIC** (Windows, for v1.0)

`term_size` goes through `core:sys/linux` directly, because `core:sys/posix`
exposes neither `ioctl` nor a `winsize` struct (`runetea/term.odin:676-686`).
Darwin and BSD are unvalidated and untested — the design doc's own words are
*"Ship Linux as verified, Darwin/BSD as best-effort pending a contributor"*
(`docs/superpowers/specs/2026-07-25-runetea-design.md:515`).

**Windows is explicitly out of scope for v1.0** (same doc, `:490-494`). It is a
separate ~1,000-LOC console backend, not a port.

**When it bites:** immediately, on any non-Linux machine.
**What to do instead:** nothing, for now. On Darwin, expect the size query — and
therefore `.Diff` mode and full-screen truncation, see 3.5 — to be the first
thing that fails.

### 1.2 No stack traces — **TOOLCHAIN**

`core:debug/trace` does not link on the reference machine (`cannot find
-lstdc++exp`), so a panic gives you a message, not a backtrace
(`docs/superpowers/specs/2026-07-25-runetea-design.md:380-383`).

### 1.3 `SIGUSR2` is reserved package-wide — **INTRINSIC**

The signal watcher uses it for its own stop nudge (`runetea/signals.odin:14-35`).
An application cannot use `SIGUSR2` for itself.

### 1.4 The blocked signal mask is inherited by child processes — **INTRINSIC**

`runetea/signals.odin:116`. **When it bites:** the moment you shell out to
`$EDITOR`, a pager, or a build tool. The child inherits `SIGINT`/`SIGTERM`/
`SIGWINCH` blocked and becomes un-Ctrl-C-able.
**What to do instead:** clear the mask yourself before `exec`. Nothing in
RuneTea does it for you, and RuneTea has no `suspend`/`exec` helper (see 8.1).

### 1.5 `signal_watcher_start` must run before any other thread exists — **INTRINSIC**

POSIX signal masks are inherited by threads at creation. A minimal repro with
one unrelated unblocked thread killed the process 5/5 times on an external
`SIGINT`, *even though a correctly-blocked `sigwait` watcher existed*
(`runetea/signals.odin:70-83`).

**When it bites:** an application that starts its own worker pool before calling
`run()`. `run()` gets the ordering right internally
(`runetea/tea.odin:217-247`), so this only affects apps doing their own
threading.

---

## 2. Message and Cmd model

### 2.1 Every `Msg` type must be POD — **INTRINSIC**

`string`, `cstring`, `^T`, `[]T`, `[dynamic]T`, `map`, and `any` are **illegal**
anywhere in a `Msg`'s field tree (`runetea/arena.odin:65-96`). This is the
single largest permanent ergonomic cost of the design, and it touches every
program.

Concretely illegal: Bubble Tea's `PasteMsg{Content string}`
(`runetea/input.odin, Paste_Start_Msg`), `BatchMsg([]Cmd)` (`runetea/batch.odin:12-22`),
anything carrying an HTTP body or an `fmt.aprintf` result.

**What to do instead:** a fixed-capacity `Msg_Text` for short text (see 2.3);
for anything larger, put the payload in application-owned storage and send a
handle (an index, an ID) as the `Msg`.

### 2.2 The POD check is at *runtime*, not compile time — **TOOLCHAIN**

Odin cannot fold `is_pod_type` into a compile-time constant
(`runetea/arena.odin:153-162`; repro in `tools/podcheck/main.odin`).

**When it bites:** an illegal `Msg` type compiles clean and panics the first
time that code path executes — possibly in production, on a rare branch.
**What to do instead:** call `box()` on every `Msg` type you define, once, in a
test.

### 2.3 `Msg_Text` holds 255 bytes — **INTRINSIC** (the cap) / **fixed** (the silence)

`MSG_TEXT_CAP :: 255`, and 255 rather than 256 because `len` is a `u8`
(`runetea/msg.odin`). The cap is what makes the type POD, and POD is what lets
it cross a `Msg` boundary at all — it cannot be raised without giving up the
thing it exists for.

**Truncation is no longer silent.** `Msg_Text` carries a `truncated` flag, set
exactly when the input did not fit, readable with `msg_text_truncated(m)`.
`msg_text_fmt` formats into `MSG_TEXT_CAP + 1` bytes and keeps `MSG_TEXT_CAP`,
so an exact fit and a clip are distinguished precisely rather than guessed from
the length.

**When it bites in practice:** rarely for its intended use. `Msg_Text` exists
for error strings and status lines, and 255 bytes holds `dial: connection
refused` a hundred times over. It bites when someone reaches for it as a general
payload carrier — an HTTP response body, a log line, a file path list.
**What to do instead:** for a bounded-but-longer payload, a `[N]u8` + `len` of
your own is equally POD and equally legal. For an unbounded one, keep it in your
model and send a handle. RuneTea has no handle type for you; that is the
not-yet-built half of this entry.

### 2.4 `msg_text_string` borrows; only `msg_text_clone` owns — **INTRINSIC**

`runetea/msg.odin, msg_text_string`. Retaining the borrowed string past the current
statement dangles once the loop frees the `Msg`. The naming is the entire
warning.

### 2.5 Cancellation is polling, never preemption — **INTRINSIC**

*"Nothing about a `Cancel_Token` can interrupt a Cmd that is blocked inside a
syscall it never returns from"* (`runetea/cmd.odin:80-89`; full argument,
including why `pthread_cancel` is strictly worse, in
`docs/superpowers/cancellation-decision.md:552-571`).

**When it bites:** quit takes as long as your slowest blocking Cmd. Named
unfixable cases: `net.dial_tcp_*` (`core:net` has no timeout), a child-process
`wait()`, a blocking read on a hung NFS mount.
**What to do instead:** write Cmds as bounded retry loops that poll the token.
`examples/http` shows the shape.

### 2.6 `run()` bounds quit at 100 ms; `run_nbio()` does not — **NOT-YET-BUILT**

`QUIT_GRACE = 100ms` applies to `run()` only (`runetea/tea.odin:281-282`).
`run_nbio` keeps a fully synchronous teardown and blocks on the slowest Cmd
(`docs/superpowers/cancellation-decision.md:557-560`).

### 2.7 A Cmd that panics leaks whatever it had allocated — **INTRINSIC**

`setjmp`/`longjmp` recovery does not unwind and does not run `defer`
(`runetea/cmd.odin:487-498`). **When it bites:** a long-running app whose Cmds
panic repeatedly grows without bound. The same applies to a panic inside
`batch()`/`sequence()` coordination logic (`runetea/batch.odin:249-270`).

### 2.8 One `^Thread` struct (~256 B) leaks per `run()`/`run_nbio()` session — **INTRINSIC**

Deliberate, bounded, one per session, and the only entry on the leak
allowlist in `tools/test.sh`. `self_cleanup = true` has a genuine race inside
`core:thread` that ThreadSanitizer catches reproducibly, so the thread is
detached by hand instead; the kernel stack and TCB *are* reclaimed
(`runetea/cmd.odin:349-406`).

**When it bites:** a process that starts thousands of `run()` sessions.

### 2.9 A detached Cmd is exposed to a `core:thread` race — **TOOLCHAIN**

A signal-then-free race on `t.start_ok` in `thread_unix.odin`, caught by TSan
roughly 1 run in 5–8 (`runetea/cmd.odin:375-406`). Not patchable from this
package. **When it bites:** rarely, on a `detached = true` Cmd whose body
finishes in microseconds — which is what `batch()`/`sequence()` coordinators do.

### 2.10 One OS thread per compose Cmd, at every nesting depth — **INTRINSIC**

`runetea/batch.odin:44-53`. A hot loop building hundreds of individually
composed sub-batches spawns hundreds of threads
(`docs/superpowers/batch-sequence-decision.md:428-437`).

### 2.11 A `Tick`/`Every` inside `batch()`/`sequence()` gates nothing — **NOT-YET-BUILT**

`sequence([step_a, tick(1s), step_b])` does **not** pause for a second; the tick
step signals `done` immediately (`runetea/cmd.odin:651-662`). There is no
correct semantics for a nested `Every` at all
(`docs/superpowers/batch-sequence-decision.md:404-419`).

### 2.12 `batch()` takes a slice, not a variadic — **INTRINSIC**

`batch([]Cmd{a, b}, context.allocator)` (`runetea/batch.odin:98-102`).

### 2.13 Timer handles must be stopped exactly once — **INTRINSIC**

`tick_cancellable`/`every` hand out a `Timer_Handle` that must be passed to
`timer_stop` exactly once — never zero times (the handle *and* its cloned
closure env are stranded for the life of the process), never twice (a refcount
decrement against possibly-freed memory). `runetea/timer.odin:56-72`. Plain
`tick()` deliberately hands out no handle so the common case is unleakable.

### 2.14 Timer subsystem start failure is silent — **NOT-YET-BUILT**

If `nbio.acquire_thread_event_loop` fails, every future `tick`/`every` on that
`Dispatcher` never fires, with no error surfaced
(`runetea/timer.odin:344-355`, `:582-591`). **When it bites:** your spinner
stops, forever, with no diagnostic. This is the worst-shaped remaining
limitation in the library and it is on the list to fix.

### 2.15 Back-pressure policy is "retry forever", not "drop" — **NOT-YET-BUILT**

`deliver_result` retries on a full mailbox and a caller has no way to say "I am
cosmetic, drop me" (`runetea/cmd.odin:408-435`;
`docs/superpowers/tick-every-decision.md:467-470`). **When it bites:** a 60 fps
`every()` whose consumer stalls blocks the timer thread instead of shedding
frames.

### 2.16 `every()` does not align to wall-clock multiples — **INTRINSIC**, deliberate

Two independent 1-second `Every`s never tick in lockstep
(`runetea/timer.odin:184-192`). Under a stall, `every()` skips at most one
interval and never bursts catch-up fires (`:678-686`) — right for animation,
wrong for anything counting ticks.

### 2.17 Mailbox capacity is hard-coded at 256 — **NOT-YET-BUILT**

`runetea/tea.odin:212`, `runetea/loop_nbio.odin:52`. A paste over ~1000
characters fills it and the reader spins (`runetea/tea.odin:453-462`).

### 2.18 The mailbox is single-consumer, and `try_recv`'s `ok=false` is ambiguous — **INTRINSIC**

Empty and closed are the same answer; `mailbox_closed_and_empty` disambiguates
(`runetea/mailbox.odin:117-157`).

---

## 3. Rendering

### 3.1 OSC 8 hyperlinks in `.Diff` — **FIXED**

*Previously the worst entry in this document.* The `.Diff` renderer consumed
non-SGR escapes for width and dropped them, so a view containing an OSC 8
hyperlink rendered as plain text — and a frame in which only the *destination*
changed cost zero bytes, because every cell compared equal.

`Cell` now carries an interned `link` index beside its `style` index, and OSC 8
is tracked per cell exactly as SGR is (`runetea/screen.odin`,
`runetea/render.odin`). A program that uses no hyperlinks emits byte-for-byte
what it emitted before.

**Two residual contracts, both real:**

- **Close your hyperlinks before the end of each line.** The model treats an
  erased cell as unlinked, and the `.Diff` emitter guarantees that by closing
  the link before every `\e[K` it writes. The `.Full_Screen` repaint, which
  passes your view's bytes through untouched, cannot: a line that opens a link
  and never closes it before the renderer's trailing `\e[K` may leave the erased
  tail linked on some terminals. RuneGloss closes everything it emits; a
  hand-written view owes nothing.
- **An unterminated OSC 8 changes nothing.** No `ST`, no `BEL`, no link — acting
  on half a URI would open a link nobody asked for. See 3.9.

### 3.2 Views may contain styling and hyperlinks, not motion — **INTRINSIC**, now checkable

`.Diff` models exactly two escapes per cell: SGR and OSC 8. A view containing a
C0 control byte (`\t`, `\r`, `\b`, `\a`), a cursor-motion CSI, an erase, a
window-title OSC, a sixel, or a truncated escape is *lying to the model* — it
renders correctly under `.Full_Screen` and wrongly under `.Diff`, and nothing
notices.

**This is now checkable and loud rather than only described:**

- `runetea.view_diff_safe(view) -> (ok, at, why)` is a public, allocation-free
  predicate. Call it in your own tests, on your own views.
- Debug builds assert it on every frame and panic naming the byte offset and the
  reason (`RUNETEA_DIFF_STRICT`, default `ODIN_DEBUG`; force with
  `-define:RUNETEA_DIFF_STRICT=true|false`).

`\t` is the one that bites in practice: it is a *move* to the next tab stop,
whose position the cell model does not track. Expand tabs to spaces.
`examples/editor` does, in both its Tab key handler and — since this checker was
pointed at it — its document loader.

**What to do instead:** if your view genuinely needs to drive the terminal, use
`.Full_Screen`, which tolerates anything.

### 3.3 An inline frame taller than the screen corrupts the display — **NOT-YET-BUILT**

The inline renderer rewinds with `\e[<n>A`, which **clamps at the top margin**,
while the matching `\e[<n>B` does not compensate. A frame taller than the
terminal therefore desynchronises "home" permanently, and the error compounds
every frame (`runetea/render.odin, `render_inline` ("A frame TALLER than the screen")` — *"Unchanged, not newly
introduced"*).

**When it bites:** any `.Inline` application that renders more lines than the
terminal has rows. This is the most user-visible unfixed rendering defect in the
library.
**What to do instead:** keep inline frames short (that is what the mode is for),
or use `.Full_Screen`/`.Diff`, which have an absolute origin and truncate
instead.

### 3.4 Content taller than the viewport is truncated at the bottom — **INTRINSIC**, deliberate

`.Full_Screen` and `.Diff` drop what does not fit, and drop a *whole logical
line* even when one of its wrapped rows would have fitted
(`runetea/render.odin, `render_full_screen` ("TRUNCATE AT THE BOTTOM")`). Scrolling is the application's job.
`examples/editor` scrolls itself.

### 3.5 `.Diff` degrades to a full repaint when the size is unknown — **INTRINSIC**

No width or height means no viewport to model, so the frame is `.Full_Screen`'s
bytes and the model is invalidated (`runetea/render.odin, `render_diff` ("NO SIZE, NO VIEWPORT, NO MODEL")`).

**When it bites:** wherever `TIOCGWINSZ` has no answer — a pty with no size ever
set, output redirected to a file, a test harness. The mode that exists to save
bandwidth quietly costs ~104 KB/s again. It recovers on the first
`Window_Size_Msg`.

### 3.6 Style interning is by raw byte spelling — **INTRINSIC**

`\e[1m\e[31m` and `\e[31;1m` intern as two different styles even though they
render identically (`runetea/screen.odin, Style_Table`).

**When it bites:** a hand-written view (or a third-party widget) that emits
varying spellings of the same style makes `.Diff` repaint unchanged cells
forever — the mode's entire benefit is lost, silently. RuneGloss fixes its SGR
parameter order precisely to avoid this (`runegloss/render.odin:679-686`);
nothing enforces it on views you write yourself.
**What to do instead:** emit one fixed spelling per style.

### 3.7 Style-table overflow forces a permanent repaint — **INTRINSIC**

Past `STYLE_TABLE_MAX :: 4096` distinct styles or `STYLE_BYTES_MAX :: 1 MiB`,
the table is dropped and the screen force-repainted, bounded to one retry per
frame (`runetea/screen.odin, STYLE_TABLE_MAX` and `runetea/render.odin, render_diff`'s style-overflow retry). Aliasing
two styles onto one index would be a silently wrong screen, which is the one
failure this design cannot tolerate.

**When it bites:** a view that manufactures unbounded distinct SGR strings — a
colour gradient recomputed per frame. A *single* frame with more than 4096
distinct styles repaints permanently. The same applies to the hyperlink table.

### 3.8 A wide cluster on the right margin diverges from xterm — **INTRINSIC**

RuneTea models it as written *in* that column; xterm-family terminals leave the
cell blank and wrap the whole cluster (`runetea/screen.odin's header, "A WIDE CLUSTER AT THE LAST COLUMN"`). This is a
pre-existing consequence of `rows_for_line`'s ceil division, and the width layer
and the cell model are uniformly "one cell optimistic" together rather than
inconsistent with each other.

**When it bites:** a CJK or emoji line ending exactly at the right margin.

### 3.9 A truncated escape measures as zero width to the end of the string — **INTRINSIC**

`runetea/width.odin:119-131`. The terminal will consume the missing tail from
whatever is written next, so counting the fragment as content would be worse.
**Consequence worth knowing:** text placed *after* an unterminated escape in the
same view is swallowed as payload, not painted. `view_diff_safe` reports this as
`.Truncated_Escape`.

### 3.10 `\e[K` is never used to clear a styled or linked tail — **INTRINSIC**

Whether an erase records underline, strike, or only the background is
terminal-dependent, so those cells are written as real spaces
(`runetea/render.odin, `emit_row`'s "\e[K OPPORTUNITY"`). **When it bites:** a full-width coloured status
bar costs N space-writes per changed row instead of 3 bytes.

### 3.11 Render mode is fixed at construction — **NOT-YET-BUILT**

`runetea/render.odin, `renderer_init` ("fixed AT CONSTRUCTION")`. An application that wants an inline prompt and
then a full-screen editor wants two `run()` sessions.

### 3.12 A `.Diff` `Renderer` must not be copied by value — **INTRINSIC**

Both `Screen`s hold pointers *into* the `Renderer` struct
(`runetea/render.odin, Renderer.screens`). It self-heals on the next frame, but do not do
it.

### 3.13 A grapheme cluster longer than 64 KiB renders as a blank — **INTRINSIC**

`Cell.len` is a `u16`; storing a truncated prefix would put invalid UTF-8 on the
wire (`runetea/screen.odin, put_cell`). Adversarial input only.

### 3.14 `View` is a `string`, not a declarative struct — **INTRINSIC** for v1.0

Bubble Tea v2's per-frame declaration of alt-screen / mouse mode / focus / paste
/ Kitty state, diffed by `viewEquals`, is **not** ported
(`docs/superpowers/specs/2026-07-25-runetea-design.md:409-417`). All terminal
modes are set once at `term_enter_raw`.

---

## 4. Unicode and width

### 4.1 Unicode data is pinned to UCD 15.1.0 — **NOT-YET-BUILT** (blocked on `core:unicode`)

`runetea/width.odin:6-11`, `:351-357`; *"unaddressed by design… out of scope
here. Noted, not fixed"*
(`docs/superpowers/render-width-decision.md:230-236`).

**When it bites:** any emoji or script added in Unicode 16 or 17 measures with
stale grapheme-break and width properties. New ZWJ sequences can split into
multiple clusters and blow the column count, desynchronising the inline rewind
or putting a caret in the wrong column.

### 4.2 East-Asian *Ambiguous* width is a global boolean you must guess — **INTRINSIC**

There is no universally correct answer and the terminal does not report it
(`runetea/width.odin:37-49`). Default is narrow, matching `core:unicode` and
xterm.

**When it bites:** a user on a CJK-locale terminal that renders box-drawing
characters, curly quotes, Greek and Cyrillic double-wide sees every border and
every box layout ragged.
**What to do instead:** expose `Width_Options{ambiguous_is_wide = true}` as a
user setting. RuneTea cannot detect it for you.

### 4.3 Only 16 runes per cluster are inspected for the width corrections — **INTRINSIC**

`MAX_INSPECTED_RUNES :: 16` (`runetea/width.odin, MAX_INSPECTED_RUNES`). A cluster longer
than that keeps the iterator's own width and loses the VS16 / regional-indicator
/ leading-mark corrections. Real ZWJ family emoji stay under a dozen runes; this
is a hostile-input concern.

### 4.4 A cluster split by an embedded escape measures as two clusters — **INTRINSIC**

`"e" + "\e[0m" + U+0301` is two segments, not one cluster
(`runetea/width.odin:82-86`). Harmless in the cases that occur (both paths give
width 1) but a real divergence from strict UAX #29.

### 4.5 Unknown terminal width means "one row per logical line" — **INTRINSIC**

`rows_for_line` returns 1 with no width, which is the pre-fix behaviour and the
only sound default with zero information (`runetea/width.odin:319-337`).

**When it bites:** with output redirected or on a pty with no size, the inline
renderer's rewind under-counts on any wrapped line and the frame walks up the
screen.

---

## 5. Input

### 5.1 Lone `ESC` and unterminated paste need a timer — **INTRINSIC** without one, **largely mitigated**

Three related cases, all with the same root cause: a decoder with no clock
cannot distinguish "a sequence is still arriving" from "a key was pressed".

- **A lone `ESC` at the end of the buffer** resolves immediately as
  `Key_Code.Escape` (`runetea/input.odin, `decode_keys`' lone-ESC note`).
- **`ESC O` with no third byte** resolves as `Alt+O`; and `Alt+O` immediately
  followed by another keystroke *within one read* is swallowed as an
  unrecognised SS3 (`:1263-1274`, pinned by `test_esc_o_ambiguity`).
- **An unterminated bracketed paste** strands at most five held-back bytes
  (`:1184-1194`).

**The Kitty keyboard protocol removes the first two entirely.** With
`Disambiguate` negotiated, Escape arrives as `CSI 27 u` — a complete,
unambiguous sequence with a final byte — and `Ctrl+[` arrives as `CSI 91;5 u`.
They are simply different byte strings (`runetea/input.odin, kitty_decode`). RuneTea
requests Kitty by default and decodes the reply into
`Keyboard_Enhancements_Msg`.

**What to do instead:** enable and prefer the Kitty protocol, and check the
`Keyboard_Enhancements_Msg` reply so your application knows which world it is
in — `examples/editor` prints `kitty:on`/`kitty:off` in its status line for
exactly this reason. On a terminal with no Kitty support, a user who presses
Escape *as the last byte of a read* gets Escape, which is what they meant
> 99% of the time; the residual risk is an ESC-prefixed sequence split across a
read boundary, which requires a terminal writing a partial escape and a read
landing inside it.

### 5.2 Legacy (X10) mouse coordinates wrap past column 223 — **INTRINSIC**

The X10 encoding packs a coordinate into one byte as `coordinate + 32`, so
column 224 encodes as byte 0 and is indistinguishable from garbage. It clamps to
0 rather than reporting a negative index (`runetea/input.odin, x10_mouse`).

**This limitation is the entire reason `term_enter_raw` always requests
`?1006h`** (SGR extended coordinates) alongside every tracking mode
(`runetea/term.odin:116-125`). SGR reports coordinates as decimal parameters
with no upper bound.

**When it bites:** only on a terminal that ignored the `?1006h` request, and only
past column 223. Nothing to do about it; it is what the protocol says.

### 5.3 X10 cannot say *which* button was released — **INTRINSIC**

A release is `Cb` bits 0–1 == 3, the same value the protocol uses for "no
button", so the identity is simply not on the wire. Such an event reports
`kind = .Release, button = .None`. Faking it from the last press was rejected:
it would be a guess presented as a fact, and it breaks with two buttons held
(`runetea/input.odin, x10_mouse`).

### 5.4 urxvt (1015) and SGR-pixel (1016) mouse encodings are not decoded — **NOT-YET-BUILT**, assessed as closed

RuneTea negotiates and decodes SGR (1006) and decodes legacy X10 as the
fallback. Neither 1015 (urxvt) nor 1016 (SGR-pixel) is requested or decoded.

**1016 (SGR-pixel)** reports pixel coordinates rather than cells. A cell-grid
TUI has nothing to do with pixel coordinates, and RuneTea never requests it, so
no terminal will ever send it. Closed on the merits.

**1015 (urxvt)** is the interesting one, and the honest answer is narrower than
"every modern terminal speaks 1006":

- Nothing in the terminfo database advertises mouse *encodings*. `kmous=\E[M` is
  present in 22 of the 40 entries installed here, including
  `rxvt-unicode-256color`, and it describes the X10 form only. Terminfo
  therefore offers no evidence either way, which is itself worth knowing.
- rxvt-unicode gained SGR (1006) support in 9.25 (2016). Versions older than
  that ignore `?1006h` and keep sending X10 — which RuneTea **does** decode, so
  the failure mode is not "mouse does not work" but "mouse does not work past
  column 223" (see 5.2).
- 1015 is an urxvt-only extension. Supporting it would buy correct coordinates
  past column 223 on rxvt-unicode older than 9.25, and nothing else.

**Verdict: document and close.** The population is "urxvt from before 2016, in a
terminal window wider than 223 columns". If you are in it, the symptom is mouse
coordinates that wrap, and the fix is upgrading urxvt.

### 5.5 There is no terminfo consultation — **NOT-YET-BUILT**, assessed as closed for v1.0, with two named gaps

The key tables are xterm/VT220 defaults, not the terminal's own
(`runetea/input.odin`). The usual claim — "xterm defaults cover the common
terminals" — was **measured against every terminfo entry installed on the
reference machine** rather than assumed. Decoded key capabilities per entry:

| Entry | decoded | missed | what is missed |
|---|---|---|---|
| `xterm`, `xterm-256color` | 136 | 21 | keypad block, F13–F20, `kmous` |
| `tmux`, `tmux-256color` | 136 | 2 | `kmous` (decoded elsewhere), `kcbt`\* |
| `screen` and variants | 23 | 2 | as above |
| `screen.xterm-256color` | 133 | 21 | keypad block, F13–F20 |
| `vt220`, `wsvt25` | 22–25 | 8 | F13–F20, `khlp`, `krdo` |
| `linux` | 20 | 16 | **F1–F5**, F13–F20, keypad |
| `rxvt-unicode`, `rxvt` | 25–29 | 46–58 | **all modified keys** |
| `Eterm`, `sun`, `cons25`, `mach` | 6–29 | 11–64 | most function keys |

\* `kcbt` is Shift+Tab, and measuring this **found and closed a real gap** — see
below.

**So the claim holds for the terminals people use** (xterm, tmux, screen,
alacritty/foot/kitty/wezterm all emit xterm sequences) **and does not hold for
two specific populations:**

- **The Linux virtual console.** F1–F5 are `\e[[A` … `\e[[E`, which are not
  valid CSI sequences under this grammar at all. F6–F12 use the standard tilde
  forms and *do* decode. **When it bites:** F1–F5 on a bare TTY.
- **rxvt / rxvt-unicode modified keys.** Shifted and ctrl-modified navigation
  uses lowercase finals (`\e[a`, `\e[b`) and `$`-final forms (`\e[3$`, `\e[7$`,
  `\e[8$`). Unmodified keys decode fine. **When it bites:** Shift+Arrow,
  Ctrl+Home and friends on urxvt.

Everything else missed is the keypad application-mode block (`\eOw`, `\eOx`, …,
`\eOM` for keypad Enter) and F13–F20, which `Key_Code` has no members for. Those
are vocabulary gaps, not table gaps: terminfo would not help.

**Verdict: document and close for v1.0.** Consulting terminfo is a large, real
piece of work (parsing the binary format or shelling out to `infocmp`, plus a
runtime-built trie and a fallback for `TERM` values with no entry), and the
measurement says it would buy the Linux console's F1–F5 and urxvt's modified
keys.

### 5.6 Shift+Tab — **FIXED**

`CSI Z` (`kcbt`) now decodes as `Tab + {.Shift}`. It was previously on the
cleanly-ignored path, so **Shift+Tab did nothing on 21 of the 40 terminfo
entries installed here** — xterm, xterm-256color, tmux, screen, rxvt,
rxvt-unicode — unless the Kitty protocol happened to be negotiated, under which
the same keypress *did* decode (`CSI 9;2u`). "Previous field" is a standard
binding in every form-shaped TUI, and this was the highest-value finding of the
terminfo measurement.

### 5.7 Modifier bits above bit 8 are masked off — **NOT-YET-BUILT**

`Modifiers` has no Super, Hyper, CapsLock, or NumLock member, so `CSI 1;33A`
decodes as plain `Up` and Kitty's Ctrl+Super+a decodes as Ctrl+a
(`runetea/input.odin, xterm_mods` and `kitty_mods`). *"Lossy but honest."*
**When it bites:** any application wanting a Super-key binding.

### 5.8 A Kitty event with more than one associated codepoint drops its text — **NOT-YET-BUILT**

`runetea/input.odin, `kitty_decode`'s associated-text field`. Needs a POD-safe multi-rune field.
**When it bites:** IME and dead-key composition under the Kitty protocol.

### 5.9 `Key_Msg.kind == .Repeat` only exists under Kitty — **INTRINSIC**

The legacy encoding reports auto-repeat as an ordinary press
(`runetea/input.odin, Key_Kind`).

### 5.10 Enabling `.Report_Event_Types` makes every key arrive twice — **API trap**

Press *and* release. No example filters on `kind`
(`examples/editor/main.odin:71-75`). If you enable it, filter.

### 5.11 `CSI R` is decoded as F3 — **INTRINSIC** collision

A cursor position report (`CSI <row>;<col> R`) and modified F3 (`CSI 1;<mod> R`)
are the same bytes when row == 1. Resolved as F3, which is safe **only because
RuneTea never issues a DSR 6n** (`runetea/input.odin, `decode_keys`' "cursor position reports" note`). If you issue
one yourself, this is the collision to revisit.

### 5.12 Other cleanly-ignored input — **NOT-YET-BUILT**, mostly vocabulary

Consumed whole, emitting nothing: DECSET 9 (X10 press-only tracking), unpaired
`CSI 201~`, Kitty set/push/pop requests, F13–F35, the keypad block, media keys,
lone modifier keypresses, `Begin` (`CSI E`), and rxvt's lowercase-final arrows
(`runetea/input.odin, `decode_keys`' CLEANLY IGNORED list`). None leak garbage runes; that contract is
tested.

---

## 6. Terminal state and crash safety

### 6.1 Nothing restores the terminal on `SIGKILL` or `SIGSTOP` — **INTRINSIC**

The crash handler covers `SIGSEGV SIGBUS SIGILL SIGFPE SIGABRT SIGTRAP SIGHUP
SIGQUIT SIGTERM` (`runetea/guard.odin:162-164`). **When it bites:** `kill -9`
leaves the shell in raw mode and possibly in the alternate screen; recovery is
blind-typing `reset`.

### 6.2 A short `write` silently drops the tail of a frame — **NOT-YET-BUILT**

`flush_frame` is a single unlooped `posix.write` (`runetea/tea.odin:485-491`),
and `posix.write` is unlooped throughout `term.odin` (`:304-313`). The
cursor-hidden flag is *sticky* precisely because "a short write can deliver the
hide and drop the show" (`:443-452`).

**When it bites:** a large frame on a congested tty can be truncated mid-escape.
This is a genuine unhandled partial write and, with 2.14, one of the two
remaining entries in this document that should be fixed rather than documented.

### 6.3 A crash in a two-instruction window can emit an unpaired reset — **INTRINSIC**

Every terminal opt-in sets its flag *before* writing, so the restore assumes
"set" whenever it is not certain we did not set it
(`runetea/term.odin:275-297`, `:324-357`, `:391-409`). A crash between the flag
and the `write()` can pop a Kitty stack entry belonging to the shell. This is
argued explicitly as the right direction to be wrong in.

### 6.4 `guarded()` is not nestable on one thread — **INTRINSIC**

One `jmp_buf` per thread. A nested call returns `recovered = true` *without
running the body* rather than corrupting the jump target
(`runetea/guard.odin:31-65`). **When it bites:** calling `guarded()` from inside
`update`, `view`, or a Cmd body silently skips your body.

### 6.5 Bounds violations and nil derefs are **not** recoverable — **INTRINSIC**

They trap to the Tier-2 crash handler and kill the process
(`runetea/guard.odin:62-65`). **When it bites:** the likeliest TUI crash of all —
indexing a cell buffer out of range — is the one Tier 1 cannot catch. The
terminal is restored and the exit is honest, but the session dies.

### 6.6 A recovered `update` panic leaves your model half-mutated — **INTRINSIC**

`update` takes `model: ^T` (which bought a compile-time fix: 105 s → 1.07 s at a
32 KiB model), so a panic partway through leaves partial mutations and RuneTea
cannot roll them back (`runetea/tea.odin:74-97`;
`docs/superpowers/tier1-coverage-decision.md:376-480`).

**When it bites:** after `run()` returns a `Panicked_Error`, treat `p.model` as
**suspect** — do not persist it.
**What to do instead:** compute into locals and write into `m^` last. That is
structural, and it is the only mitigation available.

### 6.7 `install_crash_handlers()` is per-thread and must precede `term_enter_raw` — **INTRINSIC**

`sigaltstack` is per-thread (`runetea/guard.odin:126-150`). A thread you spawn
yourself has no altstack, so a stack-overflow `SIGSEGV` there re-faults and never
restores the terminal.

### 6.8 `Panicked_Error.message` is caller-owned and leaks if you ignore it — **API hazard**

`runetea/tea.odin:16-24`. `delete()` it.

### 6.9 `run()` does not own the terminal — **INTRINSIC**, deliberate

Unlike Bubble Tea, the application calls `term_enter_raw` itself and must pair
it with `defer term_restore()` and `install_crash_handlers()`, in that order
(`runetea/term.odin:190-201`, `runetea/guard.odin:141-150`). Alt screen and
full-screen rendering are **two independent opt-ins**: setting
`render_mode = .Full_Screen` without `alt = true` repaints over the user's
scrollback.

### 6.10 The Kitty push is fire-and-forget — **INTRINSIC**

A terminal may enable fewer flags than requested, or never reply
(`runetea/term.odin:174-188`). Handle `Keyboard_Enhancements_Msg` never
arriving.

---

## 7. RuneGloss (styling)

### 7.1 No wrapping, no truncation, no layout joins — **NOT-YET-BUILT**

`width`/`height` are **floors, not clamps**: content wider than `width` widens
the block (`runegloss/render.odin:51-56`). Word breaking, CJK line-break rules
and ANSI-preserving splits are explicitly out of scope, as are Lipgloss's
`JoinHorizontal`/`JoinVertical`, `table`, `tree`, and `list`
(`docs/superpowers/specs/2026-07-25-runetea-design.md:498-503`).

**When it bites:** immediately, for anyone expecting Lipgloss's `MaxWidth`. A
long line visibly overflows its box.

### 7.2 Non-canonical SGR resets silently lose the outer style — **INTRINSIC**

Only `\e[0m` and `\e[m` are recognised as resets. `\e[00m`, `\e[0;1m`, `\e[22m`,
`\e[39m`, `\e[49m` are not, and *"the outer style is silently LOST from that
point to the end of the row… Worse, runetea's cell model does not recognise them
either, so it still believes those cells are bold+red and a later frame will not
repaint them; the wrong pixels persist"* (`runegloss/render.odin:391-424`).

**When it bites:** embedding output from another tool that uses `\e[39m` to
reset only the foreground. The damage *persists across frames*.
**What to do instead:** normalise foreign SGR to `\e[0m` before handing it to
RuneGloss.

### 7.3 A truncated trailing escape in content is dropped — **INTRINSIC**, accepted

`runegloss/render.odin:507-571`. Width-neutral, and the terminal was never going
to paint it, but it is silent data loss.

### 7.4 Hard caps with no error — **INTRINSIC**

- `SGR_CAP :: 64` — a style run past 64 bytes is dropped past the cap
  (`runegloss/render.odin:629-656`). The longest run RuneGloss can currently
  build is 50 bytes, so this is unreachable today.
- `BORDER_CELL_CAP :: 8` — a custom border glyph longer than 8 bytes yields an
  **empty** cell (`runegloss/border.odin:14-53`). A ZWJ-cluster border glyph
  renders as a gap.

### 7.5 Bad colour input returns "no colour", not an error — **INTRINSIC**

A malformed hex string or out-of-range palette index styles nothing, silently
(`runegloss/color.odin:55-56`, `:83-88`). A typo'd `"#7D56F"` renders unstyled
with no diagnostic.

### 7.6 Colour down-conversion ignores palette entries 0–15 — **INTRINSIC**

And `BASE16` is xterm's defaults, *"NOT FIXED IN REALITY: every terminal lets
the user retheme 0-15"* (`runegloss/color.odin:219-223`, `:360-366`). The choice
is theme-independence over accuracy.

### 7.7 Profile detection never consults `isatty` — **INTRINSIC**, deliberate

`runegloss/color.odin:135-139`. Piping a RuneGloss app's output to a file keeps
the escapes unless the app calls `set_default_profile(.None)` itself.

### 7.8 `set_default_profile` is process-wide and affects only later Styles — **INTRINSIC**

`runegloss/color.odin:183-208`.

### 7.9 24-bit → 256 conversion is uncached — **NOT-YET-BUILT**

~720 cube roots per coloured Style per `render()` call
(`runegloss/color.odin:307-312`). Free on `.True_Color`. Width is also measured
twice per line, once per pass (`runegloss/render.odin:77-202`).

### 7.10 No fluent chaining — **INTRINSIC**

A permanent ergonomic divergence from Lipgloss (`runegloss/style.odin:5-24`).

---

## 8. Not ported from Bubble Tea

### 8.1 Absent for v1.0 — **NOT-YET-BUILT**

`suspend`/`exec` (shelling out to `$EDITOR`); the full terminal response decoder
(DA1/2/3, XTGETTCAP, OSC 10/11/12/52, DSR, XTVERSION) — which means **no
adaptive light/dark theming**; scroll-region optimisation; the declarative
`View` struct (3.14)
(`docs/superpowers/specs/2026-07-25-runetea-design.md:488-503`).

### 8.2 No closures — **INTRINSIC** to Odin

Every `Cmd` carries an explicit `env: rawptr` plus a `^Cancel_Token` parameter.
*"The port's largest permanent ergonomic cost, and it touches every user
program"* (`runetea/cmd.odin:9-21`).

### 8.3 `Program(T)` fixes the model type for the whole session — **INTRINSIC**

Parametric, not interface-based. Use a `state` enum, or make `T` itself a vtable
(`runetea/tea.odin:30-33`).

### 8.4 "Bubble Tea v2 parity" is a moving target

ultraviolet grew 10,915 → 15,451 LOC (+41%) in seven months with no tagged
release (`docs/superpowers/specs/2026-07-25-runetea-design.md:566-572`).

---

## 9. What the test suite does and does not check

### 9.1 `odin test -sanitize:thread` does **not** detect data races on this toolchain

Proven with a deliberate unsynchronised counter: `odin build` +
`-sanitize:thread` reports the race and exits 66; `odin test` +
`-sanitize:thread` reports nothing and exits 0, *with the race physically
occurring in both* (`tools/test.sh:11-12`, `:157-172`).

**The only real race gate is `./tools/test.sh race`**, which builds
`tools/racecheck` as a standalone program under TSan. helgrind is not a
substitute: Odin's `sync.Mutex`/`Sema` are raw futex syscalls, invisible to it
(`tools/test.sh:17-22`).

### 9.2 The pyte cross-check is not on the gate

`./tools/difftest/run.sh` needs python3 + pyte, so it is a separate invocation —
a missing module must not become a green run (`tools/difftest/check.py:37-45`).
The equivalence invariant itself *is* on the gate, in
`runetea/diff_oracle_test.odin`, with no external dependencies.

**pyte cannot check hyperlinks.** It has no link model — it consumes OSC 8 and
ignores it. What it checks for a hyperlink case is that emitting the links
corrupted nothing else. The in-package oracle checks the links themselves, and
`RUNETEA_DIFF_FAULT=drop_link` proves it is not vacuous (429 of 500 cases
diverge).

### 9.3 pyte needs a correction, and disagrees with RuneTea by design

pyte's `erase_in_display` does not re-attribute never-written cells, which is
corrected in `check.py`. pyte measures width per code point with `wcwidth`, so
VS16 emoji and regional-indicator flags are a different model, and it resolves
DECAWM's pending wrap *before* checking width, so a combining mark at the right
margin makes it scroll. Those cases are excluded from the pyte-safe corpus as
disagreements the harness was built to have
(`runetea/difffuzz.odin:20-31`, `:52-60`).

### 9.4 The wide-cell pair expansion in the diff emitter is provably inert

Removing it (`RUNETEA_DIFF_FAULT=no_pair_expand`) changes not one byte across
the whole fuzz corpus. It is kept for locality and for real-hardware behaviour
no cell model can express (`runetea/render.odin, `emit_row` ("THE WIDE-CELL INVARIANT")`), and that finding is
itself pinned by a test.

---

## 10. `examples/editor` — what you inherit if you copy it

- **Hard caps of 250 lines × 256 runes, both silently dropping input**
  (`examples/editor/edit/editor.odin:70-71`). The 250 is itself a workaround:
  Odin warns *"Declaration of 'x' may cause a stack overflow"* for any local
  over exactly 262144 bytes.
- **Fixed `VIEWPORT :: 10`** — the editor does not use the terminal's height for
  its text area (`:72`).
- **No horizontal scrolling**; the wheel's horizontal axis is ignored (`:468`).
- **Tab indents with 4 spaces, never a literal `0x09`** — deliberate, because a
  real tab in the view would lie to the `.Diff` cell model (see 3.2). The
  document *loader* now sanitises control characters for the same reason; that
  was a live bug found by pointing `view_diff_safe` at a real view.
- **`Ctrl+I` (toggle help) is unreachable without the Kitty protocol** — it is
  the same byte as Tab. The degradation is *visible*: the status line prints
  `kitty:off` (`:507-521`).

---

## Changes made while compiling this document

Four things on this list were closed rather than described:

| Was | Now |
|---|---|
| OSC 8 hyperlinks silently dropped by `.Diff` (3.1) | Tracked per cell, fuzzed, cross-checked |
| The `.Diff` view contract described but uncheckable (3.2) | `view_diff_safe()` + a debug-build assertion |
| `Msg_Text` truncating silently (2.3) | `truncated` flag + `msg_text_truncated()` |
| Shift+Tab undecoded on 21/40 terminals (5.6) | `CSI Z` → `Tab + {.Shift}` |

Plus one bug the new checker found: `examples/editor`'s loader admitted literal
tabs and other C0 bytes into the view (10).

The two entries that most deserve to be closed next are **2.14** (silent timer
subsystem failure) and **6.2** (unlooped `write` dropping a frame's tail).
