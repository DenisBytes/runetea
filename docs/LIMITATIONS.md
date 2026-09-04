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
| **FIXED** | It used to be one of the above and is not any more. The entry stays, because knowing what the behaviour *was* is how you read a bug report from an older build — and because an entry that vanishes is indistinguishable from an entry nobody wrote. |
| **API trap / API hazard** | Nothing is wrong; the shape invites a specific mistake. |

A **FIXED** entry names the release its fix landed in. There is exactly one so
far: **v1.0-audit**, the sweep recorded at the end of this document.

---

## 1. Platform

### 1.1 Linux only, in practice — **NOT-YET-BUILT** (Darwin/BSD) / **INTRINSIC** (Windows, for v1.0)

`term_size` goes through `core:sys/linux` directly, because `core:sys/posix`
exposes neither `ioctl` nor a `winsize` struct (`runetea/term.odin, term_size`).
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

The signal watcher uses it for its own stop nudge (`runetea/signals.odin, SIG_WAKE`).
An application cannot use `SIGUSR2` for itself.

### 1.4 The blocked signal mask is inherited by child processes — **INTRINSIC** (the inheritance) / **FIXED** (having no way to undo it)

`exec(2)` resets signal *handlers* to `SIG_DFL` and drops the altstack, but it
does **not** reset the blocked **mask** — so a child spawned while RuneTea's
watcher mask is installed starts with `SIGINT`/`SIGTERM`/`SIGWINCH`/`SIGUSR2`
blocked and is un-Ctrl-C-able. That part is POSIX and cannot be changed.

**What was fixed is that there was no supported way to undo it.** RuneTea now
exposes two public primitives (`runetea/signals.odin`):

- `signal_unblock_for_child()` — unblocks exactly the signals
  `signal_watcher_start` blocks, on the calling thread. Call it in the child,
  **between `fork` and `exec`**; it is async-signal-safe (`pthread_sigmask` is
  on POSIX's list) and does nothing else, precisely so that stays true. It
  `UNBLOCK`s rather than emptying the mask, so anything the *application*
  blocked for its own reasons survives.
- `runetea_signal_set(^posix.sigset_t)` — the one definition of that set, so a
  caller building its own mask (a `posix_spawn` sigmask attribute, say) does not
  hard-code a copy that goes stale.

<!-- doccheck: body -->
```odin
argv := [?]cstring{"less", nil}
pid := posix.fork()
if pid == 0 {
	rt.signal_unblock_for_child()
	posix.execvp("less", raw_data(argv[:]))
	posix._exit(127)   // only reached if execvp failed
}
```

**RuneTea itself execs nothing**, so there is no internal call site to fix: the
only `fork`/`exec` pairs in the repository are the standalone harnesses under
`tools/`. Pinned by `test_a_child_process_can_be_given_back_a_clean_signal_mask`,
which measures `SigBlk` **after a real `exec`** — with and without the call — and
by `test_runetea_signal_set_covers_every_signal_the_watcher_blocks`, so a signal
added to the watcher and not to the unblock is a test failure rather than a
child that silently inherits it.

**Residual:** you must still call it. RuneTea has no `suspend`/`exec` helper
(see 8.1) that would call it for you.

### 1.5 `signal_watcher_start` must run before any other thread exists — **INTRINSIC**

POSIX signal masks are inherited by threads at creation. A minimal repro with
one unrelated unblocked thread killed the process 5/5 times on an external
`SIGINT`, *even though a correctly-blocked `sigwait` watcher existed*
(`runetea/signals.odin, signal_watcher_start`).

**When it bites:** an application that starts its own worker pool before calling
`run()`. `run()` gets the ordering right internally
(`runetea/tea.odin, run`'s signal-watcher-before-dispatcher ordering), so this only affects apps doing their own
threading.

---

## 2. Message and Cmd model

### 2.1 Every `Msg` type must be POD — **INTRINSIC**

`string`, `cstring`, `^T`, `[]T`, `[dynamic]T`, `map`, and `any` are **illegal**
anywhere in a `Msg`'s field tree (`runetea/arena.odin, box`'s MESSAGE OWNERSHIP CONTRACT). This is the
single largest permanent ergonomic cost of the design, and it touches every
program.

Concretely illegal: Bubble Tea's `PasteMsg{Content string}`
(`runetea/input.odin, Paste_Start_Msg`), `BatchMsg([]Cmd)` (`runetea/batch.odin`'s header),
anything carrying an HTTP body or an `fmt.aprintf` result.

**What to do instead:** a fixed-capacity `Msg_Text` for short text (see 2.3);
for anything larger, put the payload in application-owned storage and send a
handle (an index, an ID) as the `Msg`.

### 2.2 The POD check is at *runtime*, not compile time — **TOOLCHAIN**

Odin cannot fold `is_pod_type` into a compile-time constant
(`runetea/arena.odin, is_pod_type`; repro in `tools/podcheck/main.odin`).

**When it bites:** an illegal `Msg` type compiles clean and panics the first
time that code path executes — possibly in production, on a rare branch.
**What to do instead:** call `box()` on every `Msg` type you define, once, in a
test.

### 2.3 `Msg_Text` holds 255 bytes — **INTRINSIC** (the cap) / **FIXED** (the silence)

`MSG_TEXT_CAP :: 255`, and 255 rather than 256 because `len` is a `u8`
(`runetea/msg.odin`). The cap is what makes the type POD, and POD is what lets
it cross a `Msg` boundary at all — it cannot be raised without giving up the
thing it exists for.

**Truncation is no longer silent.** `Msg_Text` carries a `truncated` flag, set
exactly when the input did not fit, readable with `msg_text_truncated(m)`.
`msg_text_fmt` formats into `MSG_TEXT_CAP + 1` bytes and keeps `MSG_TEXT_CAP`,
so an exact fit and a clip are distinguished precisely rather than guessed from
the length. Pinned by `test_msg_text_from_records_whether_it_fitted`,
`test_msg_text_fmt_records_whether_it_fitted` and
`test_msg_text_truncation_keeps_the_prefix_and_both_accessors_agree`, which
drives an exact-fit and a one-byte-over payload through both constructors.

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
syscall it never returns from"* (`runetea/cmd.odin, Cancel_Token`; full argument,
including why `pthread_cancel` is strictly worse, in
`docs/superpowers/cancellation-decision.md:552-571`).

**When it bites:** quit takes as long as your slowest blocking Cmd. Named
unfixable cases: `net.dial_tcp_*` (`core:net` has no timeout), a child-process
`wait()`, a blocking read on a hung NFS mount.
**What to do instead:** write Cmds as bounded retry loops that poll the token.
`examples/http` shows the shape.

### 2.6 `run()` bounds quit at 100 ms; `run_nbio()` does not — **NOT-YET-BUILT**

`QUIT_GRACE = 100ms` applies to `run()` only (`runetea/tea.odin, run`'s `QUIT_GRACE`).
`run_nbio` keeps a fully synchronous teardown and blocks on the slowest Cmd
(`docs/superpowers/cancellation-decision.md:557-560`).

### 2.7 A Cmd that panics leaks whatever it had allocated — **INTRINSIC**

`setjmp`/`longjmp` recovery does not unwind and does not run `defer`
(`runetea/cmd.odin, run_cmd_guarded`). **When it bites:** a long-running app whose Cmds
panic repeatedly grows without bound. The same applies to a panic inside
`batch()`/`sequence()` coordination logic (`runetea/batch.odin, compose_procedure`).

### 2.8 One `^Thread` struct (~256 B) leaks per `run()`/`run_nbio()` session — **INTRINSIC**

Deliberate, bounded, one per session, and the only entry on the leak
allowlist in `tools/test.sh`. `self_cleanup = true` has a genuine race inside
`core:thread` that ThreadSanitizer catches reproducibly, so the thread is
detached by hand instead; the kernel stack and TCB *are* reclaimed
(`runetea/cmd.odin, dispatcher_reap`'s "WHY self_cleanup = false").

**When it bites:** a process that starts thousands of `run()` sessions.

### 2.9 A detached Cmd is exposed to a `core:thread` race — **TOOLCHAIN**

A signal-then-free race on `t.start_ok` in `thread_unix.odin`, caught by TSan
roughly 1 run in 5–8 (`runetea/cmd.odin, dispatcher_reap`'s "WHY self_cleanup = false"). Not patchable from this
package. **When it bites:** rarely, on a `detached = true` Cmd whose body
finishes in microseconds — which is what `batch()`/`sequence()` coordinators do.

### 2.10 One OS thread per compose Cmd, at every nesting depth — **INTRINSIC**

`runetea/batch.odin, compose`. A hot loop building hundreds of individually
composed sub-batches spawns hundreds of threads
(`docs/superpowers/batch-sequence-decision.md:428-437`).

### 2.11 A `Tick`/`Every` inside `batch()`/`sequence()` gates nothing — **NOT-YET-BUILT**

`sequence([step_a, tick(1s), step_b])` does **not** pause for a second; the tick
step signals `done` immediately (`runetea/cmd.odin, dispatch_ex`'s Tick/Every note). There is no
correct semantics for a nested `Every` at all
(`docs/superpowers/batch-sequence-decision.md:404-419`).

### 2.12 `batch()` takes a slice, not a variadic — **INTRINSIC**

`batch([]Cmd{a, b}, context.allocator)` (`runetea/batch.odin, batch`).

### 2.13 Timer handles must be stopped exactly once — **INTRINSIC**

`tick_cancellable`/`every` hand out a `Timer_Handle` that must be passed to
`timer_stop` exactly once — never zero times (the handle *and* its cloned
closure env are stranded for the life of the process), never twice (a refcount
decrement against possibly-freed memory). `runetea/timer.odin, Timer_Handle`. Plain
`tick()` deliberately hands out no handle so the common case is unleakable.

### 2.14 Timer subsystem start failure — **FIXED**, before v1.0-audit

*Previously described here as "the worst-shaped remaining limitation in the
library".* If `nbio.acquire_thread_event_loop` failed, `timer_dispatch` released
the handle and returned; every future `tick`/`every` on that `Dispatcher` then
never fired, forever, with **no diagnostic of any kind**. Your spinner simply
stopped.

It is now a **`Timer_Unavailable_Msg`** delivered through the Mailbox to your
`update()` — the same shape `Panicked_Msg` (`runetea/cmd.odin`) uses for the
analogous "a background thing you asked for can never produce a result" case,
and POD for the same reason (the cause travels as a `Msg_Text`, not a `string`).
It means exactly one thing, and it is permanent: **no timer on this Dispatcher
will ever fire.**

**ONCE PER `Dispatcher`, not once per failed dispatch**, and that is a decision
rather than an economy (`runetea/timer.odin, timer_report_unavailable`). The
failure is a property of the Dispatcher's single, lazily-started timer thread,
not of the individual `tick()` that discovered it, and nothing retries the
acquire — so every later message would carry identical information. It would
also be actively harmful in exactly the case that matters: animation-driven apps
re-dispatch on a cadence, and back-pressure on a full Mailbox is retry-forever,
never drop (2.15), so a per-dispatch report would let a broken timer subsystem
saturate the Mailbox and stall the very application it was warning.

**Ordinary teardown is not reported.** `timer_service_ensure_started` also
returns nil after `dispatcher_destroy`, which is shutdown, not a defect; a
separate `start_failed` flag keeps the two apart on purpose rather than by
accident of timing.

**What is left is the reaction, which is yours.** RuneTea cannot restart the
subsystem and does not pretend to: handle the Msg by degrading (a static frame
instead of a spinner), by polling some other way, or by quitting.

Pinned by `test_timer_start_failure_is_reported_through_the_mailbox` (the
failure produces a Msg rather than silence) and
`test_timer_start_failure_is_reported_once_per_dispatcher` (it produces exactly
one, which is the half that keeps the report from saturating the Mailbox it
travels through). `test_timer_unavailable_msg_is_pod` pins the type itself,
since a non-POD Msg from a Cmd is a silent no-op (2.24).

### 2.15 Back-pressure policy is "retry forever", not "drop" — **NOT-YET-BUILT** (the policy) / **FIXED** in v1.0-audit (its cost)

`deliver_result` retries on a full mailbox and a caller still has no way to say
"I am cosmetic, drop me" (`runetea/cmd.odin`;
`docs/superpowers/tick-every-decision.md:467-470`). Nothing sheds frames.

**What was fixed is what the retry cost.** It used to be an unbounded
`thread.yield()` spin, and this entry used to describe that as "blocks the timer
thread", which was wrong in both directions: it never blocked, and it burned a
whole core doing so. Measured in isolation before the fix: an `every(50µs)`
against a 2 ms `update` pinned a core at **100% CPU**; an `every(16ms)` against a
60 ms `update` sat at **82% CPU** for 34.2 s of wall clock. It is now a bounded
spin (`BACKPRESSURE_SPINS` = 64 yields, for the momentary case) followed by an
exponential sleep from `BACKPRESSURE_MIN_SLEEP` (50 µs) to `BACKPRESSURE_MAX_SLEEP`
(1 ms). The same two measurements are now **6%** and **3% / 34.1 s** — 567 ticks
delivered against 569 before, so nothing was traded away for it. Teardown latency
stays bounded because `mailbox_send` re-checks `closed` on every attempt, so a
close is noticed within one sleep.

**When it still bites:** a producer faster than its consumer never drops a
message, so a 60 fps `every()` behind a stalled `update` builds latency rather
than shedding frames. That is the policy, and the policy is unchanged. Pinned by
`test_backpressure_delivers_every_message_to_a_slow_consumer`, which asserts the
retry-forever half — that the sleep loses nothing — since the CPU figures above
are a measurement rather than an assertion a unit test can make.

### 2.16 `every()` does not align to wall-clock multiples — **INTRINSIC**, deliberate

Two independent 1-second `Every`s never tick in lockstep
(`runetea/timer.odin, every`). Under a stall, `every()` skips at most one
interval and never bursts catch-up fires (`runetea/timer.odin, timer_fire`'s "CATCHING UP") — right for
animation, wrong for anything counting ticks. Both of those shorthands had rotted
onto unrelated comments before the citation gate existed; `:678-686` in
particular resolved correctly at the commit that introduced this document and was
pointing at a `Timer_Unavailable_Msg` comment one commit later.

### 2.17 Mailbox capacity is hard-coded at 256 — **NOT-YET-BUILT**

`MAILBOX_CAP :: 256`, package-private, with no way for an application to choose
another number (`runetea/tea.odin`, `runetea/loop_nbio.odin`). A paste longer
than that still fills it and the reader still waits — the waiting is now the
bounded spin-then-sleep of 2.15 rather than a hot loop, but the capacity itself
is unchanged.

**It is also `COALESCE_BUDGET`**, the most messages either host applies before it
stops and paints, which is deliberate: the drain must be bounded or a producer
faster than the loop starves rendering entirely, which is exactly the shape
`run_nbio` used to fail in (2.21).

### 2.18 The mailbox is single-consumer, and `try_recv`'s `ok=false` is ambiguous — **INTRINSIC**

Empty and closed are the same answer; `mailbox_closed_and_empty` disambiguates
(`runetea/mailbox.odin`).

### 2.19 A `Cmd` value is SINGLE-USE, and re-dispatching one is refused — **INTRINSIC** (the contract) / **FIXED** in v1.0-audit (what breaking it did)

`Cmd` is a copyable POD struct with no destructor, so nothing in the type system
stops you storing one in your model and returning it from `update` twice. Doing
so used to **double-free the Cmd's heap-cloned env**: a deterministic `SIGSEGV`,
5 runs out of 5, reported as `bad free @ cmd.odin`. The `batch()`/`sequence()`
form was worse — a triple-double-free of the spec, the child slice and every
child env, followed by a read of a garbage enum. The `tick()`/`every()` form
armed one `Timer_Handle` twice against a single subsystem reference and
double-freed the handle and its cloned env on the *timer* thread.

Every heap-owning `Cmd` now carries a `Cmd_Ticket` — two `u32`s, no pointer —
issued by its constructor and **claimed exactly once** at the single funnel every
kind of dispatch passes through, before any branch reads `env`, `timer` or
`compose`. A second dispatch of the same value therefore finds a stale ticket,
runs nothing, frees nothing, and reports to your `update`:

    dispatch(): this cmd_from Cmd was already dispatched and was NOT run again --
    a Cmd value is SINGLE-USE; build a fresh one instead of storing and returning
    the same one twice

`cmd_nil()` and `quit_cmd()` carry the zero ticket, own nothing, and stay
reusable forever — which matters, because every `update` in this repository
returns one of them on most keystrokes.

**What to do instead:** build a fresh Cmd. The constructors are cheap and this is
the intended pattern; `examples/spinner` calls `spin_tick_cmd()` once per fire,
forever. Pinned by `test_redispatching_a_cmd_from_is_refused_with_a_diagnostic`,
`test_redispatching_a_batch_is_refused_with_a_diagnostic`,
`test_redispatching_a_sequence_is_refused_with_a_diagnostic` and
`test_redispatching_a_tick_is_refused_with_a_diagnostic`.

**Residual, and real:** the refusal travels to `update` through the Mailbox, so a
re-dispatch that happens *after* the mailbox has closed is silently dropped.
"Fails loudly" means "fails loudly while the loop is running". Measured: the same
probe reports `refused=2` under a real pty and `refused=0` when driven from a
finite `input_source_from_bytes`, which closes the mailbox at EOF.

### 2.20 Passing `update`'s own `alloc` to a Cmd constructor — **FIXED** in v1.0-audit for `cmd_from`/`tick`/`every`, **NOT-YET-BUILT** for `batch`/`sequence`

`update` is handed one allocator, spelled `alloc`, and it is the **frame arena**.
Every Cmd constructor takes an allocator as its last argument. Passing the one
already in scope is the obvious move, it compiles clean, and it heap-clones the
Cmd env *into the arena* — which `guarded_render` reclaims at the end of the same
frame, typically before the worker thread has run the body (`runetea/arena.odin`).

**What it used to cost.** A minimal probe — one Cmd whose env holds a tag and a
length, dispatched from `update` with `alloc` — read a **zeroed** env, not garbage
it might have noticed, because `virtual.Arena` zeroes reused blocks on `.Alloc`.
No assert, no diagnostic, `run()` returned `nil`, the process exited **0**, and
nothing anywhere said a word — in a release build and in `-debug` alike. This
entry used to end *"nothing detects it… `cmd_from` cannot tell one
`mem.Allocator` from another"*, which was the wrong conclusion drawn from a true
premise: it cannot tell an arbitrary allocator from another, but the frame arena
is not arbitrary. It is one `mem.Allocator` value **this package constructed**
(`runetea/arena.odin, frame_allocator`) and handed to user code at exactly two
points, so the question "did the caller hand back the allocator we just gave
them?" is two pointer comparisons.

`cmd_from`, `tick`, `tick_cancellable` and `every` now make those two comparisons
and **panic** at
the call site (`runetea/cmd.odin, cmd_alloc_contract_check`), naming the
constructor and the `#caller_location`. The panic is raised inside `update`, which
runs under `guarded()`, so it ends the session with `Panicked_Error` and exit
status 1 rather than taking the process down — exit 0 with a zeroed env becomes a
named failure at the exact line. `dispatch_ex` carries a second, reporting (not
panicking) check for the Cmd that was *built* while no frame was armed and
dispatched later. The check is **always on**, not gated like `VIEW_STRICT`: it is
one load and two compares on a path already about to heap-allocate and start a
thread, and a check that is compiled out of the `-o:speed` build your users run is
how the `.Diff` contract check came to be useless (3.2). It is armed **per frame**
rather than keyed on `virtual.arena_allocator_proc` alone, so an application's own
long-lived `virtual.Arena` — a perfectly correct place for a Cmd env — is not
falsely refused.

**`batch()` and `sequence()` are NOT checked, and their failure is worse.** They
take the same trailing allocator and allocate the `Compose_Spec` and the child
list from it, and nothing compares. Measured on the same probe shape, ten runs
each:

| `batch([]Cmd{a, b}, alloc)` | `sequence([]Cmd{a}, alloc)` |
|---|---|
| 0 of 10 runs ran **either** child body | 10 of 10 ran the child, by luck of arena reuse |
| 1 of 10 died with SIGSEGV (exit 139) | exit 0 every time |
| exit 0 on the other 9 | |

So the constructor whose misuse loses the most work is the one still silent about
it. Fixing it is the same two comparisons in `runetea/batch.odin, compose`; it was
not done in v1.0-audit because that file had no owner in the wave that added the
check. Pinned by `test_a_cmd_from_given_updates_own_frame_allocator_is_refused`;
nothing pins the `batch`/`sequence` half, which is what an unfixed entry means.

**What to do instead, unchanged:** pass `context.allocator` to every Cmd
constructor. Every example and every sample in `docs/API.md` does. The rule is one
sentence long — *a Cmd outlives the frame that built it, so its env must too* —
and the fact that both allocators are spelled `alloc` at the call site is the
whole trap.

### 2.21 `run_nbio()` starved keyboard input while Cmd results were queued — **FIXED** in v1.0-audit

`nbio.tick()` was unreachable while the mailbox was non-empty, so a program whose
Cmds produced results faster than the loop drained them never read the keyboard
again — including the key that would have quit it. Two changes were needed and
the budget alone was measured *not* to be sufficient: the drain is now bounded by
`COALESCE_BUDGET` and `nbio.tick()` runs on **every** iteration (with a zero
timeout when the drain stopped on the budget, `NO_TIMEOUT` when it emptied the
queue), and **decoded input no longer travels through the Mailbox at all** in
`run_nbio` — the loop applies the read's backlog directly and re-arms the read
itself. With only the budget in place the repro still hung, because freeing 256
slots and handing them straight back to a saturating producer is not progress.

Pinned by `test_run_nbio_still_reads_input_while_the_mailbox_never_empties`,
which drives a producer that refills the mailbox faster than the loop drains it
and requires the quit key to still get through.

### 2.22 `run()` can return while a background reaper still owns your allocations — **FIXED** in v1.0-audit (the silence), **INTRINSIC** (the situation)

`run()` waits `QUIT_GRACE` (100 ms) for in-flight Cmds and then returns anyway,
leaving a detached reaper thread still freeing ~7 KiB across ~17 live
allocations **made through the caller's `context.allocator`**. If that allocator
is torn down on the way out of `main`, the reaper writes into released memory:
measured as a deterministic `SIGSEGV` with a clean cliff at exactly the grace
period — a 90 ms Cmd exits 0, a 150 ms Cmd exits 139 — and it segfaults even for
a Cmd that allocates nothing, because what writes into the released memory is
RuneTea's own teardown.

There was no signal at all that this had happened. `Program(T)` now carries a
public `reaper_pending: bool`, set by `run()` on the way out and never read by
it. **True means: keep `context.allocator` alive until the process exits.**
`run_nbio` tears the Dispatcher down synchronously and never sets it. Pinned by
`test_run_reports_a_pending_reaper_when_a_cmd_outlives_the_grace` and
`test_run_reports_no_pending_reaper_when_nothing_is_in_flight`.

A `Run_Error` variant was rejected for it: this is not a failure of the run, and
an app that ignores the flag behaves exactly as it did before.

### 2.23 Messages still queued at quit were leaked — **FIXED** in v1.0-audit

`mailbox_destroy` never freed the `any`s left in the ring, so every message that
arrived after the quit decision was leaked, in `run()` and `run_nbio()` alike. It
now drains the ring under the lock it already took and `box_free`s each entry.
This makes an always-implicit precondition **enforceable**: every value handed to
`mailbox_send` must be a `box()` allocation. Anything sending a bare `any` now
gets a loud bad-free instead of a silent leak.

Pinned by `test_mailbox_destroy_frees_messages_still_queued` and, for the third
consumer that dropped its in-hand message on a `.Closed` send rather than in the
ring, `test_the_reader_frees_the_message_it_still_holds_when_the_mailbox_closes`
— one 12-byte box per session, which no leak audit noticed because it was one.

### 2.24 A non-POD `Msg` returned from a `Cmd` is a no-op you can ignore — **NOT-YET-BUILT**

`box()` panics naming the offending type, the panic is recovered, and the
resulting `Panicked_Msg` reaches `update()`. If `update` has no
`case rt.Panicked_Msg:`, **nothing else happens**: no stderr, no non-zero exit,
no `Panicked_Error`. The Cmd simply never delivers, forever, and the program
looks like one whose Cmd is slow.

What was fixed is the *content* of the report: `box()` now puts both the
offending `typeid` and the `box()` call site into the message text, leading with
them so both survive `Msg_Text`'s 255-byte truncation. What was not fixed is the
escalation — `apply_msg` delivers the message and does nothing further when no
case matches. **What to do instead:** give every `update` a real
`case rt.Panicked_Msg:` body, and call `box()` on every Msg type you define once,
in a test (2.2).

### 2.25 Reading a `Msg_Text` out of a type switch does not compile — **TOOLCHAIN**, with a one-line workaround

`msg_text_string` takes `^Msg_Text`, and an Odin `switch v in msg` binding is not
addressable, so `rt.msg_text_string(&v.message)` inside
`case rt.Panicked_Msg:` fails with *"Cannot take the pointer address of
'v.message'"*. The workaround is a local copy (`mt := v.message`), it is in
`docs/API.md` §5, and it applies to **every** fixed-array field of every Msg, not
just `Msg_Text`. `if pm, ok := msg.(rt.Panicked_Msg); ok` binds an addressable
local and does not need it.

Three alternative signatures were measured and all lose to the copy: a by-value
`msg_text_string(Msg_Text) -> string` returns a pointer into a dead parameter, a
returning-by-value accessor cannot avoid the 257-byte copy anyway, and an
out-parameter form is worse to read than the workaround it replaces
(`runetea/msg.odin`).

---

## 3. Rendering

### 3.1 OSC 8 hyperlinks in `.Diff` — **FIXED**, before v1.0-audit

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
  the link before every `\e[K` it writes. This is now weaker than it was:
  v1.0-audit made **every frame start from a known state in all three modes**, so
  a link (or an SGR run) left open by the previous frame is closed at the head of
  the next one, and `.Full_Screen` also closes it before its own trailing
  `\r\n\e[J` (3.17). What is still yours is the **per-line** `\e[K`: a line that
  opens a link and never closes it before the end of that line may leave the
  erased tail of *that row* linked on some terminals. RuneGloss closes everything
  it emits.
- **An unterminated OSC 8 changes nothing.** No `ST`, no `BEL`, no link — acting
  on half a URI would open a link nobody asked for. See 3.9.

Pinned by eighteen tests in `runetea/render_test.odin`, of which the four that
matter most here are `test_diff_a_hyperlink_that_appears_is_opened_and_closed`,
`test_diff_a_link_whose_url_changes_repaints_the_run` (the zero-byte frame that
was the defect), `test_diff_never_clears_a_linked_tail_with_el` (the first
residual above) and `test_diff_an_unterminated_osc8_changes_nothing` (the
second).

### 3.2 Views may contain styling and hyperlinks, not motion — **INTRINSIC**, now checkable

`.Diff` models exactly two escapes per cell: SGR and OSC 8. A view containing a
C0 control byte (`\t`, `\r`, `\b`, `\a`), a cursor-motion CSI, an erase, a
window-title OSC, a sixel, or a truncated escape is *lying to the model* — it
renders correctly under `.Full_Screen` and wrongly under `.Diff`, and nothing
notices.

**This is now checkable and loud rather than only described:**

- `runetea.view_diff_safe(view) -> (ok, at, why)` is a public, allocation-free
  predicate. Call it in your own tests, on your own views.
- **Every build that is not optimised** asserts it on every frame and panics
  naming the byte offset and the reason. The gate is `VIEW_STRICT`, whose default
  is `ODIN_DEBUG || ODIN_OPTIMIZATION_MODE < .Speed` — so `odin build .`,
  `odin build . -debug` and `odin test` all check, and `-o:speed` /
  `-o:aggressive` compile the check out entirely. `DIFF_STRICT` defaults to
  `VIEW_STRICT`; force either with
  `-define:RUNETEA_VIEW_STRICT=true|false` / `-define:RUNETEA_DIFF_STRICT=true|false`
  (`runetea/contract.odin`).
- **`.Inline` and `.Full_Screen` are checked too**, one tier weaker.
  `view_render_safe` is `view_diff_safe` with `\t` permitted — neither mode has a
  cell model for a tab to lie to — and it still rejects cursor motion, because
  both modes **count the physical rows they painted** and a view that moves the
  cursor itself makes that count a lie. Under `.Inline` the next frame then
  erases the wrong rows, forever.

**Both halves of that used to be wrong.** The default was `ODIN_DEBUG`, so a
plain `odin build .` shipped with the check off; and only `.Diff` was checked at
all, so the two modes that count rows had no contract enforced on them. Pinned by
`test_render_contract_assert_is_silent_on_a_tab_and_loud_on_a_move` and
`test_diff_contract_assert_points_a_tab_at_the_modes_that_model_it`.

`\t` is the one that bites in practice: it is a *move* to the next tab stop,
whose position the cell model does not track. Expand tabs to spaces.
`examples/editor` does, in both its Tab key handler and — since this checker was
pointed at it — its document loader.

**What to do instead:** if your view genuinely needs a tab, use `.Full_Screen` or
`.Inline`, which model a tab's column effect (4.4) rather than pretending it has
none. If it needs to move the **cursor**, no mode will take it — all three count
the rows they painted, and there is no supported way to hand the terminal a
motion escape through a view. Emit the cursor position through `p.cursor`
instead, which is what it is for.

### 3.3 An inline frame taller than the screen — **FIXED**, before v1.0-audit, with a named residual

*Previously "the most user-visible unfixed rendering defect in the library".*
The inline renderer rewinds with `\e[<n>A`, which **clamps at the top margin**.
A frame taller than the terminal scrolls its own top rows into scrollback, so
the rewind walked up fewer rows than it asked for while the matching `\e[<n>B`
walked down all of them — "home" slid, and because `last_rows` kept
over-counting, the error **compounded every frame**. The display degraded
permanently instead of recovering.

`.Inline` now records **what the rewind can actually reach** rather than what it
painted: `min(rows, term_height - 1)`, which is provably the number of the
frame's own rows still on screen above the cursor (`runetea/render.odin,
render_inline` — "A FRAME TALLER THAN THE SCREEN"). The cursor park is clamped
to the same number, so the up/down pair stays symmetric by construction.

**IT DOES NOT TRUNCATE, unlike `.Full_Screen`/`.Diff` (3.4), and that asymmetry
is the point.** Those modes own an absolute origin and repaint it every frame,
so a line they refuse to paint is a line that would have destroyed the origin.
`.Inline` owns no origin and exists precisely to **leave its output in the
user's scrollback** — dropping lines would be the mode discarding the one thing
it is for, and it could not be undone later either, since the dropped rows would
already have scrolled past. Every line is still written, in full; only the
bookkeeping stopped lying.

**With the height unknown (0) the pre-fix behaviour is preserved exactly**, byte
for byte — no fd to query, a failed `ioctl`, output redirected, the golden
harness. There is no margin to clamp against and guessing one would be strictly
worse. Pinned by `test_inline_with_an_unknown_height_rewinds_every_painted_row`;
the fix itself by three byte-exact tests at known heights, including a one-row
terminal (where nothing is reachable, and the `\e[0A` that a naive clamp would
emit is *not* a no-op — a zero CSI parameter means one).

**Residual, and real:** the rows that scrolled off still hold the *old* frame's
text and no rewind will ever erase them, so scrolling far enough back shows
stale frames above the live one. Scrollback is not addressable; nothing can fix
that. It is bounded — the visible viewport is correct on every frame, and the
mode is exactly as it was the moment frames fit again.

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
parameter order precisely to avoid this (`runegloss/render.odin, build_sgr`'s "ONE SGR SEQUENCE PER STYLE");
nothing enforces it on views you write yourself.
**What to do instead:** emit one fixed spelling per style.

### 3.7 Style-table overflow forces a repaint — **INTRINSIC** (the degradation) / **FIXED** in v1.0-audit (the frame that overflowed twice)

Past `STYLE_TABLE_MAX :: 4096` distinct styles or `STYLE_BYTES_MAX :: 1 MiB`, the
table is dropped and the screen force-repainted, bounded to one retry per frame
(`runetea/screen.odin, STYLE_TABLE_MAX` and `runetea/render.odin, render_diff`'s style-overflow retry). Aliasing
two styles onto one index would be a silently wrong screen, which is the one
failure this design cannot tolerate.

**The bound was the bug.** A frame carrying more distinct styles than an *empty*
table can hold overflows, gets its retry, and overflows again — and the second
overflow was simply discarded. The diff was then computed from a model that had
silently kept the previous style for every cell past the cap, and the screen was
wrong with no diagnostic. That frame now falls back to `.Full_Screen`'s own byte
stream, byte-identical to a repaint, and leaves `force_repaint` set so the next
frame resynchronises from a real `\e[2J`. It is the single place `.Diff` degrades
and it now has exactly three callers: no known size (3.5), a frame the model
cannot represent, and the fault-injection hook. Pinned by
`test_diff_falls_back_to_a_repaint_when_one_frame_overflows_the_style_table`.

**When it still bites:** a view that manufactures unbounded distinct SGR strings
— a colour gradient recomputed per frame — repaints every frame and the mode's
whole benefit is gone. The same applies to the hyperlink table.

### 3.8 A wide cluster on the right margin diverges from xterm — **INTRINSIC**

RuneTea writes it *in* that column and clamps the cursor to the margin, which is
what pyte does; alacritty inserts a leading spacer and wraps, and foot pads with
spacers and forces a wrap (`runetea/screen.odin's header, "A WIDE CLUSTER AT THE LAST COLUMN"`).

**What changed in v1.0-audit is that the three RuneTea layers now agree.** This
entry used to say the divergence was "a consequence of `rows_for_line`'s ceil
division" and that the width layer and the cell model were "uniformly one cell
optimistic together". Both halves were false: `rows_for_line` divided,
`line_fills_its_rows` took a modulo, and `screen_put` walked placements, so the
three were not consistent — only consistently derived from the wrong quantity. A
line whose last cluster is wide and lands on the margin was counted as one row
too many, which drew the caret a row below its line and truncated lines that
would have fitted; and the `\e[K` decision was made from a modulo that could not
see the case at all, leaving stale characters on screen forever. Measurement,
the cell model and pyte now all come from one placement walk
(`runetea/width.odin, measure_line`).

**pyte was kept as the rule and xterm was not, deliberately**: pyte is the
independent oracle `tools/difftest` scores this package against, and picking the
terminal-family rule would have meant scoring against an oracle we had
overridden. It leaves one residual, in `.Inline` only: that mode has no cell
model — the real terminal is the painter — so on xterm-family terminals its
rewind is one row short for a line whose last cluster is wide and starts on the
last column. Over-counting instead would reintroduce 3.3's compounding failure,
which is strictly worse than one stale row. Fixing it properly needs a
margin-policy option on `measure_line`.

**When it bites:** a CJK or emoji line ending exactly at the right margin.

### 3.9 A truncated escape measures as zero width to the end of the string — **INTRINSIC**

`runetea/width.odin, display_width`'s truncated-escape rule. The terminal will consume the missing tail from
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

### 3.15 `view` must hand-thread its allocator into every allocation — **NOT-YET-BUILT**, and an API trap

`view` is handed a frame arena as a parameter named `alloc`, and everything
allocated from it is reclaimed wholesale when the frame ends. But every
allocating call in Odin — `fmt.aprintf`, `strings.builder_make`, `strings.clone`,
`rg.render` — takes its allocator as an argument with a **default that falls back
to `context.allocator`**. Omit it and the view string is heap-allocated and freed
by nobody: the loop resets the arena, and the arena never held it
(`runetea/tea.odin`, `runetea/arena.odin`).

It compiles, it renders identically, and it leaks **one view per frame** for the
life of the process. There is no type distinction between a correct view and a
leaking one, so nothing at the boundary can detect it.

**What you get is a warning on a passing test.** `odin test` on a package with
any test that drives `run()` prints `+++ leak` lines for it — measured on a
20-frame session — and then reports *"The test was successful."* It becomes a
gate only if you copy this repository's own `tools/test.sh` leak audit, which is
a repo tool a downstream user does not get.

A proposed automatic check — "assert in debug builds that the frame arena's
high-water mark moved" — was **rejected as unsound**: a view that legitimately
returns a constant string, or one built entirely from `strings.to_string` on a
builder the model owns, allocates nothing from the arena and is correct.

**What to do instead:** pass `alloc` explicitly at every allocating call in
`view`, in `cursor`, and in anything they call. Read the leak warnings your own
`odin test` prints; they name the line.

### 3.16 `Window_Size_Msg{0, 0}` is a sentinel, and it reaches `update` unfiltered — **INTRINSIC**

`SIGWINCH` fires, the watcher re-runs `TIOCGWINSZ`, and on failure — or when the
ioctl answers with a zero column or row count, which a pty with no size ever set
really does — it sends `Window_Size_Msg{0, 0}` rather than nothing
(`runetea/signals.odin`). Sending nothing would hide the event; sending the
sentinel lets an application distinguish "the size is unknown now" from "no
resize happened".

The loop guards **itself** against it, each axis separately, before touching the
renderer, and then passes the raw message through like any other
(`runetea/tea.odin`). Your `update` gets the zeros.

**When it bites:** `m.w, m.h = ws.w, ws.h` — the obvious line, and the one this
document's sibling `docs/API.md` printed unguarded until v1.0-audit — throws away
a known-good size and leaves the layout computing against zero columns.
**What to do instead:** `if ws.w > 0 { m.w = ws.w }`, likewise for `h`. Zero on
either axis means *unknown* everywhere in this library: the renderer reads an
unknown height as "do not truncate" (3.4, 3.5), `rows_for_line` reads an unknown
width as one row per logical line (4.6), and 0 is what your model holds before
the first `term_size`. It is a state your view must handle, not a nicety.
`examples/editor` guards it and unit-tests the guard.

### 3.17 A view that leaves an SGR run or a hyperlink open — **FIXED** in v1.0-audit

A view is a string, and nothing obliges it to close what it opened. It used to
cost, differently in each mode and all three badly. `.Inline` wrote its `\e[2K`
rewind **with the previous frame's pen still set**, so one unclosed style flooded
the whole erased region. `.Diff` re-accumulated the view's own escape onto last
frame's copy of it — `\e[41m`, then `\e[41m\e[41m`, then three — so every cell of
a static bar interned as a *different* style, compared unequal to itself, and
repainted forever at **+16 bytes per frame**, ending in a sawtooth of forced
repaints. And because `Screen.style` crossed frames while `.Full_Screen` did not
carry one, the two modes rendered the same view **differently** after any resize.

A frame now starts from the default SGR and with no hyperlink open, in all three
modes — and **conditionally**, so nothing that already closed its own styles pays
a byte: the reset is written only when the previous frame actually left one open.
Every existing byte-exact expectation, and every RuneGloss-rendered view, emits
exactly what it did before.

**Residual:** the per-line `\e[K` is still a view-side contract (3.1), and 7.2's
non-canonical resets are still invisible to both the model and the renderer.

Pinned per mode, because the defect was a different one in each:
`test_inline_resets_sgr_before_its_rewind`,
`test_full_screen_resets_sgr_before_the_trailing_ed`,
`test_diff_cost_does_not_grow_when_a_view_leaves_a_style_open` (the +16 bytes a
frame) and `test_diff_and_full_screen_agree_across_a_resize_with_an_open_style`
(the two modes disagreeing, which is the part no single-mode test could see).

### 3.18 `view` and `cursor` take the model BY VALUE, and Odin parameters are not addressable — **INTRINSIC**

`view: proc(model: T, ...)` and `cursor: proc(model: T, ...)` take the model by
value, deliberately: they are read-only, and `update`'s pointer signature exists
for a codegen reason (6.6) that does not apply to a parameter nothing writes
through. Odin procedure parameters are immutable **and non-addressable**, so
inside a view you cannot take the address of a field or slice a fixed-size array
one:

```
string(m.items[i].name[:m.items[i].n])
    // Error: Cannot slice array 'm.items[i].name[:m.items[i].n]',
    //        value is not addressable
```

Fixed-capacity arrays are exactly what the POD/no-GC rules push you toward, so
this lands on the first list or table anybody writes. (`&m.field` for
`rg.render` used to fail the same way; `rg.render` is a proc group now and takes
a `Style` by value, so that half is gone.)

**What to do instead:** one local copy of the model at the top of the view —
`mm := m` — which is addressable and lives for the body. Slice `mm`, write the
result into something allocated from `alloc`, and let the copy die. The idiom is
worked in `docs/API.md` §6.

**The obvious shortcut is a use-after-return, and it does not warn.**
`mm := m; return string(mm.items[0].name[:n])` compiles and hands back a string
pointing into a dead stack frame — measured, it comes back as
`"\x00\x00\x00\x00\x00"`. The local is only good for the body. The copy is also
the whole model, so hoist it out of any loop; for a model measured in kilobytes,
the shape to reach for is a smaller `T` holding a pointer to storage you own,
which is legal for a *model* even though it is illegal for a `Msg` (2.1).

### 3.19 The hardware caret in the viewport-owning modes — **FIXED** in v1.0-audit

`.Full_Screen` and `.Diff` never hid the terminal's own caret, so a program that
declared no `Cursor` left it parked on top of whatever cell the last write landed
on — blinking over the content, moving every frame, and under `.Diff` landing
somewhere different each time depending on what changed.

The mode that owns the viewport now hides the caret and **leaves it hidden**,
showing it again only on a frame that declares `Cursor{show = true}` and on
`renderer_clear`. The cost is exactly one `\e[?25l` on the first frame; the
paired `\e[?25h` comes from `term_restore` on every exit path including signals,
which `cursor_hide_arm` already guaranteed. `.Inline` is unchanged byte for byte:
it does not own the viewport, so it hides only around a frame that declares a
cursor or rewinds. **An identical `.Diff` frame still costs zero bytes** — the
extra condition on the hide is what preserves that. Pinned by
`test_full_screen_hides_the_caret_it_owns` and
`test_diff_hides_the_caret_it_owns`.

**`.Inline` had no way to ask for the same thing, and asking by hand stranded the
user's shell.** That is the half this entry omitted when it was first written.
`Cursor{show = false}` is the zero value and reads as "no opinion", not "hide it",
and the arming call that promises the paired `\e[?25h` was package-private — so an
`.Inline` application that simply did not want a blinking block in its output had
to write `"\e[?25l"` itself and got **no** show back from `term_restore`, from the
crash handlers or from the stop path. Measured on a pty: exit status 0, hides=1,
shows=0, and a shell left with an invisible caret recoverable only by blind-typing
`reset` or `tput cnorm`. `Term_Opts` now carries a sixth opt-in,
`cursor_hide: bool` (`runetea/term.odin, Term_Opts`) — `CSI ? 25 l` on acquire and
`CSI ? 25 h` from `term_restore_c` on **every** exit path, exactly like the other
five, which also means it is replayed automatically on `SIGCONT` (an app's own
write is not; `fg` after a `Ctrl+Z` would have shown the caret again for the rest
of the session). A per-frame `Cursor{show = true}` still wins over it: the field
is the session's default, not a veto. Measured on the same probe shape afterwards:
an `.Inline` session declaring it writes `\e[?25l` at acquire and once more on its
first frame (six bytes, deliberate — `render.odin` consults the declaration so its
per-frame pairing does not undo it sixty times a second) and exactly **one**
`\e[?25h`, from `term_restore`, as the last thing before the paste teardown.
Pinned by
`test_a_declared_cursor_hide_writes_the_hide_and_term_restore_writes_the_show`,
`test_a_declared_cursor_hide_is_written_inside_the_alt_screen_and_shown_outside_it`,
`test_a_declared_cursor_hide_is_shown_again_when_the_process_dies_by_signal`,
`test_a_declared_cursor_hide_comes_back_on_the_resume_path` and
`test_an_inline_session_that_declared_cursor_hide_hides_once_and_never_shows`.

### 3.20 An `.Inline` frame of R rows needs R+1 terminal rows — **INTRINSIC**

`render_inline` (`runetea/render.odin`) terminates **every** line it paints with
`\r\n`, the last one included, because the next frame's rewind counts
`\e[1A\e[2K` pairs upward from column 1 of the row *below* the frame and there
has to be such a row. So a one-row view needs a two-row terminal, a three-row
view needs four, and **at one terminal row `.Inline` can show nothing at all**:
whatever is written scrolls itself off, `reachable` clamps to `term_height - 1`
= 0, and no rewind is ever emitted. The screen is blank for the whole session.

Measured on a real pty at 60 columns, by replaying the bytes through pyte:
`examples/spinner` at one row paints an empty screen and keeps doing so;
`examples/simple` at exactly three rows loses the greeting that tells the user
how to quit; `examples/quickstart` at exactly seven loses the question it exists
to ask. All three had a minimum-size guard at the time, and all three guards
were one row short, because the `\r\n` after the *last* line is easy to forget
and nothing in the API mentions it.

**Why it is INTRINSIC rather than a bug.** Dropping the final `\r\n` would put
the cursor at the end of the frame's last line instead of below it, which is
where `.Inline`'s whole contract lives: the frame is left in the user's
scrollback and the shell prompt continues after it. It would also make the
rewind's row count depend on where the last line ended, which is exactly the
class of arithmetic 3.3 removed. The row is the price of the mode.

**What to do instead:** size your minimum against the frame you paint **plus
one** — `MIN_ROWS :: <rows view() paints> + 1`, written as an expression so
adding a line cannot make it stale. All four single-file examples do this now,
and each pins it with a test that measures its own view through
`rt.rows_for_line` rather than asserting a number:
`test_the_quickstart_minimum_height_leaves_a_row_for_inlines_terminator` and
its three siblings. Below the minimum, paint **one** row (which is all that can
be relied on) rather than a shorter version of the real frame.

**Residual, and it is not the example's to fix:** at one row there is no frame
of any shape that survives, so a "too small" message cannot be shown either.
`examples/spinner` responds by stopping its animation — ten writes a second into
a window that shows none of them is pure cost — and resuming on the resize back
up (`test_a_height_below_the_inline_minimum_stops_the_animation_tick`). The
viewport-owning modes are immune: `.Full_Screen` and `.Diff` address every row
absolutely and truncate at the bottom (3.4) instead of scrolling.

---

## 4. Unicode and width

### 4.1 Unicode data is pinned to UCD 15.1.0 — **NOT-YET-BUILT** (blocked on `core:unicode`)

`runetea/width.odin`'s header; *"unaddressed by design… out of scope
here. Noted, not fixed"*
(`docs/superpowers/render-width-decision.md:230-236`).

**When it bites:** any emoji or script added in Unicode 16 or 17 measures with
stale grapheme-break and width properties. New ZWJ sequences can split into
multiple clusters and blow the column count, desynchronising the inline rewind
or putting a caret in the wrong column.

### 4.2 East-Asian *Ambiguous* width is a global boolean you must guess — **INTRINSIC**

There is no universally correct answer and the terminal does not report it
(`runetea/width.odin, Width_Options.ambiguous_is_wide`). Default is narrow, matching `core:unicode` and
xterm.

**When it bites:** a user on a CJK-locale terminal that renders box-drawing
characters, curly quotes, Greek and Cyrillic double-wide sees every border and
every box layout ragged.
**What to do instead:** expose `Width_Options{ambiguous_is_wide = true}` as a
user setting. RuneTea cannot detect it for you.

### 4.2a Emoji width is a second question terminals disagree about — **INTRINSIC**, and now selectable

Same shape as 4.2, one layer up: `display_width` measures one extended grapheme
cluster as one advance, and most of the terminals actually deployed advance **per
character** instead. Driven live against VTE 2.91 (GNOME Terminal's engine,
`python3-gi`, 60 columns, calibrated first on `"abcdefg"`→7 and `"中文"`→4, then
reading `get_cursor_position()` after each cluster):

| cluster | VTE | default (`.Grapheme_Cluster`) | `.Legacy_Wcwidth` |
|---|---|---|---|
| `abc` | 3 | 3 | 3 |
| `中文字` | 6 | 6 | 6 |
| 👍 (U+1F44D) | 2 | 2 | 2 |
| 👍🏽 (skin tone) | 4 | **2** | 4 |
| 🇯🇵 (RI flag) | 2 | 2 | 2 |
| 👨‍💻 (ZWJ) | 4 | **2** | 4 |
| 1️⃣ (keycap) | 1 | **2** | 1 |
| ❤️ (VS16) | 1 | **2** | 1 |

Four of ten wrong on the terminal that ships with GNOME, **in both directions** —
two columns too few for the skin-tone and ZWJ clusters, so a RuneGloss right
border hangs two columns outside the frame; one column too many for the keycap and
the VS16 heart, so it sits one column inside it.

**There is no set of better numbers to switch to.** kitty, WezTerm, foot and
Ghostty advance one cluster width for exactly the inputs VTE splits, so adopting
VTE's answers would move the raggedness onto them. What was missing was any way to
*say which terminal you are on* — and any way to detect that the question is open
at all:

<!-- doccheck: body -->
```odin
s := "\U0001F468\u200D\U0001F4BB"
// Is this string's width a matter on which terminals disagree?
shaky := rt.display_width(s) !=
         rt.display_width(s, rt.Width_Options{emoji_width = .Legacy_Wcwidth})
_ = shaky
```

`Width_Options.emoji_width` (`runetea/width.odin, Emoji_Width`) selects between
`.Grapheme_Cluster` (the zero value, and this library's behaviour since before the
option existed — right for kitty, WezTerm, foot, Ghostty, anything answering DEC
mode 2027) and `.Legacy_Wcwidth` (the sum of the runes' own widths, no cluster
folding — right for every VTE-based terminal, alacritty, xterm, tmux and screen).
RuneGloss exposes it as `rg.emoji_width(&s, p)` beside `rg.ambiguous_wide`, and it
reaches every measurement a `Style` makes.

**The default is deliberately not the most-deployed answer.** `.Legacy_Wcwidth`
matches more terminals, and making it the default would silently re-rag every box
that lines up today on the terminals that were already right. The default has to
be the one that changes no existing frame.

**When it bites:** a bordered or aligned block containing emoji, on the other
family of terminal from the one you tested on. **What to do instead:** expose it
as a user setting, exactly as 4.2 advises for Ambiguous width — RuneTea cannot
detect it for you either. Pinned by
`test_display_width_legacy_wcwidth_matches_a_measured_vte`,
`test_display_width_emoji_policy_defaults_to_the_cluster_answer`,
`test_measure_line_wraps_by_the_emoji_policy` and
`test_emoji_width_policy_squares_a_box_on_a_per_character_terminal`.

A cluster's width is **no longer bounded by 2** under `.Legacy_Wcwidth`: the
four-emoji ZWJ family measures 8. Every measuring path in `width.odin` handles
that, but code of your own that assumed "1 or 2" from a cluster iterator does not.

### 4.3 Only 16 runes per cluster are inspected for the width corrections — **INTRINSIC**

`MAX_INSPECTED_RUNES :: 16` (`runetea/width.odin, MAX_INSPECTED_RUNES`). A cluster longer
than that keeps the iterator's own width and loses the VS16 / regional-indicator
/ leading-mark corrections. Real ZWJ family emoji stay under a dozen runes; this
is a hostile-input concern.

### 4.4 A tab's width depends on where the string starts — **INTRINSIC**, and it breaks composition

`\t` is the one C0 byte with a defined column effect, and v1.0-audit made the
width layer model it: it advances to the next multiple of `tab_stop`
(`TAB_STOP_DEFAULT :: 8`) counted from `Width_Options.start_col`, rather than
measuring 0 (`runetea/width.odin`). Set `tab_stop` to a negative number to get the
old zero-width reading back.

**The composition law does not survive it.** `display_width(a) + display_width(b)`
is no longer `display_width(a + b)` once a tab is involved, because the tab in `b`
is measured from column 0 in the first form and from `display_width(a)` in the
second. `start_col` is the honest answer: tell the measurement which column the
string is laid out from. `display_width("\tx")` is 9; with `start_col = 3` it is 6.

`display_width` also measures against an **infinitely wide** terminal — no wrap,
no margin clamp — because it has no `term_width` to clamp against. `measure_line`
is the one that knows about a margin, and there a tab never wraps: it clamps to
the right margin rather than moving to the next row, which is what pyte does.

**What it cost before:** a single `\t` in an `.Inline` view under-counted its own
rows, so the rewind erased one row too few and the frame **slid one row down the
screen every frame, forever**, leaving a ladder of stale frames behind it. Pinned
by `test_display_width_tab_advances_to_the_next_tab_stop`,
`test_display_width_tab_composition_holds_only_through_start_col` and
`test_inline_rewinds_the_rows_a_tab_actually_painted`. `.Diff` still refuses a
tab outright (3.2) — the cell model has no tab stops to track.

### 4.5 A cluster split by an embedded escape measures as two clusters — **INTRINSIC**

`"e" + "\e[0m" + U+0301` is two segments, not one cluster
(`runetea/width.odin, cluster_next`'s escape pre-pass). Harmless in the cases that occur (both paths give
width 1) but a real divergence from strict UAX #29.

### 4.6 Unknown terminal width means "one row per logical line" — **INTRINSIC**

`measure_line` (and therefore `rows_for_line`) returns 1 row with no width, which
is the only sound default with zero information — and it is what makes every
byte-exact render test possible at all, since none of them supplies an fd
(`runetea/width.odin, measure_line`).

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
  unrecognised SS3 (`:1487-1500`, pinned by `test_esc_o_ambiguity`).
- **An unterminated bracketed paste** strands at most five held-back bytes — a
  proper prefix of the terminator — so nothing wedges and the loop keeps making
  progress; what persists is the paste *mode*, until the process exits
  (`:1378-1388`).

**The Kitty keyboard protocol removes the first two entirely.** With
`Disambiguate` negotiated, Escape arrives as `CSI 27 u` — a complete,
unambiguous sequence with a final byte — and `Ctrl+[` arrives as `CSI 91;5 u`.
They are simply different byte strings (`runetea/input.odin, kitty_decode`).

**RuneTea does NOT request Kitty by default.** This entry claimed the opposite
until v1.0-audit, which meant it advertised a mitigation nobody was getting.
`term_enter_raw`'s `Term_Opts.kb` defaults to `{}`, and `{}` is documented in
`runetea/term.odin` as *"do not touch the terminal's keyboard"* — nothing is
written, no `CSI > n u`, no `CSI ? u`, and therefore **no
`Keyboard_Enhancements_Msg` ever arrives**. Verified on a real pty:
`examples/spinner` (`{kb = {.Disambiguate}}`) opens with `\e[>1u\e[?u`;
`examples/quickstart` (`{paste = true}`) writes neither.

**Two of the five examples are fully exposed to this, including the front-page
one.** `examples/quickstart` and `examples/simple` call
`term_enter_raw(fd, {paste = true})` and **both quit on Escape**, so the
split-escape path in the first bullet above is live for them. That is a
deliberate choice — the quickstart's job is to be the smallest complete program,
and a Kitty negotiation in it is one more line a newcomer has to not understand —
but it is a choice you inherit if you copy it.

**What to do instead:** pass `{kb = {.Disambiguate}}` to `term_enter_raw`, and
check the `Keyboard_Enhancements_Msg` reply so your application knows which world
it is in — `examples/editor` prints `kitty:on`/`kitty:off` in its status line for
exactly this reason, and hides its `Ctrl+I` binding from the header when the
answer is off, because with Kitty off that byte *is* Tab. On a terminal with no
Kitty support, a user who presses Escape *as the last byte of a read* gets
Escape, which is what they meant > 99% of the time; the residual risk is an
ESC-prefixed sequence split across a read boundary, which requires a terminal
writing a partial escape and a read landing inside it. **If your program quits on
Escape and cannot negotiate Kitty, do not quit on Escape** — bind `q` or `Ctrl+C`
as well, which is what the two exposed examples do.

### 5.2 Legacy (X10) mouse coordinates wrap past column 223 — **INTRINSIC**

The X10 encoding packs a coordinate into one byte as `coordinate + 32`, so
column 224 encodes as byte 0 and is indistinguishable from garbage. It clamps to
0 rather than reporting a negative index (`runetea/input.odin, x10_mouse`).

**This limitation is the entire reason `term_enter_raw` always requests
`?1006h`** (SGR extended coordinates) alongside every tracking mode
(`runetea/term.odin, MOUSE_ON_NORMAL`/`MOUSE_ON_BUTTON`/`MOUSE_ON_ANY`, each of which pairs its tracking mode with `?1006h`). SGR reports coordinates as decimal parameters
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

### 5.5 There is no terminfo consultation — **NOT-YET-BUILT**, assessed as closed for v1.0; both named gaps are now **FIXED** in v1.0-audit

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
alacritty/foot/kitty/wezterm all emit xterm sequences), and the two populations
where it did not hold **were the two things terminfo would have bought. Both are
now decoded directly, so terminfo would buy nothing at all:**

- **The Linux virtual console's F1–F5** (`\e[[A` … `\e[[E`) now decode as
  `.F1`–`.F5`. They needed their own arm ahead of the parameter scan, because
  `[` (0x5B) is a legal CSI *final* byte: the old grammar consumed `\e[[` as an
  unknown CSI and **typed the trailing letter into the application** — pressing
  F1 on a bare TTY inserted a capital `A`. A letter outside A–E is now consumed
  whole and emits nothing, and `\e[[` alone holds back for its letter. Pinned by
  `test_linux_console_function_keys_decode`.
- **rxvt / rxvt-unicode's modified keys.** All twelve `$`/`^`/`@`-final forms —
  Shift, Ctrl and Ctrl+Shift on kDC/kIC/kHOME/kEND/kNXT/kPRV — now decode through
  the existing tilde table with the modifier taken from the final byte. These
  used to **leak their parameter digits and the `$` into the application as
  runes**, and to swallow the *next* keystroke as well, because a CSI ending on
  an intermediate byte resynchronised two bytes in. Pinned by
  `test_urxvt_modified_tilde_keys_decode`,
  `test_urxvt_dollar_keys_do_not_eat_the_next_keystroke` and
  `test_the_dollar_arm_does_not_steal_decrpm` — the last one because `$` is also
  a legitimate *intermediate* byte in a DECRQM reply, so the new arm requires a
  bare decimal parameter run and cannot steal one.

rxvt's **lowercase-final** arrows (`\e[a`, `\e[b`) remain on the cleanly-ignored
list (5.12); they are a vocabulary question, not a leak.

Everything else missed is the keypad application-mode block (`\eOw`, `\eOx`, …,
`\eOM` for keypad Enter) and F13–F20, which `Key_Code` has no members for. Those
are vocabulary gaps, not table gaps: terminfo would not help.

**Verdict: document and close for v1.0**, more firmly than before. Consulting
terminfo is a large, real piece of work (parsing the binary format or shelling
out to `infocmp`, plus a runtime-built trie and a fallback for `TERM` values with
no entry), and the measurement that justified it has now been paid off directly.

### 5.6 Shift+Tab — **FIXED**, before v1.0-audit

`CSI Z` (`kcbt`) now decodes as `Tab + {.Shift}`. It was previously on the
cleanly-ignored path, so **Shift+Tab did nothing on 21 of the 40 terminfo
entries installed here** — xterm, xterm-256color, tmux, screen, rxvt,
rxvt-unicode — unless the Kitty protocol happened to be negotiated, under which
the same keypress *did* decode (`CSI 9;2u`). "Previous field" is a standard
binding in every form-shaped TUI, and this was the highest-value finding of the
terminfo measurement. Pinned by `test_shift_tab_decodes_from_csi_z`,
`test_shift_tab_keeps_its_shift_when_another_modifier_is_present` and
`test_shift_tab_agrees_between_the_legacy_and_kitty_encodings`.

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

Press *and* release. No example filters on `kind`, and every example says so
where it chooses its flags rather than leaving the reader to find out
(`examples/editor/main.odin`). If you enable it, filter on `Key_Msg.kind`.

### 5.11 `CSI R` is decoded as F3 — **INTRINSIC** collision

A cursor position report (`CSI <row>;<col> R`) and modified F3 (`CSI 1;<mod> R`)
are the same bytes when row == 1. Resolved as F3, which is safe **only because
RuneTea never issues a DSR 6n** (`runetea/input.odin, `decode_keys`' "cursor position reports" note`). If you issue
one yourself, this is the collision to revisit.

### 5.12 Other cleanly-ignored input — **NOT-YET-BUILT**, mostly vocabulary

Consumed whole, emitting nothing: DECSET 9 (X10 press-only tracking), unpaired
`CSI 201~`, Kitty set/push/pop requests, F13–F35, the keypad block, media keys,
lone modifier keypresses, `Begin` (`CSI E`), and rxvt's lowercase-final arrows
(`runetea/input.odin, `decode_keys`' CLEANLY IGNORED list`). None of these leaks garbage runes; that
contract is tested, over these sequences.

**The list used to carry two entries that did leak, and the header above them
claimed otherwise.** The Linux console's F1–F5 and urxvt's `$`-final keys were
both on the cleanly-ignored list, both typed bytes into the application, and one
of the two bullets contradicted the list's own header three lines later by
conceding that "the `[` is a final byte and the letter is left over". Both are
now genuinely decoded (5.5), so the header is true of what remains rather than of
what was convenient to enumerate.

### 5.13 Terminal replies (OSC / DCS / APC / PM / SOS) — **FIXED** in v1.0-audit (the leak) / **NOT-YET-BUILT** (surfacing them)

A terminal answers queries. An OSC colour reply, an XTVERSION string, a DCS
payload — all of them used to reach `decode_keys` with no parser at all, which
meant the escape introducer was consumed and **the payload was typed into the
application as keystrokes**: a colour reply became `rgb:...` in your text field.

All five string-escape forms are now scanned to their terminator: `ST` in both
spellings, `BEL` for OSC only (a DCS or APC payload may legitimately contain
0x07), and `CAN`/`SUB` as ECMA-48 cancels. An `ESC` not followed by `\\` aborts
the string and is handed back to the main loop, so a real key sequence arriving
after a malformed reply still decodes. An incomplete one holds back, the same
discipline the CSI path already has. Pinned by
`test_string_escapes_are_consumed_whole` and
`test_string_escapes_are_literal_text_inside_a_paste`.

**Nothing is DECODED from them — they produce no `Msg`.** OSC 8 hyperlinks, OSC
10/11 colour replies and XTVERSION are all consumed and dropped, because none of
them has a `Msg` type to become and inventing one is a separate unit (8.1's
"terminal response decoder"). **What it costs a caller:** the byte accounting
changed. A `consumed` count over a buffer containing a string escape is now the
whole sequence rather than 1, and a decoder that assumed `decode_keys` never
holds back more than about six bytes is wrong — an unterminated string escape
holds back until it terminates or is cancelled.

### 5.14 8-bit C1 introducers, and xterm's `modifyOtherKeys` — **FIXED** in v1.0-audit

`0x9B` (CSI), `0x8F` (SS3), `0x90` (DCS), `0x9D` (OSC), `0x9E` (PM), `0x9F` (APC)
and `0x98` (SOS) used to decode as `U+FFFD` followed by the payload leaking out
as runes. Every grammar now dispatches from an introducer gate that resolves both
the 7-bit and the 8-bit spelling into one pair of values, so `\x9b` and `\e[` take
the same path. A C1 byte that introduces nothing decodes as `Alt +` the C0 it
shadows, which is xterm's `eightBitInput` meta encoding.

`CSI 27;<mod>;<code>~` — xterm's `modifyOtherKeys` reports — used to be dropped
twice over, by a parameter-count gate and by a table that lists 27 as unassigned.
They now decode, reusing Kitty's key-code mapping because the payload *is* a
Unicode key code in exactly that sense.

**Deliberately not recognised:** 8-bit bracketed paste (`0x9B 200~`). The paste
END is matched inside the paste branch against a byte string, so a still-arriving
terminator can be compared against a prefix of itself; recognising an 8-bit
START without an 8-bit END would wedge the decoder in paste mode for the rest of
the session. An 8-bit `CSI 200~` is cleanly ignored instead.

Pinned by `test_eight_bit_c1_introducers_decode`,
`test_eight_bit_introducers_hold_back` (a C1 introducer split across two reads
must not be resolved early), `test_plain_c1_bytes_decode_as_alt_plus_their_c0`
and `test_modify_other_keys_reports_decode`.

### 5.15 `TERM=dumb` and an unset `TERM` — **FIXED** in v1.0-audit

`TERM=dumb`, an empty `TERM` and no `TERM` at all used to be honoured for
**colour only**: RuneGloss picked `.None`, and RuneTea then wrote its full escape
repertoire at the same terminal regardless.

`term_supports_escapes()` is now public and false for all three, and
`term_enter_raw` gates **all six opt-ins** on it: raw mode is still granted (it
is line discipline, and the program still runs) but not one escape sequence goes
out, and because the guard flags stay false the paired teardown stays silent too.
It is deliberately a `TERM` test and not a terminfo lookup, for the reasons in
5.5. Pinned by `test_a_dumb_terminal_gets_no_escape_sequences` and
`test_term_supports_escapes_accepts_an_ordinary_terminal`.

**The renderer degrades with them, and this entry used to say it did not.** It
read *"the renderer is not gated … call `term_supports_escapes()` yourself before
choosing `p.render_mode`, and pick `.Inline`"* — which was true for exactly one
wave, was invalidated by the `render_plain` fix, and was still being printed as
advice afterwards. Migration note for anyone who followed it: that hand-rolled
mode switch is now redundant, and harmless (`.Inline` degrades to the same plain
writer as the other two).

What is true now: `guarded_render` (`runetea/tea.odin, guarded_render`) — the one
paint path `run()` and `run_nbio()` share — sets `Renderer.plain` from
`term_supports_escapes()` once per frame, and `renderer_render` routes to
`render_plain` (`runetea/render.odin, render_plain`) **ahead of** the mode
dispatch, the DECTCEM pair and `.Diff`'s early return, because each of those three
emits addressing of its own. No CUP, no `\e[H`, no `\e[2J`, no `\e[K`, no
SGR, no `\e[?25l`/`\e[?25h` — and **the view's own escapes are stripped**, which
is the one decision that goes beyond "the renderer emits nothing" and is argued
where it is made: RuneGloss drops *colour* at a `.None` profile but still emits
*attributes*, an application may hand-roll an SGR of its own, and at this terminal
neither would be seen — they would be printed. Measured end to end: the flagship
editor over a real pty at 100×30 is 2,918 bytes under `TERM=dumb` and 2,918 under
no `TERM`, containing **not one `0x1B` byte** — against 2,065 bytes and 91 of them
under `TERM=xterm-256color` from the same binary and the same keystrokes.
Pinned by `test_a_dumb_terminal_gets_a_session_with_no_escape_sequences` (end to
end through `run()`, with an `xterm-256color` control that proves the assertion is
about `TERM` and not about a script that never produced an escape),
`test_a_plain_renderer_writes_not_one_escape_in_any_mode` and
`test_a_plain_frame_keeps_every_byte_that_is_not_part_of_an_escape`.

**Three things this deliberately does NOT change.** `.Inline`'s frames are *appended*
rather than rewound-and-replaced, since the rewind is itself the escape that may
not be written — a dumb-terminal transcript is the views in order, which is the
only sensible reading of scrollback at a terminal with no cursor control.
`Renderer.plain` is `false` in a Renderer built by `renderer_init` and set only by
the host, so an **embedder driving `renderer_render` itself** is not gated and has
to set the field (deliberate: the alternative makes byte-exact renderer tests pass
or fail by the shell they run under — see `runetea/render.odin, Renderer` on
`plain`). And `term_enter_raw` returns **true** under `TERM=dumb` rather than
false: it granted line discipline, which succeeded, so an application's "not a
tty" branch does not fire — the capability question is a separate one and
`term_supports_escapes()` is the proc that answers it.

---

## 6. Terminal state and crash safety

### 6.1 Nothing restores the terminal on `SIGKILL` or `SIGSTOP` — **INTRINSIC**

The crash handler covers eleven signals — `SIGSEGV SIGBUS SIGILL SIGFPE SIGABRT
SIGTRAP SIGHUP SIGQUIT SIGTERM SIGINT SIGPIPE` — plus the job-control pair
`SIGTSTP`/`SIGCONT` (`runetea/guard.odin`, `install_crash_handlers`). `SIGKILL`
and `SIGSTOP` cannot be caught by anything, ever.

**What an uncatchable signal actually strands is more than this entry used to
say.** It said "raw mode and possibly the alternate screen"; the leak is in fact
**the exact set of opt-ins the application asked for**, and for `examples/editor`
— Kitty `.Disambiguate` + bracketed paste + `.Normal` mouse + alt screen — that
is **five** things, measured:

| Left set by `kill -9` | Sequence never written back |
|---|---|
| raw mode | the saved `termios` is never restored |
| one Kitty keyboard-stack entry | `\e[>1u` pushed, `\e[<1u` never popped |
| the alternate screen | `\e[?1049h` set, `\e[?1049l` never written |
| mouse tracking with SGR coordinates | `\e[?1000h` + `\e[?1006h` set, never cleared |
| bracketed paste | `\e[?2004h` set, `\e[?2004l` never written |

**Mouse tracking is the most user-visible of the four escape-level leaks**, and
the one this entry omitted entirely: it injects `\e[<0;12;7M`-style garbage into
the shell's command line on every click and every scroll flick, which is why
`term_restore_c` clears it before the cursor.

Two things this list deliberately does *not* claim. **Focus reporting**
(`\e[?1004h`) leaks only for an application that enables it — `examples/editor`
does not. **The cursor is normally left visible, not hidden**: a frame ends by
showing the caret, so an invisible cursor is the narrow mid-frame race 6.2
already argues, not the normal outcome. Under `TERM=dumb` or no `TERM` none of
the escape-level leaks can happen at all, because the enables were never written
(5.15) — only raw mode leaks there.

**A sixth item joined the table for applications that declare it.** `Term_Opts`
gained `cursor_hide` (3.19), and `\e[?25l` set that way is exactly as
unrecoverable from `kill -9` as the other five — a shell with no caret at all,
which is the least legible of the six to a user who does not know what happened.
It is not in the table above because `examples/editor` does not set it; an
application that does inherits a sixth row.

**Recovery is still `reset`, typed blind**, and it clears all of them.

### 6.1a Ctrl+Z used to strand the terminal too — **FIXED** in v1.0-audit

`SIGTSTP` is catchable, and nothing caught it: suspending an app with Ctrl+Z left
the *shell* running against a raw tty, on the alternate screen, with mouse
reporting on. `install_crash_handlers` now installs a `SIGTSTP`/`SIGCONT` pair
(exposed separately as `install_stop_handlers()` for an application that
re-installs its own handlers and needs to put these back).

`SIGTSTP` captures the acquired state, restores the terminal, sets the signal
back to `SIG_DFL`, unblocks it and re-raises — so **the process genuinely stops**,
rather than a handler quietly returning and pretending to. On resume the mask and
the handlers are restored, `term_acquire` re-runs with the captured options, and a
process-directed `SIGWINCH` is kicked so `run()`'s watcher emits a
`Window_Size_Msg` in case the window changed while you were stopped. `SIGCONT`
covers the stop that cannot be mediated (`SIGSTOP`) by re-applying on the way
back. Pinned by
`test_a_job_control_stop_restores_the_tty_and_a_resume_re_acquires_it` and
`test_install_crash_handlers_covers_sigpipe_sigint_and_job_control`.

**The resume also forces a repaint now, and it did not at first.** This entry
used to stop at the synthetic `SIGWINCH` above, which is not the same thing: a
`Window_Size_Msg` says the size *may* have changed, and `renderer_set_width` /
`renderer_set_height` set `.Diff`'s `force_repaint` only when it actually **did**.
So `fg` at an unchanged window size resumed into a diff against a cell model that
still described the pre-stop frame — while your shell had, in the meantime,
printed its prompt and your next command's output over it. `.Diff` then patched
only the cells it believed had changed and left the shell's text on screen **for
the rest of the session**: the same permanent corruption the stop handling exists
to prevent, arriving through the resume instead. Both handlers now also call
`request_repaint` (`runetea/render.odin, request_repaint`), a process-global
atomic flag the next frame consumes, which is the only shape a `proc "c"` signal
handler with no arguments could use to reach a `Renderer` that lives on `run()`'s
stack. Measured over a real pty at 70×16 with a `.Diff` app and no alt screen:
`SIGTSTP`, then a shell prompt written over rows 1–2, then `SIGCONT` — the frame
comes back whole with no keypress, where the interloper's text used to sit there
until the program exited. Pinned by
`test_a_repaint_request_makes_an_unchanged_diff_frame_repaint`,
`test_a_repaint_request_stops_the_next_inline_frame_rewinding` and
`test_a_repaint_request_re_hides_the_caret_the_teardown_showed`.

`request_repaint` is **public**, because the framework is not the only thing that
can lose the screen: an application that shells out to `$EDITOR`, `less` or a
`git` pager comes back to exactly the same wreckage, and before this there was no
way to say so. It is idempotent, costs one atomic store, and is consumed by the
following frame — a request that lands mid-frame is honoured by the next one
rather than dropped.

### 6.2 A short `write` dropping the tail of a frame — **FIXED**, before v1.0-audit

`flush_frame` used to be a single, unlooped `posix.write` whose result was
discarded. `write(2)` may transfer fewer bytes than asked and report success, so
a large frame on a congested tty was silently truncated — **possibly
mid-escape-sequence**, leaving the terminal reading the next frame's bytes as
arguments to a sequence that was never finished.

`flush_frame` now loops until the whole buffer is out (`runetea/tea.odin`,
`flush_frame`/`write_all`): a short return is progress, `EINTR` retries
verbatim, `EAGAIN` yields and retries (the same "transient, retry; terminal,
give up" policy every producer in this codebase already applies to a full
Mailbox). Pinned by a test that forces real short writes through a non-blocking
pipe.

**On an unrecoverable error the session ends with `Terminal_Error`** — including
its `errno`, which the type now carries, because "write to the terminal failed"
cannot be acted on and "…: EBADF" can. Not a panic: this runs mid-frame with the
terminal raw and possibly on the alternate screen, and the one thing that must
still happen is the caller's `defer term_restore()`, which an ordinary unwind
gets and a panic does not. Not silence either: EIO/EPIPE/EBADF all mean the
terminal is gone, so continuing would be rendering to nothing at full frame
rate, forever. `run()` and `run_nbio()` both propagate it, pinned end to end by
`test_run_ends_with_a_terminal_error_when_the_frame_cannot_be_written`.

**`cursor_hidden` is still sticky, and its comment now says why honestly.** The
old justification was purely this bug — one subsystem working around another —
but two independent reasons survive the fix, neither fixable from the writing
side: a **crash signal** can land between the write that carried the leading
`\e[?25l` and the one that would have carried the trailing `\e[?25h` (the dying
process runs no `defer`s, so only `crash_handler` → `term_restore_c`, reading
that flag, shows the cursor again — pinned by
`test_cursor_shows_on_the_crash_path_after_a_truncated_frame`), and an
**unrecoverable write error** mid-flush leaves exactly the same asymmetry.
Sticky costs an idempotent extra `\e[?25h` at teardown; non-sticky costs an
invisible cursor forever (`runetea/term.odin, cursor_hide_arm`).

**Residual:** `posix.write` is still unlooped in `term.odin` itself. Those are
single sequences of at most 16 bytes written outside any frame, and two of them
(`kitty_enable`, `paste_enable`) already reason explicitly about what a partial
write means for their rollback flags. A short write there is a different, much
smaller hazard than a truncated frame, and it is not addressed here.

### 6.3 A crash in a two-instruction window can emit an unpaired reset — **INTRINSIC**

Every terminal opt-in sets its flag *before* writing, so the restore assumes
"set" whenever it is not certain we did not set it
(`runetea/term.odin, kitty_enable`, `paste_enable`, `alt_enable`). A crash between the flag
and the `write()` can pop a Kitty stack entry belonging to the shell. This is
argued explicitly as the right direction to be wrong in.

### 6.4 `guarded()` is not nestable on one thread — **INTRINSIC**

One `jmp_buf` per thread. A nested call returns `recovered = true` *without
running the body* rather than corrupting the jump target
(`runetea/guard.odin, guarded`). **When it bites:** calling `guarded()` from inside
`update`, `view`, or a Cmd body silently skips your body.

### 6.5 Bounds violations and nil derefs are **not** recoverable — **INTRINSIC**

They trap to the Tier-2 crash handler and kill the process
(`runetea/guard.odin, guarded`'s "Bounds violations and nil derefs never reach here"). **When it bites:** the likeliest TUI crash of all —
indexing a cell buffer out of range — is the one Tier 1 cannot catch. The
terminal is restored and the exit is honest, but the session dies.

### 6.6 A recovered `update` panic leaves your model half-mutated — **INTRINSIC**

`update` takes `model: ^T` (which bought a compile-time fix: 105 s → 1.07 s at a
32 KiB model), so a panic partway through leaves partial mutations and RuneTea
cannot roll them back (`runetea/tea.odin, Program.update`;
`docs/superpowers/tier1-coverage-decision.md:376-480`).

**When it bites:** after `run()` returns a `Panicked_Error`, treat `p.model` as
**suspect** — do not persist it.
**What to do instead:** compute into locals and write into `m^` last. That is
structural, and it is the only mitigation available.

### 6.7 `install_crash_handlers()` is per-thread and must precede `term_enter_raw` — **INTRINSIC**

`sigaltstack` is per-thread (`runetea/guard.odin, install_crash_handlers`). A thread you spawn
yourself has no altstack, so a stack-overflow `SIGSEGV` there re-faults and never
restores the terminal.

### 6.8 `Panicked_Error.message` is caller-owned and leaks if you ignore it — **API hazard**

`runetea/tea.odin, Panicked_Error`. `delete()` it.

### 6.9 `run()` does not own the terminal — **INTRINSIC**, deliberate

Unlike Bubble Tea, the application calls `term_enter_raw` itself and must pair
it with `defer term_restore()` and `install_crash_handlers()`, in that order
(`runetea/term.odin, term_enter_raw`, `runetea/guard.odin, install_crash_handlers`). Alt screen and
full-screen rendering are **two independent opt-ins**: setting
`render_mode = .Full_Screen` without `alt = true` repaints over the user's
scrollback.

### 6.10 The Kitty push is fire-and-forget — **INTRINSIC**

A terminal may enable fewer flags than requested, or never reply
(`runetea/term.odin`). Handle `Keyboard_Enhancements_Msg` never arriving — and
note that with the default `Term_Opts{}` it never even asks, so the message never
arrives for a different reason (5.1).

### 6.11 There is no in-loop hook for `SIGINT`/`SIGTERM` — **INTRINSIC**

The signal watcher turns an external `SIGINT`/`SIGTERM` into an `Interrupt_Msg`,
and the loop converts that to `Interrupted_Error` **before `update` runs**
(`runetea/tea.odin`). `Interrupt_Msg` is an exported type — it is the message
type of the standalone watcher API (`signal_watcher_start` + `mailbox_recv`,
which `tools/rawcheck` uses) — so a `case rt.Interrupt_Msg:` written inside an
application's `update` **compiles with no warning and can never run**. Verified
under a real pty: a probe with that branch, sent `SIGTERM`, never printed from
it. `docs/API.md`'s message table now carries the row and says so.

**When it bites:** you cannot save state on a signal from inside `update`. What
you get is `Interrupted_Error` after `run()` has already returned, with the model
in whatever state its last real message left it.
**What to do instead:** persist from after `run()` returns, not from inside it,
and treat `Interrupted_Error` as a clean shutdown — `exit_code` maps it to 130
rather than 1 for exactly that reason.

### 6.12 A failed `pthread_create` used to lose a Cmd and hang teardown forever — **FIXED** in v1.0-audit

`core:thread`'s `create_and_start_with_data` returns `nil` silently when
`pthread_create` fails, and nothing checked it. A detached Cmd was then lost with
its `WaitGroup` never signalled, so `dispatcher_destroy` waited for it for the
life of the process. The reaper's own spawn was worse: `if t != nil` gated only
the `pthread_detach`, so on `nil` it leaked the reap context, the dispatcher, the
mailbox and the guard state, never joined the pool, and then blocked the caller
for the full grace period waiting for a reaper that did not exist.

Every spawn and every `new(Task_Env)` is now checked, and the detached branch
unwinds in exact reverse before reporting a `Panicked_Msg`. It is still true that
a machine out of threads cannot run your Cmd; what changed is that it says so and
lets you quit. Pinned by
`test_a_failed_detached_spawn_reports_and_does_not_wedge_teardown`, which fails
the spawn for real (an `LD_PRELOAD` shim over `pthread_create`) rather than
simulating the `nil`.

**RuneTea starts four kinds of thread, and for a while only this one was
checked.** That is worth recording because the first version of this fix turned
the hang into a **SIGSEGV** for the other three: `run()` dereferenced a nil reader
thread at `tea.odin`, the signal watcher dereferenced a nil watcher, and `tick()`
dereferenced a nil timer thread on the loop thread — a crash in place of a hang is
a different bug, not a fix. All four now go through one checked constructor
(`runetea/cmd.odin, thread_create_checked`) and each has its own honest outcome:
`run()` returns `Terminal_Error{detail = "could not start the input reader
thread…"}`; `signal_watcher_start` puts the caller's signal mask **back** (leaving
`SIGINT` blocked with no watcher to act on it is worse than having no watcher) and
returns false; the timer subsystem marks itself permanently unavailable so every
later `tick`/`every` answers with `Timer_Unavailable_Msg` rather than retrying a
spawn that will fail again. Pinned by
`test_a_failed_reader_thread_ends_run_with_a_terminal_error`,
`test_a_failed_watcher_thread_reports_false_and_restores_the_mask` and
`test_a_failed_timer_thread_spawn_is_reported_and_does_not_crash`.

---

## 7. RuneGloss (styling)

### 7.1 Wrapping, truncation and layout joins — **FIXED** in v1.0-audit

**This entry used to say RuneGloss had none of them, and that `width`/`height`
were floors.** All of that is now false, and the change is breaking:

- **`width` and `height` are EXACT clamps**, not floors. Content wider or taller
  than the request is reflowed to fit instead of widening the block. `0` still
  means unconstrained. `rg.overflow(&s, .Grow)` restores the old floor semantics
  verbatim if you were relying on them.
- **`width` and `height` now INCLUDE the border** (Lipgloss v2), where they
  previously excluded it. Margin remains outside. A bordered box therefore comes
  out **2 columns narrower and 2 rows shorter** than before for the same
  arguments. The argument for it is local rather than compatibility-driven: if
  `width` excluded the border, `rg.width(&s, 40)` could not be written without
  first knowing the border's own column cost, so `border()` would have to be
  called *before* `width()` and setter order would become load-bearing — the
  exact trap the box model exists to avoid.
- **`rg.wrap`, `rg.truncate`, `rg.measure`, `rg.join_horizontal`,
  `rg.join_vertical`, `rg.frame_size` and `rg.border_size` all exist.** `wrap` is
  greedy word wrap that hard-breaks at grapheme-cluster boundaries and
  re-establishes the active SGR on every produced row; `truncate` budgets its
  tail *inside* `max_w` and closes a style run it cut through; the joins emit one
  `\e[0m` before padding a row that left the pen set, because otherwise the
  padding of a red row paints red and the join grows a coloured notch exactly
  where the blocks meet.
- **`Overflow{Wrap, Truncate, Grow}`** on `Style`, `.Wrap` being the zero value
  and inert while `width` and `height` are both 0, with `rg.ellipsis` for the
  truncation tail.

**What the old behaviour cost, because it was worse than this entry admitted.**
"A long line visibly overflows its box" understated it by a wide margin, and by
the wrong mechanism. One over-budget content line widened its own box; the
widened box ran past the terminal width; the terminal's own DECAWM wrap then
split **every one of that box's rows** across two physical rows, orphaned the
top-right corner onto a line of its own, doubled the box's height and displaced
every row below it. No horizontal join was needed to trigger it — a single
`rg.width(60)` box on an 80-column terminal with one long path did it. And it was
not confined to `.Inline`: under `.Full_Screen`/`.Diff` the doubled physical-row
cost is charged against the terminal height, so 3.4's bottom truncation **deleted
the tail of the frame**. At 80×9 one long path removed the box's bottom border,
the button row and the status line.

Pinned by `test_width_clamps_instead_of_flooring` and
`test_one_long_line_cannot_widen_a_bordered_block` (the clamp),
`test_width_includes_the_border_and_frame_size_reports_the_cost` (the box
model), `test_wrap_breaks_at_words_and_drops_the_break_spaces`,
`test_wrap_reestablishes_the_active_style_on_every_row`,
`test_truncate_budgets_its_tail_inside_the_width`,
`test_truncation_never_splits_a_grapheme_cluster`,
`test_join_horizontal_keeps_every_column_aligned` and
`test_join_closes_a_styled_row_before_padding_it`.

**Still absent:** `table`, `tree`, `list`, and fluent chaining (7.10). CJK
line-break rules (UAX #14) are not implemented — `wrap` breaks on spaces and
falls back to cluster boundaries, so a CJK paragraph with no spaces hard-breaks.

### 7.1a There is no horizontal truncation in the RENDERER — **INTRINSIC**

`rg.truncate` clamps text you hand it. **Nothing clamps a view.** `paint_frame`
measures each logical line and writes it in full; `.Full_Screen` and `.Diff`
truncate at the **bottom** only (3.4), and `.Inline` truncates nothing at all
(3.3). A line longer than the terminal is therefore wrapped by the terminal, and
the extra physical rows are charged against the height budget.

**When it bites:** any string you did not size yourself — a file path, a host
name, an error message — reaching a fixed-width layout.
**What to do instead:** clamp at the point of use, with `rg.truncate` or with a
`Style` carrying `rg.width` + `rg.overflow(.Truncate)`. `examples/http` does
exactly this for its host column, and its comment says why `.Truncate` and not
`.Wrap`: under `.Inline`, a wrapped row costs a physical row the rewind does not
know about, and the frame walks down the screen.

### 7.2 Non-canonical SGR resets silently lose the outer style — **INTRINSIC**

Only `\e[0m` and `\e[m` are recognised as resets. `\e[00m`, `\e[0;1m`, `\e[22m`,
`\e[39m`, `\e[49m` are not, and *"the outer style is silently LOST from that
point to the end of the row… Worse, runetea's cell model does not recognise them
either, so it still believes those cells are bold+red and a later frame will not
repaint them; the wrong pixels persist"* (`runegloss/render.odin`'s SGR-reset recognition rule).

**When it bites:** embedding output from another tool that uses `\e[39m` to
reset only the foreground. The damage *persists across frames*.
**What to do instead:** normalise foreign SGR to `\e[0m` before handing it to
RuneGloss.

### 7.3 A truncated trailing escape in content is dropped — **INTRINSIC**, accepted

`runegloss/render.odin, drop_truncated_escape`. Width-neutral, and the terminal was never going
to paint it, but it is silent data loss.

### 7.4 Hard caps with no error — **INTRINSIC**

- `SGR_CAP :: 64` — a style run past 64 bytes is dropped past the cap
  (`runegloss/render.odin, SGR_CAP`). The longest run RuneGloss can currently
  build is 50 bytes, so this is unreachable today.
- `BORDER_CELL_CAP :: 8` — a custom border glyph longer than 8 bytes yields an
  **empty** cell (`runegloss/border.odin, Border_Cell`). A ZWJ-cluster border glyph
  renders as a gap.

### 7.5 Bad colour input returns "no colour", not an error — **INTRINSIC**

A malformed hex string or out-of-range palette index styles nothing, silently
(`runegloss/color.odin, color_hex` and `color_ansi`). A typo'd `"#7D56F"` renders unstyled
with no diagnostic.

### 7.6 Colour down-conversion ignores palette entries 0–15 — **INTRINSIC**; the conversion itself was **FIXED** in v1.0-audit

`BASE16` is xterm's defaults, *"NOT FIXED IN REALITY: every terminal lets the
user retheme 0-15"* (`runegloss/color.odin`). The choice is theme-independence
over accuracy, and it is unchanged.

**What was fixed is that the conversion collapsed contrast.** Two independent
causes. (1) `BASE16` was *commented* "xterm's defaults" and actually held the IBM
VGA / legacy-conhost palette — dim half at `0x80`, slot 4 `#000080`, white
`#C0C0C0` — so the table the comment described and the table in the file were
different tables. It now holds xterm's real defaults. (2) `nearest_16` picked a
hue family by CIE76 and then took whichever member the arithmetic landed on,
which was routinely the dim twin of a bright colour; it now takes the twin whose
L\* is nearer the target, which is parameter-free and cannot change hue. Measured against black,
the brand accent `#7D56F4` used to come out of `.ANSI` at **1.31:1**; it now comes
out at **4.43:1**, against **4.51:1** at full truecolour — so the conversion now
very nearly preserves the ratio instead of destroying it.

**Anything asserting exact SGR bytes under `Profile.ANSI` must be re-baselined.**
Forty of the 240 cube-and-ramp entries moved; none crosses a hue family.
Verified in the current tree: `#7D56F4` → 12 (was 4), `#FF5F87` → 9 (was 1),
`#04B575` → 6 (was 2), palette index 21 → 4 (was 12), index 33 → 12 (was 4).

`rg.contrast_ratio` and `rg.relative_luminance` are public so a test can assert a
palette still clears a WCAG threshold after `rg.convert(c, .ANSI)`. Pinned by
`test_contrast_ratio_matches_the_wcag_anchors`.

**Two residuals, both real.** (1) **A near-black still degrades to black.**
`#333333` → slot 0, which is a **1.00:1** ratio against a black background — the
same "literally invisible" outcome the audit named, and the fix above does not
address it, because slot 0 genuinely *is* the nearest of sixteen. Sixteen colours
cannot represent a dark grey that is distinguishable from black; the honest
answer is not to use one when the profile might be `.ANSI`, and
`rg.contrast_ratio` is how you find out. (2) What no library can check is what
the **user** has rethemed slots 0–15 to.

### 7.7 Profile detection never consults `isatty` — **INTRINSIC**, deliberate

`runegloss/color.odin, detect_profile_env`'s "NOT CONSULTED, deliberately: isatty". Piping a RuneGloss app's output to a file keeps
the escapes unless the app calls `set_default_profile(.None)` itself.

### 7.8 `set_default_profile` is process-wide and affects only later Styles — **INTRINSIC**

`runegloss/color.odin, set_default_profile`.

### 7.9 24-bit → 256 conversion is uncached — **NOT-YET-BUILT**

~720 cube roots per coloured Style per `render()` call
(`runegloss/color.odin, convert`). Free on `.True_Color`. Width is also measured twice per
line, once per pass (`runegloss/render.odin`), and a `render` with an active clamp
now makes **two** allocations from the supplied allocator instead of one — the
reflowed text is a temporary, freed before return. Nothing reaches the heap behind
the caller's back either way.

### 7.10 No fluent chaining — **INTRINSIC**

A permanent ergonomic divergence from Lipgloss (`runegloss/style.odin`'s header).

### 7.11 `.None` is not a plain-text mode — **INTRINSIC**, and it was documented wrongly

Under `Profile.None` — `$NO_COLOR`, `TERM=dumb` — **only colour is dropped.**
Attributes still emit SGR (`bold` is still `\e[1m…\e[0m`, and so are faint,
italic, underline, reverse and strike) and the box model still restructures the
string: padding, width, height, alignment and borders all apply.

This is a statement about `rg.render`'s return value, and it stays true of the
string in your hand. What happens to it afterwards depends on who prints it: a
frame going through RuneTea's `run()`/`run_nbio()` at a terminal that declares no
capabilities has those surviving attributes stripped one layer further down, by
`render_plain` (5.15) — which exists precisely because this entry's "only colour"
is not enough at such a terminal. `$NO_COLOR` alone does **not** trigger that:
`TERM` is what the renderer reads.

`README.md`, `docs/API.md` and `examples/spinner` all said *"under `.None`,
`render` returns its input byte for byte"* until v1.0-audit. Measured on the
README's own worked example, which is printed directly above the sentence that
made the claim: the 16-byte input `"Hello, RuneGloss"` comes out of that style at
`.None` as **310 bytes** — a five-line, thirty-column rounded box with three
`\e[1m…\e[0m` runs in it.

**The invariant that does hold is narrower, and it belongs to the STYLE rather
than the PROFILE**, which is what the source comments always said and the docs
dropped: *a style that asks for nothing renders its input byte for byte*, at
every profile. Verified: `rg.render` of a fresh `new_style_profile(.None)` over
`"Hello, RuneGloss"` returns exactly those 16 bytes.

**When it bites:** piping a RuneGloss view to a file, a log parser or a
screen-reader-friendly transcript under `$NO_COLOR` and getting box-drawing
characters, padding and stray SGR instead of plain text (see 11.4).
**What to do instead:** do not send it through a configured `Style` at all.
`.None` is a colour policy, not an output mode. Making `build_sgr` skip
attributes under `.None` was considered and rejected: it would make the profile
silently change *layout-adjacent* behaviour, and the honest fix is the sentence,
not the code.

---

## 8. Not ported from Bubble Tea

### 8.1 Absent for v1.0 — **NOT-YET-BUILT**

`suspend`/`exec` (shelling out to `$EDITOR` — the *signal-mask* half of doing it
by hand is now provided and documented, see 1.4; the termios save/restore and
the process plumbing are not); the full terminal response decoder
(DA1/2/3, XTGETTCAP, OSC 10/11/12/52, DSR, XTVERSION) — which means **no
adaptive light/dark theming**; scroll-region optimisation; the declarative
`View` struct (3.14)
(`docs/superpowers/specs/2026-07-25-runetea-design.md:488-503`).

### 8.2 No closures — **INTRINSIC** to Odin

Every `Cmd` carries an explicit `env: rawptr` plus a `^Cancel_Token` parameter.
*"The port's largest permanent ergonomic cost, and it touches every user
program"* (`runetea/cmd.odin`'s header).

### 8.3 `Program(T)` fixes the model type for the whole session — **INTRINSIC**

Parametric, not interface-based. Use a `state` enum, or make `T` itself a vtable
(`runetea/tea.odin, Program`).

### 8.4 "Bubble Tea v2 parity" is a moving target

ultraviolet grew 10,915 → 15,451 LOC (+41%) in seven months with no tagged
release (`docs/superpowers/specs/2026-07-25-runetea-design.md:566-572`).

### 8.5 There is no component library. None of Bubbles exists — **NOT-YET-BUILT**

**This is the largest single thing a reader is likely to assume and be wrong
about, and until v1.0-audit no user-facing document in this repository said it
anywhere.** RuneTea is presented as "a port of Bubble Tea"; the practical value
of Bubble Tea for *shipping* an application is
[Bubbles](https://github.com/charmbracelet/bubbles), and none of its thirteen
components has an equivalent here:

`textinput`, `textarea`, `viewport`, `list`, `table`, `progress`, `paginator`,
`help`, `key`, `filepicker`, `stopwatch`, `timer`, `spinner`.

Not one of those words appeared in `README.md`, `docs/API.md` or this document —
including in §8, the section titled "Not ported from Bubble Tea", whose entire
absent-for-v1.0 list was `suspend`/`exec`, the terminal response decoder,
scroll-region optimisation and the declarative `View` struct. Worse, the README
cited `bubbles/spinner` as a design reference for `tick` without ever saying
Bubbles is absent, which reads as though it is available. The equivalent
statement for the *styling* half — "RuneGloss is deliberately a subset of
Lipgloss" — was made twice, in both documents; the framework half was made
nowhere.

**The omission was informed rather than accidental.** The design record describes
v1.0 verbatim as "the Bubbles-free set", records that 35 of the 63 upstream
Bubble Tea examples import bubbles and that zero examples resembling a real
application are pure bubbletea, and defers a RuneBubbles to a later tier at
roughly double v1.0's cumulative effort
(`docs/superpowers/specs/2026-07-25-runetea-design.md:485-500`). That is a
defensible plan. Not telling the reader was not.

**When it bites:** on your first text field. There is no `key.Binding`, no help
renderer, no viewport, no list with filtering — you write each of them out of
`Key_Msg`, a model field and a `view`.
**What to do instead:** budget for it, and read `examples/editor` first. It is
the worked example of what a widget costs in this framework: caret movement by
grapheme cluster, a scrolled viewport measured in physical rows, a responsive
header, a help panel and a status bar, all hand-written, in one file. Nothing
about the framework makes those hard — `Cluster_Iter`, `measure_line`,
`rg.truncate` and `rg.wrap` exist precisely so they can be written correctly —
but it is all yours to write.

---

## 9. What the test suite does and does not check

### 9.1 `odin test -sanitize:thread` does **not** detect data races on this toolchain

Proven with a deliberate unsynchronised counter: `odin build` +
`-sanitize:thread` reports the race and exits 66; `odin test` +
`-sanitize:thread` reports nothing and exits 0, *with the race physically
occurring in both* (`tools/test.sh`'s `tsan)` case and its WARNING, verified
2026-07-26).

**The only real race gate is `./tools/test.sh race`**, which builds
`tools/racecheck` as a standalone program under TSan. helgrind is not a
substitute: Odin's `sync.Mutex`/`Sema` are raw futex syscalls, invisible to it
(`tools/test.sh`'s header).

### 9.2 The pyte cross-check IS on the gate — **changed** in v1.0-audit

This entry used to say the opposite, with this argument: `./tools/difftest/run.sh`
needs python3 and pyte, so it must be a separate invocation, because "the day the
module is missing, a shelled-out checker becomes a skip, and a skip inside a
green run is indistinguishable from a pass".

**That is an argument against the skip, not against the dependency**, and the
documentation gate forced the dependency anyway — grepping a byte stream cannot
see a frame, so the pty check now replays through pyte too (9.5). So the
dependency is taken and the skip is refused: `python3` and `pyte` are hard
requirements of `./tools/test.sh`, every checker that needs them exits non-zero
when they are absent, and difftest runs as the last stage of the default suite
(~3 s wall clock, deterministic seeds 0..199). The equivalence invariant *also*
remains on the gate in `runetea/diff_oracle_test.odin` with no external
dependencies, so a machine without python still checks something real.

**pyte cannot check hyperlinks.** It has no link model — it consumes OSC 8 and
ignores it. What it checks for a hyperlink case is that emitting the links
corrupted nothing else. The in-package oracle checks the links themselves, and
`RUNETEA_DIFF_FAULT=drop_link` proves it is not vacuous (429 of 500 cases
diverge).

### 9.3 pyte needs a correction, and disagrees with RuneTea by design — and one disagreement ended

pyte's `erase_in_display` does not re-attribute never-written cells, which is
corrected in `check.py`. pyte measures width per code point with `wcwidth`, so
VS16 emoji and regional-indicator flags are a different model, and it resolves
DECAWM's pending wrap *before* checking width, so a combining mark at the right
margin makes it scroll. Those cases are excluded from the pyte-safe corpus as
disagreements the harness was built to have (`runetea/difffuzz.odin`).

**One of them stopped being a disagreement.** A wide cluster at the right margin
was a three-way split — the width layer divided, the cell model placed, pyte
placed — and v1.0-audit made all three come from one placement walk, agreeing
with pyte (3.8). Real xterm-family terminals still do something else, and that is
now the *only* remaining party to the disagreement.

### 9.4 The diff fuzz corpus can now see the frame-shape bugs — **FIXED** in v1.0-audit

The generator produced only fixed-geometry frames from a bounded style pool, so
it could not construct either of the two failures the audit found in the shared
frame shape: a **resize** (3.17's SGR/link carry-over is a property of the
transition, not of any one size) or a **style-table overflow** (3.7's second
overflow needs more distinct styles than an empty table holds). Neither was
reachable, so neither was ever going to be found by fuzzing.

Four additions, all inside the generator so both harnesses inherit what they can:
one frame in six resizes either axis or both (opt-in via `diff_fuzz_init`'s
`resizes` parameter, because the size lives in the harness's `Renderer`, not in
the generator); one seed in eleven emits a burst of 400 distinct truecolour
escapes; every seed now also produces a margin-straddling wide-cluster line and a
line that leaves an SGR open.

**The resize prong now reaches the pyte cross-check too.** It did not at first,
and the gap mattered: the in-package oracle (`runetea/diff_oracle_test.odin`)
shares `runetea/screen.odin`'s model of where a wide cluster lands and what
`\e[K` erases with the renderer it is checking, so a misconception there is baked
into both sides of that comparison. `tools/difftest` shares nothing with either.
It now runs the generator with `resizes = true`, calls `renderer_set_width` /
`renderer_set_height` on both renderers, and emits a `SIZE <cols> <rows>` record
that `check.py` turns into `pyte.Screen.resize` on both screens.
**Corpus change:** for the same seed the generator emits different frames than it
did, so any harness that pinned exact fuzz output rather than the equivalence
invariant will see a difference. Nothing in this repository did.

Pinned by `test_the_fuzz_corpus_reaches_resizes_style_overflow_and_margin_clusters`,
which asserts the corpus actually CONTAINS each of the three shapes rather than
that the generator has a parameter for them — a generator whose new prong never
fires is the same corpus with a longer changelog. `test_diff_oracle_pyte_safe_subset`
pins the in-package half.

### 9.5 The documentation gate now decides a SCREEN, not a byte stream — **FIXED** in v1.0-audit

`README.md` credited the doc gate with running the quickstart under a real pty
"asserting on the frames it painted". It ran three unanchored `grep -qE` over the
raw escape-visible byte dump, spanning the whole four-frame transcript. Nothing
in it modelled a terminal, so **no assertion was on a frame at all** — and that
was demonstrated, not argued: a one-token mutation to `render.odin` produced a
screen with four stacked stale header lines, and the old gate printed
"pty OK ... with the expected frames" and exited 0.

The gate now replays ptyrun's bytes through pyte and compares the resulting
**cell grid** against the fenced `text` block in `README.md` itself — read out of the
document rather than copied into the script, so the two cannot drift. `ptyrun`
gained a step script with real `TIOCSWINSZ` resizes, and writes **one `write()`
per step** instead of one per byte: the old per-byte pacing was not a keyboard
(a terminal delivers a keypress in one write), and driving the quickstart with
`1b5b42` that way delivered a lone `ESC`, which the quickstart binds to quit. The
old gate never noticed because it only ever typed three bytes with no sequence
among them.

**Residual:** only the quickstart is driven this way. The other four examples are
built, and since v1.0-audit `odin test`ed (9.8), but not driven under a pty.

<!-- doccheck: no-test this entry's subject IS a gate: tools/doccheck/run.sh plus screen.py. There is no @(test) procedure to cite because the fix is not library behaviour, and inventing one that re-ran the gate from inside odin test would assert nothing the gate does not already assert on every run. Its negative control is recorded above: render.odin's `reachable - 2` mutation, red under the new gate and green under the old. -->

### 9.6 `odin doc` used to list the test fixtures — **FIXED** in v1.0-audit

`odin doc runetea` is the command `README.md` and `docs/API.md` hand a newcomer
for symbol discovery, and because `*_test.odin` lives in the same package
directory it listed **366 of 516 symbols that were test scaffolding** — names
like `Fetch_Env`, `Counter`, `Gate_Env` and `PER`, indistinguishable from API.
Every test file in both documented packages now begins with `#+private`
(`odin test` still discovers `@(test)` procedures in a private file). The gate
asserts the *property* rather than the mechanism: it computes the set of
top-level names declared only in test files and fails if any appears in
`odin doc`'s output. `runetea` now lists **202** symbols, `runegloss` **85**, with
0 of 508 and 0 of 78 test-only names leaking.

**`examples/editor/edit` too, since 2026-09-04.** It was left out on the grounds
that `odin doc` on that package is not a documented command — true, and a weak
reason for a package that exists to be copied. Its test file now carries
`#+private` like the other two, and the package is on `DOC_PACKAGES`, so the
gate would notice if that changed.

<!-- doccheck: no-test this entry's subject IS a gate: tools/doccheck/run.sh's `apidoc` check, which computes the set of names declared only in *_test.odin and fails if any reaches odin doc's output. There is no @(test) procedure to cite because the fix is a compiler directive, not library behaviour. Its negative control is recorded above: stripping the #+private lines makes the check red on 458 names. -->

### 9.7 The wide-cell pair expansion in the diff emitter is provably inert

Removing it (`RUNETEA_DIFF_FAULT=no_pair_expand`) changes not one byte across
the whole fuzz corpus. It is kept for locality and for real-hardware behaviour
no cell model can express (`runetea/render.odin, `emit_row` ("THE WIDE-CELL INVARIANT")`), and that finding is
itself pinned by a test.

### 9.8 The single-file examples had no tests at all — **FIXED** in v1.0-audit

`examples/editor` was split into a library package (`examples/editor/edit`)
specifically so its model/update/view could be driven from a test, and that is
still the right shape for anything the size of an editor. The other four —
`quickstart`, `simple`, `spinner`, `http` — are single-file `package main`, and
until 2026-09-04 nothing checked them but a build. The documentation gate runs
the quickstart under a pty; the other three were compiled and never executed by
anything.

**What that cost is measurable, not hypothetical.** F47's minimum-size guards
landed first as *reasoning* — "this program's view is ONE ROW, so there is no
minimum HEIGHT to guard: a one-row frame fits any terminal that exists", "this
view is TWO ROWS ... two rows fit any terminal anyone has" — and all four were
wrong by exactly one row, for the reason 3.20 documents. Nothing disagreed,
because there was nothing that could.

`odin test` works on a `package main`: the generated runner supplies its own
entry point and `main` is simply never called. So each of the four now carries a
`main_test.odin`, and `tools/test.sh` runs them as four more stages under the
same leak audit as everything else. The tests deliberately measure the view
through `rt.rows_for_line` rather than asserting a row count, so a wrapped line
counts what it really costs:
`test_the_quickstart_minimum_height_leaves_a_row_for_inlines_terminator`,
`test_the_simple_minimum_height_leaves_a_row_for_inlines_terminator`,
`test_the_spinners_minimum_height_leaves_a_row_for_inlines_terminator`,
`test_the_http_minimum_height_leaves_a_row_for_inlines_terminator`, plus the
`Window_Size_Msg{0,0}` sentinel (3.16) in each and
`test_a_resize_back_above_the_minimum_reissues_exactly_one_tick` for the
spinner's paused animation.

**Residual:** these are unit tests over `update`/`view`, not pty runs. Only the
quickstart is driven through a real terminal (9.5), and extending that to the
other four would mean four more expected-screen blocks somebody has to keep
true. The editor is the one example whose *whole session* is driven, through
`rt.run` over scripted bytes with a golden frame stream.

---

## 10. `examples/editor` — what you inherit if you copy it

- **Hard caps of `MAX_LINES :: 250` lines × `MAX_COLS :: 256` runes**
  (`examples/editor/edit/editor.odin`). The 250 is itself a workaround: Odin
  warns *"Declaration of 'x' may cause a stack overflow"* for any local over
  exactly 262144 bytes. They no longer drop input *silently*: `insert_rune`,
  `split_line` and `join_next` return `bool`, a refused edit changes nothing at
  all, and the status bar names it (`LINE FULL` / `DOC FULL`).
- **A `Delete` or `Backspace` that joined two lines past the cap used to
  annihilate the next line.** The old join copied what fit, broke out of the
  loop, and then closed the gap and decremented the line count
  **unconditionally** — so the tail that did not fit was gone with no message.
  The join is now refused up front, before anything is mutated, and
  Backspace-at-column-0 peeks before it moves so a refused join leaves the caret
  where it was. Pinned by
  `test_backspace_refuses_the_same_join_and_leaves_the_caret_alone`. **A partial
  join was rejected deliberately**: silently losing half a line is the failure,
  not the trigger.
- **The layout is responsive as of v1.0-audit, and used to be three constants.**
  `VIEWPORT :: 10` meant that on a 30-row terminal seventeen rows were dead; a
  101-column `HELP_LINE` wrapped onto a second row at 80 columns, which the
  `.Inline`-style rewind bookkeeping does not budget for; a 74-dash `RULE` stopped
  six columns short of an 80-column window. All three are now computed from
  `term_w`/`term_h` — `text_rows(m)` is `max(1, term_h - CHROME_ROWS)`, the header
  drops hints one at a time until what is left fits (reserving the quit binding so
  it can never be crowded out), and the rule is `term_w` dashes wide. With an
  unknown size (0) they fall back to `VIEWPORT_UNSIZED :: 10`,
  `RULE_UNSIZED_COLS :: 74` and `HELP_UNSIZED_COLS :: 78`, so layout and paint are
  wrong together or right together.
- **The window is measured in PHYSICAL rows, not logical lines**, because the
  editor does not truncate document lines (it has no horizontal scrolling, so a
  truncated line is text the user could never see again). A long line therefore
  costs the rows it wraps to, and the visible line count shrinks accordingly.
- **`MIN_COLS :: 20` × `MIN_ROWS :: 6`.** Below either, the whole frame is one
  line reading `need 20x6, have WxH` — one line, because what the blank screen
  used to be was the *first* view line not fitting and `.Full_Screen`/`.Diff`
  dropping whole logical lines (3.4). A 0 on either axis means "unknown" and never
  trips it (3.16).
- **The help panel replaces the text area** rather than being appended below the
  status bar, which is what made its height unbudgetable; it takes an exact
  `rg.width(term_w)`/`rg.height(text_area_rows)` with `.Wrap`, so its prose
  reflows instead of its border shattering below 78 columns. `cursor()` and
  `click_target()` go quiet while it is up, and on the too-small frame.
- **No horizontal scrolling**; the wheel's horizontal axis is ignored.
- **The caret moves by grapheme cluster, not by rune.** Typing `e` + U+0301 and
  pressing Left used to be a dead keystroke, and Backspace removed the accent and
  left the base letter — one visible character took two presses. Built on the now
  public `rt.Cluster_Iter`, with no allocation and no cache (every insert, delete,
  paste and join would have to invalidate one). Pinned by
  `test_the_caret_moves_by_grapheme_cluster_not_by_rune`.
- **Tab indents with 4 spaces, never a literal `0x09`** — deliberate, because a
  real tab in the view would lie to the `.Diff` cell model (see 3.2). The
  document *loader* sanitises control characters for the same reason, and so does
  the `.Rune` key branch: a Kitty text-input report can still deliver a C0 byte
  even though the decoder no longer produces one.
- **`Ctrl+I` (toggle help) is unreachable without the Kitty protocol** — it is
  the same byte as Tab. The degradation is *visible* in two places now: the status
  line prints `kitty:off`, and the header stops advertising the binding at all
  when no `CSI ? u` reply came back.
- **A CRLF paste used to insert a blank line after every line.** Fixed in the
  example rather than in the decoder, whose verbatim contract is right: a paste is
  streamed one `Key_Msg` per rune (a `string` field in a Msg is illegal, 2.1), so
  `update` never sees the next byte and cannot look ahead. A `paste_cr` flag
  swallows an LF that follows a CR, cleared on `Paste_Start`/`Paste_End` so it
  cannot leak between pastes.

---

## 11. Accessibility

**This section exists because there was nothing here.** Measured against the tree
this audit started from: a grep for
`accessib|screen reader|colou?r.blind|low.vision|high.contrast|reduced.motion|WCAG|contrast`
across `README.md`, `docs/API.md` and this document returned **zero** matches in
2,445 lines. The nearest thing to an acknowledgement was one clause of 3.3 —
*"Scrollback is not addressable; nothing can fix that"* — written about a
rendering residual, not about a reader.

Accessibility has not been a design input for this library, and pretending
otherwise here would be the same failure as the four false claims listed at the
end of this document. What follows is what its absence costs, labelled the same
way as everything else.

Two things are genuinely handled and are worth saying first: **`$NO_COLOR` is
honoured** unconditionally and first, exactly as no-color.org specifies including
`NO_COLOR=0` (`runegloss/color.odin`, `detect_profile_env`); and
**`rg.contrast_ratio` / `rg.relative_luminance` exist**, so an application can
assert a WCAG ratio over its own palette, including after down-conversion (7.6).

### 11.1 The alternate screen plus `.Diff` is structurally opaque to assistive technology — **INTRINSIC**

The alternate screen buffer has **no scrollback**, by definition — that is what
it is for. `.Diff` compounds it: the mode's entire value is that it writes only
the cells that changed, so even the bytes that do go out are not a readable
transcript of anything. Together they mean that a session leaves **nothing**
behind for the three tools that read a terminal after the fact:

- a screen reader's **review mode**, which walks the terminal's buffer rather
  than following the caret,
- the terminal's own **search** and **copy-out**,
- anything piping or logging the session.

This is not a RuneTea defect — it is what `\e[?1049h` means, and every full-screen
TUI has it. It is listed because RuneTea *recommends* the combination for
full-screen applications and its flagship example uses it, and because a reader
choosing a render mode is not told.

**What to do instead:** make `alt` and `p.render_mode` **settings, not
constants**. `.Inline` leaves every frame in scrollback and is the accessible
default for anything that is not a full-screen editor; `.Full_Screen` without
`alt` at least leaves the final screen behind. Neither `run()` nor
`term_enter_raw` reads any environment variable for this.

### 11.2 There is no `--no-alt` lever, and RuneTea provides none — **NOT-YET-BUILT**

Nothing in `runetea` consults the environment for an accessibility preference.
`term_enter_raw` reads exactly one environment variable, `TERM`, and only to
decide whether escapes are supported at all (5.15). There is no
`RUNETEA_NO_ALT`, no reduced-motion flag, no high-contrast flag. An end user of
an application built on RuneTea has **no lever at all** unless the application
author wrote one; none of the five examples does.

**What to do instead:** read your own environment variable or command-line flag
in `main` and pass the result into `Term_Opts.alt` and `p.render_mode`. It is
four lines, and nobody will do it unless it is written down.

### 11.3 Animation runs forever with no way to slow or stop it — **NOT-YET-BUILT**, and a WCAG 2.2.2 concern

`examples/spinner` reissues a 100 ms `tick` from `update` on every fire, for the
life of the process. There is no pause key, no reduced-motion check, and no
interval setting — `q`, `Ctrl+C` and Escape quit the program, which is the only
way to stop the motion. That pattern is the one this project's own README and
`docs/API.md` §4 present as *the* way to animate, so it is what gets copied.

WCAG 2.2.2 (Pause, Stop, Hide) asks that any automatically-moving content lasting
more than five seconds be pausable. A spinner is arguably decorative, but the
same reissue-from-`update` loop is what a progress bar, a live log tail and a
clock are built from, and those are not.

**What to do instead:** keep the tick interval in your model rather than in a
constant, and bind a key that stops reissuing. Stopping is free — `tick` hands
back no handle precisely so that not reissuing it leaks nothing.

### 11.4 `rg.blink` is exported with no warning, and `.None` does not remove it — **API hazard**

`rg.blink(&s, on)` emits SGR 5. WCAG 2.3.1 (Three Flashes or Below Threshold) is
a **Level A** criterion, and blinking text is also a documented migraine and
vestibular trigger. Nothing in the API or the documentation said so.

It is worse than an ordinary attribute for one specific reason: **`Profile.None`
does not remove it.** `$NO_COLOR` and `TERM=dumb` drop colour and nothing else
(7.11), so a user who has set `NO_COLOR` — which is the closest thing to an
accessibility preference this library reads — still gets the blink. `TERM=dumb`
is the one case where something downstream saves them, and only inside `run()`:
`render_plain` strips every escape in the frame, blink included (5.15). `NO_COLOR`
at a capable terminal has nothing downstream of it at all.

**What to do instead:** do not use it. If you must, gate it on your own setting,
and note that many terminal emulators ignore SGR 5 outright, which means the
attribute mostly costs you bytes and reaches only the subset of users whose
terminal honours it — the subset it can harm.

### 11.5 Colour is the only channel RuneGloss offers for state — **INTRINSIC**

`Style` has colour, six attributes and a box model. There is no notion of a
*semantic* state (error, warning, success) that could be rendered as a symbol or
a label on a terminal where colour is not available or not distinguishable, and
nothing in the library encourages a second channel.

`examples/http` is the shape to watch, and it is only half wrong: a network
failure prints the word `error:`, which is a real second channel, but a `200` and
a `500` differ **only** by `#04B575` versus `#FF5F87` — green against red, in the
same layout, at the same width, with no glyph. Green against red is the worst
available pair for the most common form of colour vision deficiency, which
affects roughly one man in twelve, and it survives every down-conversion this
library does: measured, under `.ANSI` those two resolve to slots 6 and 9 — still
the same two hues.

**What to do instead:** never carry meaning in colour alone. Add a glyph or a
word; `✓`/`✗` costs two columns. RuneGloss will not stop you either way, and it
will not help you either — this is a discipline, not a feature.

### 11.6 Nothing here has ever been tested with assistive technology — **NOT-YET-BUILT**

No screen reader has been run against any of this. No high-contrast or
colour-blindness simulation has been applied to the default palettes. The claims
in 11.1 are structural — they follow from what `\e[?1049h` and a cell diff *are* —
but "structurally true" is not "observed", and this document does not pretend
otherwise. A report from someone using RuneTea with a screen reader is as valuable
as the macOS test run the README asks for, and for the same reason: it is a
platform nobody here has.

---

## Changes made while compiling this document

Four things on this list were closed rather than described:

| Was | Now |
|---|---|
| OSC 8 hyperlinks silently dropped by `.Diff` (3.1) | Tracked per cell, fuzzed, cross-checked |
| The `.Diff` view contract described but uncheckable (3.2) | `view_diff_safe()` + an assertion on every frame — a debug-build one then, every non-optimised build now (3.2) |
| `Msg_Text` truncating silently (2.3) | `truncated` flag + `msg_text_truncated()` |
| Shift+Tab undecoded on 21/40 terminals (5.6) | `CSI Z` → `Tab + {.Shift}` |

Plus one bug the new checker found: `examples/editor`'s loader admitted literal
tabs and other C0 bytes into the view (10).

## The limitations sweep that followed

The two entries this document nominated to be closed next — **2.14** and
**6.2** — were closed, along with two more that turned out on inspection to be
defects rather than design limits:

| Was | Now |
|---|---|
| `flush_frame` a single unlooped `write`, tail of a frame silently dropped (6.2) | Looped, `EINTR`/`EAGAIN` handled, unrecoverable failure returns `Terminal_Error` **with its errno** |
| Timer subsystem start failure completely silent (2.14) | `Timer_Unavailable_Msg` through the Mailbox, once per `Dispatcher` |
| No way to clear the inherited signal mask for a child process (1.4) | `signal_unblock_for_child()` + `runetea_signal_set()`, documented for the `fork`/`exec` window |
| An inline frame taller than the screen corrupting the display permanently (3.3) | Rewind and cursor park clamped to what CUU can actually reach; nothing truncated |

Every one of the four is pinned by a test that fails when the fix is reverted.
Two things were *not* changed while doing it, and are worth stating because
"fixed" would have been the easier answer:

- **`cursor_hidden`'s stickiness was kept.** The bug it was named after (6.2) is
  gone, but a crash signal or a write error landing between a frame's hide and
  its show is a separate, unfixable reason for it. The comment was corrected
  rather than the code.
- **`.Inline` was not made to truncate.** `.Full_Screen` and `.Diff` truncate to
  protect an absolute origin; `.Inline` has none, and truncating would discard
  the scrollback output the mode exists to produce (3.3).

## v1.0-audit — the adversarial sweep

An external audit produced 62 verified findings against this codebase. Most of
them were closed rather than described, and every **FIXED in v1.0-audit** label
above belongs to that sweep. The four that changed the most:

| Was | Now |
|---|---|
| The same `Cmd` value returned twice from `update` double-freed its env — a deterministic `SIGSEGV`, 5 runs of 5 (2.19) | A ledger claims each Cmd exactly once; the second dispatch is refused and reported, and nothing is freed twice |
| `run_nbio()` never closed its mailbox at teardown, so every retry-forever producer spun for the life of the process with the terminal left raw and on the alt screen | `defer mailbox_close` ordered after `defer dispatcher_destroy`, so LIFO runs the close first — the invariant `run()` already had |
| An unclosed SGR in a view flooded `.Inline`'s erased region and grew `.Diff`'s per-frame cost without bound, +16 B/frame (3.17) | Every frame starts from a known pen and link state, in all three modes, and only writes the reset when the previous frame left one open |
| One frame per **message**, so a 1,332-byte paste into `examples/editor` emitted 26,268 bytes over 57 reads | One frame per **batch** of already-queued messages: 1,699 bytes over 2, with unchanged single-keystroke latency |

Both paste figures are `examples/editor` at 100×30 under a real pty, one
`write()` of 1,332 bytes. The comparison understates the win if anything: the
editor's frame is *larger* now than it was, because its text area became the
whole window (10).

**And four things this document said that were not true**, which is worse than a
bug because it is the document a reader is told to trust:

| It said | It is |
|---|---|
| "RuneTea requests Kitty by default" (5.1) | It requests nothing by default, and the two examples that quit on Escape are the exposed ones |
| "`kill -9` leaves the shell in raw mode and possibly in the alternate screen" (6.1) | Five things leak, including mouse reporting, which types garbage into the shell on every click |
| "No wrapping, no truncation, no layout joins" and "`width` is a floor" (7.1) | All of them exist, and `width` is an exact clamp that includes the border |
| Nothing, anywhere, about the absence of a component library (8.5) | Thirteen Bubbles components do not exist here, and now the README says so on its front page |

**What was not fixed, and is now written down instead:** passing `update`'s frame
allocator to a Cmd constructor is still an undetected use-after-free (2.20); a
non-POD Msg from a Cmd is still a no-op an application can ignore (2.24); a
`view` that forgets to thread its allocator still leaks a frame per frame with
only a warning on a passing test (3.15); the renderer still emits escapes under
`TERM=dumb` (5.15); the diff fuzz corpus's resize prong does not reach the
third-party oracle (9.4); and accessibility (11) is a whole section of gaps, none
of which was even named before.
