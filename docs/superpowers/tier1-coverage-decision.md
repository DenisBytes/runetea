# Tier 1 coverage — extended to View and Cmd, built and verified

**Date:** 2026-07-26
**Status:** Decided and shipped. Tier 1 now wraps all three places user code
runs (`update`, `view`, Cmd procedures), not `update` alone.
**Toolchain:** Odin dev-2026-07-nightly:819fdc7. Linux only. `core:`/`base:`
only, no third-party dependencies.

> **AMENDED 2026-07-27 — READ §5 BEFORE RELYING ON ANYTHING BELOW ABOUT
> RECOVERY.** `Program.update` now takes `^T` instead of `T`, and that removed
> a real safety property this document was written under: a recovered `update`
> panic no longer leaves `p.model` in its last good state. It can leave the
> model half-mutated, and an application cannot roll that back itself. Coverage
> of `view` and Cmd procedures (§1–§4) is unaffected. §5 has the whole story.

This is the fifth and last T1 decision. Spike-findings.md §4 claimed Tier 1
"recovers a panic in user code." That was true for exactly one of the three
places user code actually runs: `update`, guarded inside `apply()`. A panic
in `view` (called both by `run()`'s/`run_nbio()`'s initial paint and by
`apply()`'s per-iteration render) or inside a Cmd procedure (running on a
pool worker or a detached thread) fell straight through to Tier 2 — safe (the
process died honestly, terminal restored) but not *recoverable*, and not what
the document claimed. This document is that gap closed: what was built, the
five design decisions the task laid out as non-trivial, and the verification
that proves each one.

---

## 1. The five constraints, and what was decided

### (a) `guarded()` is not nestable — structure, not nesting

`apply()` already calls `guarded(update)` and returns before `view` would
ever run. The fix is a **second, sequential** `guarded()` call for `view`,
not one nested inside the update guard. By the time `view` is ever reached,
the update guard has already returned (successfully or via its own
recovery), so `g_armed` is back to `false` — an ordinary, non-nested call
from `guarded()`'s point of view.

Concretely: `guarded_render` (new, `tea.odin`, package-private) wraps exactly
`p.view(p.model, alloc)` in its own `guarded()` call, and is shared by
**both** places `view` actually runs:
- `run()`'s (and `run_nbio()`'s) initial paint, before the mailbox loop
  starts.
- `apply()`'s per-iteration render, after `update` returns.

One helper, one guarded code path for `view`, called from three sites
(`run()`, `run_nbio()`, `apply()`) instead of three hand-maintained copies
that could drift out of sync with each other.

### (b) A panicking Cmd — deliver a `Panicked_Msg`, do not force `run()` to end

A Cmd runs on a pool worker or a detached thread with no caller synchronously
waiting for its result the way `apply()` waits on `update` — its result
already travels asynchronously through the mailbox. **Decision: box the
panic as an ordinary `Panicked_Msg{message: Msg_Text}` and deliver it through
the exact same mailbox path as any other Cmd result.** The app's own
`update` decides what to do with it — log it, ignore it, retry, quit — the
same choice it already has for any other Cmd-reported error
(`examples/http`'s `Err_Msg` is the existing precedent for that pattern).

Rejected alternatives and why:
- **Drop it silently.** Ruled out by the task itself, and rightly — a
  vanishing Cmd result is indistinguishable from a slow one, which is exactly
  the kind of silent failure this whole crash-recovery effort exists to
  avoid.
- **Surface it through `run()`'s own `Run_Error`.** Would require new
  out-of-band signaling from a background thread into `run()`'s main loop —
  machinery the mailbox-as-single-wait-point design doesn't otherwise need —
  and would force the ENTIRE session to end because ONE background Cmd (of
  possibly several concurrently in flight) panicked. That is disproportionate
  and inconsistent with every other error path in the framework, which
  already routes async failures through Msg, not through forcing `run()` to
  return early.

A `Panicked_Msg` with no matching `case` in the app's `update` switch is not
silently dropped — it reached `update`'s switch and simply wasn't acted on,
exactly like any other Msg type an app doesn't care about (an app that never
checks for `Quit_Msg` "ignores" it the same way today, and nobody considers
that a leak).

`Panicked_Msg.message` is `Msg_Text`, not a bare `string` — required by the
POD message-ownership contract (T1-B, `message-ownership-decision.md`):
`box()` panics on any Msg type with an owned pointer anywhere in its field
tree, and a bare `string` field would trip that on the very next Cmd panic.

**Side effect worth recording:** before this change, `box()`'s own
non-POD-type panic (a genuinely different, pre-existing panic path — see
`message-ownership-decision.md` §2, Option B) was noted as producing "an
honest, immediate process abort" specifically because Cmd bodies ran
unguarded. That is no longer true: a Cmd that calls `box()` with a bad Msg
type now also gets caught by `run_cmd_guarded` and turned into a
`Panicked_Msg`, same as any other panic in that Cmd. `message-ownership-
decision.md` was left as-is (a dated record of what was measured at the
time, out of this task's stated scope), but this is flagged here since it
changes behavior that document describes.

### (c) longjmp skips `defer` — what each new guard reclaims

- **`view`**: `guarded_render`'s recovery path calls `frame_reset(fa)` before
  building the diagnostic string, exactly mirroring `apply()`'s existing
  handling of a failed `update` — the frame arena is the thing a failed
  `view()` call owned (a partially-built `strings.Builder`, etc.), and
  wholesale reclaim is the same move already proven for `update`.
- **Cmd env**: `run_cmd_guarded` frees `cmd.env` unconditionally, once,
  immediately after `guarded()` returns (panic or not) — replacing the bare
  `free()` call that used to sit right after the unguarded procedure call.
  This is a genuine improvement, not just a preserved behavior: before this
  change a panicking Cmd took the whole process down, so `cmd.env` was never
  freed on that path either. Now it always is.
- **Cmd panic message**: cloned by `guard_assertion_failure` into
  `g_panic_alloc` (== `context.allocator` at the `guarded()` call site,
  since `run_cmd_guarded` passes no explicit allocator). Immediately copied
  into the `Panicked_Msg`'s `Msg_Text` and then `delete`'d — unlike
  `apply()`'s update-panic path (which hands `info.message` to the *caller*
  of `run()` via `Panicked_Error` and therefore cannot free it), nothing
  else ever holds a reference to this particular copy, so freeing it right
  away is correct, not merely convenient. It does NOT reproduce
  `guard.odin`'s already-documented `Panic_Info.message` leak on the
  `update`/`view` panic paths (that pre-existing gap is unrelated to this
  change and was left as-is, out of scope here).
- **What is honestly NOT reclaimed**: any heap memory a Cmd body allocates
  itself (typically via `context.allocator`, since a Cmd's result must cross
  a thread boundary — see `arena.odin`'s LIFETIME CONTRACT) before
  panicking. Unlike `update`/`view`, a Cmd has no frame-arena equivalent to
  wholesale-reclaim on the recovery path — `frame_allocator(fa)` is
  per-`run()`-iteration and explicitly forbidden for anything crossing a
  thread boundary, which is exactly what a Cmd's own scratch allocations
  usually are not, but easily could be. A Cmd that panics after allocating
  its own scratch buffer leaks that buffer, the same as any non-guarded Odin
  code with no RAII would. This is a fundamental limit of setjmp/longjmp
  recovery in a language with no unwind-driven destructors, not something
  this change closes — recorded honestly in `run_cmd_guarded`'s own doc
  comment rather than silently promised away.

### (d) What a recovered view panic displays — a diagnostic frame, then terminate

Three options were weighed (recorded in `guarded_render`'s own doc comment,
`tea.odin`):
- **Last good frame** (skip rendering, leave the screen as it was): silently
  hides the crash — the screen keeps showing stale content indistinguishable
  from the app simply being idle. Worse for debugging than an honest crash
  message.
- **Nothing** (blank): actively worse than stale content — this is exactly
  the failure mode the task's own framing calls out.
- **A diagnostic line — ADOPTED.** `guarded_render` renders and flushes
  `"[view panicked: <message>]"` through the same `Renderer` real frames use,
  THEN returns `Panicked_Error`, ending the `run()` session — symmetric with
  `update`'s existing behavior. It costs nothing `update`-panic recovery
  doesn't already pay (`Panicked_Error` already carries `info.message` for
  the caller of `run()` to log), and it means the LAST thing the user's real
  terminal shows, once their own `defer term_restore()` runs, is a plain-text
  explanation rather than silence or frozen stale state.

**Terminate, not continue**, and this is a real decision, not an oversight: a
model whose `view` panics on its current state will almost always panic
again on the next call with the same (or barely different) state — looping
forever re-panicking and re-painting the same diagnostic every frame is a
worse outcome than an honest, one-time, clearly-explained exit. This also
keeps `view`'s failure mode symmetric with `update`'s: either kind of
user-code panic ends the session cleanly; neither is allowed to corrupt
state and keep going.

### (e) Tier 2 must still work — verified, not assumed

Bounds violations and nil derefs trap directly and never reach
`assertion_failure_proc` (verified in T0); wrapping `view` and Cmd
procedures in `guarded()` cannot change that, since `guarded()` only
installs a different `assertion_failure_proc` — it has no effect on a
hardware trap. This was proven live under a real pty rather than assumed by
analogy to T0 (§3 below): `tools/tier1check view-bounds` and `... cmd-bounds`
both still die by SIGILL with the terminal restored. `sigaltstack`
installation was untouched — still installed per-thread by
`install_crash_handlers()` on all four thread classes (pool workers via
`thread.Pool`'s `init_proc` hook, detached Cmds, the reader thread, the
signal watcher).

---

## 2. What was built

| File | What |
|---|---|
| `runetea/tea.odin` | `guarded_render` (new, package-private) + `View_Step($T)` (new, file-private) — the shared guarded-view helper described in (a)/(d). `run()`'s initial paint now calls it instead of calling `p.view` bare. `apply()`'s tail now calls it instead of its old inline render/flush/reset block. |
| `runetea/loop_nbio.odin` | `run_nbio`'s initial paint now calls the same `guarded_render` (cross-file, package-private) instead of calling `p.view` bare — identical coverage on the nbio-hosted loop, no duplicated logic. |
| `runetea/cmd.odin` | `Panicked_Msg{message: Msg_Text}` (new, exported) + `Cmd_Step` (new, file-private) + `run_cmd_guarded` (new) — wraps a Cmd's procedure call in `guarded()`, frees `cmd.env` unconditionally, and turns a recovered panic into a boxed `Panicked_Msg`. `run_cmd_task` and `run_cmd_detached` both call it instead of calling `cmd.procedure` bare. |
| `runetea/tea_test.odin` (+146) | `test_program_recovers_from_a_panicking_view`, `test_program_recovers_from_a_panicking_initial_view` (pins both `guarded_render` call sites separately), `test_program_survives_a_panicking_cmd` (end-to-end: a real `run()` session where `update` reacts to `Panicked_Msg` by quitting). |
| `runetea/cmd_test.odin` (+67) | `test_dispatch_recovers_a_panicking_cmd_on_the_pool`, `test_dispatch_recovers_a_panicking_cmd_when_detached` — pin `Panicked_Msg` delivery directly against the `Dispatcher`, one test per thread class. |
| `tools/racecheck/main.odin` (+65/-9) | Phase B (dispatcher) extended: a fraction of both pool (`1/13`) and detached (`1/11`) Cmds now panic instead of returning normally. The drainer counts `Panicked_Msg` results specifically and the phase asserts the count matches the expected total exactly (1676 for the current volumes) — proof that `guard.odin`'s `thread_local` state survives thousands of arm/disarm cycles reusing the same pool worker OS threads, under real ThreadSanitizer, not just a single-shot unit test. |
| `tools/tier1check/main.odin` (new) | Real-pty verification tool, three modes: `view-panic` (Tier 1 recovers, in-process), `view-bounds` and `cmd-bounds` (Tier 2 still catches a bounds trap in `view`/an init Cmd on a pool worker — forks, since the child is expected to die; the parent is an independent observer that re-opens the pty slave by path to inspect post-crash termios state). |
| `docs/superpowers/spike-findings.md` | §4 rewritten to describe all three guarded call sites and the two different endings (§4 below); Addendum item 7 marked RESOLVED with a pointer to this document. |

---

## 3. Verification

### 3.1 Panic in `view` → Tier 1 recovers

Unit tests (`runetea/tea_test.odin`):
```
test_program_recovers_from_a_panicking_view            -- panics on the 2nd
                                                            render (apply()'s
                                                            call site)
test_program_recovers_from_a_panicking_initial_view    -- panics on the 1st
                                                            render (run()'s
                                                            initial-paint call
                                                            site, no keypress
                                                            sent at all)
```
Both assert `err.(Panicked_Error)` and that the accumulated output contains
the diagnostic text.

Real pty (`tools/tier1check view-panic`, current run):
```
run() returned: Panicked_Error{message = "tier1check: view exploded"}
bytes seen on the pty master side (62):
"count: 0\r\n\e[1A\e[2K[view panicked: tier1check: view exploded]\r\n"
post-run termios: ECHO=true ICANON=true (both should be TRUE -- cooked mode restored)
PASS: view panic recovered under a real pty -- terminal restored, diagnostic reached the screen, run() returned cleanly
```
Genuine character device (`posix_openpt`/`grantpt`/`unlockpt`, same
technique as `tools/ttycheck`), not a pipe or an in-process simulation: the
initial frame (`count: 0`) paints, the rewind fires, then the diagnostic —
exactly what a real terminal emulator on the other end of that pty would
have shown a user.

### 3.2 Panic in a Cmd → `Panicked_Msg`, no death, no hang

Direct `Dispatcher` tests (`runetea/cmd_test.odin`), one per thread class:
```
test_dispatch_recovers_a_panicking_cmd_on_the_pool      -- pool worker
test_dispatch_recovers_a_panicking_cmd_when_detached    -- detached thread
```
Both dispatch a Cmd that unconditionally `panic()`s, `mailbox_recv` (plain
blocking receive, same convention as every other dispatch test in this
file), and assert the received message is a `Panicked_Msg` carrying the
expected text.

End-to-end (`runetea/tea_test.odin::test_program_survives_a_panicking_cmd`):
a real `Program`/`run()` session where a keypress dispatches a panicking pool
Cmd, `update` reacts to the resulting `Panicked_Msg` by quitting, and the
test asserts BOTH `err == nil` (not `Panicked_Error` — a Cmd panic does not
force the session to end) AND that the model actually observed the message
(`got_panic_msg == true`), so the test can only pass if delivery genuinely
happened, not merely if the process didn't crash.

At volume, under ThreadSanitizer (`./tools/test.sh race`, phase B, current
run):
```
--- phase B: dispatcher (pool + detached Cmds, destroy while in flight) ---
  dispatcher: 21500 results drained (dispatched 20000 pool + 1500 detached)
  dispatcher: 1676 of those were Panicked_Msg (expected 1676) -- guarded Cmd panics survive pool-thread reuse and detached-thread volume under TSan
```
20000 pool-dispatched Cmds (1/13 panicking) + 1500 detached Cmds (1/11
panicking) = 1676 expected `Panicked_Msg` results, exactly matched, with
`dispatcher_destroy` called immediately after the last dispatch (most work
still queued or running) and a concurrent drainer racing the teardown the
whole time. No TSan report, exit 0.

### 3.3 Bounds violation in `view` or a Cmd → still Tier 2, verified under a pty

```
$ /tmp/tier1check view-bounds
.../tools/tier1check/main.odin(242:6) Index 9 is out of range 0..<4
child exit status: WIFSIGNALED=true signal=SIGILL WIFEXITED=false exit_code=0
post-crash termios (independent observer fd): opened=true ECHO=true ICANON=true (both should be TRUE)
PASS: bounds violation in View bypassed Tier 1, hit Tier 2 -- process died honestly by signal, terminal restored

$ /tmp/tier1check cmd-bounds
.../tools/tier1check/main.odin(338:6) Index 9 is out of range 0..<4
child exit status: WIFSIGNALED=true signal=SIGILL
post-crash termios (independent observer fd): opened=true ECHO=true ICANON=true (both should be TRUE)
PASS: bounds violation in a Cmd (pool worker thread) bypassed Tier 1, hit Tier 2 -- process died honestly by signal, terminal restored
```
Both modes fork: the child is the "framework" process and is expected to
die, so the parent bounds its wait (5s, `WNOHANG`-polled) rather than
blocking forever — a bug that turned Tier 2 into a hang would fail this
harness observably instead of wedging it. The parent inspects post-crash
termios through an **independent** fd, opened by the pty's slave *path*
after the fork (not the dead child's own fd) — the same thing a real
external terminal-watching process would see. Both die by `SIGILL` (the
bounds trap), both show the line discipline restored (`ECHO=true
ICANON=true`), confirming `guarded()` around `view`/Cmd execution has no
effect on what Tier 2 catches.

### 3.4 Non-vacuousness — each new guard reverted and re-tested

**View guard** (`tea.odin`'s `guarded_render`, temporarily replaced with a
bare `p.view(...)` call, no `guarded()`):
```
$ odin test runetea -define:ODIN_TEST_NAMES=runetea.test_program_recovers_from_a_panicking_view
[FATAL] ... [tea_test.odin:82:view_boom_view()] panic: view exploded
$ echo $?
132   # killed by SIGILL -- the WHOLE test binary dies, not a clean test failure
```

**Cmd guard** (`cmd.odin`'s `run_cmd_guarded`, temporarily replaced with a
bare `cmd.procedure(...)` call, no `guarded()`):
```
$ odin test runetea -define:ODIN_TEST_NAMES=runetea.test_dispatch_recovers_a_panicking_cmd_on_the_pool
.../cmd_test.odin(75:2) panic: boom on pool
$ echo $?
132

$ odin test runetea -define:ODIN_TEST_NAMES=runetea.test_dispatch_recovers_a_panicking_cmd_when_detached
$ echo $?
132
```
In every case, without the fix the relevant test does not fail gracefully —
it takes the entire test binary down with it, exit 132 (killed by SIGILL on
the unguarded `panic()`), the same "honest, immediate process abort" already
documented in `message-ownership-decision.md` for an unguarded Cmd panic.
This is the proof the new tests actually exercise the fix rather than
passing vacuously. Both guards were restored immediately after this check;
the full suite (§3.5) was re-run clean afterward.

### 3.5 Full suite and race gate

```
$ ./tools/test.sh
Finished 85 tests in 1.142388891s. All tests were successful.
```
85 = the 80 tests present before this task + 5 new
(`test_program_recovers_from_a_panicking_view`,
`test_program_recovers_from_a_panicking_initial_view`,
`test_program_survives_a_panicking_cmd`,
`test_dispatch_recovers_a_panicking_cmd_on_the_pool`,
`test_dispatch_recovers_a_panicking_cmd_when_detached`). Leak report
unchanged in character from before this task (the pre-existing, documented
`guard.odin` `Panic_Info.message` leak on `update`/`view` panic paths; the
new Cmd-panic tests leak nothing new — `run_cmd_guarded` frees its
intermediate panic-message copy, see (c) above).

```
$ ./tools/test.sh race
=== racecheck: all phases completed without crashing (3.302224187s) ===
```
Exit code 0. All six phases clean, including the new Panicked_Msg-count
assertion in phase B (§3.2 above).

Both examples (`examples/simple`, `examples/http`) and every tool under
`tools/` were rebuilt and confirmed to still compile clean after these
changes (the new `Panicked_Msg` type is purely additive to the public
surface; no existing signature changed).

---

## 4. Known residual gaps (recorded honestly, not blockers)

- **A Cmd's own scratch allocations are not reclaimed on panic** — see (c)
  above. Only `cmd.env` and the panic-message copy are explicitly freed;
  anything else the Cmd body allocated via `context.allocator` before
  panicking leaks, the same as any non-guarded Odin code with no RAII would.
  Closing this fully would need a scoped allocator per Cmd invocation, which
  was evaluated and rejected once already for a related reason (Option C,
  per-message arena, `message-ownership-decision.md` §2 — real `mmap`/`munmap`
  cost per allocation, ~456x slower than a plain heap allocation).
- **`guard.odin`'s `Panic_Info.message` leak on the `update`/`view` panic
  paths** is pre-existing (present before this task, documented in
  `message-ownership-decision.md`) and unchanged by this work — `Panicked_
  Error.message` is handed to the caller of `run()`, which owns it, and
  nothing currently frees it if the caller doesn't. The Cmd panic path does
  NOT reproduce this leak (see (c) above) since there is no caller waiting
  on that particular copy.
- **`box()`'s non-POD-type panic inside a Cmd now recovers instead of
  aborting the process** — a genuine behavior change from what
  `message-ownership-decision.md` §2 (Option B) describes ("an honest,
  immediate process abort" for a Cmd body on a pool worker). Flagged in §1(b)
  above; that document itself was left unedited, out of this task's scope.

---

## 5. AMENDMENT 2026-07-27 — Tier 1 no longer protects MODEL STATE

**This section weakens a guarantee the rest of this document was written
under.** Nothing above about *view* or *Cmd* coverage changes; §1(c)'s account
of what each guard reclaims is still accurate as far as memory goes. What
changed is a property that was never called out here explicitly, because at
the time it came for free — and that is exactly why it needs calling out now
that it does not.

### 5.1 What changed

`Program.update`'s signature changed from

```odin
update: proc(model: T, msg: any, alloc: mem.Allocator) -> (T, Cmd)
```

to

```odin
update: proc(model: ^T, msg: any, alloc: mem.Allocator) -> Cmd
```

`view` is unchanged (still by value), and `guarded()` itself is untouched.

The reason is a measured toolchain defect, not a preference: LLVM code
generation for `apply()`'s single by-value `update` call was superlinear in
`sizeof(T)`, capping model size at single-digit kilobytes (32 KiB: 102 s to
build; 64 KiB: did not finish in 200 s; pointer form: ~0.2 s flat out to
256 KiB). The full measurement table and the bisection that pinned it to that
one call live in `docs/superpowers/specs/2026-07-25-runetea-design.md` §5,
under "DECISION REVERSED 2026-07-27".

### 5.2 The property that was lost

With the by-value signature, `apply()` did:

```odin
s.p.model, s.cmd = s.p.update(s.p.model, s.msg, s.alloc)
```

`update` worked on its own copy, and the result only reached `p.model` through
that assignment. `guarded()`'s `longjmp` unwinds nothing and runs no `defer` —
it jumps straight back to the `setjmp` in `guarded()`, **skipping the
assignment entirely**. So a panicking `update` left `p.model` holding the last
good state *by construction*, with no code anywhere written to make that
happen. Tier 1 recovery therefore resumed from a model that was consistent, not
merely intact.

With `^T`, `update` writes into `p.model` directly. A panic partway through
leaves it **half-mutated**: fields written before the panic point are updated,
fields after it are not, and any invariant spanning the two is broken.

### 5.3 What Tier 1 guarantees now, precisely

After a recovered `update` panic:

| | |
|---|---|
| **Guaranteed** | The process survives. The frame arena is reclaimed wholesale (`frame_reset`). The message is `box_free`'d exactly once. `run()` returns `Panicked_Error` carrying the panic text. The session ENDS — the loop does not feed further messages into `update` with the damaged model. The terminal is restored by the caller's own `defer` (unchanged; that was always the caller's job). |
| **NOT guaranteed** | Anything at all about the contents of `p.model`. It may be fully updated, untouched, or inconsistent. |

Because the session ends immediately, the exposure is bounded to whatever the
**caller of `run()`** does with `p.model` after a `Panicked_Error` return.
Callers should treat the model as suspect there — do not persist it, do not
resume from it.

### 5.4 An application cannot roll this back itself

The obvious mitigation does not work, and it is worth being explicit about why
so nobody writes it and believes it:

```odin
update :: proc(m: ^Model, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	old := m^                  // snapshot
	defer if failed { m^ = old }   // NEVER RUNS
	...
}
```

`longjmp` skips the **application's** code exactly as thoroughly as it skips
the framework's. It jumps out of `update` back into `apply()`: no statement
after the panic point runs, no `defer` registered in `update`'s frame runs, and
no error path inside `update` runs. There is nowhere to put a restore.

**The mitigation that does work is structural:** do everything that can fail
FIRST — compute into locals, bounds-check, assert, validate — and write into
`m^` only once nothing further can panic. Then a panic leaves the model exactly
as it was, because nothing had been written yet. This is a discipline for
`update` authors, and it is the whole of the advice.

### 5.5 Not fixed here: an opt-in snapshot

A snapshot mechanism (`Program.snapshot_on_update: bool`, copy `p.model` aside
before the guarded call, restore it on recovery) would restore the old
guarantee for apps that want it, at the cost of one `sizeof(T)` copy per
message. **It was deliberately NOT built as part of this change** — out of
scope, and adding an opt-in safety feature nobody had asked for in the same
change that removes an implicit one is how a trade-off gets obscured rather
than recorded. Noted here as a known, viable option, not as a plan.

### 5.6 Pinned by a test

`runetea/tea_test.odin::test_a_recovered_update_panic_can_leave_the_model_half_mutated`
drives a real `run()` session whose `update` writes one half of a two-field
invariant, panics, and never writes the other. It asserts the resulting state
**exactly** (`a == 1`, `b == 0`, `a != b`), not permissively — a test that
accepted either answer would document nothing. If a future change restores the
old guarantee, that test is designed to FAIL, and its failure is the signal to
come back and rewrite this section.

Also recorded in-code, at length, on `Program.update` and at `apply()`'s
`guarded()` call (`runetea/tea.odin`), and in `examples/editor/edit/editor.odin`'s
capacity comment — which existed *because of* the ceiling this change removed.
