# RuneTea

RuneTea is a terminal-UI framework for [Odin](https://odin-lang.org): an Elm
architecture (one model, one `update`, one `view`) driven by a real event loop
that turns keystrokes, mouse reports, window resizes, signals and background
work into messages. It is a port of Go's [Bubble
Tea](https://github.com/charmbracelet/bubbletea), and `runegloss/` is its
[Lipgloss](https://github.com/charmbracelet/lipgloss) — for anyone who wants
that shape of TUI in a language with no garbage collector, no closures, and an
explicit allocator on every call.

**Platform: Linux is verified. macOS and BSD are not.** See
[Platforms](#platforms) — it is the first thing to read if you are not on
Linux.

---

## Contents

- [Quickstart](#quickstart)
- [The architecture](#the-architecture)
- [Messages](#messages)
- [Commands](#commands)
- [Render modes](#render-modes)
- [Terminal opt-ins](#terminal-opt-ins)
- [RuneGloss](#runegloss)
- [Examples](#examples)
- [Platforms](#platforms)
- [Limitations — required reading](#limitations--required-reading)
- [Tests and gates](#tests-and-gates)
- [Documentation map](#documentation-map)

---

## Quickstart

A complete program. It is
[`examples/quickstart/main.odin`](examples/quickstart/main.odin), quoted
verbatim — `tools/doccheck/run.sh` fails the test suite if this block and that
file ever differ, so what you are reading is a program that compiles and runs.

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
}

// `m` is a POINTER: mutate it in place and return only the Cmd. That is
// RuneTea's one deliberate divergence from Bubble Tea's value-based Update --
// see rt.Program.update (runetea/tea.odin) for the build-time measurements
// that bought it and the crash-safety property it cost.
update :: proc(m: ^Model, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	switch v in msg {
	case rt.Key_Msg:
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
	if !rt.term_enter_raw(fd) { fmt.eprintln("not a tty"); os.exit(1) }
	defer rt.term_restore()

	src, ok := rt.input_source_from_fd(fd)
	if !ok { fmt.eprintln("bad input source"); os.exit(1) }
	defer rt.input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: rt.Program(Model)
	rt.program_init(&p, Model{}, update, view)

	// The last argument is the fd each finished frame is written to. Pass it
	// and the display updates live; leave it out (-1) and the whole session
	// accumulates in `b` instead, which is how the golden tests read it.
	if err := rt.run(&p, &src, &b, fd); err != nil { fmt.eprintln("error:", err) }
}
```

Build and run it:

```console
$ odin build examples/quickstart -out:quickstart
$ ./quickstart
```

Press `j`, then space, then `q`, and the terminal shows this — captured from a
real pty by `tools/ptyrun`, which is also how the test suite checks it:

```text
What should we buy at the market?

  [ ] Buy carrots
> [x] Buy celery
  [ ] Buy kohlrabi

Press q to quit.
```

Three things in that program are worth naming before anything else, because
they are the three ways RuneTea differs from Bubble Tea at the call site:

1. **`update` takes `^Model`** and returns only a `Cmd`. Bubble Tea's `Update`
   takes and returns a model by value.
2. **`run()` does not own the terminal.** You call `term_enter_raw` and pair it
   with `defer term_restore()` yourself. Bubble Tea's `Program` does this for
   you; here the layer that entered raw mode is the layer that leaves it.
3. **Every allocation names its allocator.** `view` is handed a per-frame arena
   and everything it builds from that allocator is reclaimed wholesale when the
   frame ends. Nothing in a view is ever freed by hand.

---

## The architecture

Three procedures and a struct:

<!-- doccheck: decl arch -->
```odin
Model :: struct { count: int }

// Mutates the model in place; returns the next Cmd (or rt.cmd_nil()).
update :: proc(m: ^Model, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	if k, ok := msg.(rt.Key_Msg); ok && k.code == .Escape { return rt.quit_cmd() }
	m.count += 1
	return rt.cmd_nil()
}

// Pure: model in, frame string out, allocated from the frame arena.
view :: proc(m: Model, alloc: mem.Allocator) -> string {
	return fmt.aprintf("count: %d", m.count, allocator = alloc)
}
```

wired up with `program_init` and driven by `run`:

<!-- doccheck: body arch -->
```odin
p: rt.Program(Model)
rt.program_init(&p, Model{}, update, view)
// optional, and all defaulted: an initial Cmd, a cursor callback, a render
// mode, a legacy-key encoding.
p.render_mode = .Inline
```

`Program` is parametric over the model type (`Program($T)`) rather than an
interface. That is *stronger* checking than Go's: Go verifies only that your
methods exist, not that `Update` returns the same concrete type it was given.
The cost is that a model cannot be swapped for a different type mid-run — use a
state enum, or make `T` itself a vtable.

### Why `update` takes a pointer

This is the one deliberate, breaking divergence from Bubble Tea's value-based
`Update`, and it is not an aesthetic preference: **the by-value round-trip made
LLVM codegen superlinear in `sizeof(T)`**, which put a hard, invisible ceiling
on how large a model a RuneTea application could have. Measured as wall-clock
`odin build` of a minimal program whose model is an `[N]int`, before and after
(commit `e9773a1`):

| model size | by value | by pointer |
|---|---|---|
| 8 KiB | 2.28 s | 1.18 s |
| 16 KiB | 8.97 s | 1.17 s |
| 32 KiB | 105.91 s | 1.07 s |
| 64 KiB | did not finish in 200 s | 1.12 s |
| 1 MiB | not attempted | 1.20 s |

Nothing *fails* at 64 KiB — a build simply stops finishing, which is the worst
shape a limit can have. The full bisection is in the comment on
`Program.update` in [`runetea/tea.odin`](runetea/tea.odin).

**What it cost, stated plainly:** crash recovery no longer protects model
*state*. With the by-value signature a panicking `update` left the model at its
last good value, because the recovery jump skipped the assignment. With a
pointer, `update` writes into your model directly, so a panic partway through
leaves it half-mutated. RuneTea still guarantees that the process survives, the
terminal is restored, the frame arena is reclaimed and `run()` returns
`Panicked_Error` — it guarantees nothing about the model's contents afterwards.
The only mitigation that works is structural: do everything that can fail
first, into locals, and write into `m^` last. See
[`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) 6.6.

---

## Messages

A `Msg` is any value. `update` receives it as `any` and type-switches on it:

<!-- doccheck: decl arch -->
```odin
handle :: proc(m: ^Model, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	switch v in msg {
	case rt.Key_Msg:                    // a keypress (or a pasted rune)
		if v.code == .Rune && v.r == 'q' { return rt.quit_cmd() }
	case rt.Mouse_Msg:                  // press/release/motion/wheel, 0-based cells
		m.count = v.x
	case rt.Window_Size_Msg:            // SIGWINCH; w/h in cells
		m.count = v.w
	case rt.Focus_Msg:                  // terminal focus gained
	case rt.Blur_Msg:                   // terminal focus lost
	case rt.Paste_Start_Msg:            // bracketed paste opened
	case rt.Paste_End_Msg:              // ...and closed
	case rt.Keyboard_Enhancements_Msg:  // which Kitty flags the terminal took
	case rt.Panicked_Msg:               // a background Cmd panicked and was recovered
	case rt.Timer_Unavailable_Msg:      // no tick()/every() on this session will ever fire
	}
	return rt.cmd_nil()
}
```

**Every message type must be POD.** `box()` — the function that puts a value on
the wire — rejects any type with a `string`, pointer, slice, map or `any`
anywhere in its field tree, at runtime, the first time that path executes. This
is the single largest permanent ergonomic cost of the design, and it is what
makes message ownership decidable: exactly one allocation per message, freed by
the loop. For short text there is `Msg_Text` (a 255-byte inline buffer that
records whether it truncated); for anything larger, keep the payload in your own
storage and send a handle.

```odin
Fetched_Msg :: struct {
	id:     int,
	status: int,
	err:    rt.Msg_Text,   // NOT `string` -- box() would reject it
}
```

Test it once and the runtime check becomes a compile-time-ish guarantee:
`rt.is_pod_type(Fetched_Msg)` is a plain boolean you can assert in your own
tests. See [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) 2.1–2.4.

---

## Commands

A `Cmd` is work that happens off the update loop and delivers a message back
into it. Odin has no closures, so the captured environment is explicit: a named
procedure plus an `env` value that `cmd_from` heap-clones for you.

<!-- doccheck: decl cmds -->
```odin
Fetch_Env :: struct { id: int }
Fetch_Done_Msg :: struct { id: int, ok: bool }

fetch :: proc(env: rawptr, cancel: ^rt.Cancel_Token) -> any {
	e := cast(^Fetch_Env)env
	// ... do the slow thing, polling cancel_requested if it can take a while ...
	if rt.cancel_requested(cancel) { return nil }
	return rt.box(Fetch_Done_Msg{id = e.id, ok = true}, context.allocator)
}

start :: proc(id: int) -> rt.Cmd {
	return rt.cmd_from(fetch, Fetch_Env{id = id}, context.allocator)
}
```

Cancellation is **cooperative polling, never preemption**: a `Cancel_Token`
cannot interrupt a Cmd blocked in a syscall it never returns from. A Cmd that
wants to be interruptible must do bounded waits and check the token between
them. `examples/http` shows the shape.

**Composition.** `batch` runs its children concurrently; `sequence` runs them
one after another, each waiting for the last:

<!-- doccheck: decl cmds -->
```odin
both :: proc() -> rt.Cmd {
	return rt.batch([]rt.Cmd{start(1), start(2)}, context.allocator)
}

in_order :: proc() -> rt.Cmd {
	return rt.sequence([]rt.Cmd{start(1), start(2)}, context.allocator)
}
```

Both take a **slice, not a variadic** (Odin variadics must be last, and the
allocator is explicit everywhere in this package). A `tick`/`every` placed
inside a `sequence` gates nothing — see
[`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) 2.11.

**Timers.** `tick` fires once after a duration and hands back no handle, which
is what makes the common animation pattern — reissue from `update` on every
fire — structurally unable to leak. `every` repeats on its own and hands back a
`Timer_Handle` you must pass to `timer_stop` exactly once.

<!-- doccheck: decl cmds -->
```odin
Frame_Msg :: struct { t: time.Tick }

frame_fn :: proc(env: rawptr, t: time.Tick) -> any {
	return rt.box(Frame_Msg{t = t}, context.allocator)
}

next_frame :: proc() -> rt.Cmd {
	return rt.tick(100 * time.Millisecond, frame_fn, struct{}{}, context.allocator)
}

// A poll that runs until you stop it. Keep the handle; call rt.timer_stop(h)
// exactly once, even if it already fired.
poll :: proc() -> (rt.Cmd, ^rt.Timer_Handle) {
	return rt.every(1 * time.Second, frame_fn, struct{}{}, context.allocator)
}
```

`quit_cmd()` ends the session; returning it from `update` is how a program
exits.

---

## Render modes

Set `p.render_mode` before `run()`. `.Inline` is the zero value, so a program
that says nothing keeps the inline renderer.

| Mode | What it does | Use it for |
|---|---|---|
| `.Inline` | Rewinds over its own previous frame and repaints, leaving output in your scrollback. | Prompts, pickers, progress, anything short that should still be on screen after the program exits. |
| `.Full_Screen` | Repaints an absolute origin every frame and clears below itself. Truncates content taller than the viewport. | Applications that own the viewport. Pair with `alt = true` (below) for the usual full-screen experience. |
| `.Diff` | The *same frame* `.Full_Screen` paints, delivered as the minimum set of writes that turns what is on screen into it. | The same applications — over ssh, in tmux, on a slow link, or any time you would rather not repaint an unchanged screen 60 times a second. |

### The measurement

From `./tools/difftest/run.sh measure`, on a 100×30 screen:

```text
  identical consecutive frames   repaint 2017 B    diff 0 B   (0.0%)
  one changed cell               repaint 2017 B    diff 17 B   (0.8%)
  five changed cells, one line   repaint 2017 B    diff 21 B   (1.0%)
  full-screen change             repaint 2017 B    diff 2055 B   (101.9%)

--- 60 fps for one second, static screen (the ssh case) ---
  repaint: 121020 bytes/s      diff: 2060 bytes/s (2060 of that is frame 1's
  initial paint; every later frame is 0)

--- examples/editor, typing 'The quick brown fox' (19 keystrokes) ---
  19 frames    repaint 14341 B total, 754 B/frame
  19 frames    diff    2203 B total, 115 B/frame   (15.4% of repaint)
  60 idle frames (nothing typed):  repaint 45840 B    diff 0 B
```

**An identical consecutive frame costs zero bytes.** That is the single most
useful fact about this library: a full-screen application can re-render as often
as it likes and pay nothing for the frames that did not change, and a real
editor session pays about a seventh of a repaint for the ones that did. The
worst case — every cell different — is 101.9% of a repaint, i.e. the diff is
never meaningfully worse than the thing it replaces.

**What `.Diff` costs you.** It models exactly two escapes per cell, SGR and
OSC 8 hyperlinks. A view containing a tab, a carriage return, a cursor-motion
sequence, an erase or a window-title OSC is lying to that model: it renders
correctly under `.Full_Screen` and wrongly under `.Diff`. This is checkable —
`rt.view_diff_safe(view)` is a public, allocation-free predicate you can assert
in your own tests, and debug builds assert it on every frame. It also needs the
terminal's width *and* height; with either unknown it degrades to
`.Full_Screen`'s exact byte stream. See
[`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) 3.2 and 3.5.

### The cursor

`.Inline`, `.Full_Screen` and `.Diff` all place the real terminal cursor if you
ask them to, via an optional per-frame callback. A program that never sets one
emits not a single extra byte.

```odin
Prompt_Model :: struct { typed: string }

caret :: proc(m: Prompt_Model, alloc: mem.Allocator) -> rt.Cursor {
	// `line` indexes the view's "\n"-separated LOGICAL lines. `col` is a
	// DISPLAY column -- what rt.display_width measures -- and not a byte or
	// rune index, which would put the caret in the wrong place the moment the
	// prefix contains a wide rune or a styling escape.
	prefix := fmt.aprintf("prompt> %s", m.typed, allocator = alloc)
	return rt.Cursor{line = 2, col = rt.display_width(prefix), show = true}
}
```

---

## Terminal opt-ins

`term_enter_raw` puts the tty in raw mode and, optionally, turns on terminal
features. **Every one of them defaults to off, and off means not one byte is
written.** A terminal must never be left in a state this process did not
deliberately enter, so each opt-in is paired with a teardown that `term_restore`
(and the crash-signal path) performs exactly once.

<!-- doccheck: body -->
```odin
fd := posix.FD(os.fd(os.stdin))

// install_crash_handlers FIRST -- term_enter_raw arms its restore flag before
// tcsetattr has touched the tty, and a crash in that window is only
// recoverable if a handler already exists.
rt.install_crash_handlers()
ok := rt.term_enter_raw(
	fd,
	{.Disambiguate},  // kb:     Kitty keyboard protocol flags
	true,             // paste:  bracketed paste (DECSET 2004)
	.Normal,          // mouse:  .None / .Normal / .Button_Event / .Any_Event
	false,            // focus:  focus in/out reporting (DECSET 1004)
	true,             // alt:    the alternate screen buffer (DECSET 1049)
)
if !ok { os.exit(1) }
defer rt.term_restore()
```

| Parameter | What it buys | What it costs |
|---|---|---|
| `kb: Kitty_Flags` | `.Disambiguate` makes Tab and Ctrl+I, Enter and Ctrl+M, Escape and Ctrl+`[` **different keys** instead of one shared byte, and removes the lone-`ESC` ambiguity entirely. `.Report_Event_Types` adds press/repeat/release. `.Alternate_Keys`, `.All_Keys_As_Escapes`, `.Associated_Text` are the rest of the protocol. | Fire-and-forget: a terminal without Kitty support ignores it and keys keep arriving in the legacy encoding. `.Report_Event_Types` makes **every key arrive twice** — enable it only together with a `kind == .Press` filter. |
| `paste: bool` | Pasted text arrives bracketed by `Paste_Start_Msg`/`Paste_End_Msg`, with every rune flagged `pasted = true`, so a newline in a paste is not Enter and a `q` is not your quit binding. | The content is *streamed* as ordinary `Key_Msg`s, not delivered as one string — a `string` payload is illegal in a Msg. That is O(1) memory for an arbitrarily large paste. |
| `mouse: Mouse_Mode` | `.Normal` reports press and release; `.Button_Event` adds drag; `.Any_Event` reports every cell the pointer crosses. Coordinates are 0-based cells, matching `Cursor`. | `.Any_Event` is a flood of wakeups. RuneTea always pairs the tracking mode with SGR extended coordinates (`?1006h`), because the legacy encoding cannot express a column past 223. |
| `focus: bool` | `Focus_Msg` / `Blur_Msg` when the terminal window gains or loses focus. | Nothing, if you handle them. Enabling a mode with no handler behind it is the thing these defaults exist to make easy to avoid. |
| `alt: bool` | The alternate screen buffer: a cleared buffer of your own, and on exit the user's shell exactly as they left it, scrollback intact. | Deliberately **independent** of `render_mode`. `.Full_Screen` without `alt` repaints over the user's scrollback; `alt` without `.Full_Screen` is a legal (if unusual) inline session inside the alt buffer. Ask for both if you want the usual full-screen experience. |

Whether the terminal actually honoured the Kitty request arrives as a
`Keyboard_Enhancements_Msg`; a terminal with no support never replies at all,
so "no message" means "legacy encoding". `examples/editor` prints
`kitty:on`/`kitty:off` in its status line for exactly this reason.

---

## RuneGloss

`runegloss/` is a styling layer in the shape of Lipgloss: colours with
automatic down-conversion to what the terminal can actually show, attributes,
padding, margins, alignment, and borders. Odin has no method chaining, so
Lipgloss's fluent builder becomes a mutable value plus `^Style` setters.

**A `Style` is a plain value type** — no strings, no pointers, no slices — so
you can store one in your model, copy it, and hand copies around with no
aliasing. That is why the shipped examples build their styles once in `main`
and keep them in the `Model` instead of rebuilding them every frame.

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
	rg.width(&box, 30)                // a FLOOR, not a clamp
	return rg.render(&box, "Hello, RuneGloss", alloc)
}
```

On a truecolour terminal that is a grey rounded frame around a white-on-purple
box, thirty columns wide:

```text
╭──────────────────────────────╮
│                              │
│       Hello, RuneGloss       │
│                              │
╰──────────────────────────────╯
```

and the bytes it actually emits, with escapes made visible, are:

```text
\e[38;5;240m╭──────────────────────────────╮\e[0m
\e[38;5;240m│\e[0m\e[1;38;2;250;250;250;48;2;125;86;244m                              \e[0m\e[38;5;240m│\e[0m
\e[38;5;240m│\e[0m\e[1;38;2;250;250;250;48;2;125;86;244m       Hello, RuneGloss       \e[0m\e[38;5;240m│\e[0m
\e[38;5;240m│\e[0m\e[1;38;2;250;250;250;48;2;125;86;244m                              \e[0m\e[38;5;240m│\e[0m
\e[38;5;240m╰──────────────────────────────╯\e[0m
```

Note that every style is one SGR sequence with its parameters in a fixed order.
That is not cosmetic: `.Diff` interns styles by their exact byte spelling, so
two spellings of the same style are two styles and a cell that "did not change"
would be repainted forever. RuneGloss guarantees the fixed spelling of anything
it emits; a hand-written view owes it to itself.

On a terminal that reports no colour — or under `$NO_COLOR` — the profile is
`.None` and `render` returns its input byte for byte, with no `if` anywhere in
your view.

**RuneGloss is deliberately a subset of Lipgloss.** There is no wrapping, no
truncation, and no `JoinHorizontal`/`JoinVertical`/`table`/`tree`/`list`;
`width` and `height` are floors, not clamps, so content wider than `width`
widens the block rather than being cut. See
[`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) section 7 before assuming
otherwise.

---

## Examples

Each is its own `main` package. Build with `odin build <dir> -out:<name>`, or
run straight from source with `odin run`:

```console
$ odin run examples/quickstart   # this README's quickstart: a list picker, .Inline
$ odin run examples/simple       # the smallest possible program: a key counter
$ odin run examples/spinner      # tick()-driven animation + RuneGloss styling
$ odin run examples/http         # batch() of two concurrent, cancellable network Cmds
$ odin run examples/editor       # the whole apparatus: .Diff, alt screen, mouse,
                                 # bracketed paste, Kitty keys, a real cursor
```

`examples/editor` is the one to read once the quickstart makes sense: its
model, `update` and `view` live in a separate package (`examples/editor/edit`)
precisely so they can be driven through the real `run()` loop from scripted
input bytes in a test, rather than only by a human staring at a terminal.

---

## Platforms

**Linux is the verified platform.** Everything in this repository — the 352
tests, the ThreadSanitizer race gate, the pty harnesses, the byte-count
measurements — was run on Linux, and the terminal-size query goes through
`core:sys/linux` directly because `core:sys/posix` exposes neither `ioctl` nor
a `winsize` struct.

**macOS and BSD are UNVERIFIED.** Those code paths exist and the package
compiles, but **no Mac or BSD machine was available**, so nothing on them has
ever been run — not one test, not one frame. Treat any claim about them as
untested. The size query is the first thing to expect trouble from, and
`.Diff` mode plus full-screen truncation both depend on it.

**Windows is out of scope for v1.0.** It is a separate console backend, not a
port.

If you run RuneTea on a Mac or a BSD, a bug report — or a green test run — is
the single most valuable contribution available right now.

---

## Limitations — required reading

[`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) is 1,000 lines and it is not
marketing. It is the consolidated list of everything RuneTea does not do, does
not do fully, or does differently from what you would reasonably expect, each
entry labelled **INTRINSIC** (cannot be fixed without changing the design),
**NOT-YET-BUILT** (a real gap with a known shape) or **TOOLCHAIN** (Odin's
`core:` libraries, not RuneTea), each saying when it bites and what to do
instead, and each cross-referencing the source comment that argues the case.

**Read it before adopting.** Not skim — read. The entries most likely to change
your design are:

- **2.1** every `Msg` must be POD, checked at *runtime* (2.2).
- **2.5** cancellation is polling, never preemption; quit takes as long as your
  slowest blocking Cmd.
- **3.2** what a `.Diff` view may and may not contain.
- **5.5** there is no terminfo consultation — measured against 40 installed
  entries, with the two populations it fails named.
- **6.5** bounds violations and nil derefs are *not* recoverable; they end the
  process (with the terminal restored).
- **6.6** a recovered `update` panic leaves your model half-mutated.
- **7.1** RuneGloss has no wrapping and no truncation.

---

## Tests and gates

```console
$ ./tools/test.sh          # 352 tests across three packages, + leak audit + doc gate
$ ./tools/test.sh race     # the real race gate: ThreadSanitizer over tools/racecheck
$ ./tools/difftest/run.sh  # the diff renderer cross-checked against pyte (needs python3 + pyte)
```

**What each gate actually checks.**

`./tools/test.sh` runs `odin test` over the three packages that hold tests —
`runetea` (281), `examples/editor/edit` (26) and `runegloss` (45), 352 in total
— as three invocations rather than one, because both of the latter *import*
`runetea` and a single test package would be an import cycle. It then does two
things `odin test` does not:

- **A leak audit.** `odin test`'s tracking allocator prints leaks but does not
  fail for them, and a suite that always reports leaks cannot report a *new*
  one. The audit turns the report into a gate: every leak site must be on an
  allowlist naming exactly one deliberate, bounded entry (one `^Thread` struct
  per `run()` session), or the run fails.
- **The documentation gate** (`tools/doccheck/run.sh`): every Odin code block
  in this README and in [`docs/API.md`](docs/API.md) is extracted and compiled,
  every `main` package under `examples/` and `tools/` is built, and the
  quickstart is executed under a real pty and asserted on. A sample that stops
  compiling fails the suite.

`./tools/test.sh race` is **the real race gate**. It builds `tools/racecheck` —
a standalone program that hammers the mailbox, dispatcher, signal watcher,
timer thread, both event loops and the batch/sequence coordinators under real
concurrency — with `-sanitize:thread`, and ThreadSanitizer's own non-zero exit
*is* the gate.

`./tools/test.sh tsan` is **NOT a race gate**, and the mode says so on every
run. `odin test -sanitize:thread` does not detect data races on this toolchain
— verified against a deliberate 4-thread unsynchronised counter that raced
physically (392,997 of 400,000 increments landed) and was reported by
`odin build -sanitize:thread` and *not* by `odin test -sanitize:thread`. The
mode is kept only because it still catches allocator and CHECK failures.

`./tools/difftest/run.sh` replays both byte streams — the full repaint's and
the diff's — through [pyte](https://github.com/selectel/pyte), a third-party
VT100 emulator written by people who have never seen this repository, and
compares the resulting screens cell for cell. It is deliberately **off** the
`test.sh` gate: it needs python3 and pyte, and a missing module inside a test
would turn into a skip, which inside a green run is indistinguishable from a
pass. The invariant itself is on the gate, with no external dependencies, in
`runetea/diff_oracle_test.odin`. `./tools/difftest/run.sh measure` prints the
byte counts quoted above.

---

## Documentation map

| Where | What |
|---|---|
| This file | What RuneTea is, and enough to write a first program. |
| [`docs/API.md`](docs/API.md) | The public API organised by task — "how do I make a spinner", "how do I handle a resize" — with a full symbol index. |
| [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) | Everything it does not do. Required reading before adopting. |
| The source | **The reasoning.** Comments in `runetea/` and `runegloss/` are unusually dense on purpose: they argue the case for each decision, name the alternatives that were rejected, and cite the measurements. `docs/API.md` points into them rather than restating them. |
| `docs/superpowers/` | Maintainer-facing decision records: cancellation, batch/sequence, message ownership, nbio, render width, tick/every, Tier-1 coverage. |

`odin doc runetea` and `odin doc runegloss` generate a complete symbol
reference straight from those comments (`-short` for signatures only), which is
why `docs/API.md` does not try to be one.
