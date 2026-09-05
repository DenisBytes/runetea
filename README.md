<h1 align="center">RuneTea</h1>

<p align="center">
  <b>The Elm Architecture for <a href="https://odin-lang.org">Odin</a>.</b><br>
  A port of <a href="https://github.com/charmbracelet/bubbletea">Bubble Tea</a> — for terminals, without a garbage collector.
</p>

<p align="center">
  <a href="https://github.com/DenisBytes/runetea/blob/main/LICENSE"><img alt="MIT licence" src="https://img.shields.io/badge/licence-MIT-blue.svg"></a>
  <a href="https://odin-lang.org"><img alt="Odin dev-2026-07" src="https://img.shields.io/badge/Odin-dev--2026--07-6699cc.svg"></a>
  <img alt="531 tests" src="https://img.shields.io/badge/tests-531%20passing-brightgreen.svg">
  <img alt="Linux verified" src="https://img.shields.io/badge/Linux-verified-brightgreen.svg">
  <img alt="macOS and BSD unverified" src="https://img.shields.io/badge/macOS%20%7C%20BSD-unverified-orange.svg">
  <a href="docs/API.md"><img alt="API docs" src="https://img.shields.io/badge/docs-API-informational.svg"></a>
</p>

---

```text
What should we buy at the market?

  [ ] Buy carrots
> [x] Buy celery
  [ ] Buy kohlrabi

Press q to quit.
```

<sup>Not a mock-up. Every <i>screen</i> in this README was captured from a program running under a real pty and replayed through <a href="https://github.com/selectel/pyte">pyte</a>, a third-party VT100 emulator; this one is re-captured and compared cell for cell on every test run by <a href="tools/doccheck/run.sh">the doc gate</a>. The byte tables further down are a tool's stdout, not screens.</sup>

RuneTea gives you one model, one `update`, one `view`, and a real event loop
that turns keystrokes, mouse reports, window resizes, signals and background
work into messages. `runegloss/` is its [Lipgloss](https://github.com/charmbracelet/lipgloss):
colours that degrade to whatever the terminal can actually show, plus padding,
borders, alignment, width-correct wrapping and truncation, and block joins.

It is written for a language with **no garbage collector, no closures, and an
explicit allocator on every call** — so the places where it diverges from Bubble
Tea are the places where Go's design leaned on a feature Odin does not have.
Those divergences are named, measured, and listed in one table below.

> [!IMPORTANT]
> **Linux is the verified platform.** macOS and BSD compile but have never been
> run — no machine was available. See [Platform support](#platform-support)
> before you build on either.

## Contents

- [Install](#install) · [Quickstart](#quickstart) · [Coming from Bubble Tea](#coming-from-bubble-tea)
- [What you get](#what-you-get) · [Examples](#examples) · [The `.Diff` renderer](#the-diff-renderer) · [RuneGloss](#runegloss)
- [Platform support](#platform-support) · [Limitations](#limitations) · [Tests and gates](#tests-and-gates) · [Documentation](#documentation)

## Install

Odin has no package manager, so RuneTea is vendored. Either drop the two
directories into your tree and import them by relative path — which is what
every example here does — or add the repo as a submodule and give it a
collection name:

```console
$ git submodule add https://github.com/DenisBytes/runetea.git vendor/runetea
$ odin build . -collection:rune=vendor/runetea
```

<!-- doccheck: skip needs the -collection flag it is documenting; verified by hand, not compilable standalone -->
```odin
import rt "rune:runetea"
import rg "rune:runegloss"
```

Requires **Odin `dev-2026-07`** or newer. No third-party dependencies, at all —
`core:` only.

To try it before you vendor it:

```console
$ git clone https://github.com/DenisBytes/runetea.git && cd runetea
$ odin run examples/quickstart
```

## Quickstart

Here is a complete program: a list you can move around and tick items off. It
is [`examples/quickstart/main.odin`](examples/quickstart/main.odin) quoted
verbatim — the test suite fails if this block and that file ever differ, so
what you are reading below compiles and runs.

<!-- doccheck: file examples/quickstart/main.odin -->
```odin
package main

// THE README'S QUICKSTART, and the only copy of it. README.md quotes this file
// verbatim and tools/doccheck/run.sh fails if the two ever drift -- a sample
// that stops compiling is worse than no sample at all, because it burns the
// reader's trust in the first five minutes.
//
// It is a port of Bubble Tea's own README example (the shopping list), so
// anyone arriving from Go can put the two side by side and see exactly what
// changed: `Update` takes `*Model` instead of returning one, `tea.Msg` is
// `any`, there is no `tea.NewProgram(...).Run()` that owns the terminal, and
// every allocation names the allocator it came from.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import rt "../../runetea"

CHOICES := [?]string{"Buy carrots", "Buy celery", "Buy kohlrabi"}

Model :: struct {
	cursor:   int,
	selected: [len(CHOICES)]bool,
	// F47. The terminal's height, so `view` can say "too small" instead of
	// painting a 7-row frame into a 1-row window -- where the terminal scrolls
	// all but the last row away and the program looks hung. Seeded in `main`
	// from rt.term_size and kept live from Window_Size_Msg; 0 is "unknown"
	// (no tty, or the ioctl failed) and never trips the guard.
	term_h:   int,
}

// The rows `view` below paints -- one question, one blank, one per choice, one
// blank, one hint -- PLUS ONE. Written as an expression rather than a number so
// that adding a choice cannot silently make the minimum wrong.
//
// The +1 is not slack, and this constant was `4 + len(CHOICES)` until it was
// measured. Under .Inline every line of the frame is terminated with "\r\n",
// the last one included (render_inline, runetea/render.odin), because the next
// frame's rewind counts \e[1A\e[2K pairs upward from column 1 of the row BELOW
// the frame. A frame of R rows therefore needs R+1 terminal rows; painting R
// into exactly R scrolls the top row into scrollback, and r.last_rows' clamp
// to term_height-1 means no later rewind can ever reach it again.
//
// MEASURED under a real pty (pyte replay, 60 columns, after one 'j'):
//   rows = 7 (the old minimum)   "What should we buy at the market?" is GONE.
//              The question this program exists to ask, scrolled away, on a
//              terminal the guard had just certified as big enough.
//   rows = 8   all seven lines present, and every taller terminal is correct.
MIN_ROWS :: 5 + len(CHOICES)

// `m` is a POINTER: mutate it in place and return only the Cmd. That is
// RuneTea's one deliberate divergence from Bubble Tea's value-based Update --
// see rt.Program.update (runetea/tea.odin) for the build-time measurements
// that bought it and the crash-safety property it cost.
update :: proc(m: ^Model, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	switch v in msg {
	case rt.Window_Size_Msg:
		// w == 0 / h == 0 is rt's "the ioctl failed" sentinel: ignore it rather
		// than clobbering a known-good size.
		if v.h > 0 { m.term_h = v.h }
	case rt.Key_Msg:
		// PASTED TEXT IS NOT KEYSTROKES (F37). Without this, every character of
		// a paste runs the bindings below -- a pasted "buy quinoa" quits on its
		// 'q' and the session is gone with no message. Bracketed paste (the
		// `paste = true` in main) is what makes the two DISTINGUISHABLE, by
		// setting `pasted` and by delivering the space as .Rune ' ' rather than
		// .Space; this branch is what makes the distinction matter. A list
		// picker has no text field, so the right thing to do with a paste is
		// nothing at all.
		if v.pasted { return rt.cmd_nil() }
		switch {
		case v.code == .Rune && v.r == 'q',
		     v.code == .Rune && v.r == 'c' && .Ctrl in v.mods,
		     v.code == .Escape:
			return rt.quit_cmd()
		case v.code == .Up, v.code == .Rune && v.r == 'k':
			if m.cursor > 0 { m.cursor -= 1 }
		case v.code == .Down, v.code == .Rune && v.r == 'j':
			if m.cursor < len(CHOICES) - 1 { m.cursor += 1 }
		case v.code == .Enter, v.code == .Space:
			m.selected[m.cursor] = !m.selected[m.cursor]
		}
	}
	return rt.cmd_nil()
}

// Everything allocated here comes from `alloc` -- the per-frame arena RuneTea
// hands the view -- and is reclaimed wholesale when the frame ends. Nothing in
// a view is ever freed by hand.
view :: proc(m: Model, alloc: mem.Allocator) -> string {
	// F47. One line that fits, rather than a frame whose first rows the
	// terminal scrolls away.
	if m.term_h > 0 && m.term_h < MIN_ROWS {
		return fmt.aprintf("need %d rows, have %d\n", MIN_ROWS, m.term_h, allocator = alloc)
	}
	b := strings.builder_make(alloc)
	strings.write_string(&b, "What should we buy at the market?\n\n")
	for choice, i in CHOICES {
		point := i == m.cursor ? ">" : " "
		check := m.selected[i] ? "x" : " "
		fmt.sbprintfln(&b, "%s [%s] %s", point, check, choice)
	}
	strings.write_string(&b, "\nPress q to quit.\n")
	return strings.to_string(b)
}

main :: proc() {
	fd := posix.FD(os.fd(os.stdin))

	// install_crash_handlers BEFORE term_enter_raw: term_enter_raw arms its
	// own restore flag before tcsetattr has touched the tty, so a crash in
	// that window is only recoverable if a handler already exists.
	rt.install_crash_handlers()
	// `paste = true` is DECSET 2004, bracketed paste. Without it the terminal
	// delivers pasted text as ordinary keystrokes with `pasted == false`, so
	// there is no way for update() to tell a paste from typing and every
	// pasted character runs a binding. Bubble Tea -- the thing this is a port
	// of -- enables it by default and offers WithoutBracketedPaste as the
	// opt-out; RuneTea makes the application own the terminal, so the opt-in
	// belongs here. It is HALF the fix on its own: see update's `v.pasted`
	// branch for the other half, and note that the two have to ship together
	// (DECSET 2004 alone still lets a pasted 'q' quit).
	if !rt.term_enter_raw(fd, {paste = true}) { fmt.eprintln("not a tty"); os.exit(1) }
	defer rt.term_restore()

	src, ok := rt.input_source_from_fd(fd)
	// term_restore BEFORE os.exit: os.exit does not run defers, so the line
	// above never fires on this path and the terminal is left in raw mode.
	if !ok { rt.term_restore(); fmt.eprintln("bad input source"); os.exit(1) }
	defer rt.input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: rt.Program(Model)
	rt.program_init(&p, Model{}, update, view)
	// A Window_Size_Msg only ever arrives on a SIGWINCH, so a program that is
	// never resized would spend its whole life not knowing how tall its
	// terminal is. ok == false leaves it 0, which view() reads as "unknown".
	if _, h, ok := rt.term_size(fd); ok { p.model.term_h = h }

	// The last argument is the fd each finished frame is written to. Pass it
	// and the display updates live; leave it out (-1) and the whole session
	// accumulates in `b` instead, which is how the golden tests read it.
	err := rt.run(&p, &src, &b, fd)
	// term_restore FIRST, then the message, then a real exit status. Printing
	// before the terminal is restored writes the diagnostic into whatever mode
	// the program left the terminal in; falling off the end of main after an
	// error exits 0, which makes a crash indistinguishable from a clean quit to
	// anything that checks. rt.exit_code maps nil -> 0, Interrupted_Error ->
	// 130 and every genuine fault -> 1.
	if err != nil {
		rt.term_restore()
		fmt.eprintln("error:", err)
		os.exit(rt.exit_code(err))
	}
}
```

```console
$ odin run examples/quickstart
```

Three things there are worth naming, because they are the three ways RuneTea
differs from Bubble Tea at the call site:

1. **`update` takes `^Model`** and returns only a `Cmd`.
2. **`run()` does not own the terminal.** You call `term_enter_raw` and pair it
   with `defer term_restore()` yourself — the layer that entered raw mode is the
   layer that leaves it.
3. **Every allocation names its allocator.** `view` is handed a per-frame arena;
   everything it builds from that allocator is reclaimed wholesale when the
   frame ends. Nothing in a view is ever freed by hand.

## Coming from Bubble Tea

If you know Bubble Tea, this table is the whole port.

| Bubble Tea (Go) | RuneTea (Odin) | Why it changed |
|---|---|---|
| `tea.Model` interface | `rt.Program($T)` | Parametric, not an interface — Go only checks that your methods *exist*, not that `Update` returns the concrete type it was given. |
| `Update(Msg) (Model, Cmd)` | `update(m: ^T, msg: any, alloc) -> Cmd` | The by-value round-trip made LLVM codegen superlinear in `sizeof(T)`. See below. |
| `View() string` | `view(m: T, alloc) -> string` | The allocator is a parameter; the frame arena is reclaimed for you. |
| `tea.Cmd` = `func() Msg` | `rt.cmd_from(proc, env, alloc)` | Odin has no closures, so the captured environment is an explicit `env` value. |
| `tea.Msg` = `any` | `any`, **but POD only** | No GC, so message ownership has to be decidable: one allocation per message, freed by the loop. |
| `tea.Batch(a, b)` | `rt.batch([]rt.Cmd{a, b}, alloc)` | Odin variadics must come last, and the allocator is explicit everywhere. |
| `tea.Sequence(a, b)` | `rt.sequence([]rt.Cmd{a, b}, alloc)` | Same. |
| `tea.Tick` | `rt.tick(...)` / `rt.every(...)` | `tick` hands back no handle, so the reissue-from-`update` animation pattern cannot leak. |
| `tea.Quit` | `rt.quit_cmd()` | — |
| `tea.NewProgram(m, opts...).Run()` | `rt.term_enter_raw(fd, opts)`, then `rt.run(&p, ...)` | Opt-ins are one `Term_Opts` struct, not functional options; the app owns the tty. |
| `tea.WithAltScreen()` | `{alt = true}` | — |
| `tea.WithMouseCellMotion()` | `{mouse = .Button_Event}` | — |
| `lipgloss.NewStyle().Bold(true)` | `s := rg.new_style(); rg.bold(&s, true)` | No method chaining in Odin; `Style` is a plain value you can store in your model. |

<details>
<summary><b>Why <code>update</code> takes a pointer — the measurements</b></summary>

<br>

This is the one breaking divergence, and it is not an aesthetic preference.
Bubble Tea's value-based `Update` made LLVM code generation superlinear in
`sizeof(T)`, which put a hard, invisible ceiling on how large a model a RuneTea
application could have. Wall-clock `odin build` of a minimal program whose model
is an `[N]int`:

| model size | by value | by pointer |
|---|---|---|
| 8 KiB | 2.28 s | 1.18 s |
| 16 KiB | 8.97 s | 1.17 s |
| 32 KiB | 105.91 s | 1.07 s |
| 64 KiB | did not finish in 200 s | 1.12 s |
| 1 MiB | not attempted | 1.20 s |

Nothing *fails* at 64 KiB — a build simply stops finishing, which is the worst
shape a limit can have. The full bisection is on `Program.update` in
[`runetea/tea.odin`](runetea/tea.odin).

**What it cost, stated plainly:** crash recovery no longer protects model
*state*. With the by-value signature a panicking `update` left the model at its
last good value, because the recovery jump skipped the assignment. With a
pointer, a panic partway through leaves the model half-mutated. RuneTea still
guarantees the process survives, the terminal is restored, the frame arena is
reclaimed and `run()` returns `Panicked_Error` — it guarantees nothing about the
model's contents afterwards. The mitigation is structural: do everything that
can fail first, into locals, and write into `m^` last.
([`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) 6.6.)

</details>

## What you get

**Input, decoded properly.** A full CSI/SS3 grammar: arrows, Home/End/PgUp/PgDn,
F1–F12 in all three encodings, the xterm modifier bitmask, and the
[Kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/) —
which makes Tab and Ctrl+I, Enter and Ctrl+M, Escape and Ctrl+`[` **different
keys** instead of one shared byte — **when you ask for it**: `term_enter_raw`
touches the terminal's keyboard only if you pass `{kb = {.Disambiguate}}`, and
this README's own quickstart deliberately does not. A partially-arrived sequence
is never decoded; it is held back until it completes or the buffer proves it
cannot. Terminal replies — OSC, DCS, APC — are consumed rather than typed into
your application as keystrokes.

**Messages.** Keys, mouse (SGR extended, 0-based cells), window resize via
`SIGWINCH`, focus/blur, bracketed paste, plus notice messages for the things
that usually fail silently — which Kitty flags the terminal actually took, a
background `Cmd` that panicked and was recovered, a timer subsystem that could
not start.

<!-- doccheck: decl tour -->
```odin
Model :: struct { count: int }

handle :: proc(m: ^Model, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	switch v in msg {
	case rt.Key_Msg:                    // a keypress (or a pasted rune)
		if v.code == .Rune && v.r == 'q' { return rt.quit_cmd() }
	case rt.Mouse_Msg:                  // press/release/motion/wheel
		m.count = v.x
	case rt.Window_Size_Msg:            // SIGWINCH; w/h in cells
		m.count = v.w
	case rt.Focus_Msg, rt.Blur_Msg:     // terminal focus
	case rt.Paste_Start_Msg:            // bracketed paste opened
	case rt.Paste_End_Msg:              // ...and closed
	case rt.Keyboard_Enhancements_Msg:  // which Kitty flags the terminal took
	case rt.Panicked_Msg:               // a Cmd panicked -- or the framework refused one
	case rt.Timer_Unavailable_Msg:      // no tick()/every() will ever fire
	}
	return rt.cmd_nil()
}
```

**Commands.** Background work that delivers a message back into the loop. No
closures, so the environment is explicit — `cmd_from` heap-clones it for you.
`batch` runs children concurrently, `sequence` runs them in order.

<!-- doccheck: decl tour -->
```odin
Fetch_Env      :: struct { id: int }
Fetch_Done_Msg :: struct { id: int, ok: bool }

fetch :: proc(env: rawptr, cancel: ^rt.Cancel_Token) -> any {
	e := cast(^Fetch_Env)env
	// ... the slow thing, polling `cancel` if it can take a while ...
	if rt.cancel_requested(cancel) { return nil }
	return rt.box(Fetch_Done_Msg{id = e.id, ok = true}, context.allocator)
}

start :: proc(id: int) -> rt.Cmd {
	return rt.cmd_from(fetch, Fetch_Env{id = id}, context.allocator)
}

both :: proc() -> rt.Cmd { return rt.batch([]rt.Cmd{start(1), start(2)}, context.allocator) }
```

> Cancellation is **cooperative polling, never preemption.** A `Cancel_Token`
> cannot interrupt a Cmd blocked in a syscall that never returns, so quitting
> takes as long as your slowest blocking Cmd.

> A `Cmd` value is **single-use.** Returning the same stored `Cmd` from
> `update` twice does not run it twice: the second dispatch is refused and
> reported to your `update` as a `Panicked_Msg` naming the kind. Build a fresh
> one each time — `cmd_nil()` and `quit_cmd()` are the exceptions, because they
> own nothing.

**Every `Msg` must be POD.** `box()` rejects any type with a `string`, pointer,
slice, map or `any` anywhere in its field tree. That is the largest permanent
ergonomic cost of the design, and it is what makes ownership decidable without a
GC. For short text there is `Msg_Text` (a 255-byte inline buffer that records
whether it truncated); for anything bigger, keep it in your own storage and send
a handle. `rt.is_pod_type(T)` is a plain boolean you can assert in your own tests.

**Crash safety, in two tiers.** A panicking `update` or `Cmd` is caught, the
terminal restored, and `run()` returns rather than leaving the user in a broken
tty. Fatal signals are caught too, by a handler that is `proc "c"` and
async-signal-safe — eleven of them, plus `SIGTSTP`/`SIGCONT`, so Ctrl+Z and `fg`
hand the terminal back and take it again — and the first frame after a resume
repaints rather than diffing against whatever your shell printed over it. (Bounds violations and nil derefs are
*not* recoverable — they end the process, with the terminal restored.)

**What you do not get: widgets.** Bubble Tea's practical value for shipping an
application is [Bubbles](https://github.com/charmbracelet/bubbles) — `textinput`,
`textarea`, `viewport`, `list`, `table`, `progress`, `paginator`, `help`, `key`,
`filepicker`, `stopwatch`, `timer`, `spinner`. **None of the thirteen exists
here, and there is no plan for them in v1.0.** RuneTea is the loop and RuneGloss
is the paint; every widget is yours to write, out of `Key_Msg`, a model field and
a `view`. `examples/editor` is what that looks like in full — caret movement by
grapheme cluster, a scrolled viewport, a help panel and a status bar, all
hand-written in one file. Budget for that before you adopt this.
([`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) 8.5.)

## Examples

Each is its own `main` package. Four screens follow; the quickstart's is at
the top of this file. All five are real captures, taken under a pty at **80
columns by 24 rows** — the industry default, and the size a reader is most
likely to be sitting at.

```console
$ odin run examples/quickstart   # a list picker -- this README's quickstart
$ odin run examples/simple       # the smallest possible program: a key counter
$ odin run examples/spinner      # tick()-driven animation + RuneGloss styling
$ odin run examples/http         # batch() of two concurrent, cancellable network Cmds
$ odin run examples/editor       # the whole apparatus at once
```

<details>
<summary><b>examples/simple</b> — a Model, an update, a view, and nothing else</summary>

<br>

```text
Hi. This program will exit on 'q'.

Keys pressed: 4
```
</details>

<details>
<summary><b>examples/spinner</b> — animation driven entirely by <code>tick</code>, no keypress</summary>

<br>

```text
⠼ Loading... 'p' pauses, 'q' quits
```

One frame of ten; the capture caught it mid-cycle. Braille frames advanced by a
`tick` reissued from `update` on every fire, and stoppable with `p` or space —
WCAG 2.2.2 asks that automatically-moving content be pausable, and
`$RUNETEA_REDUCE_MOTION` makes this one start paused — the same pattern Bubble Tea's
`bubbles/spinner` uses, and the reason `tick` hands back no handle to leak.
(There is no RuneTea equivalent of `bubbles/spinner`, or of any other Bubble —
see [What you get](#what-you-get). Note also that this animates at 10 Hz for as
long as it runs, with no pause key; see
[`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) 11.3 before you copy the shape into
something that runs for hours.)
</details>

<details>
<summary><b>examples/http</b> — two concurrent, cancellable network <code>Cmd</code>s under one <code>batch()</code></summary>

<br>

```text
http://example.com:80         200
http://example.org:80         200
```

Both checks start together from a single `batch()` returned by `init_cmd`, each
line goes from `checking...` to its own result the moment that check lands, and
the program quits when both are done. Which line settles first is whatever the
network decided — `batch()` promises concurrency, never order.
</details>

<details open>
<summary><b>examples/editor</b> — <code>.Diff</code>, alt screen, mouse, paste, Kitty keys, a real cursor</summary>

<br>

```text
RuneTea editor   arrows Home End PgUp PgDn   Ctrl+<-/-> word   Ctrl+C quit
--------------------------------------------------------------------------------
  1 The quick brown fox jumps over the lazy dog.
  2 Type anything. Arrow keys move the caret, and Left at column 1
  3 wraps to the end of the previous line.
  4 Ctrl+Left and Ctrl+Right jump whole words -- that is CSI 1;5D
  5 and CSI 1;5C, the xterm modifier encoding.
  6 Backspace deletes backwards (0x7F). Delete deletes FORWARD
  7 (CSI 3~). They are different sequences and different actions.
  8 Home and End go to the ends of this line.
  9 PageUp and PageDown scroll by a whole viewport, which is as
 10 tall as this window minus the four rows of chrome -- resize
 11 and watch the line count in the status bar follow.
 12 Paste something multi-line: bracketed paste streams it in as
 13 ordinary keypresses with pasted = true, so the text lands as
 14 text even when it contains what looks like an escape sequence.
 15 Tab indents by four spaces.
 16 Ctrl+I toggles the help panel -- a DIFFERENT key from Tab, but
 17 only because the Kitty disambiguation flag is on.
 18 Ctrl+C quits.
   ~
   ~
--------------------------------------------------------------------------------
Ln 1, Col 1   18 lines   window 1-18   term 80x24   kitty:off   last:-
```

Read this one once the quickstart makes sense. Its model, `update` and `view`
live in a separate package (`examples/editor/edit`) precisely so they can be
driven through the real `run()` loop from scripted input bytes in a test, rather
than only by a human staring at a terminal.

The layout is derived from the terminal, not from constants: the header drops
hints one at a time until what is left fits, the rule is as wide as the window,
and the text area is every row that is not chrome — `window 1-18` at 80x24, more
when you make the window taller. Below 20x6 it says `need 20x6, have WxH` and
paints nothing else. `kitty:off` in the status bar is honest: the capture's
emulator never answered the `CSI ? u` query, so `Ctrl+I` is Tab here and the
header does not offer the help binding.
</details>

## The `.Diff` renderer

Set `p.render_mode` before `run()`. `.Inline` is the zero value.

| Mode | What it does | Use it for |
|---|---|---|
| `.Inline` | Rewinds over its own previous frame and repaints, leaving output in your scrollback. | Prompts, pickers, progress — anything that should still be on screen after the program exits. |
| `.Full_Screen` | Repaints from an absolute origin every frame. | Applications that own the viewport. Pair with `alt = true`. |
| `.Diff` | The **same frame** `.Full_Screen` paints, delivered as the minimum set of writes that turns what is on screen into it. | The same applications — over ssh, in tmux, on a slow link. |

`.Full_Screen` and `.Diff` also hide the terminal's caret for as long as they own
the viewport, showing it again only for a frame that declares one. And both of
them, paired with `alt = true`, leave **nothing in scrollback** — which is where
a screen reader, terminal search and copy-out all look. Make the mode a setting
if that might matter to your users
([`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) 11.1).

From `./tools/difftest/run.sh measure`. The two geometries are not the same, and
the caption here used to name only the second: the first two blocks come from
`measure()` on an **80×24** screen, the `examples/editor` block from
`measure_editor()` on **100×30**.

```text
  identical consecutive frames   repaint 2017 B    diff 0 B      (0.0%)
  one changed cell               repaint 2017 B    diff 17 B     (0.8%)
  five changed cells, one line   repaint 2017 B    diff 21 B     (1.0%)
  full-screen change             repaint 2017 B    diff 2055 B   (101.9%)

--- 60 fps for one second, static screen (the ssh case) ---
  repaint: 121026 bytes/s      diff: 2066 bytes/s
  (2066 of that is frame 1's initial paint; every later frame is 0)

--- examples/editor, typing 'The quick brown fox' (19 keystrokes) ---
  19 frames    repaint 20022 B total, 1053 B/frame
  19 frames    diff    2203 B total, 115 B/frame   (11.0% of repaint)
  60 idle frames (nothing typed):  repaint 63780 B    diff 0 B
```

**An identical consecutive frame costs zero bytes.** That is the single most
useful fact about this library: re-render as often as you like and pay nothing
for the frames that did not change. A real editing session pays about a ninth
of a repaint for the ones that did, and the worst case — every cell different —
is 101.9%, so the diff is never meaningfully worse than the thing it replaces.
(The editor's repaint cost went up this cycle, from 754 to 1053 B/frame, because
its text area is now the whole window instead of a fixed ten rows. The diff cost
did not move at all: it is proportional to what *changed*, and one keystroke
changes one cell whatever the window size.)

**One keystroke, one frame.** The loop applies every message already queued
before it paints, so a burst costs one frame rather than one frame each. A
1,332-byte paste into `examples/editor` at 100×30, delivered the way a terminal
delivers one — a single `write()` — used to come back as **26,268 bytes over 57
reads**; it is now **1,699 bytes over 2**. Latency is unchanged: a lone
keystroke was one frame before and is one frame now.

**What it costs you.** `.Diff` models exactly two escapes per cell: SGR and
OSC 8 hyperlinks. A view containing a tab, a carriage return, a cursor motion,
an erase or a window-title OSC is lying to that model — it renders correctly
under `.Full_Screen` and wrongly under `.Diff`. This is checkable:
`rt.view_diff_safe(view)` is a public, allocation-free predicate you can assert
in your own tests, and **every build that is not optimised** — `odin build .`,
`odin build . -debug`, `odin test` — asserts it on every frame. `-o:speed` and
`-o:aggressive` compile the check out. `.Inline` and `.Full_Screen` get the
weaker `rt.view_render_safe` check, which permits `\t` and still rejects cursor
motion, because both modes count the rows they painted and a view that moves the
cursor itself makes that count a lie.

## RuneGloss

Colours with automatic down-conversion to whatever the terminal can actually
show, attributes, padding, margins, alignment and borders. Odin has no method
chaining, so Lipgloss's fluent builder becomes a mutable value plus `^Style`
setters — and a `Style` is a **plain value type**, so you can build it once and
keep it in your model.

<!-- doccheck: decl gloss -->
```odin
styled_box :: proc(alloc: mem.Allocator) -> string {
	box := rg.new_style()             // profile detected from $NO_COLOR/$TERM/$COLORTERM
	rg.fg(&box, rg.color("#FAFAFA"))
	rg.bg(&box, rg.color("#7D56F4"))
	rg.bold(&box, true)
	rg.padding(&box, 1, 3)            // CSS arities: 1, 2 or 4 values
	rg.border(&box, rg.ROUNDED)       // NORMAL / ROUNDED / THICK / DOUBLE / HIDDEN
	rg.border_fg(&box, rg.color(240)) // 256-colour palette index
	rg.align(&box, .Center)
	rg.width(&box, 30)                // EXACT, and it includes the border
	return rg.render(&box, "Hello, RuneGloss", alloc)
}
```

```text
╭────────────────────────────╮
│                            │
│      Hello, RuneGloss      │
│                            │
╰────────────────────────────╯
```

Thirty columns, corner to corner: `width` is an **exact clamp and it includes
the border**, which is Lipgloss v2's box model. Content wider than the content
area is wrapped (or truncated, with `rg.overflow(&s, .Truncate)`); `rg.overflow(&s, .Grow)`
brings back the old floor semantics if you want them.

On a terminal that reports no colour — or under `$NO_COLOR` — the profile is
`.None` and **every colour is dropped, with no `if` anywhere in your view.**
Attributes and layout are not: bold, faint, italic, underline, reverse and
strike still emit SGR, and padding, width, alignment and borders still
restructure the string. Under `.None` the box above is still a five-line,
thirty-column bordered box — 310 bytes out for 16 bytes in, with three
`\e[1m…\e[0m` runs in it. The invariant that really holds is narrower and
belongs to the *style*, not the profile: **a style that asks for nothing renders
its input byte for byte**, at every profile. If you need plain text for a log or
a pipe, pass the text through, not through a Style. Truecolour degrades to 256
and then to 16 by nearest CIE76 ΔE in CIELAB space, not by truncation, and
`rg.contrast_ratio` / `rg.relative_luminance` let you check what a down-converted
pair actually costs you.

Every style RuneGloss emits is **one SGR sequence with its parameters in a fixed
order**. That is not cosmetic: `.Diff` interns styles by their exact byte
spelling, so two spellings of one style would be two styles, and a cell that
"did not change" would repaint forever.

> RuneGloss is deliberately a subset of Lipgloss. It now has wrapping
> (`rg.wrap`), truncation (`rg.truncate`), measurement (`rg.measure`), frame
> arithmetic (`rg.frame_size`) and `rg.join_horizontal`/`rg.join_vertical`. It
> still has no `table`, no `tree`, no `list`, and no fluent chaining.

## Platform support

| Platform | Status |
|---|---|
| **Linux** | **Verified.** Every test, the race gate, the pty harnesses and every byte-count in this README was run here. |
| **macOS / BSD** | **Unverified.** The code paths exist and the package compiles, but no machine was available — not one test, not one frame has ever run. |
| **Windows** | Out of scope for v1.0. It is a separate console backend, not a port. |

The terminal-size query is the first thing to expect trouble from on a Mac or a
BSD; `.Diff` and full-screen truncation both depend on it. **If you run RuneTea
on either, a bug report — or a green test run — is the single most valuable
contribution available right now.**

**Accessibility: the user has levers now, and one default still works against
them.** The alternate screen plus `.Diff` — the combination `examples/editor`
uses and the one this README recommends for full-screen apps — puts nothing in
scrollback, which is where a screen reader's review mode, the terminal's own
search, and copy-out all look. So RuneTea reads three environment variables on
your behalf, and **you do not have to do anything for the first two to work**:

| Variable | Effect | Enforced |
|---|---|---|
| `RUNETEA_NO_ALT` | never enter the alternate screen | **yes**, over the application's own request |
| `RUNETEA_INLINE` | force `Render_Mode.Inline` | **yes** |
| `RUNETEA_REDUCE_MOTION` | `rt.reduce_motion()` returns true | advisory — `examples/spinner` starts paused |

They can only take a terminal mode *away*, never grant one. `$NO_COLOR` is
honoured, now strips `rg.blink` (WCAG 2.3.1 is Level A), and `rg.contrast_ratio`
exists. If your application has its own `--no-alt` flag, route it through
`rt.set_a11y_prefs` rather than inventing a parallel lever only you honour.

What none of that fixes: **nothing here has ever been run with a screen reader.**
[`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) section 11 is the full, honest list.

## Limitations

[`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) is the consolidated list of
everything RuneTea does not do, does not do fully, or does differently from what
you would reasonably expect — each entry labelled **INTRINSIC**,
**NOT-YET-BUILT**, **TOOLCHAIN** or **FIXED**, each saying when it bites and what
to do instead, each citing the source comment that argues the case. Its
citations are checked by the same gate that compiles the samples, so a claim
pointing at a line that has moved is a build failure.

**Read it before adopting.** The entries most likely to change your design:

| | |
|---|---|
| **2.1 / 2.2** | Every `Msg` must be POD, checked at *runtime*. |
| **2.5** | Cancellation is polling, never preemption. |
| **2.19** | A `Cmd` value is single-use; re-dispatching one is refused. |
| **3.2** | What a `.Diff` view may and may not contain. |
| **3.15** | `view` gets an allocator it must hand-thread; forget and you leak a frame — detected and reported since v1.0-final, but still yours to fix. |
| **5.5** | No terminfo consultation — measured against 40 installed entries. |
| **6.5** | Bounds violations and nil derefs are *not* recoverable. |
| **6.6** | A recovered `update` panic leaves your model half-mutated. |
| **8.5** | There is no component library. Every widget is yours to write. |
| **11** | Accessibility: the alt screen plus `.Diff` is opaque to assistive tech. |

## Tests and gates

```console
$ ./tools/test.sh          # 531 tests, seven packages, + leak audit + doc gate + pyte
$ ./tools/test.sh race     # the real race gate: ThreadSanitizer over tools/racecheck
$ ./tools/difftest/run.sh  # the diff renderer cross-checked against pyte, on its own
```

531 is `runetea` 404 + `examples/editor/edit` 41 + `runegloss` 69 +
`examples/{quickstart,simple,spinner,http}` 3 + 3 + 7 + 4. The four single-file
examples joined the gate last: `odin test` works on a `package main` (the
generated runner supplies its own entry point), and until they were on it the
only thing checking them was a build — which is how four minimum-size guards
came to be off by exactly one row at once
([`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) 3.20, 9.8).

- **The leak audit** turns `odin test`'s tracking-allocator report into a gate.
  Every leak site must be on an allowlist naming exactly one deliberate, bounded
  entry, or the run fails — because a suite that always reports leaks cannot
  report a *new* one.
- **The documentation gate** ([`tools/doccheck`](tools/doccheck/run.sh)) extracts
  and compiles every Odin block in this README, in [`docs/API.md`](docs/API.md)
  and in [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md); builds all 27 `main`
  packages; runs the quickstart under a **real pty** with real keystrokes and a
  real resize, replays its bytes through pyte and compares the resulting **cell
  grid** against the screen printed at the top of this file; resolves every
  source citation, test name and relative link the three documents make; and
  checks that `odin doc` lists the library rather than its test fixtures. A
  sample that stops compiling, a citation that has rotted, or a screen that no
  longer matches fails the suite.
- **`./tools/test.sh race` is the real race gate**, and `tsan` is not:
  `odin test -sanitize:thread` does not detect data races on this toolchain —
  verified against a deliberate 4-thread unsynchronised counter that raced
  physically and was reported by `odin build -sanitize:thread` and *not* by
  `odin test`. The `tsan` mode says so on every run, and is kept only because it
  still catches allocator failures.
- **`difftest`** replays both byte streams — the full repaint's and the diff's —
  through [pyte](https://github.com/selectel/pyte), a third-party VT100 emulator
  written by people who have never seen this repository, and compares the
  resulting screens cell for cell. It runs **on** the default gate: `python3` and
  `pyte` are hard requirements of the suite, and every checker that needs them
  exits non-zero when they are absent rather than skipping. That is the reversal
  of an earlier argument — "a missing module would become a skip, and a skip
  inside a green run is indistinguishable from a pass" is an argument against
  the *skip*, not against the dependency.

## Documentation

| Where | What |
|---|---|
| This file | What RuneTea is, and enough to write a first program. |
| [`docs/API.md`](docs/API.md) | The public API **organised by task** — "how do I make a spinner", "how do I handle a resize" — with a symbol index. |
| [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) | Everything it does not do. Required reading before adopting. |
| `odin doc runetea` | Every public symbol with its doc comment (`-short` for signatures only). |
| The source | **The reasoning.** Comments in `runetea/` and `runegloss/` are unusually dense on purpose: they argue each decision, name the alternatives that were rejected, and cite the measurements. |

## Contributing

Issues and pull requests are welcome. Two things make a contribution land fast:

1. **`./tools/test.sh` must pass**, including the doc gate. If you change a
   public signature, the samples in the docs will fail to compile — that is the
   gate working.
2. **A test that fails before your fix.** Every bug in this repository was found
   by something automated; the fastest way to get a fix reviewed is to hand over
   the thing that catches it.

The single most valuable contribution right now is a test run on macOS or BSD.

## Acknowledgments

RuneTea is a port, and the design is not mine. [Bubble Tea](https://github.com/charmbracelet/bubbletea),
[Lipgloss](https://github.com/charmbracelet/lipgloss) and the rest of
[Charm](https://charm.sh) are the original and remain the reference — if you
write Go, use theirs. Thanks also to [pyte](https://github.com/selectel/pyte),
whose independence is what makes the diff renderer's correctness checkable at
all, and to the [Odin](https://odin-lang.org) project.

## License

[MIT](LICENSE)
