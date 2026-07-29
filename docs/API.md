# RuneTea — the public API, by task

## What this document is, and what it deliberately is not

This is a **map**, not a reference. It is organised by the question you are
likely to be holding — *how do I make a spinner, how do I handle a resize, how
do I run something in the background without freezing the UI* — and for each one
it names the handful of symbols involved, shows a sample that compiles, and
points at the source.

**It does not restate the source comments, on purpose.** Comments in `runetea/`
and `runegloss/` are unusually dense: they argue each decision, name the
alternatives that were rejected and why, and cite the measurements. That is the
reasoning, it is versioned with the code it explains, and copying it here would
create a second copy to rot. So this document tells you *which* symbol you want
and *where the argument lives*; the argument itself stays where it is.

**For a complete symbol reference, generate one:**

```console
$ odin doc runetea            # every public symbol, with its doc comment
$ odin doc runetea -short     # signatures only
$ odin doc runegloss
```

`odin doc` reads the same comments, so it is always current and always complete
— which is exactly why this file does not try to be either. What a generated
dump cannot do is answer "where do I start"; that is this file's whole job.

**Before you build on any of it, read
[`LIMITATIONS.md`](LIMITATIONS.md).** Every section below links into it at the
points where the honest answer is "it does not do that".

Every code block in this file is extracted and compiled by
`tools/doccheck/run.sh`, which runs as part of `./tools/test.sh`.

---

## Contents

1. [Starting a program](#1-starting-a-program)
2. [Reacting to input — the message vocabulary](#2-reacting-to-input--the-message-vocabulary)
3. [Doing work off the loop — commands](#3-doing-work-off-the-loop--commands)
4. [Timers — "how do I make a spinner"](#4-timers--how-do-i-make-a-spinner)
5. [Putting data in a message](#5-putting-data-in-a-message)
6. [Drawing — render modes, the cursor, the view contract](#6-drawing--render-modes-the-cursor-the-view-contract)
7. [Handling a resize](#7-handling-a-resize)
8. [Owning the terminal](#8-owning-the-terminal)
9. [How a session ends](#9-how-a-session-ends)
10. [Testing your own application](#10-testing-your-own-application)
11. [Measuring text](#11-measuring-text)
12. [RuneGloss](#12-runegloss)
13. [Symbol index](#13-symbol-index)

---

## 1. Starting a program

| Symbol | File | What it is |
|---|---|---|
| `Program($T)` | `runetea/tea.odin` | Your model plus the callbacks and options that drive it. |
| `program_init` | `runetea/tea.odin` | Fills in the four required fields. Everything else is a defaulted struct field you set directly. |
| `run` | `runetea/tea.odin` | The event loop. A reader thread turns bytes into messages; the calling thread renders. |
| `run_nbio` | `runetea/loop_nbio.odin` | The same loop hosted on `core:nbio`, with no reader thread. |
| `Input_Source` | `runetea/loop.odin` | Where input comes from. `input_source_from_fd` for a terminal, `input_source_from_bytes` for a test. |

`program_init` takes only what every program must have. Everything optional is
a field with a zero value that means "do nothing", so a program written before
an option existed keeps compiling and keeps behaving identically:

<!-- doccheck: body -->
```odin
p: rt.Program(Model)
rt.program_init(&p, Model{}, update, view /*, init_cmd */)

p.render_mode = .Diff              // .Inline is the zero value
p.cursor      = nil                // optional per-frame Cursor callback
p.legacy      = {}                 // which side of each legacy C0 collision you want
```

| Field | Zero value | Meaning |
|---|---|---|
| `model` | — | your `T` |
| `update` | — | `proc(m: ^T, msg: any, alloc: mem.Allocator) -> Cmd` |
| `view` | — | `proc(m: T, alloc: mem.Allocator) -> string` |
| `init_cmd` | `Cmd{}` | fired once before the first input is read — the equivalent of Bubble Tea's `Init()`. The first frame is painted **before** it is dispatched, so an app whose first action is asynchronous still shows its loading state immediately. |
| `cursor` | `nil` | `proc(m: T, alloc: mem.Allocator) -> Cursor`, called once per frame right after `view`, under the same crash guard |
| `render_mode` | `.Inline` | see [§6](#6-drawing--render-modes-the-cursor-the-view-contract) |
| `legacy` | `{}` | `Legacy_Key_Encoding` — see [§2](#2-reacting-to-input--the-message-vocabulary) |
| `quit` | `false` | set by the loop when `Quit_Msg` arrives; you do not write it |

### `run` and `run_nbio`

Their signatures:

```
run      :: proc(p: ^Program($T), src: ^Input_Source, out: ^strings.Builder, flush_fd: posix.FD = -1) -> Run_Error
run_nbio :: proc(p: ^Program($T), fd: posix.FD,       out: ^strings.Builder, flush_fd: posix.FD = -1) -> Run_Error
```

`out` is where frames are built. `flush_fd` is where finished frames are
written: pass the tty and the display updates live; leave it at `-1` and the
whole session accumulates in `out` instead, which is what makes a program
testable with no terminal at all ([§10](#10-testing-your-own-application)).

| | `run` | `run_nbio` |
|---|---|---|
| input | `^Input_Source` (fd, byte slice, or your own) | a raw `posix.FD` — `nbio` needs a real OS handle |
| reader | a dedicated thread | the nbio read callback, on the calling thread |
| quit latency | bounded at 100 ms even with a Cmd still in flight | blocks on the slowest in-flight Cmd ([`LIMITATIONS.md`](LIMITATIONS.md) 2.6) |
| when to prefer it | the default | you already host an nbio event loop and want one loop, not two |

Both share the identical update/view/quit/panic logic — `apply` and
`guarded_render` in `runetea/tea.odin` are called by both, so the two hosts can
only differ in how a message *reaches* the loop, never in what happens once it
does.

### Ordering rules that are not optional

1. `install_crash_handlers()` **before** `term_enter_raw` — and once on every
   thread you spawn yourself, because `sigaltstack` is per-thread.
2. `defer term_restore()` immediately after a successful `term_enter_raw`.
3. If you start your own worker threads, start them **after** `run()` — the
   signal watcher's blocked mask is only inherited by threads created after it
   exists ([`LIMITATIONS.md`](LIMITATIONS.md) 1.5).

---

## 2. Reacting to input — the message vocabulary

`update` receives `any` and type-switches. The complete set of messages RuneTea
itself produces:

| Msg | Fields | Produced when | Needs an opt-in? |
|---|---|---|---|
| `Key_Msg` | `kind: Key_Kind`, `code: Key_Code`, `r: rune`, `mods: Modifiers`, `pasted: bool` | any keypress | no |
| `Mouse_Msg` | `kind: Mouse_Kind`, `button: Mouse_Button`, `x, y: int`, `mods: Modifiers` | mouse report; coordinates are **0-based cells** | `mouse` |
| `Window_Size_Msg` | `w, h: int` | `SIGWINCH`, with a fresh `ioctl` | no (needs `flush_fd >= 0`) |
| `Focus_Msg` / `Blur_Msg` | — | terminal window focus in/out | `focus` |
| `Paste_Start_Msg` / `Paste_End_Msg` | — | bracketed paste opens/closes | `paste` |
| `Keyboard_Enhancements_Msg` | `flags: Kitty_Flags` | the terminal answers the Kitty query | `kb` |
| `Panicked_Msg` | `message: Msg_Text` | a background Cmd panicked and was recovered | no |
| `Timer_Unavailable_Msg` | `reason: Msg_Text` | the timer subsystem could not start — **no `tick`/`every` on this session will ever fire** | no |
| `Quit_Msg` | — | you returned `quit_cmd()`. Handled by the loop; `update` never sees it. | no |

`Key_Code` is a collapsed vocabulary — `Rune, Enter, Escape, Backspace, Tab,
Space, Up, Down, Right, Left, Home, End, Page_Up, Page_Down, Insert, Delete,
F1…F12, Find, Select` — because Odin cannot express Bubble Tea's
match-by-method-set. `Modifiers` is `bit_set[Modifier]` over `Ctrl, Alt, Shift,
Meta`.

<!-- doccheck: decl input -->
```odin
Editor :: struct { line, col: int, focused: bool, in_paste: bool }

on_msg :: proc(m: ^Editor, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	switch v in msg {
	case rt.Key_Msg:
		// Under .Report_Event_Types every key arrives twice. Filter, or do
		// not enable that flag.
		if v.kind != .Press { break }
		#partial switch v.code {
		case .Rune:
			if v.r == 'c' && .Ctrl in v.mods { return rt.quit_cmd() }
			if v.pasted { /* this rune came from a paste, not a keystroke */ }
		case .Up:   m.line -= 1
		case .Down: m.line += 1
		}
	case rt.Mouse_Msg:
		if v.kind == .Press && v.button == .Left { m.line, m.col = v.y, v.x }
		if v.button == .Wheel_Up { m.line -= 3 }
	case rt.Focus_Msg:       m.focused = true
	case rt.Blur_Msg:        m.focused = false
	case rt.Paste_Start_Msg: m.in_paste = true
	case rt.Paste_End_Msg:   m.in_paste = false
	case rt.Keyboard_Enhancements_Msg:
		// No message at all means the terminal does not speak the protocol.
		if .Disambiguate in v.flags { /* Tab and Ctrl+I are distinct here */ }
	case rt.Timer_Unavailable_Msg:
		// Permanent. Degrade (a static frame instead of a spinner) or quit.
		return rt.quit_cmd()
	case rt.Panicked_Msg:
		// A Cmd blew up. The loop survived; you decide what that means.
	}
	return rt.cmd_nil()
}
```

**Legacy collisions.** Terminals collapse Ctrl+I onto Tab, Ctrl+M onto Enter and
Ctrl+`[` onto Escape. No decoder can separate them from the byte alone. Set
`p.legacy` to choose which side of each collision you want — or negotiate the
Kitty protocol, which removes the collisions entirely
([§8](#8-owning-the-terminal)).

Reading: `Key_Msg`, `Mouse_Msg` and `decode_keys` in `runetea/input.odin`;
[`LIMITATIONS.md`](LIMITATIONS.md) section 5 for the input gaps that are real
(the Linux console's F1–F5, urxvt's modified keys, `CSI R` vs F3).

---

## 3. Doing work off the loop — commands

| Symbol | File | What it is |
|---|---|---|
| `Cmd` | `runetea/cmd.odin` | a unit of off-loop work that returns one message |
| `cmd_from` | `runetea/cmd.odin` | build one from a named proc plus a heap-cloned env |
| `cmd_nil` / `cmd_is_nil` | `runetea/cmd.odin` | "no command" |
| `Cancel_Token` / `cancel_requested` | `runetea/cmd.odin` | cooperative cancellation |
| `batch` / `sequence` | `runetea/batch.odin` | run children concurrently / in order |
| `quit_cmd` | `runetea/tea.odin` | end the session |
| `Panicked_Msg` | `runetea/cmd.odin` | what a recovered Cmd panic delivers |

Odin has no closures, so the captured environment is explicit. `cmd_from`
heap-clones the `env` value you hand it, so the Cmd can outlive the frame that
created it; the runtime frees it after the body returns.

<!-- doccheck: decl cmd -->
```odin
Fetch_Env :: struct { host: [64]u8, len: int }   // POD: no `string` field
Fetch_Msg :: struct { status: int, err: rt.Msg_Text }

fetch :: proc(env: rawptr, cancel: ^rt.Cancel_Token) -> any {
	e := cast(^Fetch_Env)env
	host := string(e.host[:e.len])

	// Cancellation is POLLING, not preemption -- see below. Long work must
	// come back to this check by itself.
	for attempt in 0 ..< 5 {
		if rt.cancel_requested(cancel) { return nil }   // nil = deliver nothing
		_ = host
		_ = attempt
	}
	return rt.box(Fetch_Msg{status = 200}, context.allocator)
}

start_fetch :: proc(host: string) -> rt.Cmd {
	e: Fetch_Env
	e.len = copy(e.host[:], host)
	return rt.cmd_from(fetch, e, context.allocator)
}
```

Returning `nil` from a Cmd body delivers no message at all, which is the right
answer for a cancelled Cmd.

**Cancellation is cooperative polling and nothing else.** A `Cancel_Token`
cannot interrupt a Cmd blocked in a syscall it never returns from —
`net.dial_tcp` with no timeout, a child-process `wait()`, a read on a hung NFS
mount. Quit takes as long as your slowest blocking Cmd. Write Cmds as bounded
retry loops that poll the token between attempts; `examples/http`'s
`check_server` is a worked example. ([`LIMITATIONS.md`](LIMITATIONS.md) 2.5.)

**Composition.**

<!-- doccheck: decl cmd -->
```odin
concurrently :: proc() -> rt.Cmd {
	// Both start now; each result reaches update() the moment it is ready.
	return rt.batch([]rt.Cmd{start_fetch("a"), start_fetch("b")}, context.allocator)
}

in_order :: proc() -> rt.Cmd {
	// The second starts only after the first has finished.
	return rt.sequence([]rt.Cmd{start_fetch("a"), start_fetch("b")}, context.allocator)
}
```

A slice, not a variadic: Odin variadics must be the last parameter and the
allocator is explicit throughout this package. Note that a `tick`/`every` placed
inside a `sequence` **gates nothing** — the timer step signals "done"
immediately ([`LIMITATIONS.md`](LIMITATIONS.md) 2.11), and each composed Cmd
costs one OS thread at every nesting depth (2.10).

**`detached`.** `cmd_from(..., detached = true)` keeps a Cmd off the worker
pool. You need it only for a Cmd that itself dispatches and waits on other
Cmds: N such coordinators on an N-wide pool leaves no worker for their children
and deadlocks. `batch`/`sequence` already do this for you.

**A Cmd that panics** is recovered: the pool worker survives and your `update`
receives a `Panicked_Msg` carrying the text. What is *not* recovered is memory —
the recovery jump runs no `defer`s, so whatever that Cmd had allocated is
leaked ([`LIMITATIONS.md`](LIMITATIONS.md) 2.7).

---

## 4. Timers — "how do I make a spinner"

| Symbol | File | What it is |
|---|---|---|
| `tick` | `runetea/timer.odin` | fires **once** after a duration. Hands back no handle. |
| `tick_cancellable` | `runetea/timer.odin` | the same, plus a `Timer_Handle` you must stop exactly once |
| `every` | `runetea/timer.odin` | repeats on its own until stopped. Always hands back a handle. |
| `timer_stop` | `runetea/timer.odin` | cancel; safe on `nil`, safe after the timer already fired |
| `Timer_Fn` | `runetea/timer.odin` | `proc(env: rawptr, t: time.Tick) -> any` |
| `Timer_Unavailable_Msg` | `runetea/timer.odin` | the subsystem could not start; nothing will ever fire |

A spinner is a `tick` reissued from `update` on every fire — the same pattern
Bubble Tea's own spinner component uses:

<!-- doccheck: decl spin -->
```odin
FRAMES := []rune{'⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'}

Spinner  :: struct { frame: int }
Spin_Msg :: struct { t: time.Tick }   // POD: time.Tick is an i64

spin_fn :: proc(env: rawptr, t: time.Tick) -> any {
	return rt.box(Spin_Msg{t = t}, context.allocator)
}

spin_cmd :: proc() -> rt.Cmd {
	// No handle, nothing to release: tick()'s handle and cloned env are freed
	// by the subsystem the instant it fires. That is what makes reissuing it
	// ten times a second for the whole session allocation-neutral.
	return rt.tick(100 * time.Millisecond, spin_fn, struct{}{}, context.allocator)
}

spin_update :: proc(m: ^Spinner, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	if _, is_tick := msg.(Spin_Msg); is_tick {
		m.frame = (m.frame + 1) % len(FRAMES)
		return spin_cmd()          // reissue
	}
	return rt.cmd_nil()
}

spin_view :: proc(m: Spinner, alloc: mem.Allocator) -> string {
	return fmt.aprintf("%c working...", FRAMES[m.frame], allocator = alloc)
}
```

Pass `spin_cmd()` as `program_init`'s `init_cmd` and the animation starts before
any keypress.

**`every` is different, and so is its contract.** It auto-repeats without help
from `update` — a deliberate divergence from Go's `Every`, which is also
single-fire — and it hands back a `Timer_Handle` that you **must** pass to
`timer_stop` exactly once: never zero times (the handle and its cloned env are
stranded for the life of the process), never twice (a refcount decrement against
possibly-freed memory).

<!-- doccheck: decl spin -->
```odin
Poll :: struct { handle: ^rt.Timer_Handle }

start_polling :: proc(m: ^Poll) -> rt.Cmd {
	cmd, h := rt.every(1 * time.Second, spin_fn, struct{}{}, context.allocator)
	m.handle = h
	return cmd
}

stop_polling :: proc(m: ^Poll) {
	rt.timer_stop(m.handle)   // exactly once, even if it already fired
	m.handle = nil
}
```

`every` does not align to wall-clock multiples of its interval, and under a
stall it skips at most one interval rather than bursting catch-up fires — right
for animation, wrong for anything counting ticks
([`LIMITATIONS.md`](LIMITATIONS.md) 2.16).

---

## 5. Putting data in a message

| Symbol | File | What it is |
|---|---|---|
| `box` | `runetea/arena.odin` | put a value on the wire; **enforces** the POD rule |
| `is_pod_type` | `runetea/arena.odin` | ask whether a type is legal as a Msg |
| `Msg_Text` | `runetea/msg.odin` | a POD carrier for up to 255 bytes of text |
| `msg_text_from` / `msg_text_fmt` | `runetea/msg.odin` | build one |
| `msg_text_clone` | `runetea/msg.odin` | the **owning** accessor — use this to store the text |
| `msg_text_string` | `runetea/msg.odin` | the **borrowing** accessor — same-expression reads only |
| `msg_text_truncated` | `runetea/msg.odin` | did it fit? |

**Every Msg type must be POD**: no `string`, `cstring`, `^T`, `[]T`,
`[dynamic]T`, `map` or `any` anywhere in its field tree, recursively. `box`
checks this on every call and *panics* naming your type if it fails — a
`panic`, not an `assert`, so `-disable-assert` cannot strip it. The check is at
runtime, because Odin cannot fold a recursive type predicate into a
compile-time constant, so an illegal Msg compiles clean and fails the first time
that path executes. **Call `box` on every Msg type you define, once, in a test.**

<!-- doccheck: decl msg -->
```odin
// Legal: fixed-size, no indirection.
Progress_Msg :: struct { done, total: int }

// Legal: Msg_Text is a fixed 255-byte buffer plus a length and a flag.
Failed_Msg :: struct { code: int, reason: rt.Msg_Text }

// ILLEGAL: `detail: string` would make box() panic.
//   Bad_Msg :: struct { detail: string }

fail :: proc(code: int, host: string) -> any {
	return rt.box(Failed_Msg{
		code   = code,
		reason = rt.msg_text_fmt("dial %s: refused", host),
	}, context.allocator)
}

// Storing the text past the current statement requires the OWNING accessor:
// the Msg is freed by the loop moments after update() returns.
remember :: proc(m: Failed_Msg, alloc: mem.Allocator) -> string {
	m := m
	if rt.msg_text_truncated(m.reason) { /* 255 bytes was not the whole story */ }
	_ = rt.msg_text_string(&m.reason)          // borrows -- format with it, do not keep it
	return rt.msg_text_clone(m.reason, alloc)  // owns -- safe to store
}

// Do this in a test, once per Msg type you define.
check_pod :: proc() -> bool {
	return rt.is_pod_type(Progress_Msg) && rt.is_pod_type(Failed_Msg)
}
```

For a payload larger than 255 bytes: keep it in your own storage and send a
handle (an index, an ID). RuneTea has no handle type for you
([`LIMITATIONS.md`](LIMITATIONS.md) 2.1–2.3).

**Which allocator?** Anything headed for the mailbox — every Cmd result, every
message crossing a thread — must be boxed with `context.allocator` or another
allocator that outlives the frame. The frame arena `view` is handed is reclaimed
wholesale at the end of each frame; a message boxed from it would be freed out
from under the loop.

---

## 6. Drawing — render modes, the cursor, the view contract

| Symbol | File | What it is |
|---|---|---|
| `Render_Mode` | `runetea/render.odin` | `.Inline` (zero value), `.Full_Screen`, `.Diff` |
| `Cursor` | `runetea/render.odin` | `line`, `col`, `show` — where the caret goes |
| `view_diff_safe` | `runetea/contract.odin` | is this view legal under `.Diff`? |
| `Diff_Contract` | `runetea/contract.odin` | *why* it is not |
| `DIFF_STRICT` | `runetea/contract.odin` | `-define:RUNETEA_DIFF_STRICT=true\|false`; defaults to `ODIN_DEBUG` |

Choosing a mode is one assignment on the `Program`; see the
[README's table and byte counts](../README.md#render-modes) for which to pick.
The short version: `.Inline` leaves its output in the user's scrollback,
`.Full_Screen` owns the viewport, `.Diff` owns the viewport and costs **zero
bytes for an unchanged frame**.

**`.Diff` constrains what a view may contain.** It models exactly two escapes
per cell — SGR and OSC 8 hyperlinks. A tab, a carriage return, a cursor move, an
erase, a window-title OSC or a truncated escape renders correctly under
`.Full_Screen` and wrongly under `.Diff`. That is checkable, and you should
check it:

<!-- doccheck: decl draw -->
```odin
// Put this in your own tests, on your own views. Allocation-free.
view_is_diff_safe :: proc(v: string) -> bool {
	ok, at, why := rt.view_diff_safe(v)
	if !ok {
		// `why` is a Diff_Contract: .Control_Byte, .Truncated_Escape, ...
		fmt.eprintfln("view is not .Diff-safe at byte %d: %v", at, why)
	}
	return ok
}
```

Debug builds assert the same contract on every frame and panic naming the byte
offset. `\t` is the one that bites in practice — it is a *move* to the next tab
stop, whose position the cell model does not track. Expand tabs to spaces.

**Placing the cursor.** Optional, per frame, and a program that never sets one
emits not a single extra byte.

<!-- doccheck: decl draw -->
```odin
Prompt :: struct { typed: string }

prompt_view :: proc(m: Prompt, alloc: mem.Allocator) -> string {
	return fmt.aprintf("Enter a name:\n\n> %s\n", m.typed, allocator = alloc)
}

prompt_cursor :: proc(m: Prompt, alloc: mem.Allocator) -> rt.Cursor {
	// `line` indexes the view's "\n"-separated LOGICAL lines -- the renderer
	// converts that to a physical row itself, so a wrapped line above cannot
	// desynchronise it. `col` is a DISPLAY column: measure the prefix you
	// actually painted with display_width, because a byte index lands too far
	// right on CJK and a rune index too far left.
	prefix := fmt.aprintf("> %s", m.typed, allocator = alloc)
	return rt.Cursor{line = 2, col = rt.display_width(prefix), show = true}
}
```

Wire it with `p.cursor = prompt_cursor`. It runs immediately after `view`, from
the same model, with the same frame allocator, under the same crash guard.
Keeping it consistent with what `view` actually painted is your job; nothing can
check it.

Further reading: `render_inline`, `render_full_screen` and `render_diff` in
`runetea/render.odin`; [`LIMITATIONS.md`](LIMITATIONS.md) section 3 for the
whole list, including what an inline frame taller than the screen does (3.3),
truncation at the bottom (3.4), and style interning by byte spelling (3.6).

---

## 7. Handling a resize

`Window_Size_Msg{w, h}` arrives on `SIGWINCH`, carrying a **fresh `ioctl`
result**, not a cached one. The renderer applies it to itself before your
`update` sees it, so you only need to handle it if your own layout depends on
the size:

<!-- doccheck: decl resize -->
```odin
Layout :: struct { w, h: int }

on_resize :: proc(m: ^Layout, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	if ws, is_resize := msg.(rt.Window_Size_Msg); is_resize {
		m.w, m.h = ws.w, ws.h
	}
	return rt.cmd_nil()
}
```

Three things worth knowing:

- **A resize is not terminal to the loop.** Unlike `Quit_Msg`, it falls through
  to your `update` like any other message.
- **The first size does not arrive as a message.** `run()` seeds the renderer
  from `term_size(flush_fd)` before the first frame, but your *model* has not
  been told. If your layout needs the size, ask for it yourself in `main`:
  `if w, h, ok := rt.term_size(fd); ok { p.model.w, p.model.h = w, h }`.
  `examples/editor` does exactly this, and the reason matters: a program that is
  never resized would otherwise spend its whole life assuming an unknown size.
- **No `flush_fd`, no resize messages.** The signal watcher only starts when
  `flush_fd >= 0`. Under a test harness there is no terminal to resize.

---

## 8. Owning the terminal

| Symbol | File | What it is |
|---|---|---|
| `term_enter_raw` | `runetea/term.odin` | raw mode plus five independent opt-ins |
| `term_restore` | `runetea/term.odin` | undo exactly what was set, once |
| `term_size` | `runetea/term.odin` | `(w, h, ok)` from a live `ioctl` |
| `install_crash_handlers` | `runetea/guard.odin` | Tier-2 recovery: restore the terminal on a fatal signal |
| `Kitty_Flags`, `Mouse_Mode` | `runetea/term.odin` | the opt-in vocabularies |
| `signal_unblock_for_child` / `runetea_signal_set` | `runetea/signals.odin` | for `fork`/`exec` |

**`run()` does not own the terminal, deliberately.** The application enters raw
mode and leaves it, which is why the golden tests can drive `run()` over a plain
pipe and why nothing is written to a terminal that did not ask for it.

<!-- doccheck: body -->
```odin
fd := posix.FD(os.fd(os.stdin))

rt.install_crash_handlers()                       // FIRST -- see below
if !rt.term_enter_raw(fd, {.Disambiguate}, true, .Normal, false, true) {
	fmt.eprintln("not a tty")
	os.exit(1)
}
defer rt.term_restore()

src, ok := rt.input_source_from_fd(fd)
if !ok { os.exit(1) }
defer rt.input_close(&src)

if w, h, size_ok := rt.term_size(fd); size_ok { fmt.println(w, h) }
```

The parameters, all trailing and all defaulted to "touch nothing":

| Parameter | Default | Sequence | Gives you |
|---|---|---|---|
| `kb: Kitty_Flags` | `{}` | `CSI > n u` + `CSI ? u` | disambiguated keys, event types, alternate keys, all-keys-as-escapes, associated text |
| `paste: bool` | `false` | DECSET 2004 | `Paste_Start_Msg`/`Paste_End_Msg`, runes flagged `pasted` |
| `mouse: Mouse_Mode` | `.None` | DECSET 1000/1002/1003 + 1006 | `Mouse_Msg` |
| `focus: bool` | `false` | DECSET 1004 | `Focus_Msg`/`Blur_Msg` |
| `alt: bool` | `false` | DECSET 1049 | the alternate screen buffer |

`term_restore` writes the matching teardown for each, exactly once, and so does
the crash-signal path — whichever runs first. Nothing else in the package can
enter the alternate screen; `alt` is the only door.

**`install_crash_handlers` is per-thread and must come first.** It installs an
alternate signal stack, which only takes effect on the calling thread, so every
thread you spawn yourself must call it as its first action. And it must precede
`term_enter_raw`, because `term_enter_raw` arms its restore flag *before*
`tcsetattr` has touched the tty — a crash in that window is only recoverable if
a handler already exists. It covers `SIGSEGV SIGBUS SIGILL SIGFPE SIGABRT
SIGTRAP SIGHUP SIGQUIT SIGTERM`. Nothing can cover `SIGKILL` or `SIGSTOP`.

**Forking.** RuneTea's signal watcher blocks `SIGINT`/`SIGTERM`/`SIGWINCH`/
`SIGUSR2`, and `exec(2)` does *not* reset the blocked mask — a child spawned
without help is un-Ctrl-C-able. Call `signal_unblock_for_child()` between `fork`
and `exec` (it is async-signal-safe and does nothing else), or build your own
mask from `runetea_signal_set`. `SIGUSR2` is reserved package-wide.

---

## 9. How a session ends

`run`/`run_nbio` return a `Run_Error`, which is a union:

| Variant | Means | You must |
|---|---|---|
| `nil` | clean quit — `quit_cmd()`, or input reached EOF | — |
| `Interrupted_Error{}` | an external `SIGINT`/`SIGTERM` reached the watcher | — |
| `Terminal_Error{detail: string, errno: posix.Errno}` | init failed, or a frame could not be written | `detail` is a static string; `errno` distinguishes EIO from EBADF from EPIPE |
| `Panicked_Error{message: string}` | `update`, `view` or `cursor` panicked and was recovered | **`delete()` the message** — you own it |
| `Killed_Error{}` | *declared, but never produced in v1.0.* Nothing in the package constructs one. | — |

<!-- doccheck: body -->
```odin
p: rt.Program(Model)
rt.program_init(&p, Model{}, update, view)

b := strings.builder_make(); defer strings.builder_destroy(&b)
src := rt.input_source_from_bytes(transmute([]u8)string("q"))
defer rt.input_close(&src)

switch e in rt.run(&p, &src, &b) {
case rt.Panicked_Error:
	// The caller owns this string. Also: treat p.model as SUSPECT -- a panic
	// partway through update leaves it half-mutated. Do not persist it.
	fmt.eprintln("panicked:", e.message)
	delete(e.message)
case rt.Terminal_Error:
	fmt.eprintln("terminal:", e.detail, e.errno)
case rt.Interrupted_Error:
case rt.Killed_Error:
}
```

A `Ctrl+C` typed at the *terminal* is not this: raw mode clears `ISIG`, so it
arrives as a plain `0x03` byte in a `Key_Msg` and it is up to your `update` what
to do with it. `Interrupted_Error` is for a signal delivered from outside —
`kill -INT`, a supervisor, another shell.

---

## 10. Testing your own application

Because `run()` neither owns the terminal nor requires one, a whole session is
drivable from a byte slice with the frames accumulating in a builder. This is
how `examples/editor` is tested, and it is the reason its model/update/view live
in their own package.

<!-- doccheck: body -->
```odin
// Scripted keystrokes -- the same bytes a terminal would send.
script := "jjj \x03"          // three downs, a space, then Ctrl+C

src := rt.input_source_from_bytes(transmute([]u8)script)
defer rt.input_close(&src)

b := strings.builder_make(); defer strings.builder_destroy(&b)

p: rt.Program(Model)
rt.program_init(&p, Model{}, update, view)

// No flush_fd: every frame of the whole session lands in `b`, which is what a
// golden test compares against. It also means no signal watcher and no
// terminal-size query, so the output is a pure function of the script.
err := rt.run(&p, &src, &b)
_ = err
frames := strings.to_string(b)
_ = frames
```

`input_source_from_bytes` reports EOF once its slice is exhausted, and `run()`
treats EOF as input dying rather than as a clean quit — so end every script with
a real quit key if you want it to exit the way a real session does.

Two more things worth putting in your own tests:

- `rt.is_pod_type(Your_Msg)` for every Msg type you define
  ([§5](#5-putting-data-in-a-message)).
- `rt.view_diff_safe(your_view)` if you use `.Diff`
  ([§6](#6-drawing--render-modes-the-cursor-the-view-contract)).

---

## 11. Measuring text

| Symbol | File | What it is |
|---|---|---|
| `display_width` | `runetea/width.odin` | columns a string occupies, skipping escapes |
| `Width_Options` | `runetea/width.odin` | `ambiguous_is_wide` |
| `rows_for_line` | `runetea/width.odin` | physical rows one logical line wraps to |
| `is_ambiguous_width` | `runetea/width.odin` | is this rune East-Asian *Ambiguous*? |

`display_width` is the one measure that is correct for a terminal: it segments
by grapheme cluster, counts escape sequences as zero, and applies the VS16 /
regional-indicator / leading-mark corrections. Use it for cursor columns, for
alignment, for anything that has to line up.

<!-- doccheck: decl width -->
```odin
measure :: proc() {
	_ = rt.display_width("héllo")                                  // 5
	_ = rt.display_width("\e[1mbold\e[0m")                         // 4 -- escapes are free
	_ = rt.display_width("日本語")                                  // 6 -- wide runes
	_ = rt.display_width("│", rt.Width_Options{ambiguous_is_wide = true})  // 2, not 1
	_ = rt.rows_for_line("a long line", 4)                         // 3 rows at width 4
}
```

East-Asian *Ambiguous* width — box drawing, curly quotes, Greek, Cyrillic — has
no universally correct answer and the terminal does not report it. The default
is narrow, matching `core:unicode` and xterm. If your users are on CJK-locale
terminals, expose `Width_Options{ambiguous_is_wide = true}` (and RuneGloss's
`ambiguous_wide`) as a setting; RuneTea cannot detect it for you
([`LIMITATIONS.md`](LIMITATIONS.md) 4.2).

Unicode data is pinned to UCD 15.1.0, which is `core:unicode`'s choice, not
RuneTea's (4.1).

---

## 12. RuneGloss

`import rg "../../runegloss"`. A `Style` is a **plain value type** — no strings,
no pointers, no slices — so you can store one in your model and copy it freely.
Build styles once, in `main`, and keep them in the model; that also means the
environment is sniffed once rather than per frame.

| Group | Symbols |
|---|---|
| construct | `new_style`, `new_style_profile`, `profile` |
| colour | `color` (`color_hex`, `color_ansi`), `Color`, `Profile`, `detect_profile`, `detect_profile_env`, `default_profile`, `set_default_profile`, `clear_default_profile`, `convert` |
| attributes | `bold`, `faint`, `italic`, `underline`, `blink`, `reverse`, `strikethrough`, `attr`, `Attr`, `Attrs` |
| box model | `padding`, `margin` (1/2/4-value arities), `width`, `height`, `align`, `valign`, `Align_H`, `Align_V`, `Sides`, `ALL_SIDES` |
| borders | `border`, `border_sides`, `border_fg`, `border_bg`, `Border`, `border_cell`, `NORMAL`, `ROUNDED`, `THICK`, `DOUBLE`, `HIDDEN` |
| width | `ambiguous_wide` |
| render | `render(s: ^Style, text: string, alloc: mem.Allocator) -> string` |

<!-- doccheck: decl gloss -->
```odin
Theme :: struct { title, body, warn: rg.Style }

// Built once. rg.Style is POD, so a Theme can live in your Model.
make_theme :: proc(p: rg.Profile) -> Theme {
	t: Theme

	t.title = rg.new_style_profile(p)   // stated, not detected -- see below
	rg.fg(&t.title, rg.color("#FAFAFA"))
	rg.bg(&t.title, rg.color("#7D56F4"))
	rg.bold(&t.title, true)
	rg.padding(&t.title, 0, 2)
	rg.align(&t.title, .Center)
	rg.width(&t.title, 40)

	t.body = rg.new_style_profile(p)
	rg.border(&t.body, rg.ROUNDED)
	rg.border_fg(&t.body, rg.color(240))
	rg.border_sides(&t.body, rg.ALL_SIDES)
	rg.padding(&t.body, 1, 2)

	t.warn = rg.new_style_profile(p)
	rg.fg(&t.warn, rg.color("#FF5F5F"))
	rg.italic(&t.warn, true)

	return t
}

theme_view :: proc(t: Theme, alloc: mem.Allocator) -> string {
	// LOCAL COPIES: rg.render takes ^Style, and Odin procedure parameters are
	// not addressable. Two struct copies, no allocation.
	title, body := t.title, t.body
	return fmt.aprintf("%s\n%s\n",
		rg.render(&title, "RuneGloss", alloc),
		rg.render(&body,  "Everything here is allocated from `alloc`.", alloc),
		allocator = alloc)
}
```

**`new_style()` versus `new_style_profile(p)`.** `new_style` takes a copy of the
process-wide detected profile (`$NO_COLOR`, `$TERM`, `$COLORTERM`, sniffed once
and cached). `new_style_profile` states it outright — which is what every test in
this repository uses, because a styling test that reads `$TERM` is a test that
passes on the author's terminal and fails in CI. A `Style` carries its profile as
a copy, so a `render` is a pure function of (Style, text) and nothing can change
under it later.

**Degradation is silent and total by design.** Under `.None` — `$NO_COLOR`, a
dumb terminal — `render` returns its input byte for byte, with no `if` anywhere
in your view. 24-bit colours down-convert to the 256-colour cube or the 16 ANSI
colours as the profile requires.

**A malformed colour is "no colour", not an error.** `rg.color("#7D56F")` styles
nothing, silently — there is no error channel that would not poison every call
site ([`LIMITATIONS.md`](LIMITATIONS.md) 7.5).

**What RuneGloss does not have:** wrapping, truncation, `JoinHorizontal`,
`JoinVertical`, `table`, `tree`, `list`, fluent chaining, and clamping `width`
(it is a floor — content wider than it widens the block). See
[`LIMITATIONS.md`](LIMITATIONS.md) section 7 in full before assuming Lipgloss
parity.

---

## 13. Symbol index

Everything a normal application touches, and where it lives. (`odin doc runetea`
lists the rest — internals that are visible because Odin has no sub-package
privacy, not because they are API.)

### `runetea`

| Symbol | File |
|---|---|
| `Program($T)`, `program_init` | `tea.odin` |
| `run`, `run_nbio` | `tea.odin`, `loop_nbio.odin` |
| `Run_Error`, `Interrupted_Error`, `Panicked_Error`, `Terminal_Error`, `Killed_Error` | `tea.odin` |
| `Quit_Msg`, `quit_cmd` | `tea.odin` |
| `Input_Source`, `input_source_from_fd`, `input_source_from_bytes`, `input_close`, `input_wake` | `loop.odin` |
| `Cmd`, `cmd_from`, `cmd_nil`, `cmd_is_nil` | `cmd.odin` |
| `Cancel_Token`, `cancel_requested` | `cmd.odin` |
| `batch`, `sequence` | `batch.odin` |
| `Panicked_Msg` | `cmd.odin` |
| `tick`, `tick_cancellable`, `every`, `timer_stop`, `Timer_Fn`, `Timer_Handle`, `Timer_Unavailable_Msg` | `timer.odin` |
| `Key_Msg`, `Key_Code`, `Key_Kind`, `Modifier`, `Modifiers`, `Legacy_Key`, `Legacy_Key_Encoding` | `input.odin` |
| `Mouse_Msg`, `Mouse_Kind`, `Mouse_Button` | `input.odin` |
| `Paste_Start_Msg`, `Paste_End_Msg`, `Focus_Msg`, `Blur_Msg`, `Keyboard_Enhancements_Msg` | `input.odin` |
| `Window_Size_Msg` | `signals.odin` |
| `box`, `box_free`, `is_pod_type` | `arena.odin` |
| `Msg_Text`, `msg_text_from`, `msg_text_fmt`, `msg_text_clone`, `msg_text_string`, `msg_text_truncated`, `MSG_TEXT_CAP` | `msg.odin` |
| `Render_Mode`, `Cursor` | `render.odin` |
| `view_diff_safe`, `Diff_Contract`, `DIFF_STRICT` | `contract.odin` |
| `display_width`, `Width_Options`, `rows_for_line`, `is_ambiguous_width` | `width.odin` |
| `term_enter_raw`, `term_restore`, `term_size`, `Kitty_Flag`, `Kitty_Flags`, `Mouse_Mode` | `term.odin` |
| `install_crash_handlers`, `guarded`, `Panic_Info` | `guard.odin` |
| `signal_unblock_for_child`, `runetea_signal_set` | `signals.odin` |

### `runegloss`

| Symbol | File |
|---|---|
| `Style`, `new_style`, `new_style_profile`, `profile` | `style.odin` |
| `fg`, `bg`, `bold`, `faint`, `italic`, `underline`, `blink`, `reverse`, `strikethrough`, `attr`, `Attr`, `Attrs` | `style.odin` |
| `padding`, `margin`, `width`, `height`, `align`, `valign`, `Align_H`, `Align_V`, `Side`, `Sides`, `ALL_SIDES` | `style.odin` |
| `border`, `border_sides`, `border_fg`, `border_bg`, `ambiguous_wide` | `style.odin` |
| `Border`, `Border_Cell`, `border_cell`, `cell_str`, `NORMAL`, `ROUNDED`, `THICK`, `DOUBLE`, `HIDDEN`, `BORDER_CELL_CAP` | `border.odin` |
| `Color`, `Color_Kind`, `color`, `color_hex`, `color_ansi`, `convert` | `color.odin` |
| `Profile`, `detect_profile`, `detect_profile_env`, `default_profile`, `set_default_profile`, `clear_default_profile` | `color.odin` |
| `render` | `render.odin` |
