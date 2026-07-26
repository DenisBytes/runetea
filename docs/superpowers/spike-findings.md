# RuneTea T0 spike — findings and go/no-go

Plan: `docs/superpowers/plans/2026-07-25-runetea-spike.md`
Spec: `docs/superpowers/specs/2026-07-25-runetea-design.md` §14
Ledger: `.superpowers/sdd/2026-07-25-runetea-spike/progress.md` (all task-by-task detail;
this document only restates the numbers that bear on the kill criteria)

Toolchain: Odin dev-2026-07-nightly:819fdc7. Linux only. `core:`/`base:` only, no
third-party dependencies. All work committed directly to `master`.

Every number below was measured on this machine on 2026-07-26 (Task 11), or is cited
from a ledger entry produced by an earlier task's controller-verified run. Nothing here
is invented or estimated.

---

## 1. Mailbox — unique values, race gate

`runetea/mailbox_test.odin::test_mailbox_no_loss_under_4_producers` is the spec §14.1
test verbatim: 4 producer threads × 250 values each = **1000 unique values sent**,
collected into a `map[int]bool` by the receiver. Assertion: `len(seen) == 1000`.
**Result: passes — 1000/1000, 0 lost, 0 duplicated** (part of the 51-test suite below).

Race gate: `./tools/test.sh race` (Task 1's `tools/racecheck`, a standalone `main`
program built with `odin build -sanitize:thread`, run under `setarch -R`). This is the
**real** gate — `odin test -sanitize:thread` was proven vacuous on this toolchain (see
§"tsan gate" note below) and is not used for this verdict. Latest run:

```
--- phase A: mailbox (producers + dual consumers + concurrent close) ---
  mailbox: 7975 messages received (some sends may be cut short by the concurrent close)
--- phase B: dispatcher (pool + detached Cmds, destroy while in flight) ---
  dispatcher: 21500 results drained (dispatched 20000 pool + 1500 detached)
--- phase C: signal watcher (concurrent signals + concurrent drain + stop) ---
  signals: 2545 messages drained from 3600 signals sent
--- phase D: Program/run() (reader thread racing async-Cmd and keypress-driven quits) ---
  program: 30 full run() cycles completed (15 async-Cmd quits with no keypress, 15 keypress-driven quits)
=== racecheck: all phases completed without crashing (1.348522714s) ===
```
Exit code 0, no TSan `SUMMARY: data race` report. **Race gate clean.**

**tsan gate note** (Task 1, controller correction 2026-07-26): `odin test
-sanitize:thread` was independently proven to NOT detect races on this toolchain — a
deliberate 4-thread unsynchronized counter raced physically (392997/400000 increments
landed) but `odin test` reported "0 failures" while `odin build` + the same flag caught
it (`SUMMARY: data race`, exit 66). `tools/test.sh race` was built specifically because
of this and is the only result that counts as evidence here. TSan itself (not the
`odin test` runner) was verified bidirectionally against `tools/racecheck`: an injected
unsynchronized counter reproduces `SUMMARY: data race ... main::mb_producer_run`, exit
66; the real primitives, restored, give exit 0. So the harness is proven non-vacuous,
not merely clean by assumption.

**Kill criterion 2 ("mailbox cannot be made race-clean within a week") does not fire.**

---

## 2. nbio — did it work on a real TTY?

Yes. Task 6's `tools/ttycheck` opens a genuine pty pair via
`posix_openpt`/`grantpt`/`unlockpt`/`ptsname` (not a pipe), puts the slave into raw mode
through `term.odin`'s own `term_enter_raw`, associates the **slave** — a real character
device at `/dev/pts/N` — with `core:nbio`, and confirms a read callback delivers bytes
written into the master. Result (ledger, Task 6): "read 9 bytes from tty slave:
tty-hello. ANSWER: YES", 5/5 stable runs, Linux/io_uring backend. A negative control
(skip the raw-mode call) correctly reports a timeout rather than a false positive,
proving the probe is not vacuous.

**IMPORTANT SCOPE CORRECTION (added after the whole-branch review).** The above proves
`core:nbio` *can* read a real character device. It does **not** prove nbio can host the
event loop, and the shipped framework does not use nbio at all: `import "core:nbio"`
appears only in `tools/nbiocheck` and `tools/ttycheck`, never in `runetea/`. What ships
is `loop.odin`'s `Fd_Source` — a hand-rolled `posix.poll` + blocking `read` on a
dedicated thread + a self-pipe wake. That is not a wrapper around nbio; it shares zero
code with it, and it is structurally a miniature of the `cancelreader` the design
(spec §6) promised nbio would delete. Spec §14.2 required BOTH the nbio path and the
`posix.poll` fallback built behind one interface and both tested on Linux; only the
fallback shipped. **"The nbio event loop is RuneTea's event loop" remains an open bet
and should be the first thing T1 either lands or abandons.**

**RESOLVED (first T1 task, `docs/superpowers/nbio-decision.md`):** an
nbio-hosted `run_nbio()` was built, tested (unit tests, a real-pty harness,
and a ThreadSanitizer racecheck phase), and works correctly end to end on
Linux, including the linchpin claim (`nbio.wake_up` genuinely wakes a loop
blocked in `nbio.tick()` from another thread). Decision: **ABANDON as the
primary/shipped loop** — on the one platform this project can verify it is
not shorter, not simpler in the part that matters (input handling
reintroduces a single-thread backpressure hazard the poll-thread design
doesn't have), and the only thing that would justify its cost (Darwin/BSD
support "coming free") is exactly as unverified after this work as before
it. `run()` (`Fd_Source` + reader thread) stays the shipped path; `run_nbio`
stays in the tree, tested, as a head start for whoever eventually validates
Darwin/BSD.

Surprise found along the way: `loop.odin`'s `Fd_Source` (the shipped input path, used by
`run()`'s reader thread) originally treated `EINTR` on `poll`/`read` as
fatal, and had no way to cancel a thread blocked inside a read — both fixed in Task 6
(EINTR retry on both syscalls; a self-owned non-blocking wake pipe polled alongside the
data fd, exposed as `input_wake`). Both fixes were proven non-vacuous by reverting each
in isolation (cancellation hangs, exit 124; EINTR fails deterministically in ~43ms).

Darwin/BSD (the `posix.poll` fallback target) remain **unverified** — no hardware
available in this environment. The fallback *seam* exists (`Input_Source`'s vtable is
backend-agnostic) but the second backend was never implemented, per the plan's explicit
Linux-only scope.

**Kill criterion 1 ("nbio misbehaves on a real TTY and a poll fallback also degrades")
does not fire** — nbio does not misbehave on a real TTY, so the second half of the
conjunction is moot regardless of the fallback's unverified state.

---

## 3. Raw mode — CS8, shell usability

`term.odin:42-46`: yes, the CS8 workaround was needed and is load-bearing. Odin's
`CControl_Flags.CS8` enum member is `log2(CS8)`, and the raw `CS8` value (0x30) is
multi-bit — writing `CControl_Flags{.CS8}` directly truncates to bit 5 (0x20 == CS7),
silently running the tty at 7-bit character size. The fix transmutes through
`posix.tcflag_t` instead of using the typed bit-set literal.

Shell usability after every exit path — controller-verified under real ptys across every
task that touches this:
- Clean exit (Task 2/3): ECHO/ICANON `False,False` during raw mode, `True,True` after
  restore, `\e[?1049l\e[?25h` trailer written, exit 0.
- Tier 2 bounds trap (Task 3): SIGILL(4) → handler → termios restored `True,True`.
- Tier 2 stack overflow (Task 3): SIGSEGV(11) → termios restored `True,True` — this is
  the direct proof the `sigaltstack`/`SA_ONSTACK` fix works; without it the handler
  re-faults on the already-exhausted stack and never reaches `term_restore_c`.
- External SIGINT (Task 10, after wiring `Signal_Watcher` into `run()`): `kill -INT`
  from outside → exit code 0, termios `False,False` during / `True,True` after, restore
  trailer present. (Before that fix, an external SIGINT killed the process outright with
  no defers run and the terminal left raw + alt-screen — found by the reviewer and
  confirmed live.)

**Shell is left usable after every exit path actually exercised.**

---

## 4. Crash safety — Tier 1 and Tier 2

**CORRECTED (T1, `docs/superpowers/tier1-coverage-decision.md`).** As shipped
at the end of the T0 spike, this section's "Tier 1 recovers a panic in user
code" claim was true for exactly one of the three places user code actually
runs — `update`. A panic in `view` or in a Cmd procedure fell straight
through to Tier 2 (the process died honestly, terminal restored, but was not
*recoverable* the way `update`'s was) — see the Addendum's item 7 below,
which flagged this gap without yet closing it. T1's last decision closed it
for all three:

**Tier 1** (`assertion_failure_proc` + `setjmp`/`longjmp`, `guard.odin`):
- **`update`** — unchanged since T0. A `panic()`, a failed `assert()`, or a
  bad type assertion becomes `Panicked_Error`; `run()` returns cleanly, not a
  crash. `tea_test.odin::test_program_recovers_from_a_panicking_update`;
  `guard_test.odin` for `assert()`/bad-type-assertion recovery directly.
- **`view`** — NOW GUARDED. Both call sites (`run()`'s/`run_nbio()`'s initial
  paint and `apply()`'s per-iteration render) share one guarded helper,
  `guarded_render` (tea.odin), so there is exactly one code path to reason
  about, not two that could drift. A recovered view panic renders a
  diagnostic frame (`"[view panicked: <message>]"`) through the real
  Renderer and flushes it, THEN returns `Panicked_Error` — symmetric with
  `update`: either kind of user-code panic ends the `run()` session cleanly,
  and the last thing the user's screen shows explains what happened rather
  than going blank or silently freezing on stale content.
  `tea_test.odin::test_program_recovers_from_a_panicking_view` and
  `::test_program_recovers_from_a_panicking_initial_view`; demonstrated live
  under a real pty by `tools/tier1check view-panic`.
- **Cmd procedures** — NOW GUARDED, on both thread classes. `run_cmd_guarded`
  (cmd.odin) wraps the procedure call inside both `run_cmd_task` (pool
  workers) and `run_cmd_detached`. A panicking Cmd does NOT force `run()` to
  end — it structurally cannot: a background thread has no caller waiting
  synchronously for it the way `apply()` waits on `update`. Instead the panic
  is boxed as an ordinary `Panicked_Msg` (POD, per the message-ownership
  decision) and delivered through the exact same mailbox path as any other
  Cmd result, so the app's own `update` decides what to do with it (log,
  ignore, retry, quit) — the same choice it already has for any other
  Cmd-reported error (`examples/http`'s `Err_Msg` is the existing precedent).
  Pinned on both thread classes directly
  (`cmd_test.odin::test_dispatch_recovers_a_panicking_cmd_on_the_pool` /
  `::test_dispatch_recovers_a_panicking_cmd_when_detached`) and end-to-end
  through a real `Program`/`run()` session
  (`tea_test.odin::test_program_survives_a_panicking_cmd`, which only passes
  if the app's `update` genuinely observes the `Panicked_Msg`). Also
  exercised at volume — 20000 pool-dispatched + 1500 detached Cmds, roughly
  10% panicking — under real ThreadSanitizer by `tools/racecheck` phase B,
  which asserts the drained `Panicked_Msg` count matches the expected count
  exactly; this is what proves `guard.odin`'s `thread_local` recovery state
  survives thousands of arm/disarm cycles reusing the SAME pool worker OS
  threads, not just a single-shot unit test.
- **Non-vacuousness**, all three: each guard was temporarily reverted and its
  test re-run. Without the fix the relevant test does not fail gracefully —
  it takes the ENTIRE test binary down with it (`odin test` exits 132, killed
  by SIGILL on the unguarded `panic()`), the same "honest, immediate process
  abort" already documented in message-ownership-decision.md for an
  unguarded Cmd panic. Exact transcripts in
  `docs/superpowers/tier1-coverage-decision.md`.

**Tier 2** (signal handlers + `sigaltstack`, bypassing `assertion_failure_proc`
entirely since bounds traps and SIGSEGV never go through it): controller-verified under
a real pty (Task 3) —
- Bounds violation → SIGILL(4) → handler emits `\e[?1049l\e[?25h` → dies by signal with
  an honest exit status, termios restored `True,True`.
- **Stack overflow → SIGSEGV(11) → termios restored `True,True`.** This is the one that
  matters most: without the `SA_ONSTACK` alternate-stack fix, a stack-overflow SIGSEGV
  delivers on the exhausted stack and the handler's own `tcsetattr`/`write` calls can
  re-fault before `term_restore_c` completes, silently defeating Tier 2 for its single
  commonest real-world trigger (runaway recursion). The fix (a package-global
  `g_altstack_buf`, installed at `install_crash_handlers()` time) was verified to close
  exactly that hole.

Wrapping `view` and Cmd procedures in `guarded()` (above) does not shrink Tier
2's reach: a bounds violation inside either still traps directly and bypasses
`assertion_failure_proc` entirely, unaffected by the new `guarded()` calls
sitting around them — re-verified live under a real pty, not just assumed by
analogy to T0, via `tools/tier1check view-bounds` (trap inside `view`) and
`tools/tier1check cmd-bounds` (trap inside an init Cmd on a pool worker
thread): both die by SIGILL with termios restored `True,True`, exactly like
the T0-era `tools/crashcheck` baseline this extends.

Known residual gaps, carried forward as v1.0 findings (§ below): `sigaltstack`
is per-thread, installed only on whichever thread calls
`install_crash_handlers()` — the pool workers (Task 5) and the signal-watcher
thread (Task 7) have no altstack of their own, so a stack-overflow SIGSEGV on
those threads still defeats Tier 2. (An earlier draft of this section also
flagged `guarded()`'s nesting guard as riding on `assert(!g_armed, ...)`,
stripped by `-disable-assert` — that was fixed in the closing fix-wave,
commit `a0149d6`, see the Addendum's fixed-item 3 below; `guarded()`'s
re-entrancy check is an explicit `if g_armed { ... }` today, not an `assert`,
and survives `-disable-assert`. Listed here only to correct the stale
cross-reference, not as a live gap.)

---

## 5. Msg — cross-package type switch

Yes. `tools/msgcheck/main.odin` defines `User_Tick :: struct { n: int }` in `package
main` — a type `runetea` has never seen — boxes it via `rt.box(User_Tick{n = 99}, ...)`,
and matches it with a plain `switch v in msg { case User_Tick: ... }` in the same
foreign package. Measured output: **`matched user-defined type, n = 99`**. This was the
make-or-break assumption for the whole `Msg`-as-`any` design (Odin has no interfaces the
way Go does, so there is no other mechanism for a library to accept caller-defined
message types); it holds.

---

## 6. Cmd ergonomics — examples/http, the headline number

Go original: `/home/denisbytes/dev/bubbletea/examples/http/main.go`.
RuneTea port: `examples/http/main.odin`.

**TLS gap, recorded up front:** the Go original fetches `https://charm.sh/`. Odin core
has TCP and DNS (`core:net`) but no TLS — `core:crypto` ships primitives, not the
protocol — and the plan forbids third-party dependencies, so the Go original cannot be
ported faithfully. This port does a real HTTP/1.1 GET over plain `http://example.com:80`
instead. Verified against a real, unmodified network path in this environment
(`curl http://example.com/` returns `200 OK` from the same host) — the request in
`examples/http` genuinely resolves DNS, opens a TCP socket, sends bytes, and parses a
live response; it is not a simulation. This is a real v1.0 gap: a faithful HTTPS port
needs either a TLS dependency or Odin core growing one.

**Live behaviour**, driven through a real pty (`tools/run_http_pty.py`-style harness,
this task):
```
first frame at: 0.002s
total elapsed: 0.020s
OUTPUT: b'Checking http://example.com ...\r\n\x1b[1A\x1b[2Khttp://example.com -> 200\r\n\x1b[?1049l\x1b[?25h'
```
The "Checking..." frame paints immediately (2ms), the real status (200) arrives and
repaints ~18ms later with **no keypress sent**, and the program exits cleanly. This is
the scenario the whole mailbox-as-single-wait-point design (Task 10) exists to make
possible; it works end to end against a live host, not a mock. **The real HTTP path
ran** (not the `Err_Msg` fallback) — network access was available in this sandbox.

**LOC measurement** (`wc -l`, both files, as-shipped):

| | Go | Odin | raw ratio |
|---|---:|---:|---:|
| Raw (`wc -l`) | 82 | 105 | **1.28x** |
| Stripped (blank lines + full-line comments removed) | 64 | 75 | **1.17x** |

**The closure tax, isolated.** Of Odin's 75 stripped lines, exactly **3** exist *only*
because Odin has no closures:
- `Check_Env :: struct { host: string, port: int }` — the named env carrier Go's
  `checkServer` closure doesn't need (it captures `url` directly from package scope).
- `e := cast(^Check_Env)env` — unwrapping the `rawptr` back into a typed struct inside
  `check_server`.
- `init := rt.cmd_from(check_server, Check_Env{host = HOST, port = PORT},
  context.allocator)` — the explicit heap-clone-and-bind call that replaces Go's bare
  `return checkServer` (itself inside a 3-line `Init()` method Odin's design doesn't
  need at all, since `program_init` takes the init `Cmd` as a plain argument).

That is **3 of 75 lines (4%)** attributable to the closure workaround specifically.

**What actually drives the other ~8-11 lines of the delta** is not the `Cmd` design —
it's that `core:net` has no HTTP client. Go's `checkServer` body is 9 lines including a
one-line `c.Get(url)` that does DNS, dial, request, and response parsing. RuneTea's
`check_server` body is 22 lines because it hand-rolls the HTTP/1.1 request text, sends
it over a raw TCP socket, and manually parses the status code out of response bytes
9:12 — none of that is Cmd/closure overhead, it is reimplementing a stdlib gap. Partially
offsetting this, Go pays its own boilerplate RuneTea's design avoids: the 3-line
`Init()` method (folded into a single argument to `program_init` in Odin) and the
2-line `errMsg`/`Error()` wrapper needed to satisfy Go's `error` interface (RuneTea's
`Err_Msg` is a plain struct with no interface to satisfy).

**Would you write an app this way?** Yes. The closure-tax is real, permanent, and
touches every `Cmd`-using program, but it is small (3 lines, 4%, for a Cmd carrying
two fields) and mechanical — env struct, one cast, one `cmd_from` call, the same shape
every time. It is not the thing that would make ergonomics bad enough to stop; the
bigger, honest cost of this port was the absence of an HTTP client in `core:net`, which
is a stdlib-completeness question, not a language-design one.

**Kill criterion 3 ("examples/http ergonomics are bad enough you would not write an app
that way") does not fire.**

---

## 7. Parapoly — Program($T) through the rawptr guard boundary

Survived intact, no monomorphic fallback needed. `Program :: struct($T: typeid)` is
generic; `run(p: ^Program($T), ...)` and its private `apply(p: ^Program($T), ...)` stay
generic all the way down to the crash-recovery boundary, where `apply` builds a
file-private `Step($T)` struct, takes its address as a `rawptr`, and calls
`guarded(proc(ud: rawptr) { s := cast(^Step(T))ud; ... }, &step)` — `guarded()` itself
is fully non-generic (`proc(ud: rawptr) `) and knows nothing about `T`, yet the closure
body recovers the concrete type on the other side of the boundary. Confirmed by at least
four distinct instantiations compiling and running against the same shared machinery:
`Program(Counter)` and `Program(Boom)` (`tea_test.odin`), `Program(Model)` in
`examples/simple` and a **different** `Program(Model)` (unrelated struct, same name) in
`examples/http` — all four pass their respective tests / run live.

---

## 8. Total LOC

```
$ find runetea -name '*.odin' -not -name '*_test.odin' | xargs wc -l
  118 runetea/mailbox.odin
   83 runetea/term.odin
  165 runetea/signals.odin
  121 runetea/guard.odin
   54 runetea/render.odin
  198 runetea/loop.odin
   75 runetea/arena.odin
  164 runetea/cmd.odin
  238 runetea/tea.odin
  188 runetea/input.odin
 1404 total
```

**1404 non-test LOC against the spec's ~900 target — 1.56x over.** (Test files add
another ~1140 LOC on top, for 2544 total under `runetea/`; `examples/` and `tools/`
verification harnesses add roughly another 1100 LOC not counted here, since the spec's
own instruction for this measurement scopes it to `runetea` non-test files.) This is a
real overage, not hidden: a meaningful share of it is the extensive doc comments this
spike leaned on to record every load-bearing gotcha found along the way (ordering
invariants, lifetime contracts, the reasons behind non-obvious workarounds like CS8 and
`msg.id != nil`) — valuable for a spike whose job was to surface exactly those gotchas,
but not "framework code" in the narrow sense the 900-line estimate likely meant. Not a
kill criterion on its own, but a real planning input for T1: budget more than ~900 LOC
for the next phase, or budget separately for comments vs logic.

---

## Kill criteria — explicit verdict

From spec §14:

| Criterion | Fires? | Evidence |
|---|---|---|
| nbio misbehaves on a real TTY **and** a `posix.poll` fallback also degrades | **No** | nbio works cleanly on a real pty (§2); fallback is unimplemented but the first half of the conjunction is false, so this does not fire |
| Mailbox cannot be made race-clean within a week | **No** | `tools/racecheck` (the real gate) reports 0 races across 4 phases, proven non-vacuous by injected-bug reverts (§1) |
| `examples/http` ergonomics bad enough you would not write an app that way | **No** | closure tax measured at 3/75 stripped lines (4%); the larger LOC delta is a stdlib (HTTP client) gap, not a `Cmd`-design gap (§6) |

**None of the three kill criteria fire.**

## GO.

Proceed to T1 (spec §12): a real CSI/SS3 decoder, `batch`/`sequence` with the elastic
overflow path, and the alt-screen mode diff.

---

## v1.0 findings (real gaps, not spike blockers)

Recorded for the next phase's backlog, all measured/observed during this spike, none
invented:

- **No TLS in Odin core.** Blocks a faithful `https://` port of `examples/http`
  (§6 above). `core:crypto` ships primitives only, not the TLS protocol. Needs either a
  dependency (against the current no-third-party-deps rule) or Odin core growing one.
- **Boxed messages are never freed after `mailbox_recv`.** Every `+++ leak` line in this
  task's own `odin test` output (`arena.odin:71:box()`) is this: `box()` heap-allocates
  via `context.allocator`, the mailbox hands the `any` to `apply()`, and nothing ever
  calls `free()` on it once the frame arena/update cycle is done with it. Unbounded over
  session length — a long-running TUI receiving key/Cmd-result messages continuously
  leaks one allocation per message. Originates in the Task 4/5 design (frame-arena
  boxing was solved; heap-`context.allocator` boxing for cross-thread messages was not
  given a symmetric free). Not fixed in this spike; flagged for T1.
- **`odin test -sanitize:thread` is not a race gate on this toolchain.** Proven with a
  deliberate unsynchronized counter: the race physically occurs (confirmed via a plain
  `odin build` binary and via manual count), but `odin test -sanitize:thread` reports
  "0 failures" regardless. `tools/racecheck` (a standalone `odin build`-based harness)
  is the only validated substitute; any future CI setup must use it, not `odin test
  -sanitize:thread`, or races will pass silently.
- **`sigaltstack` is per-thread.** Only the thread that calls `install_crash_handlers()`
  gets an alternate signal stack. The pool workers (Task 5's `thread.Pool`) and the
  signal-watcher thread (Task 7) have none, so a stack-overflow SIGSEGV on any of those
  threads still defeats Tier 2 crash safety exactly the way it did before the
  `SA_ONSTACK` fix on the main thread. Neither handled nor previously documented outside
  the ledger; needs a per-thread altstack story (e.g. install on every `thread.Pool`
  worker at spawn) before Tier 2 can be called complete.
- **`guarded()`'s nesting assert is stripped by `-disable-assert`.** The re-entrancy
  guard that prevents a nested `guarded()` call from corrupting `g_guard`'s single
  `jmp_buf` per thread is implemented as `assert(!g_armed, ...)` — compiled out entirely
  under `-disable-assert` (a build users may reasonably choose for a release binary).
  Under that flag the original jump-buffer-corruption hazard returns silently, with no
  observable symptom until a nested-guard bug actually fires. Needs a non-assert guard
  (an explicit `if g_armed { return recovered-failure }` rather than a trapping check) if
  Tier 1 is meant to hold in release builds.

---

## Test verification (Task 11)

```
$ ./tools/test.sh
...
Finished 51 tests in 282.901864ms. All tests were successful.
```
51 = the 50 tests present before this task + `test_golden_simple_session`
(`runetea/golden_test.odin`), the golden-byte harness this task adds.

```
$ ./tools/test.sh race
=== tools/racecheck ===
--- phase A: mailbox ... ---           7975 messages received
--- phase B: dispatcher ... ---        21500 results drained (20000 pool + 1500 detached)
--- phase C: signal watcher ... ---    2545 messages drained from 3600 signals sent
--- phase D: Program/run() ... ---     30 full run() cycles completed
=== racecheck: all phases completed without crashing (1.348522714s) ===
```
Exit code 0 both runs.

### Golden harness — what was actually inspected

`runetea/testdata/simple_session.golden`, generated with
`-define:GOLDEN_UPDATE=true` and inspected with `cat -v`:
```
count: 0^M
^[[1A^[[2Kcount: 1^M
^[[1A^[[2Kcount: 2^M
^[[1A^[[2Kcount: 2^M
```
64 bytes. This is a `Program(Counter)` driven by the byte script `"aaq"`
(`input_source_from_bytes`) with no terminal involved. Four frames, matching the byte
script exactly: the initial paint (`count: 0`, before any input is read), then one
repaint per keypress (`\e[1A\e[2K` = cursor up one line + erase to end of line, the
naive renderer's rewind, per Task 9). The two `a` keys increment the counter to `1` then
`2`; the third byte, `q`, does not increment the counter (`counter_update`'s `q` branch
sets `done` and returns `quit_cmd()` without bumping `n`) but still triggers one more
render of the *current* model state before the async `Quit_Msg` arrives and `apply()`
short-circuits without a further render — hence the repeated `count: 2` as the fourth
and final frame. Every escape sequence present (`\r` as line terminator, `ESC [ 1 A`,
`ESC [ 2 K`) is exactly what `render.odin`'s rewind-and-repaint design is documented to
emit; nothing unexpected is in the file.


---

## Addendum — findings from the whole-branch review (added after §1-§8 were written)

The per-task reviews could not see these; a final cross-cutting pass found them.
Four were fixed in the closing fix wave; five are T1 design inputs. Recorded here
because §1-§8 read as a closing argument and omitted them.

**Fixed in the closing fix wave (commit `a0149d6`):**

1. **CRITICAL, and it would have shipped.** `mailbox_send` returned `false` for both
   *closed* and *full*, and the reader treated both as terminal — returning WITHOUT
   closing the mailbox, so the main loop blocked forever in `mailbox_recv`. Pasting
   ~1000 characters into `examples/simple` was enough. Measured: 300 and 500 chars
   fine, 1000 hangs. Now returns a three-way result; the reader retries on Full and
   exits only on Closed. Verified: 2000- and 8000-char pastes exit cleanly.
2. `sigaltstack` is per-thread — pool workers, detached Cmds, the watcher and the
   reader had none, so Tier 2 was false on three of four thread classes.
3. `guarded()`'s nesting guard was an `assert`, stripped by `-disable-assert`.
4. Both examples called `install_crash_handlers` *after* `term_enter_raw`, and the
   framework emitted an alt-screen exit (`\e[?1049l`) it never entered.

**Open — T1 design inputs, NOT defects in the bet:**

5. `run()` cannot return until the slowest in-flight Cmd finishes, and nothing can
   cancel one. Measured: one 2-second Cmd → quit takes 2.000s. `examples/http` has no
   socket timeout, so a stalled host freezes the UI with the terminal still raw.
6. The renderer rewinds *logical* lines, not *physical* rows. Any line wider than the
   terminal wraps and the rewind under-counts, corrupting the display progressively.
   `term_size()` exists and the renderer never consults it. The golden harness
   therefore certifies only short lines.
7. **RESOLVED (T1, `docs/superpowers/tier1-coverage-decision.md`).** Tier 1
   (`guarded`) originally wrapped `update` only — `view` and Cmd bodies ran
   unguarded, so a panic in either fell through to Tier 2 (safe — the process
   died honestly, terminal restored — but not *recoverable* the way a panic
   in `update` was). T1 extended `guarded()` coverage to both remaining
   call sites: `view` via a shared `guarded_render` helper covering both
   places it runs (`run()`'s/`run_nbio()`'s initial paint and `apply()`'s
   per-iteration render), and Cmd procedures via `run_cmd_guarded`, wrapping
   both thread classes (`run_cmd_task` for the pool, `run_cmd_detached` for
   detached Cmds). The two endings deliberately differ: a view panic renders
   a diagnostic frame then ends `run()` with `Panicked_Error`, symmetric with
   `update`, because `apply()` has a synchronous caller to return that to; a
   Cmd panic instead becomes an ordinary `Panicked_Msg` delivered through the
   mailbox, because a pool/detached thread has no such caller and one
   exploding background Cmd should not be allowed to force the whole session
   to end. See §4 above and the decision doc for the full design, the
   diagnostic-vs-blank-screen reasoning, and the non-vacuous revert-and-retest
   proof for each guard.
8. Message ownership is undefined and `examples/http` has already committed to an
   answer (it stores a pool-allocated string straight into the model). Decide
   borrow-vs-own **before** T1 writes more examples.
9. See the nbio scope correction in §2.

**LOC, measured correctly.** §8's 1404 counts comments. Stripped: **714 lines of code
against the ~900 target — 21% under.** 555 lines (40%) are comments, some of which now
describe architectures the code does not implement and need a correctness pass. The
real T1 planning input is that the *verification apparatus* (1140 test LOC + ~1100 LOC
of `tools/` harnesses) cost roughly 3x the framework itself.
