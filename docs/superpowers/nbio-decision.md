# The nbio-hosted event loop — built, measured, decided

**Date:** 2026-07-26
**Status:** Decided — ABANDON as T1's primary loop; keep run_nbio in-tree as a
tested reference implementation
**Toolchain:** Odin dev-2026-07-nightly:819fdc7. Linux only.

Spec §6 (`docs/superpowers/specs/2026-07-25-runetea-design.md`) claims "the
nbio event loop IS RuneTea's event loop" and uses that claim to justify
deleting `muesli/cancelreader` (844 Go LOC / 4 platform backends) and
declaring Darwin/BSD support "upstream's problem." The T0 spike proved
`core:nbio` can **read** a real tty (`tools/ttycheck`) but never proved it can
**host the loop** — what shipped instead was `loop.odin`'s `Fd_Source`
(`posix.poll` + blocking `read` on a dedicated thread + a self-pipe wake), a
hand-rolled miniature of the exact cancelreader design nbio was supposed to
delete. This document closes that open bet.

**The bet is TRUE: nbio can host the loop, and does, correctly, on Linux.**
**The decision is ABANDON anyway: on the one platform this project can verify,
hosting the loop on nbio is not simpler, not shorter, and introduces a new
class of bug the poll-thread design doesn't have — and the only thing that
would justify accepting that cost (Darwin/BSD "coming free") is exactly as
unverified after this work as before it.**

---

## 1. What was built

A second, complete event-loop host, coexisting with `run()` — nothing in the
existing path was deleted or modified in a way that could change its
behavior:

| File | What |
|---|---|
| `runetea/loop_nbio.odin` (219 LOC) | `run_nbio(p, fd, out, flush_fd)` — associates `fd` with `core:nbio`, drives reads through an nbio read-op callback loop, dispatches Cmds through the same `Dispatcher`, runs the same guarded `apply()` (Update/View/render) on the loop thread |
| `runetea/loop_nbio_test.odin` (193 LOC) | 4 headless tests: keypress+quit, async-Cmd-quit-with-no-keypress, a 2000-key mailbox-overflow regression, and a byte-for-byte `run()` vs `run_nbio()` output-parity check |
| `runetea/cmd.odin`, `runetea/signals.odin` (+52/+25 lines) | `Dispatcher` and `Signal_Watcher` gain an **optional** `wake: proc(rawptr)` / `wake_data: rawptr` hook, called after a successful `mailbox_send`. `nil` by default — run()'s poll-thread path is unchanged; `run_nbio` sets it to a thin wrapper around `nbio.wake_up` |
| `runetea/mailbox.odin` (+14 lines) | `mailbox_closed_and_empty()` — the non-blocking analogue of `mailbox_recv`'s `ok=false`, needed because `run_nbio` must never block on the mailbox itself (nbio owns the blocking wait) |
| `runetea/tea.odin` (+13/-2 lines) | `apply` and `flush_frame` widened from `@(private="file")` to `@(private="package")` so `run_nbio` reuses them verbatim — both hosts run **identical** Update/View/quit/panic-recovery logic |
| `tools/nbiowakecheck/main.odin` (96 LOC) | Isolated, minimal proof that `nbio.wake_up()` from another thread interrupts a blocked `nbio.tick()` — no Mailbox, no Dispatcher, no tty, so a positive result can't be attributed to anything else |
| `tools/simple_nbio`, `tools/http_nbio`, `tools/asyncdelay_nbio` (48+99+59 LOC) | `examples/simple` / `examples/http` ported onto `run_nbio`, for pty-driven verification (§2a/2b below) |
| `tools/racecheck/main.odin` (+59 lines) | Phase E: the same `Program`/`run()` concurrency stress Phase D already runs (30 cycles, half async-Cmd-quit, half keypress-quit), but through `run_nbio` |

**Net LOC added: +279 non-test, +193 test, +361 tools/verification** (exact
numbers in §5e). Nothing was removed — both paths ship, both pass the full
suite.

---

## 2. Answers, with evidence

### 2a. Does it work end to end on a real pty?

Yes, unambiguously. Driven with `python3 pty.fork()` + `os.execv()` (the same
approach used throughout T0), against `tools/simple_nbio`:

```
initial: b"Hi. This program will exit on 'q'.\r\n\r\nKeys pressed: 0\r\n"
after b'a': b"\x1b[1A\x1b[2K...Keys pressed: 1\r\n"
after b'b': b"\x1b[1A\x1b[2K...Keys pressed: 2\r\n"
after b'c': b"\x1b[1A\x1b[2K...Keys pressed: 3\r\n"
after q:    b"\x1b[1A\x1b[2K...Keys pressed: 3\r\n"
exit status: 0   exit_code: 0   signaled: False
```

Each keystroke produces its own, separately-observed repaint (1, 2, 3 across
four distinct reads with pacing in between) — proof of live per-keypress
updates through the nbio callback, not one batched update at exit. `'q'`
quits cleanly, exit code 0.

Terminal restore, checked via `termios.tcgetattr` on the pty before/during/
after (5/5 stable runs):

```
during raw mode: ECHO = False ICANON = False
after exit:      ECHO = True  ICANON = True
```

External SIGINT (`kill -INT` from outside, not a terminal-generated Ctrl+C —
the case that killed the process outright before Task 10 wired the
`Signal_Watcher` into `run()`) against the nbio-hosted loop, 5/5 stable:
caught, terminal restored, exit 0, not signaled.

### 2b. Does `nbio.wake_up` genuinely wake a blocked loop from another thread? (the linchpin)

**Yes — proven three independent ways, all consistent.**

**Isolated** (`tools/nbiowakecheck`, no Mailbox/Dispatcher/tty involved — the
smallest possible reproduction): acquire a loop, spawn a plain worker thread
(no event loop of its own) that sleeps 200ms then calls `nbio.wake_up(loop)`,
call `nbio.tick(5 * time.Second)`. 3/3 runs:

```
phase 1: tick() returned after 200.16ms  (err=None, woken_flag=true)
ANSWER (2b, positive): YES

phase 2 (negative control, no wake_up call): tick() returned after 300.04ms
ANSWER (2b, negative control): as expected -- tick() blocks for its own timeout
```

The negative control matters: it rules out "tick() just returns quickly
regardless." Only with an explicit `wake_up()` call does it return close to
the sleep duration instead of the timeout ceiling.

**Integrated, deterministic** (`tools/asyncdelay_nbio`, under a real pty): an
init `Cmd` sleeps 300ms on a `Dispatcher` pool worker, then resolves. 3/3
stable runs:

```
frame 1 at 0.003s: b'waiting ...\r\n'
frame 2 at 0.304s: b'...ready: value=42\r\n'
gap between frames: 0.300s
```

The loop thread was parked in `nbio.tick()` with **nothing else pending** —
no keypress, no other I/O — for exactly the sleep duration, then woke the
instant the pool thread's `mailbox_send` + `nbio.wake_up` fired.

**Integrated, real network** (`tools/http_nbio`, real DNS/TCP/HTTP against
`example.com`, no keypress ever sent): 4/4 stable runs, `-> 200`, exit 0.

Architecturally this is also provably race-free by construction, not just
empirically clean: `nbio.wake_up`'s Linux implementation writes to an
eventfd opened with `.SEMAPHORE` — a persistent kernel counter, not an
edge-triggered flag — so a `wake_up()` that races ahead of the loop calling
`tick()` again is not lost; the next `tick()` sees the accumulated count
immediately instead of blocking. `runetea/loop_nbio.odin`'s outer loop
relies on exactly this property (see its comment above the drain loop).

### 2c. Coexistence with the Cmd pool and Signal_Watcher?

**Yes, with zero conflict** — and this was almost too easy to be the
interesting finding it first looked like. `core:nbio`'s one-loop-per-thread
rule is about which thread **acquires** an event loop; it says nothing about
which threads may call `wake_up` on someone else's loop. Neither the
`Dispatcher`'s pool workers, nor a detached Cmd's own thread, nor the
`Signal_Watcher` thread ever call `nbio.acquire_thread_event_loop()` — they
only touch the already-thread-safe `Mailbox` and then call the `wake` hook,
which is exactly the documented, supported cross-thread pattern
(`core:nbio/doc.odin`'s own "Threading" section describes a worker thread
executing work against another thread's loop reference).

Evidence at volume, under ThreadSanitizer (`tools/racecheck` Phase E, added
this task): 30 full `run_nbio()` cycles (15 async-Cmd-quit-with-no-keypress,
15 keypress-quit), the `Dispatcher` pool and `Signal_Watcher` both live and
producing concurrently with the loop thread ticking/reading/tearing down —
**0 races, exit 0**, run back-to-back with the unmodified Phase D (`run()`)
so a regression in either path would show up on its own.

### 2d. Shutdown — how does it compare to `input_wake` before join?

**Structurally simpler**, and this is nbio-hosting's one genuine, durable
win. `run()`'s reader thread is a second OS thread parked in `input_read`;
shutting it down needs the self-pipe wake (`input_wake`) called *before*
`thread.join`, or the join hangs forever (this is exactly the ordering
`tools/racecheck` Phase D's own comment calls "THE shutdown-order
assertion"). `run_nbio` has no second thread reading input at all — the read
callback runs on the loop's own calling thread. `core:nbio`'s own documented
guarantee ("Callbacks are guaranteed to be invoked in a later tick, never
synchronously") means that once `run_nbio`'s `for !p.quit` loop stops calling
`nbio.tick()`, no further callback can ever fire. **Not calling tick() again
IS the entire shutdown** — there is no cancellation primitive to remember to
invoke.

The one thing that *is* still load-bearing, and non-obvious, is `defer`
ordering: the `Dispatcher` and `Signal_Watcher` must be fully stopped and
joined **before** `nbio.release_thread_event_loop()` tears down the ring —
otherwise a pool worker could call `wake_up()` on an already-destroyed loop.
`run_nbio`'s defer order (verified by reading it back, not just written and
trusted) is: `dispatcher_destroy` → `signal_watcher_stop` →
`nbio.release_thread_event_loop()` → `mailbox_destroy` → `frame_arena_destroy`
— LIFO from declaration order, deliberately mirroring the same ordering
constraint `run()` already documents for its own reasons (producers must stop
before the mailbox they write into is destroyed).

### 2e. LOC delta

Measured via `git diff --stat` against unmodified HEAD (`da381ec`) plus
`wc -l` on new files — exact, not estimated:

| | LOC |
|---|---:|
| `runetea/loop_nbio.odin` (new) | +219 |
| `runetea/cmd.odin`, `mailbox.odin`, `signals.odin`, `tea.odin` (shared hooks) | +60 net (82 insertions, 22 deletions) |
| **Framework non-test total** | **+279** |
| `runetea/loop_nbio_test.odin` (new) | +193 |
| `tools/nbiowakecheck`, `simple_nbio`, `http_nbio`, `asyncdelay_nbio` | +302 |
| `tools/racecheck` Phase E | +59 |

All additive — nothing was deleted, per this task's explicit instruction to
keep both paths. But it's worth asking the counterfactual spec §6 actually
promises: **if nbio ever fully replaced the poll-thread path**, what would
that trade look like? `loop.odin`'s `Fd_Source` (the fd-backed struct plus
its poll/read/wake procs specifically, not `Bytes_Source`, which a testing
seam still needs regardless) is ~104 LOC; `tea.odin`'s `reader_thread` is
~57. That's **~161 LOC removable** against **~279 LOC added** — nbio-hosting
is **not a net LOC reduction on Linux**, even in the best case of deleting
the old path outright. Spec §6's LOC argument was real, but it was about
*not writing three more platform-specific backends* (Darwin kqueue, BSD
kqueue, Windows IOCP) for `Fd_Source`, not about Linux being shorter — and
that argument is completely unaffected by anything measured in this
document, because Darwin/BSD remain exactly as unverified as before.

One more measured cost: importing `core:nbio` into the `runetea` package
pulls it into **every** program that imports the package, whether or not it
ever calls `run_nbio`. Measured directly (`git stash -u`, rebuild
`examples/simple`, which never calls `run_nbio`, before and after):
**494,672 → 499,904 bytes, +5,232 bytes (~1%)**, purely from the transitive
`core:nbio`/io_uring import.

### 2f. nbio behaviour that is wrong or surprising for a TTY

Two of the three things found are old news confirmed again, not new
surprises: canonical/cooked mode still blocks reads until a newline
regardless of nbio (a line-discipline effect, term_enter_raw is still
required, exactly as Task 6 found), and `nbio.read`'s positional `offset`
parameter is safely ignored for a non-seekable character device (confirmed
again working correctly, `offset=0` throughout).

**The one real, non-obvious finding: nbio's single-thread callback model
reintroduces the exact class of bug FIX 1 already found and fixed once.**
The final fix-wave report (`spike-findings.md` addendum) found and fixed a
critical bug: `reader_thread` decoding faster than the main loop drains,
filling the 256-slot mailbox, and the reader treating Full the same as
Closed — hanging `run()` forever on a 1000+ character paste. The fix there
was cheap because there are two threads: the reader retries with
`thread.yield()`, and the *other* thread (running `apply()`) makes room
concurrently, for free, via normal OS scheduling.

**That fix does not port to `run_nbio` at all.** There is no other thread —
the nbio read callback that decodes a paste burst into keys runs on the
*same* thread that would need to drain the mailbox to make room. A naive
port of the retry-with-yield pattern into `nbio_on_read` **self-deadlocks**:
yielding a thread that is the only thing that can ever unblock it does
nothing. This was caught by design, not by accident — writing
`test_run_nbio_survives_a_mailbox_overflow` (2000 `'a'`s into a 256-slot
mailbox, mirroring the original FIX 1 regression test almost exactly) before
trusting a naive implementation would have caught it the hard way (the whole
test suite hanging). The actual fix
(`runetea/loop_nbio.odin`'s `nbio_flush_backlog`) is a small state machine:
stop decoding further, remember how far the current batch got, and resume
issuing reads only once the backlog is fully drained by the *same* thread's
own next loop iteration — architecturally different from, and more subtle
than, the two-thread fix. The regression test passes (56/56 tests, whole
suite in 325ms — no hang), but the fact that this had to be independently
re-discovered and re-solved, in a harder form, is itself evidence: **the
single-loop-thread design makes this class of bug easier to reintroduce by
accident in future development** (anyone adding a new nbio-driven producer
later must remember the "never block/spin inside a callback" invariant by
hand) than the two-thread design, where the OS scheduler enforces the
equivalent property automatically.

A smaller, structural surprise, not a bug: `Input_Source`'s vtable (built
for "poll, then blocking read, cancelled by a wake byte") turned out to have
**no meaningful nbio implementation at all**. `run_nbio` takes a raw `fd`,
not an `^Input_Source` — there is nothing to "poll" when reads are already
async callbacks, and nothing to "cancel via wake byte" when there's no
second thread blocked anywhere to cancel. The two hosts share every layer
*above* input (`Program`, `apply`, `Mailbox`, `Dispatcher`, `Signal_Watcher`,
`Renderer`) but not the input layer itself, which was the one piece
originally believed to be the abstraction seam between them.

---

## 3. Recommendation: ABANDON as the primary loop

**Do not make `run_nbio` RuneTea's shipped default for T1. Keep `run()`
(the poll-thread path) as the sole path examples and future T1 work build
on. Keep `run_nbio` in the tree — tested, documented, and cheap to keep
green — as a reference implementation for whoever eventually gets Darwin/BSD
hardware, not because today's Linux-only evidence justifies migrating to it.**

This is a genuine "the bet resolved true but the decision is still no," and
the reasoning is worth stating precisely rather than hand-waved:

1. **The mechanism is proven, and that was the actual open question.** §2a-2d
   above close the scope correction in `spike-findings.md` §2 cleanly: nbio
   *can* host the loop, `wake_up` *does* wake it from another thread, and it
   *does* coexist with the pool and signal watcher. That is real, durable
   knowledge this project didn't have before today.

2. **But the only thing that would make hosting the loop on nbio worth its
   cost is Darwin/BSD support "coming free," and that is exactly as
   unverified after this work as before it.** Nothing in this environment
   can test a kqueue backend. The spec itself already flags the specific,
   documented risk: `ultraviolet/poll_bsd.go`'s own comment that "kqueue
   returns instantly when polling /dev/tty" — a tty-specific kqueue
   misbehavior two independent Charm implementations five years apart both
   hit. Proving io_uring behaves on Linux says nothing about whether that
   exact, named landmine is still there.

3. **On the one platform this project can actually verify, hosting the loop
   on nbio is not a win by any measure that was collected.** It is not
   shorter (+279 LOC added vs. ~161 LOC removable in the best case, §2e). It
   is not simpler in the part that matters most (input handling, §2f) — it
   is measurably *more* subtle, having reintroduced and required an
   independent re-fix for a bug class already paid down once. The one place
   it *is* simpler (shutdown, §2d) is a real but minor ergonomic win, not a
   correctness or maintenance win large enough to offset the rest.

4. **The poll-thread path is not blocking anything.** It is proven, ships
   today, is covered by 52 (now 56) tests and a real ThreadSanitizer gate,
   and ties RuneTea's terminal I/O to `posix.poll` + `read` — the two most
   universally portable, most-exercised, least-surprising syscalls that
   exist, rather than to `core:nbio`'s still-young io_uring/kqueue/IOCP
   abstraction layer.

5. **Maintaining nbio-hosting as a permanent, first-class second path would
   double the safety-critical surface area** (terminal I/O, crash recovery
   ordering, shutdown ordering) of the framework for a payoff that remains,
   after this entire exercise, still just a bet.

A well-evidenced "abandon" here is not a rejection of the work — it is the
honest reading of what the evidence actually supports: build it (done),
prove it (done), and don't pay its ongoing cost until the thing it's
actually for (Darwin/BSD) is something someone can verify.

---

## 4. What T1 should do next, either way

- **Do not delete `run_nbio`.** It costs nothing to keep green (§5's test
  numbers below already include it every run) and is a working head start
  for whoever eventually validates Darwin/BSD — a considerably better
  starting position than an unbuilt idea, even though it is not proof.
- **Do not migrate `examples/` or any new T1 example onto `run_nbio`.**
  `run()` stays the one path user-facing code is written against.
- **Consider a narrower, lower-risk use of `core:nbio` later: timers only.**
  Spec §6 also proposes nbio for `Tick`/`Every` (removing "~90% of real
  long-blocking Cmds from the worker pool") and for the frame-coalescing
  render ticker. That use has none of this document's risk profile — timers
  aren't tty-specific, so the Darwin `/dev/tty`-kqueue landmine (§3.2) does
  not apply, and `nbio.timeout` already works cleanly per `tools/nbiocheck`.
  A small nbio-hosted timer thread feeding the *existing* mailbox via the
  same `wake` hook this task built would capture real value (precise,
  non-busy-wait timers) without re-litigating the tty-ownership question.
  This is a reasonable, separable T2 candidate.
- **If a Darwin/BSD contributor does show up:** the actual next step is not
  "finish nbio-hosting" — it's "run `tools/ttycheck`-equivalent and
  `tools/nbiowakecheck` on real Darwin hardware first." If those come back
  clean, `run_nbio` is most of the way to being viable there and this
  document's cost/benefit tips the other way. If `/dev/tty` kqueue behaves
  the way Charm's own comment says it did, this decision does not need to
  be revisited — it already assumed that outcome was live.
- **The `wake`/`wake_data` hooks added to `Dispatcher`/`Signal_Watcher`
  should stay** — they're zero-cost (`nil` by default) for `run()`, fully
  tested by the existing suite, and are exactly the seam a future timer-only
  nbio use (above) would also need.

---

## 5. Verification

```
$ ./tools/test.sh
Finished 56 tests in 324ms. All tests were successful.
```
56 = the 52 present before this task (spike-findings.md, Task 11) + 4 new
`run_nbio` tests in `runetea/loop_nbio_test.odin`.

```
$ ./tools/test.sh race
=== tools/racecheck ===
--- phase A: mailbox ... ---           6814 messages received
--- phase B: dispatcher ... ---        21500 results drained (20000 pool + 1500 detached)
--- phase C: signal watcher ... ---    2245 messages drained from 3600 signals sent
--- phase D: Program/run() ... ---     30 full run() cycles completed
--- phase E: Program/run_nbio() ... -- 30 full run_nbio() cycles completed
=== racecheck: all phases completed without crashing (2.41s) ===
```
Exit code 0. Phase E is new this task; Phases A-D are unchanged and still
clean, confirming the shared-code edits (`cmd.odin`, `signals.odin`,
`mailbox.odin`, `tea.odin`'s visibility widening) did not regress the
already-proven poll-thread path.

`examples/simple`, `examples/http`, and every `tools/*` binary (old and new)
were rebuilt clean as part of this task's verification.
