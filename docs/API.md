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
| `reaper_pending` | `false` | set by `run()` on the way out; you read it. `true` means `run()` gave up waiting for an in-flight Cmd past its 100 ms grace and returned anyway, leaving a detached thread still freeing allocations made through *your* `context.allocator` — which must therefore outlive the slowest Cmd. `run_nbio` never sets it. |

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

Both share the identical update/view/quit/panic logic — `apply_msg` and
`guarded_render` in `runetea/tea.odin` are called by both, so the two hosts can
only differ in how a message *reaches* the loop, never in what happens once it
does.

**One frame per batch, not per message.** Both hosts apply every message that is
already queued, in arrival order, and then paint once. Every message still
reaches `update` and every `Cmd` is still dispatched the instant its message is
applied; what changed is only how many frames come out the other end. A single
keystroke still costs exactly one frame at unchanged latency; a paste costs one
frame instead of one per character. The two hosts coalesce to slightly different
degrees, and that is inherent rather than a bug: `run()`'s reader is a separate
thread feeding a 256-slot mailbox, so a burst longer than that is necessarily
split across batches, while `run_nbio` decodes a whole read on the loop thread
and applies it in one. `run_nbio` also applies a keystroke that arrives while
Cmd results are queued *before* those results; `run()` keeps mailbox arrival
order. Order *within* the input stream — `Paste_Start_Msg` before the first
pasted rune, `Mouse_Msg` before what was typed after the click — is identical in
both.

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
| `Panicked_Msg` | `message: Msg_Text` | a background Cmd panicked and was recovered — **or the framework refused something**: a `Cmd` dispatched twice, a Cmd whose thread could not start | no |
| `Timer_Unavailable_Msg` | `reason: Msg_Text` | the timer subsystem could not start — **no `tick`/`every` on this session will ever fire** | no |
| `Quit_Msg` | — | you returned `quit_cmd()`. Handled by the loop; `update` never sees it. | no |
| `Interrupt_Msg` | — | an external `SIGINT`/`SIGTERM` reached the signal watcher. Handled by the loop; **`update` never sees it** — it becomes `run()`'s `Interrupted_Error` return. | no |

Both of the last two rows are worth reading twice, because the types are
exported and a `case rt.Quit_Msg:` or `case rt.Interrupt_Msg:` in your `update`
compiles with no warning and is **unreachable**. `Interrupt_Msg` is exported
because it is the message type of the standalone watcher API
(`signal_watcher_start` + `mailbox_recv`, which `tools/rawcheck` uses), not
because `update` can receive one. **There is no in-loop hook for a signal**: you
cannot save state from `update` on `SIGTERM`. What you get is
`Interrupted_Error` after `run()` has already returned, with the model in
whatever state its last real message left it ([§9](#9-how-a-session-ends);
[`LIMITATIONS.md`](LIMITATIONS.md) 6.11).

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
[`LIMITATIONS.md`](LIMITATIONS.md) section 5 for the input gaps that are real.
The Linux console's F1–F5 and urxvt's `$`/`^`-final modified keys used to be
listed there and are now decoded (5.5); what is left is the `CSI R` vs F3
collision (5.11), modifier bits above bit 8 (5.7), and multi-codepoint Kitty
associated text (5.8).

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

**A `Cmd` value is SINGLE-USE.** `Cmd` is a copyable POD struct, so nothing stops
you storing one in your model and returning it again — and if you do, the second
dispatch is **refused**. Nothing runs, nothing is freed twice, and your `update`
receives a `Panicked_Msg` reading

    dispatch(): this cmd_from Cmd was already dispatched and was NOT run again --
    a Cmd value is SINGLE-USE; build a fresh one instead of storing and returning
    the same one twice

naming the kind (`cmd_from`, `tick()/every()`, `batch()/sequence()`). Build a
fresh Cmd each time; the constructors are cheap and that is the intended
pattern — `spin_cmd()` in [§4](#4-timers--how-do-i-make-a-spinner) is called once
per fire, forever. `cmd_nil()` and `quit_cmd()` are the two exceptions and stay
reusable, because they own nothing. One honest residual: the refusal report
travels through the mailbox, so a re-dispatch after the mailbox has closed is
dropped. That is teardown only — "fails loudly" means "fails loudly while the
loop is running".

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
leaked ([`LIMITATIONS.md`](LIMITATIONS.md) 2.7). Note that `Panicked_Msg` no
longer means "a user Cmd panicked" and nothing else: the framework raises it too,
for a refused re-dispatch and for a Cmd whose OS thread could not be started. Do
not parse its text for a cause; read it.

**Do not hand `update`'s own `alloc` to `cmd_from`/`batch`/`tick`.** That
allocator is the frame arena, reclaimed at the end of the frame, and the Cmd env
outlives the frame by definition. Use `context.allocator`, as every sample here
does.

`cmd_from`, `tick`, `tick_cancellable` and `every` **refuse** it rather than
corrupting: the frame allocator is a value this package constructed and handed to
you, so it is recognisable by two pointer comparisons, and passing it back panics
at your call site with the constructor name and file:line. That panic happens
inside `update`, which runs under the crash guard, so the session ends with
`Panicked_Error` and exit status 1 — where it used to exit **0** having read a
zeroed env. The check is always on, in every optimisation level.

`batch` and `sequence` do **not** have it yet, and their silent failure is the
worse one — measured at 0 of 10 runs executing either child, with one SIGSEGV in
ten ([`LIMITATIONS.md`](LIMITATIONS.md) 2.20). Until that lands, `batch`'s
allocator argument is the one you have to get right by reading.

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

**Reading a `Msg_Text` out of a type switch needs one extra line.** `msg_text_string`
takes `^Msg_Text`, and a `switch v in msg` binding is **not addressable** in
Odin, so the obvious spelling does not compile:

```
case rt.Panicked_Msg:
    rt.msg_text_string(&v.message)
    // Error: Cannot take the pointer address of 'v.message'
```

Copy it to a local first. This is the shape every example in this repository
should be read as using, and the reason the empty `case rt.Panicked_Msg:` bodies
elsewhere in this document never have to confront it:

<!-- doccheck: decl msg -->
```odin
report :: proc(msg: any) {
	switch v in msg {
	case rt.Panicked_Msg:
		mt := v.message                                  // one copy, 257 bytes
		fmt.eprintfln("cmd panicked: %s", rt.msg_text_string(&mt))
	}
}
```

The rule is about `switch v in` specifically — `if pm, ok := msg.(rt.Panicked_Msg); ok`
binds an addressable local, and `&pm.message` compiles there. The same one-line
copy unblocks **any** fixed-array field of any Msg, not just `Msg_Text`; see
[§6](#6-drawing--render-modes-the-cursor-the-view-contract) for the same
restriction biting `view`.

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
| `view_render_safe` | `runetea/contract.odin` | the same question for `.Inline`/`.Full_Screen` — identical except that `\t` is legal |
| `Diff_Contract` | `runetea/contract.odin` | *why* it is not (returned by both) |
| `VIEW_STRICT` | `runetea/contract.odin` | `-define:RUNETEA_VIEW_STRICT=true\|false`; defaults to **"this is not an optimised build"** |
| `DIFF_STRICT` | `runetea/contract.odin` | `-define:RUNETEA_DIFF_STRICT=true\|false`; defaults to `VIEW_STRICT` |
| `request_repaint` | `runetea/render.odin` | "something else painted over us" — the next frame repaints from scratch |

Choosing a mode is one assignment on the `Program`; see the
[README's table and byte counts](../README.md#the-diff-renderer) for which to pick.
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

**Every build that is not optimised asserts the same contract on every frame**
and panics naming the byte offset — `odin build .`, `odin build . -debug` and
`odin test` all do; `-o:speed` and `-o:aggressive` compile the check out. The
default used to be `ODIN_DEBUG`, which meant a plain `odin build .` shipped with
the check *off*, so the one thing it exists to catch reached a real terminal
unannounced.

`.Inline` and `.Full_Screen` are checked too, one tier weaker: `view_render_safe`
permits `\t` (neither mode has a cell model to lie to) and still rejects cursor
motion, because both modes **count the physical rows they painted**, and a view
that moves the cursor itself makes that count a lie — under `.Inline` the frame
then erases the wrong rows, every frame, forever.

`\t` is the one that bites under `.Diff` — it is a *move* to the next tab stop,
whose position the cell model does not track. Expand tabs to spaces.

**When something else paints over you, say so.** `.Diff` writes only the cells its
model says changed, so anything that writes to the terminal behind its back stays
on screen *for the rest of the session* — the model has no reason to touch those
cells again. Call `rt.request_repaint()` after you shell out to `$EDITOR`, a
pager, `git`, anything that draws; the next frame then repaints from scratch
instead of diffing against a screen that is no longer there. It is a single atomic
store, idempotent, and consumed by the following frame, so calling it when nothing
happened costs one full repaint and nothing else. It is not only a cell-model
reset: `.Inline` honours it by skipping its rewind, so it does not erase rows the
interloper now owns, and all three modes re-hide the caret, because whatever
showed it (a `term_restore` on the way into a stop, the pager you just left) is
exactly the thing this call is about. The
framework calls it for you on `SIGTSTP`/`SIGCONT`, which is the case that made it
necessary ([`LIMITATIONS.md`](LIMITATIONS.md) 6.1a).

**Placing the cursor.** Optional, per frame. Under `.Inline` a frame that
declares no cursor and rewinds nothing emits not a single extra byte. Under
`.Full_Screen` and `.Diff` it is different, and deliberately so: **the mode that
owns the viewport hides the hardware caret and leaves it hidden**, showing it
again only on a frame that declares `Cursor{show = true}`. A cursor-less
full-screen program therefore pays exactly one `\e[?25l` on its first frame; the
matching `\e[?25h` comes from `term_restore` on every exit path, signals
included. Before this, a `.Diff` program with no cursor left the caret parked on
top of whatever cell the last write landed on, blinking over the content, every
frame. An identical `.Diff` frame still costs **zero bytes**: the caret is
already where it needs to be, so nothing is written.

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

### Two things about `view` that will cost you an afternoon

**1. `alloc` is a parameter, and Odin's allocator arguments are trailing
defaults.** `view` is handed a frame arena, and everything it allocates from that
arena is reclaimed wholesale when the frame ends. But `fmt.aprintf`,
`strings.builder_make` and `rg.render` all take their allocator as an argument
with a default that falls back to `context.allocator`. Omit it —

```
b := strings.builder_make()                    // WRONG: context.allocator
b := strings.builder_make(alloc)               // right

fmt.aprintf("%d", n)                           // WRONG: context.allocator
fmt.aprintf("%d", n, allocator = alloc)        // right
```

— and the view string is heap-allocated and **never freed by anyone**. The loop
resets the arena; it does not free what was never in it. The program compiles,
renders identically, and leaks one view per frame for the life of the process.
Nothing at the boundary can detect it, because a correct view and a leaking view
have the same type. What you get is a warning, not a failure: `odin test` on a
package with any test that drives `run()` prints `+++ leak` lines for it and
**the test still passes**. Thread `alloc` into every allocating call in `view`,
`cursor`, and anything they call. `strings.to_string(b)` on a builder made from
`alloc` needs no further thought; a `strings.clone` does.

**2. `view` and `cursor` take the model BY VALUE, and Odin procedure parameters
are not addressable.** That makes two natural things illegal inside a view:

```
rg.render(&m.title, ...)             // Error: cannot take the pointer address
string(m.items[i].name[:m.items[i].n])
    // Error: Cannot slice array 'm.items[i].name[...]', value is not addressable
```

The first is gone — `rg.render` is a proc group and `rg.render(m.title, ...)`
compiles. The second is not, and it lands on the first widget anybody writes,
because fixed-capacity arrays are exactly what the POD/no-GC rules push you
toward. **The fix is one local copy, and where you put it matters:**

<!-- doccheck: decl draw -->
```odin
Row  :: struct { name: [32]u8, n: int }
List :: struct { rows: [64]Row, count: int }

list_view :: proc(m: List, alloc: mem.Allocator) -> string {
	mm := m                             // ONE copy, addressable, lives for the body
	b := strings.builder_make(alloc)
	for i in 0 ..< mm.count {
		strings.write_string(&b, string(mm.rows[i].name[:mm.rows[i].n]))
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)          // the builder's bytes, not mm's
}
```

**Do not return a slice of the local.** `mm := m; return string(mm.rows[0].name[:n])`
compiles and is a use-after-return: measured, it comes back as
`"\x00\x00\x00\x00\x00"`. The local is only good for the body — write through
it into something allocated from `alloc`, which is what the builder above does.
The copy is the whole model, so for a model measured in kilobytes, hoist it out
of the loop (as above) rather than copying per access. If that is too expensive,
the shape to reach for is a smaller `T` holding a pointer to storage you own —
which is legal for the *model*, unlike a `Msg`.

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
		// GUARD EACH AXIS. {0, 0} is signals.odin's "the ioctl failed"
		// sentinel and it reaches update() unfiltered -- a bare
		// `m.w, m.h = ws.w, ws.h` throws away a known-good size and leaves
		// your layout computing against zero columns.
		if ws.w > 0 { m.w = ws.w }
		if ws.h > 0 { m.h = ws.h }
	}
	return rt.cmd_nil()
}
```

**`Window_Size_Msg{0, 0}` is a sentinel, not a size.** `SIGWINCH` fires, the
watcher re-runs `TIOCGWINSZ`, and if that fails — or answers with a zero column
or row count — it sends `{0, 0}` rather than nothing, so an application can tell
"the size is unknown now" from "no resize happened". The framework defends
*itself* against it (`run()` guards each axis before touching the renderer) and
then passes the raw message through, because suppressing it would hide the event
entirely. **Zero on either axis means "unknown" everywhere in this library** —
the renderer reads an unknown height as "do not truncate", and 0 is what your
model starts at before the first `term_size`. Treat it the same way: a
`m.w == 0` branch that says "I do not know yet" is a real state your view must
handle, not a defensive nicety ([`LIMITATIONS.md`](LIMITATIONS.md) 3.16).

Three more things worth knowing:

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

**Under `.Inline`, your minimum height is the rows you paint PLUS ONE.**
`.Inline` terminates every line of the frame with `\r\n`, the last one
included, because the next frame's rewind counts `\e[1A\e[2K` pairs upward from
column 1 of the row *below* the frame — so a three-row view in a three-row
terminal scrolls its top row into scrollback, where no rewind can ever reach it
again. This is easy to get wrong by exactly one and nothing warns: all four
single-file examples shipped a minimum-size guard that was one short, and the
quickstart's cost it the question it exists to ask. Write the constant as an
expression over the view, not a number:

<!-- doccheck: decl minrows -->
```odin
CHOICES := [?]string{"carrots", "celery", "kohlrabi"}

// one question, one blank, one per choice, one blank, one hint -- and one more
// for the row .Inline's line terminator lands on.
MIN_ROWS :: 5 + len(CHOICES)
```

Below the minimum, paint **one** row (`"need %d rows, have %d"`), which is all
that can be relied on. At exactly one terminal row `.Inline` can show nothing at
all, including that message — see
[`LIMITATIONS.md`](LIMITATIONS.md) 3.20 for the measurement and for what an
application can usefully do instead (stop animating). `.Full_Screen` and `.Diff`
are immune: they address every row absolutely and truncate at the bottom.

---

## 8. Owning the terminal

| Symbol | File | What it is |
|---|---|---|
| `term_enter_raw` | `runetea/term.odin` | raw mode plus five independent opt-ins |
| `Term_Opts` | `runetea/term.odin` | the six, as one struct. Zero value means "touch nothing". |
| `term_restore` | `runetea/term.odin` | undo exactly what was set, once |
| `term_size` | `runetea/term.odin` | `(w, h, ok)` from a live `ioctl` |
| `term_supports_escapes` | `runetea/term.odin` | false for `TERM=dumb`, empty or unset. `term_enter_raw` and the renderer already gate themselves on it; ask when *you* want to degrade something |
| `install_crash_handlers` | `runetea/guard.odin` | Tier-2 recovery: restore the terminal on a fatal signal, and on Ctrl+Z |
| `install_stop_handlers` | `runetea/guard.odin` | just the `SIGTSTP`/`SIGCONT` pair, for an app that re-installs its own handlers |
| `Kitty_Flags`, `Mouse_Mode` | `runetea/term.odin` | the opt-in vocabularies |
| `signal_unblock_for_child` / `runetea_signal_set` | `runetea/signals.odin` | for `fork`/`exec` |

**`run()` does not own the terminal, deliberately.** The application enters raw
mode and leaves it, which is why the golden tests can drive `run()` over a plain
pipe and why nothing is written to a terminal that did not ask for it.

<!-- doccheck: body -->
```odin
fd := posix.FD(os.fd(os.stdin))

rt.install_crash_handlers()                       // FIRST -- see below
if !rt.term_enter_raw(fd, {kb = {.Disambiguate}, paste = true, mouse = .Normal, alt = true}) {
	fmt.eprintln("not a tty")
	os.exit(1)
}
defer rt.term_restore()

src, ok := rt.input_source_from_fd(fd)
// term_restore FIRST. This exit is AFTER the `defer` above, and os.exit runs
// no defers -- so the bare `os.exit(1)` this used to be left the terminal raw,
// on the alternate screen, with the mouse and bracketed paste still on and one
// entry pushed on the Kitty keyboard stack. Six enables written, zero disables.
if !ok { rt.term_restore(); fmt.eprintln("bad input source"); os.exit(1) }
defer rt.input_close(&src)

if w, h, size_ok := rt.term_size(fd); size_ok { fmt.println(w, h) }
```

The six opt-ins are **fields of one `Term_Opts` struct**, each with a zero value
meaning "touch nothing", so `term_enter_raw(fd)` writes no escape at all:

| Field | Default | Sequence | Gives you |
|---|---|---|---|
| `kb: Kitty_Flags` | `{}` | `CSI > n u` + `CSI ? u` | disambiguated keys, event types, alternate keys, all-keys-as-escapes, associated text |
| `paste: bool` | `false` | DECSET 2004 | `Paste_Start_Msg`/`Paste_End_Msg`, runes flagged `pasted` |
| `mouse: Mouse_Mode` | `.None` | DECSET 1000/1002/1003 + 1006 | `Mouse_Msg` |
| `focus: bool` | `false` | DECSET 1004 | `Focus_Msg`/`Blur_Msg` |
| `alt: bool` | `false` | DECSET 1049 | the alternate screen buffer |
| `cursor_hide: bool` | `false` | DECSET 25 (`CSI ? 25 l`) | the hardware caret hidden for the whole session |

They were five trailing positional parameters until this cycle, three of them
bare `bool`s — so `term_enter_raw(fd, {}, false, .None, true)` asked for *focus*
when it meant *alt*, and compiled. Migration is mechanical:
`term_enter_raw(fd, K, P, M, F, A)` becomes
`term_enter_raw(fd, {kb = K, paste = P, mouse = M, focus = F, alt = A})`, dropping
any field that was already its default.

`term_restore` writes the matching teardown for each, exactly once, and so does
the crash-signal path — whichever runs first. Nothing else in the package can
enter the alternate screen; `alt` is the only door.

**`cursor_hide` is the newest of the six, and it exists because doing it by hand
strands the user's shell.** `.Full_Screen` and `.Diff` hide the caret themselves
(§6), but `.Inline` does not and must not, and `Cursor{show = false}` is the zero
value — it reads as "no opinion", not "hide it". So an inline program that just
did not want a blinking block in its output wrote `"\e[?25l"` itself and got no
`\e[?25h` back from anything: measured on a pty as exit 0, one hide, zero shows,
and a shell whose caret is gone until the user blind-types `reset`. Declaring it
here instead means this package writes **both** halves, on every exit path
including the crash handlers, and — because `Term_Opts` is what the `SIGCONT`
handler replays — it also survives a `Ctrl+Z`/`fg`, which an application's own
write does not. A frame that declares `Cursor{show = true}` still wins over it for
that frame; the field is the session's default, not a veto.

**Every opt-in is gated on `term_supports_escapes()`.** Under `TERM=dumb`, an
empty `TERM` or no `TERM` at all, raw mode is still granted — it is line
discipline, and the program still runs — but **not one escape sequence goes out**,
and because the guard flags stay false the paired teardown stays silent too.

**So is the renderer**, and this paragraph used to say otherwise: it told you to
call `term_supports_escapes()` yourself and pick `.Inline`, which was the right
advice for one release cycle and is now redundant. `run()`/`run_nbio()` re-read
the predicate once per frame, and when it says no, **all three render modes fall
back to a plain writer** that emits no CUP, no `\e[H`/`\e[2J`/`\e[K`, no SGR and
no DECTCEM, and that strips your own view's escapes on the way out (RuneGloss
drops colour at a `.None` profile but still emits *attributes*, and nobody
downstream of this would remove them). You do not have to degrade anything by
hand. The predicate stays public because there are choices only you can make —
skipping a spinner, dropping a border, shortening a frame — and because
`term_enter_raw` returns **true** under `TERM=dumb` (line discipline succeeded),
so it is `term_supports_escapes()`, not the return of `term_enter_raw`, that
answers "can this terminal read escapes at all"
([`LIMITATIONS.md`](LIMITATIONS.md) 5.15).

**Calling `term_enter_raw` twice.** On the *same* fd it is idempotent: raw mode is
re-applied, opt-ins already on are not re-sent, and the saved cooked termios is
the one from the first call — so `term_restore` still restores a cooked terminal
rather than a raw one. On a *different* fd while a terminal is held it returns
**false** rather than silently stranding the first. Release-then-acquire
(`term_restore`, then `term_enter_raw` on any fd) works as it always did.

**`install_crash_handlers` is per-thread and must come first.** It installs an
alternate signal stack, which only takes effect on the calling thread, so every
thread you spawn yourself must call it as its first action. And it must precede
`term_enter_raw`, because `term_enter_raw` arms its restore flag *before*
`tcsetattr` has touched the tty — a crash in that window is only recoverable if
a handler already exists. It covers eleven signals — `SIGSEGV SIGBUS SIGILL
SIGFPE SIGABRT SIGTRAP SIGHUP SIGQUIT SIGTERM SIGINT SIGPIPE` — plus the job
control pair `SIGTSTP`/`SIGCONT`, so **Ctrl+Z hands the terminal back cooked and
`fg` takes it again** with your opt-ins re-applied, a `Window_Size_Msg` kicked out
in case the window changed while you were stopped, and a `request_repaint` so the
first frame after the resume repaints rather than diffing against whatever your
shell printed over it (§6). `SIGINT` is inert while
`run()`'s signal watcher holds it, and matters for an app that uses
`term_enter_raw` + `decode_keys` without `run()`. Nothing can cover `SIGKILL` or
`SIGSTOP` ([`LIMITATIONS.md`](LIMITATIONS.md) 6.1).

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

**`run()` never calls `os.exit`, and falling off `main` after an error exits 0.**
A library must not terminate its caller's process, so the exit status is yours to
set — and `rt.exit_code(err)` is the one-call mapping so you do not write the
switch and get it wrong: `nil` → 0, `Interrupted_Error` → **130** (128 + SIGINT,
the shell convention; deliberately not 1, because an external signal is a request
and a supervisor that restarts on 1 should not restart on this), everything else
→ 1.

**Restore the terminal before you print.** `os.exit` runs no `defer`s, so
`defer rt.term_restore()` never fires on an exiting path; and if the program was
on the alternate screen, a diagnostic printed *before* the restore is written
into the alt buffer and then thrown away by the `\e[?1049l` that follows it. The
order is: restore, print, exit.

<!-- doccheck: body -->
```odin
p: rt.Program(Model)
rt.program_init(&p, Model{}, update, view)

b := strings.builder_make(); defer strings.builder_destroy(&b)
src := rt.input_source_from_bytes(transmute([]u8)string("q"))
defer rt.input_close(&src)

err := rt.run(&p, &src, &b)

switch e in err {
case rt.Panicked_Error:
	// The caller owns this string. Also: treat p.model as SUSPECT -- a panic
	// partway through update leaves it half-mutated. Do not persist it.
	rt.term_restore()
	fmt.eprintln("panicked:", e.message)
	delete(e.message)
case rt.Terminal_Error:
	rt.term_restore()
	fmt.eprintln("terminal:", e.detail, e.errno)
case rt.Interrupted_Error:
case rt.Killed_Error:
}
if err != nil { os.exit(rt.exit_code(err)) }
```

All five examples end exactly this way. If `run()` set `p.reaper_pending`, an
in-flight Cmd outlived the grace period and a detached thread is still freeing
allocations from your `context.allocator`; do not tear that allocator down
before you exit ([§1](#1-starting-a-program)).

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
- `rt.view_diff_safe(your_view)` if you use `.Diff`, `rt.view_render_safe` if you
  use `.Inline` or `.Full_Screen`
  ([§6](#6-drawing--render-modes-the-cursor-the-view-contract)).

One thing a golden test will *not* catch on its own: a `view` that allocates from
`context.allocator` instead of `alloc` renders identically and leaks a frame per
frame. `odin test` reports that as a `+++ leak` **warning on a passing test**,
so read the warnings — or turn them into a gate the way `tools/test.sh` does
([§6](#6-drawing--render-modes-the-cursor-the-view-contract)).

---

## 11. Measuring text

| Symbol | File | What it is |
|---|---|---|
| `display_width` | `runetea/width.odin` | columns a string occupies, skipping escapes |
| `Width_Options` | `runetea/width.odin` | `ambiguous_is_wide`, `emoji_width`, `start_col`, `tab_stop` |
| `Emoji_Width` | `runetea/width.odin` | `.Grapheme_Cluster` (zero value) or `.Legacy_Wcwidth` — which terminal family's cluster rule to measure by |
| `measure_line` / `Line_Metrics` | `runetea/width.odin` | rows, ending column, and whether the last row is flush — from one placement walk |
| `rows_for_line` | `runetea/width.odin` | physical rows one logical line wraps to (`measure_line(...).rows`) |
| `Cluster_Iter`, `cluster_iter_make`, `cluster_next` | `runetea/width.odin` | walk grapheme clusters with corrected widths — what you need to write a truncate |
| `is_ambiguous_width` | `runetea/width.odin` | is this rune East-Asian *Ambiguous*? |
| `TAB_STOP_DEFAULT` | `runetea/width.odin` | 8 |

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

	// A TAB IS NOT ZERO-WIDTH. It advances to the next multiple of tab_stop
	// (default 8) FROM start_col, so a tab's width depends on where the string
	// begins -- which is why start_col exists and why display_width(a) +
	// display_width(b) != display_width(a + b) once a tab is involved.
	_ = rt.display_width("\tx")                                    // 9
	_ = rt.display_width("\tx", rt.Width_Options{start_col = 3})    // 6
	_ = rt.display_width("\tx", rt.Width_Options{tab_stop = -1})    // 1 -- the old zero-width reading

	// measure_line answers all three placement questions at once, against a
	// known terminal width, using the same rule the cell model uses.
	m := rt.measure_line("a long line", 4)
	_ = m.rows      // 3
	_ = m.end_col   // the column the cursor lands on, 0 ..= term_width
	_ = m.fills     // is the last row's final column written? (drives \e[K)
}
```

**Emoji width is a question terminals answer two different ways, and you have to
pick.** `.Grapheme_Cluster`, the default, advances once per extended grapheme
cluster — right for kitty, WezTerm, foot, Ghostty and anything that answers DEC
mode 2027. `.Legacy_Wcwidth` sums the runes' own widths with no cluster folding —
right for every VTE-based terminal (GNOME Terminal, Tilix, Terminator), alacritty,
xterm, tmux and screen. On a live VTE the default is wrong for four of ten test
clusters *in both directions*: two columns short on a skin-tone or ZWJ sequence,
one column long on a keycap or a VS16 heart. There is no third answer that is
right everywhere, so this is a setting to expose to your user, exactly like
`ambiguous_is_wide`; the measurements and the argument for the default are in
[`LIMITATIONS.md`](LIMITATIONS.md) 4.2a. Comparing the two answers is also how you
detect that a given string is one the terminals disagree about at all.

Note that under `.Legacy_Wcwidth` **a cluster's width is not bounded by 2** — the
four-emoji ZWJ family measures 8 — so code of your own that assumed "1 or 2" from
`cluster_next` needs to stop.

**Truncating to a column is yours to write, and the cluster iterator is what you
write it with.** Slicing at a rune boundary and re-measuring corrupts multi-rune
clusters — it drops the VS16 off an emoji, splits a regional-indicator flag pair,
leaves a dangling ZWJ. `Cluster_Iter` walks whole clusters with the corrected
widths and allocates nothing; `cluster_next` returns the cluster's bytes and its
width and advances `ci.col`, which a caller that wraps resets to 0 at each wrap.
`runegloss` ships `rg.truncate` and `rg.wrap` built on exactly this, so reach for
those first ([§12](#12-runegloss)).

East-Asian *Ambiguous* width — box drawing, curly quotes, Greek, Cyrillic — has
no universally correct answer and the terminal does not report it. The default
is narrow, matching `core:unicode` and xterm. If your users are on CJK-locale
terminals, expose `Width_Options{ambiguous_is_wide = true}` (and RuneGloss's
`rg.width_options`, which takes the whole `Width_Options` value) as a setting;
RuneTea cannot detect it for you ([`LIMITATIONS.md`](LIMITATIONS.md) 4.2).

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
| contrast | `relative_luminance`, `contrast_ratio`, `reference_rgb` |
| attributes | `bold`, `faint`, `italic`, `underline`, `blink`, `reverse`, `strikethrough`, `attr`, `Attr`, `Attrs` |
| box model | `padding`, `margin` (1/2/4-value arities), `width`, `height`, `align`, `valign`, `Align_H`, `Align_V`, `Sides`, `ALL_SIDES` |
| overflow | `overflow`, `Overflow` (`.Wrap` default, `.Truncate`, `.Grow`), `ellipsis` |
| borders | `border`, `border_sides`, `border_fg`, `border_bg`, `Border`, `border_cell`, `NORMAL`, `ROUNDED`, `THICK`, `DOUBLE`, `HIDDEN` |
| frame arithmetic | `frame_size`, `horizontal_frame_size`, `vertical_frame_size`, `border_size` |
| text | `measure`, `measure_width`, `measure_height`, `truncate`, `wrap` |
| layout | `join_horizontal`, `join_vertical` |
| width | `ambiguous_wide`, `emoji_width`, `width_options` |
| render | `render :: proc{render_ptr, render_val}` — `rg.render(&s, text, alloc)` **and** `rg.render(s, text, alloc)` |

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
	// NO LOCAL COPIES NEEDED. `render` is a proc group: render_val takes the
	// Style by value, so `rg.render(t.title, ...)` compiles even though `t` is
	// a non-addressable procedure parameter. The ^Style overload is still
	// there for the call sites that already have a pointer and would rather
	// not pay the 184-byte copy.
	return fmt.aprintf("%s\n%s\n",
		rg.render(t.title, "RuneGloss", alloc),
		rg.render(t.body,  "Everything here is allocated from `alloc`.", alloc),
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

**Colour degradation is silent and total by design.** Under `.None` —
`$NO_COLOR`, a dumb terminal — **every colour is dropped**, with no `if` anywhere
in your view. 24-bit colours down-convert to the 256-colour cube or the 16 ANSI
colours as the profile requires, by nearest CIE76 ΔE in CIELAB space.

**`.None` is not a plain-text mode.** Only colour is dropped. Attributes still
emit SGR (`bold` under `.None` is still `\e[1m…\e[0m`) and the box model still
restructures the string — padding, width, alignment and borders all apply. The
`Theme` above rendered at `.None` still comes out as bordered, padded, centred
blocks with bold runs in them. The invariant that does hold is narrower and
belongs to the **style**, not the profile: *a style that asks for nothing renders
its input byte for byte*, at every profile. If you need plain text for a log, a
pipe or a screen reader, do not send it through a configured `Style` at all
([`LIMITATIONS.md`](LIMITATIONS.md) 7.11).

**Down-conversion to 16 colours moves contrast, and you can measure it.**
`rg.contrast_ratio(fr, fg, fb, br, bg, bb)` returns the WCAG ratio for a
foreground/background pair and `rg.reference_rgb(c)` gives the RGB a `Color`
actually resolves to, so a test can assert that a palette still clears 4.5:1
after `rg.convert(c, .ANSI)`. It cannot check what the *user's* terminal has
retheméd palette slots 0–15 to ([`LIMITATIONS.md`](LIMITATIONS.md) 7.6).

**A malformed colour is "no colour", not an error.** `rg.color("#7D56F")` styles
nothing, silently — there is no error channel that would not poison every call
site ([`LIMITATIONS.md`](LIMITATIONS.md) 7.5).

**`width` and `height` are EXACT, and they INCLUDE the border.** Both were floors
until this cycle, and both excluded the border; both changes are Lipgloss v2's
answer and both are breaking. Concretely: `rg.width(&s, 30)` on a bordered style
gives you a block that is 30 columns corner to corner, where it used to give you
32 — and content wider than the content area is now **reflowed to fit** instead
of widening the block. Margin stays outside, as in Lipgloss.

`rg.overflow(&s, o)` picks how the clamp is applied:

| `Overflow` | What content that does not fit does |
|---|---|
| `.Wrap` | **the default**, and inert while `width` and `height` are both 0. Greedy word wrap, hard-breaking at grapheme-cluster boundaries, re-establishing the active SGR on every produced row. |
| `.Truncate` | cut, with `rg.ellipsis(&s, "…")` budgeted *inside* `width`, and any style run the cut passed through closed |
| `.Grow` | the old floor semantics, verbatim |

The vertical axis clamps too, and `valign` decides which rows survive: `.Top`
keeps the head, `.Bottom` the tail, `.Middle` the middle. A `width` smaller than
the style's own border plus padding yields a frame-wide block with zero content
columns rather than a sheared one.

`rg.frame_size(s)` (and the `horizontal_`/`vertical_` halves, and `rg.border_size`)
gives you the margin + border + padding cost, which is what you subtract when you
are laying out panels yourself and cannot recompute the width of a custom or
fullwidth border glyph.

**What RuneGloss still does not have:** `table`, `tree`, `list`, and fluent
chaining. `wrap`, `truncate`, `measure`, `join_horizontal` and `join_vertical`
now exist. See [`LIMITATIONS.md`](LIMITATIONS.md) section 7 in full before
assuming Lipgloss parity.

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
| `Run_Error`, `Interrupted_Error`, `Panicked_Error`, `Terminal_Error`, `Killed_Error`, `exit_code` | `tea.odin` |
| `Quit_Msg`, `quit_cmd` | `tea.odin` |
| `Input_Source`, `input_source_from_fd`, `input_source_from_bytes`, `input_close`, `input_wake` | `loop.odin` |
| `Cmd`, `Cmd_Ticket`, `cmd_from`, `cmd_nil`, `cmd_is_nil` | `cmd.odin` |
| `Cancel_Token`, `cancel_requested` | `cmd.odin` |
| `batch`, `sequence` | `batch.odin` |
| `Panicked_Msg` | `cmd.odin` |
| `tick`, `tick_cancellable`, `every`, `timer_stop`, `Timer_Fn`, `Timer_Handle`, `Timer_Unavailable_Msg` | `timer.odin` |
| `Key_Msg`, `Key_Code`, `Key_Kind`, `Modifier`, `Modifiers`, `Legacy_Key`, `Legacy_Key_Encoding` | `input.odin` |
| `Mouse_Msg`, `Mouse_Kind`, `Mouse_Button` | `input.odin` |
| `Paste_Start_Msg`, `Paste_End_Msg`, `Focus_Msg`, `Blur_Msg`, `Keyboard_Enhancements_Msg` | `input.odin` |
| `Window_Size_Msg`, `Interrupt_Msg` (watcher API only — `update` never sees one) | `signals.odin` |
| `box`, `box_free`, `is_pod_type` | `arena.odin` |
| `Msg_Text`, `msg_text_from`, `msg_text_fmt`, `msg_text_clone`, `msg_text_string`, `msg_text_truncated`, `MSG_TEXT_CAP` | `msg.odin` |
| `Render_Mode`, `Cursor`, `request_repaint` | `render.odin` |
| `view_diff_safe`, `view_render_safe`, `Diff_Contract`, `VIEW_STRICT`, `DIFF_STRICT` | `contract.odin` |
| `display_width`, `Width_Options`, `Emoji_Width`, `measure_line`, `Line_Metrics`, `rows_for_line`, `Cluster_Iter`, `cluster_iter_make`, `cluster_next`, `is_ambiguous_width`, `TAB_STOP_DEFAULT` | `width.odin` |
| `term_enter_raw`, `Term_Opts`, `term_restore`, `term_size`, `term_supports_escapes`, `Kitty_Flag`, `Kitty_Flags`, `Mouse_Mode` | `term.odin` |
| `install_crash_handlers`, `install_stop_handlers`, `guarded`, `Panic_Info` | `guard.odin` |
| `signal_unblock_for_child`, `runetea_signal_set` | `signals.odin` |

### `runegloss`

| Symbol | File |
|---|---|
| `Style`, `new_style`, `new_style_profile`, `profile` | `style.odin` |
| `fg`, `bg`, `bold`, `faint`, `italic`, `underline`, `blink`, `reverse`, `strikethrough`, `attr`, `Attr`, `Attrs` | `style.odin` |
| `padding`, `margin`, `width`, `height`, `align`, `valign`, `Align_H`, `Align_V`, `Side`, `Sides`, `ALL_SIDES` | `style.odin` |
| `overflow`, `Overflow`, `ellipsis` | `style.odin` |
| `border`, `border_sides`, `border_fg`, `border_bg`, `ambiguous_wide`, `emoji_width`, `width_options` | `style.odin` |
| `frame_size`, `horizontal_frame_size`, `vertical_frame_size`, `border_size` | `style.odin` |
| `Border`, `Border_Cell`, `border_cell`, `cell_str`, `NORMAL`, `ROUNDED`, `THICK`, `DOUBLE`, `HIDDEN`, `BORDER_CELL_CAP` | `border.odin` |
| `Color`, `Color_Kind`, `color`, `color_hex`, `color_ansi`, `convert` | `color.odin` |
| `Profile`, `detect_profile`, `detect_profile_env`, `default_profile`, `set_default_profile`, `clear_default_profile` | `color.odin` |
| `relative_luminance`, `contrast_ratio`, `reference_rgb` | `color.odin` |
| `render` (`render_ptr`, `render_val`), `measure`, `measure_width`, `measure_height`, `truncate`, `wrap`, `join_horizontal`, `join_vertical` | `render.odin` |
