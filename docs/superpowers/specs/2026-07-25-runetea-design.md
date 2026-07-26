# RuneTea — Design

**Date:** 2026-07-25
**Status:** Approved, pre-implementation
**Target:** A public, maintained Odin TUI framework in the spirit of Bubble Tea v2
**Toolchain:** Odin `dev-2026-07-nightly:819fdc7`
**Reference implementation:** `charmbracelet/bubbletea` v2.0.8 (`fc707bb`)

---

## 1. Verdict

Feasible. No hard blockers exist. Every "Odin can't do this" candidate was tested by
compiling and running real Odin, and all of them either work or have a mechanical
workaround.

The project is not small. Bubble Tea's own package is **4,414 non-test Go LOC**, which is
misleading: `tea.go:50` reads `type Msg = uv.Event` — a type *alias*. Bubble Tea v2 is a
thin policy layer over `charmbracelet/ultraviolet`, and the transitive dependency graph is
**70,699 LOC**.

Odin's standard library erases roughly half of that (§3). The realistic remaining surface
is ~30,000 Go LOC, and Odin is *sparser* than Go here — every closure becomes a named
environment struct plus a named proc plus a wrapper — so expect **30,000–38,000 Odin LOC**
for full parity.

**Scope decisions taken (§9):** public library, T3 target, Unix-first (Linux + macOS +
BSD), idiomatic Odin divergence where Go's design depends on features Odin lacks.

---

## 2. Verified facts

Everything in this table was established by compiling or running code, or by reading
source — not by inference. Scratch files under
`/tmp/claude-1000/-home-denisbytes-dev-runetea/411eeb2c-eba3-40c2-b20b-a6db5f07809d/scratchpad`.

| Question | Result | Evidence |
|---|---|---|
| Proc literals capture environment? | **No** | `Error: Undeclared name: n` |
| `any` as extensible `Msg`? | **Yes**, `switch v in msg` matches user types from other packages | ran; dispatched user-defined `Tick_Msg` |
| `Msg :: any` alias? | **Rejected** — `'any' cannot be aliased` | must spell `any` literally in every signature |
| `#partial switch` on `any`? | **Rejected** — "may only be used with a union" | no compiler assistance on the Msg boundary |
| `any` owns its payload? | **No** — 16-byte borrowed `{data: rawptr, id: typeid}` | returning `any` of a local printed `140734159169776` |
| `Model` interface via vtable + `rawptr`? | **Yes** | compiles and runs |
| `core:sync/chan` unbuffered, 4 producers × 250 values | **Broken — 629/1000 received, 371 lost** | reproduced; `send_raw` memcpys into a single `unbuffered_data` slot, then `sync.wait` releases the mutex |
| same, buffered (cap 1024) | **Correct — 1000/1000** | |
| `posix.CControl_Flags{.CS8}` | **Silently equals `{.CS7}`** — both `0x20` | `CS8 = 0x30` is multi-bit; enum is `log2(CS8)`, truncates to bit 5 |
| `nbio.associate_handle` on a non-socket fd | **Works** — async read returned 24 bytes | plus `nbio.timeout` fired; loop exited cleanly |
| termios / `sigaction` / SIGWINCH / `poll` / `sigwait` | **All present** | `core/sys/posix/{termios,signal,poll}.odin` |
| `TIOCGWINSZ` | Per-OS constants only; **no `winsize` struct, no `ioctl`** in `core:sys/posix` | `sys/linux/constants.odin:413`, `sys/darwin`, `sys/freebsd` |
| Grapheme clustering / display width | Full UAX#29 in `core:unicode/utf8/grapheme.odin` | but see §8 — four defects |

### Two upstream Odin bugs sitting directly under this project

1. **`posix.CControl_Flags{.CS8}` == `{.CS7}`.** Your TUI silently runs the tty at 7-bit
   character size. Workaround:
   `raw.c_cflag += transmute(posix.CControl_Flags)posix.tcflag_t(posix.CS8)`.
   Same defect on `TAB3`, `CR2`, `CR3`.
2. **`grapheme.odin:155`** — `text = it.str[byte_index:][:grapheme.width]` slices the
   returned cluster by *display width used as a byte count*. `"日本語"` yields three 2-byte
   fragments of 3-byte runes: invalid UTF-8. `"héllo"` yields `"\xc3"`. A tab yields `""`.
   **Never use the iterator's `text` field**; derive byte spans from consecutive
   `byte_index` values.

Both should be reported upstream.

---

## 3. What Odin core gives us free

**35,189 LOC — 49.8% of the Go dependency graph.**

| Replaced | Go LOC | By |
|---|---:|---|
| uniseg + uax29 + displaywidth + go-runewidth | 34,817 | `core:unicode/utf8/grapheme.odin` |
| `x/termios` | 372 | `core:sys/posix/termios.odin` |
| `muesli/cancelreader` | 844 | one nbio read op (§6) |
| Go channels | — | `core:sync/chan` (buffered only — see §2) |
| goroutines | — | `core:thread/pool` |
| `xo/terminfo` | 3,458 | **dropped** — Bubble Tea never sets `UseTerminfo`; dead on the input path |

---

## 4. Package layout

```
runetea/            core runtime: Program, Cmd, event loop, msg arena
  input/            escape-sequence decoder (byte-slice state machine)
  term/             termios, winsize, signals, crash-safe restore
  render/           cell buffer, line diff, ANSI writer
  width/            grapheme + display-width layer over core:unicode
runegloss/          styling — separate package, in v1.0 scope
```

`input/`, `render/`, and `width/` are each testable against golden bytes with no terminal
involved. This is not incidental: it is the only way the renderer gets debugged (§10).

---

## 5. Core types

```odin
// `any` is spelled literally in every signature. It cannot be aliased, and a
// wrapper struct would force `switch v in msg.v` on every user — and you cannot
// type-switch on a struct at all.
Cmd :: struct {
    procedure: proc(env: rawptr) -> any,
    env:       rawptr,
    allocator: mem.Allocator,   // frees env after procedure returns
}

cmd_from :: proc(fn: proc(e: ^$E) -> any, env: E, alloc := context.allocator) -> Cmd {
    p := new_clone(env, alloc)
    return Cmd{procedure = auto_cast fn, env = p, allocator = alloc}
}

Program :: struct($T: typeid) {
    model:  T,
    update: proc(model: T, msg: any, alloc: mem.Allocator) -> (T, Cmd),
    view:   proc(model: T, alloc: mem.Allocator) -> View,
}
```

**Why parapoly for the root model.** Go's `Update(Msg) (Model, Cmd)` returns the
*interface*, permitting mid-run model swapping. Odin has no interfaces, and
`[dynamic]Program` fails with *"Invalid use of a non-specialized polymorphic type"*. The
parapoly form is in fact **stronger** static checking than Go's — Go verifies only method-set
conformance, not that `Update` returns the same concrete type. Model-swapping mid-run is
rare in practice (one root model with a `state` enum is the standard idiom), and where it is
needed, `T` may itself be a vtable struct; the designs compose.

Heterogeneous child registries (a `[]Component` holding a text input beside a spinner) use
an explicit vtable: ~60 LOC of runtime, ~6 lines of boilerplate per widget, one unchecked
`cast(^T)self` per method. **Static composition is the documented default**; vtables are for
dynamic registries only.

**The `Cmd` tax.** Three lines of Go become roughly eight of Odin, and this touches *every*
user program. It is the largest permanent ergonomic regression in the port and there is no
way around it — only around the edges (`context.user_ptr` for same-thread callbacks;
`thread.create_and_start_with_poly_data` carries 64 bytes inline, covering most environments
with no heap allocation). Port `examples/http` in spike week one and count the lines before
committing a year.

Two further closures exist in Bubble Tea's public API beyond `Cmd` and need the same
treatment: `View.OnMouse func(MouseMsg) Cmd` (`tea.go:126`) and
`WithFilter(func(Model, Msg) Msg)` (`options.go:133`).

---

## 6. Concurrency and the event loop

**DECISION REVERSED 2026-07-26 — see `docs/superpowers/nbio-decision.md`.**
The bet below resolved *true* and the decision is still *no*. nbio can host the
loop (proven: pty-driven end-to-end, `wake_up` verified three ways with a
negative control, no conflict with the pool or signal watcher). But:

- The only payoff is Darwin/BSD arriving free from upstream, and that is exactly
  as unverified now as before — including the specific named landmine
  (`ultraviolet/poll_bsd.go`: "kqueue returns instantly when polling /dev/tty").
- On Linux, the only platform verifiable here, it is a net loss: +279 LOC added
  against ~161 removable, and *more* subtle where it matters most. nbio's
  single-threaded callback model reintroduces the paste-overflow deadlock class
  fixed in T0, and the two-thread fix does not port — yielding on the only
  thread that could drain the mailbox is a self-deadlock. It needs a backlog
  state machine instead.

What ships is `loop.odin`'s `Fd_Source`: `posix.poll` + blocking `read` on a
dedicated thread + a self-pipe wake + EINTR retry. `run_nbio` stays in-tree,
tested and green, as a reference implementation for whoever gets Darwin/BSD
hardware. A narrower nbio use — **timers only** (`Tick`/`Every`, the frame
ticker) — carries none of this risk, since timers are not tty-specific, and
remains recommended.

The original claim, kept for context:

**The nbio event loop *is* RuneTea's event loop.**

```
nbio loop (owns the terminal thread)
├─ associate_handle(tty_fd) ──> read op ──> input decoder
├─ timeout ops               ──> Tick / Every
├─ wake_up  <── mailbox <── thread.Pool (Cmds)
└─ tick() ──> Update ──> View ──> renderer diff ──> write
```

Verified: `nbio.associate_handle` accepts an arbitrary non-socket fd, reads from it
asynchronously, and `nbio.timeout` fires — on io_uring (Linux), kqueue (Darwin/BSD), IOCP
(Windows), all maintained by Odin core.

This deletes three expensive pieces at once:

- **The cancellable read.** `muesli/cancelreader` is 844 LOC across four backends purely
  because Go's runtime owns `os.Stdin`, restarts `EINTR`, and won't let you interrupt a
  blocking `read(2)`. None of that is true in Odin. Becomes one nbio read op.
- **The timer thread.** `Tick`/`Every` become nbio timeout ops. This also removes ~90% of
  real long-blocking Cmds from the worker pool.
- **The Darwin/BSD backends we cannot test** become upstream's code rather than ours.

**This does not erase the Darwin risk, it relocates it.** The test above used a pipe; a TTY
is a character device, and that is precisely where kqueue misbehaved for Charm —
`ultraviolet/poll_bsd.go:23` carries the comment *"kqueue returns instantly when polling
/dev/tty so fallback to select"*, and two independent Charm implementations five years apart
both chose `select` over `poll` for Darwin. Being inside widely-exercised upstream code is a
materially better position than owning a bespoke backend, but it is not proof.

**Mitigation:** a `posix.poll`-based fallback (~150 LOC) behind the same interface, with
`select` as the Darwin baseline rather than a contingency tier. The spike tests **both paths
on Linux** so the fallback is known-good before it is ever needed.

### Cmd dispatch

Go spawns a goroutine per Cmd and explicitly leaks it (*"It's not possible to cancel them so
we'll have to leak the goroutine"*). At ~30–50 µs and 8 MB of stack reservation per Odin
thread, that cannot be transliterated. Design:

- A bounded `thread.Pool` sized to `os.get_processor_core_count()`.
- Elastic overflow via `thread.create_and_start_with_data(self_cleanup = true)` — this *is*
  the leaked-goroutine semantic, used deliberately and rarely.
- **Batch/Sequence coordinators must take the elastic path or run inline.** A fixed pool
  deadlocks on batch-of-batches: coordinators block on child completion for children that
  have no worker.

### The mailbox

**Buffered, capacity ≥ 1. Never unbuffered.** This is not a preference — Odin's unbuffered
channel lost 371 of 1000 messages under the N-producer load RuneTea generates (input reader,
every Cmd thread, external `send`, `println`). Bubble Tea's `p.msgs` *is* unbuffered, so this
is a place where faithful porting is actively wrong.

Either a buffered `chan.Chan`, or ~200 LOC of hand-rolled MPSC over `sync.Sema` + ring +
`sync.Mutex` — the latter also supplies the blocking multi-way receive Odin lacks. Decide in
the spike.

### Signals

`pthread_sigmask` + `posix.sigwait` on a dedicated thread — **not** a self-pipe. Block
SIGINT/SIGTERM/SIGWINCH/SIGCONT process-wide and `sigwait()` on an ordinary thread that can
take locks and push into the mailbox, with no async-signal-safety constraint at all. This is
a closer analogue of Go's `signal.Notify` than the self-pipe, and it makes suspend race-free:
`sigprocmask(BLOCK, {SIGCONT})` → restore termios → `posix.kill(0, .SIGTSTP)` → `sigwait`.

Clear that mask before `os.process_start`, or `$EDITOR` inherits it. Note `suspendProcess`
(`tty_unix.go:40`) signals the whole process *group*, not just the process.

### Frame timing

The Go renderer is **ticker-driven, not message-driven**: `defaultFPS = 60`, `maxFPS = 120`
(`renderer.go:13-14`), with a dedicated goroutine calling `flush()` (`tea.go:1392-1420`).
Renders *coalesce* — N Updates between ticks produce one frame. RuneTea reproduces this with
an nbio timeout op rather than a thread, which removes the mutex covering `cursedRenderer`
throughout: the loop thread owns all terminal state, so the flush is just another callback on
the same thread.

---

## 7. Memory model

Per-frame arena.

```odin
box :: proc(v: $V, alloc := context.allocator) -> any {
    p, _ := new(V, alloc)
    p^ = v
    return p^        // `return p` yields ^V and never matches `case V`
}
```

Point `alloc` at a per-frame `virtual.Arena` and one `arena_free_all` per loop iteration
resolves the entire Msg lifetime question. This is **cleaner than Go's GC** for the Elm
architecture, not merely adequate: a 200-row render reaches exact steady state with zero
drift.

It also doubles as the recovery path after a `longjmp`, which does not unwind or run `defer`
(§8).

---

## 8. Crash safety — built in the spike, not month three

Go's `recover()` has no direct Odin equivalent, but the capability is reconstructible.
`longjmp` is typed `-> !`, which is exactly what makes it a legal body for
`Assertion_Failure_Proc` — the return type that looks like proof of impossibility is the
mechanism:

```odin
context.assertion_failure_proc = proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
    g_panic_msg = strings.clone(message, g_panic_alloc)   // MUST clone before jumping
    libc.longjmp(&g_guard, 1)
}
```

This recovers `panic()`, `assert()`, and type-assertion failures. With
`libc.signal`/`sigaction` handlers for SIGSEGV/SIGILL/SIGBUS/SIGABRT/SIGFPE/SIGHUP/SIGQUIT it
also recovers bounds traps and nil derefs, restores the terminal, and returns cleanly from
`run()`. That covers all five `recover()` sites in Go (`tea.go:725, 895, 921, 939, 1028`).

Two constraints:

- `longjmp` does not unwind or run `defer`. The recovery branch must `arena_free_all` — which
  §7 supplies for free — and release any held mutex explicitly.
- **Bounds-check failures bypass `assertion_failure_proc` entirely** (`bounds_check_error` is
  contextless and calls `bounds_trap()` directly). The SIGILL handler is therefore the
  *primary* net for the likeliest TUI crash — indexing a cell buffer during render — not a
  backstop.

Belt and braces: a process-global `Terminal_State` singleton; signal handlers doing
`tcsetattr` + raw `write(2)` of `\e[?1049l\e[?25h` then re-raising with `SIG_DFL`; and an
`@(fini)` proc (must be `proc "contextless"`). **Design the singleton on day one** —
retrofitting it is painful, and every crash before it works leaves the shell wedged in raw
mode with a hidden cursor.

Do **not** take a dependency on `core:debug/trace`: it does
`foreign import "system:stdc++exp"` (C++23 `<stacktrace>`) and fails to link on this machine
(`cannot find -lstdc++exp`). Use libc `backtrace()` via `foreign import`, or ship without
stack traces.

---

## 9. API divergence from Bubble Tea

Approved direction: idiomatic Odin where Go's design depends on features Odin lacks.

| Go design | Don't port it | RuneTea design |
|---|---|---|
| 6 key/mouse types matched by **method set** | No Odin equivalent exists | `Key_Msg{kind: .Press/.Release, ...}` and `Mouse_Msg{kind: .Click/.Release/.Wheel/.Motion, ...}`. "All mouse events" is `case Mouse_Msg:`; "only clicks" is one `if`. Removes the hardest type-system dependency in `tea.go` |
| 6 goroutines, 11 channel kinds, 13 `select`s, `context.Context` tree | Transliterating any of it | One nbio loop + one mailbox. Channel closure *is* the cancel signal — `chan.send` returns `false` on closed where Go panics |
| `p.msgs` unbuffered rendezvous | Reproducing it | Buffered. Unbuffered is *corrupt* with N producers, and `exec.go`'s three `go p.Send(...)` sites self-deadlock at zero capacity |
| Goroutine per Cmd; blocking-sleep `Tick`/`Every` | 10k ticks = 10k threads | Bounded pool + elastic overflow + nbio timeout ops. Use `time.tick_now()` (CLOCK_MONOTONIC_RAW), **not** `time.now()` (CLOCK_REALTIME — jumps with NTP) |
| `fmt.Errorf("%w: %w", ...)` sentinels | Emulating `errors.Is` | `Run_Error :: union {Killed, Interrupted, Panicked, Terminal_Error, mem.Allocator_Error}`. The init path becomes an `or_return` chain, *shorter* than Go |
| Lip Gloss `NewStyle().Fg(c).Bold(true).Render(s)` | Not blocked — `->` works | Chaining compiles, but each Style would carry ~40 proc pointers (~320 bytes). Prefer `rg.render(rg.Style{fg = c, bold = true, padding = {0,1}}, s)`. Odin's designated initializers make this *nicer* than the original; the used surface is 27 distinct symbols across all 63 examples |
| `image/color.Color` interface | — | Union. Shared with RuneGloss |
| `cancelreader`, 844 LOC / 4 backends | Any of it | One nbio read op |
| `os/signal.Notify` | Self-pipe emulation | `pthread_sigmask` + `sigwait` on a watcher thread |
| Win32 `INPUT_RECORD` → serialize to `CSI …_` → re-parse | The round-trip | Map `INPUT_RECORD` → Event directly (post-v1.0). Deletes 243 Go LOC and the only reason to port x/ansi's 273-line transition table |

### `View` is a declarative struct, not a string

`tea.go:84-188`. `View` carries `Content, OnMouse, Cursor, BackgroundColor, ForegroundColor,
WindowTitle, ProgressBar, AltScreen, ReportFocus, DisableBracketedPasteMode, MouseMode,
KeyboardEnhancements`. Alt-screen, mouse mode, focus reporting, bracketed paste and Kitty
flags are **per-frame declarations diffed by `viewEquals`** (`cursed_renderer.go:803-842`),
not commands. That mode-diff machinery is real work and is budgeted in T2.

---

## 10. Testing

**The golden-byte harness is non-negotiable and comes before the renderer.** The diff
renderer has no oracle and fails silently: `transformLine` is ~500 dense ncurses-derived
lines choosing between ECH/REP/ICH/DCH/EL/CUP/CUB/BS/HT by byte cost, with off-by-one and
wide-cell invariants throughout, plus a cursor solver trialling 4×3 encodings per move. Port
it mechanically in two weeks, then debug it for six across xterm/kitty/alacritty/ghostty/
tmux/screen/linux console, each with a different capability mask.

Two sources, both cheap:

1. **Transcribe ultraviolet's corpus.** `terminal_renderer_test.go` (1,338 lines) and
   `terminal_renderer_output_test.go` (193) are tables of *literal expected byte strings*
   with per-OS variants (`"\x1b[H\x1b[2JLorem ipsu\r\nm dolor si\r\n…"`). Directly reusable.
2. **Instrument the Go implementation.** Both write to a pipe: wrap `cursedRenderer` in a
   counting `io.Writer`, capture the exact byte stream for a fixed 80×24 frame sequence,
   diff RuneTea's output byte-for-byte. ~400 LOC.

**Headless seams are spike-tier, not later.** Bubble Tea's own tests drive a whole Program
off `bytes.Buffer` in and out (`screen_test.go:137-156`), via `WithOutput(io.Writer)` /
`WithInput(io.Reader)`. An fd-only input design has no story for this — Charm needed a fifth
backend (`poll_fallback.go`, 158 LOC) for exactly that case. RuneTea's input layer must
accept a `core:io.Stream`, not just a handle, from day one. The golden harness depends on it.

**Stdout interleaving is solved upstream and must be ported.** `cursed_renderer.go:707-762`
— `insertAbove` is a 55-line scroll-down / `IL` / rewrite dance injecting unmanaged lines
above the view; it silently no-ops in altscreen (`renderer.go:69`). Plus `LogToFile` as the
sanctioned debug channel. You cannot printf-debug a TUI, so this is spike-tier.

Note there is no `teatest` in v2 — it was `x/exp/teatest`, v1-era. Bubble Tea ships 1,297
test LOC and 2 golden files in total. We inherit almost no scaffolding.

---

## 11. The width layer

`core:unicode/utf8/grapheme.odin` ships full UAX#29 extended grapheme clustering — GB1–GB13,
Hangul, Indic conjunct break GB9c, emoji ZWJ GB11, regional indicators — plus an East Asian
width table. Segmentation is **correct**: verified against the Go libraries on six test
strings, counts matched exactly. This deletes 34,817 LOC and is the single biggest
de-risking fact in the project.

It is **not** a drop-in cell-buffer substrate. Four verified gaps:

1. `grapheme.odin:155` slices by width-as-byte-count (§2). Derive byte spans from
   consecutive `byte_index` values instead.
2. **VS16 ignored.** `❤️` (U+2764 U+FE0F) measures 1; every terminal and both Go libraries
   say 2.
3. **Regional indicator pairs measure 1, not 2** — `tables.odin:3829` puts the whole RI
   block at width 1.
4. **Tables pinned to UCD 15.1.0**; Go's uax29 is on 17.0.0. Two major versions of new
   scripts and emoji will segment and measure wrong. The in-tree generator already reaches
   `Age_17_0`, so regeneration is possible but unbudgeted.

Also `normalized_east_asian_width` is not a `go-runewidth` replacement: it returns 1 for
combining marks (should be 0) because it early-returns for `r <= 0x10FF`.

**Budget 300–500 LOC:** byte-span reconstruction, VS16 → force 2, RI-pair → force 2, an
ambiguous-width flag, and a zero-width set from `nonspacing_mark_ranges`. Fix upstream while
there.

---

## 12. Scope tiers

Revised down from the pre-nbio estimate: the platform layer drops from ~2,600 LOC / 6–8
weeks to ~700 LOC / 2–3 weeks.

| Tier | Cum. weeks | What a user can build |
|---|---:|---|
| **T0 — Spike** | 2 | Nothing. Proves the design end to end. |
| **T1 — Inline runtime** | 7 | CLI spinners, y/n prompts, single-select menus, long tasks with live status. The upstream tutorial plus `simple`, `http`, `result`, `sequence`, `debounce`, `print-key`. No full-screen, no color, no mouse. |
| **T2 — Full-screen, repaint renderer** | 16 | File browser, log tailer, dashboard, scrollable pager. Mouse, resize, alt screen, 256-color, the `View` mode-diff. *Caveat:* full repaint at 60fps pushes ~104–134 KB/s for a **static** screen — fine locally, unusable over ssh. |
| **T3 — Diff renderer + RuneGloss** ← **v1.0** | **34–38** | Everything above, ssh-usable: identical frame = **0 bytes**; 5 changed cells = **12 bytes** (`ESC[13;9H#####`). 28 of 63 upstream examples portable — the Bubbles-free set. |
| **T4 — Parity** | 55–65 | Kitty keyboard, full response decoder (DA1/2/3, XTGETTCAP, OSC 10/11/12/52, DSR, XTVERSION) unlocking adaptive light/dark theming, scroll optimization, Windows, suspend/exec. |
| **T5 — Ecosystem** | ~78 | RuneBubbles (10 components), all 63 examples, docs. |

Sequence T4 as Kitty first (biggest UX win), response decoder second (RuneGloss needs it for
theming), **Windows last** — a separate ~1,000 LOC codebase with its own test matrix and the
least demand from an Odin audience. **Declare Windows out of scope for v1.0 in writing.**

**A RuneTea without a RuneGloss is a demo, not a framework.** 41/63 examples import lipgloss,
35/63 bubbles, 47/63 at least one. The 16 pure-bubbletea examples are *all* framework-feature
demos — `print-key`, `window-size`, `mouse`, `focus-blur`, `exec`, `suspend`. Zero examples
resembling a real application are pure bubbletea. RuneGloss is in v1.0 scope at
**5,000–6,500 LOC** (lipgloss v2 is 7,758; dropping `table/`, `tree/`, `list/`, `layer.go`,
`canvas.go`, `blending.go` is not viable because examples use them).

---

## 13. Risks

1. **The diff renderer has no oracle and fails silently.** Highest-probability stall. §10 is
   the mitigation and it must exist first.
2. **Scope creep into the ecosystem.** T3 is ~36 weeks; T5 is ~78. Porting Bubbles components
   is *easy* and never finishes the renderer.
3. **Threading bugs with no race detector by default.** Replacing a race-detector-covered Go
   runtime with hand-rolled threading atop a channel implementation that is demonstrably
   broken. Budget `-sanitize:thread` from the start.
4. **Darwin/BSD are unvalidated and untestable here.** §6 relocates the risk upstream; it does
   not remove it. Ship Linux as verified, Darwin/BSD as best-effort pending a contributor.
5. **Terminal-state debugging.** Every crash before §8 works wedges the shell.
6. **Maintenance tail.** The most complete Odin TUI library (RaphGL/TermCL) was archived in
   July 2026 with the author stating he had left Odin. Simultaneously the strongest argument
   that RuneTea fills a real gap and the clearest warning about month twelve.

### The moving target

`go.mod` pins ultraviolet at `v0.0.0-20260703014108-f5a850f9c2b7` — a pseudo-version, **no
tagged release**. Between the two copies in the local module cache it grew **10,915 → 15,451
non-test LOC (+41%) in seven months**, gaining an entire poll subsystem, a console
abstraction, `TerminalScreen`, and a window layer, while losing `layout.go`.

"Bubble Tea v2 parity" is therefore not a fixed target, and a year-long port chasing it
finishes against a version that no longer exists. **Two standing policies:**

- Pin one ultraviolet commit in the README and declare it the spec.
- Treat RuneTea's event vocabulary as **ours** from day one (§9). The mouse/key collapse is
  not an isolated concession — it is the general policy.

---

## 14. Build this first

**A ~900 LOC spike, time-boxed to two weeks, running `examples/simple` and `examples/http`
inline.** Nothing else. Its only purpose is to break every load-bearing assumption before
anything exists that would be painful to discard.

In this order:

1. **Mailbox** — buffered `chan.Chan` vs hand-rolled MPSC (`sync.Sema` + ring + mutex).
   Test with 4 threads × 250 unique values; assert 1000/1000. Everything sits on this.
2. **nbio loop** — `associate_handle(tty_fd)`, read op, `nbio.timeout`, `wake_up`. Build the
   `posix.poll` fallback behind the same interface and **test both on Linux** so the escape
   hatch is proven before it is needed.
3. **termios raw mode** with the `CS8` transmute workaround, save/restore, and the global
   `Terminal_State` singleton.
4. **Crash safety** — `assertion_failure_proc` + `setjmp`/`longjmp` + SIGSEGV/SIGILL/SIGBUS/
   SIGABRT handlers. Prove `run()` returns cleanly from a `panic()` in user `update`, a
   deliberate out-of-range index, and a nil deref — terminal restored in all three.
5. **`sigwait` thread** for SIGINT + SIGWINCH.
6. **`any`-boxed Msg into a per-frame arena**, one `arena_free_all` per iteration. Confirm the
   type switch matches user types **defined in a separate package**.
7. **`Cmd` fat pointer + `cmd_from`**, dispatched to a `thread.Pool`, results landing in the
   mailbox. Port `examples/http` verbatim and **count the lines** — that number is the
   ergonomic tax, and it should be looked at before committing a year.
8. **`core:io.Stream` input seam** (§10) — required by the golden harness.
9. **Naive inline renderer** — track last-frame line count, rewind with CUU/EL, repaint.
10. **The golden-byte harness**, even though the naive renderer will fail it. Wire it up now;
    it is the instrument you live inside for the next six months.

### Kill criteria, stated in advance

- nbio misbehaves on a real TTY **and** the `posix.poll` fallback also degrades; or
- the mailbox cannot be made clean under `-sanitize:thread` within a week; or
- the `Cmd` ergonomics in ported `examples/http` are bad enough that you would not write an
  app that way.

None of these is likely. All are cheap to discover in two weeks and expensive to discover in
five months.

---

## 15. Open questions for the plan

- Mailbox: buffered `chan.Chan` or hand-rolled MPSC? Decide with §14.1 in hand.
- Whether `View` mode-diffing lands in T2 or is deferred to T3.
- RuneGloss package boundary: separate repo or subdirectory?
