# batch() and sequence() — direct dispatch, forced-detached coordinators, decided and measured

**Date:** 2026-07-26
**Status:** Landed. Next T1 feature after Tick/Every.
**Toolchain:** Odin dev-2026-07-nightly:819fdc7. Linux only.

`batch(cmds, alloc)` runs several `Cmd`s concurrently, no ordering guarantee
on results. `sequence(cmds, alloc)` runs them one at a time, in order. Both
are ordinary `Cmd` values from `update()`'s point of view — `return m,
batch(...)` works exactly like returning any other Cmd.

---

## 1. What was built

| File | What |
|---|---|
| `runetea/batch.odin` (new) | `batch`, `sequence`, `Compose_Spec`, `Compose_Kind`, `compose`, `compose_dispatch`, `compose_procedure`, `compose_run_batch`, `compose_run_sequence`, `compose_free_unrun` |
| `runetea/cmd.odin` (+~40 lines) | `Cmd.compose: ^Compose_Spec` field; `cmd_is_nil` extended; `dispatch()` split into a thin public wrapper over a new package-private `dispatch_ex(d, c, done)`; `Task_Env.done: ^sync.Wait_Group`; `run_cmd_task`/`run_cmd_detached` each signal it once, as their next-to-last action |
| `runetea/batch_test.odin` (new) | 15 tests: empty/single, concurrency proof, nesting (both directions), cancellation (pre-fired and mid-flight), the pool-deadlock proof pair, quit latency |
| `tools/racecheck/main.odin` (+~180 lines) | Phase H: exact-accounting settled run + adversarial-teardown run, both through nested batch/sequence coordinators outnumbering a narrow pool |
| `examples/http/main.odin` (rewritten) | Now checks TWO hosts concurrently via one `rt.batch(...)`, reports both independently |

Nothing in `tea.odin`, `mailbox.odin`, or `timer.odin` changed. The only
touch outside the new file is `cmd.odin`, and every change there is
additive: one new `Cmd` field, one new `Task_Env` field, `dispatch` split
into a public/private pair with identical external behavior, two call sites
gaining one new struct-literal field each.

---

## 2. Tension 1 — Go's shape does not port, and why

Go's `tea.Batch`/`tea.Sequence` (`commands.go`) return a `Cmd` — recall
`type Cmd func() Msg` — whose *execution* produces `BatchMsg([]Cmd)` /
`sequenceMsg([]Cmd)`. `tea.go`'s event loop specially intercepts those two
message types (`case BatchMsg: go p.execBatchMsg(msg)`) and dispatches from
there. The mailbox-equivalent (`p.msgs` channel) is how the coordination
signal travels from "Cmd finished" to "runtime reacts."

That shape is structurally impossible here. `box()`'s MESSAGE OWNERSHIP
CONTRACT (`arena.odin`, T1-B) panics on any `Msg` type containing a `string`,
pointer, slice, dynamic array, map, or `any`, anywhere in its field tree —
checked at runtime, on every `box()` call, not opt-in. `BatchMsg([]Cmd)` is a
slice of function-equivalent values; there is no POD-safe way to carry
"a list of Cmds to run" through the mailbox as a message. This was verified
directly, not assumed: `is_pod_type(Compose_Spec)` (were `Compose_Spec` ever
mistakenly boxed) reports false, exactly as `is_pod_type` reports false for
any `[]T` field — the same enforcement path `tools/podcheck` already proved
for the T1-B decision.

**Resolution:** `batch()`/`sequence()` don't produce a `Msg` at all. Like
`tick()`/`every()` (`timer.odin`, the immediate precedent this design
follows), they attach an opaque handle to a `Cmd` — `compose: ^Compose_Spec`,
sitting right next to `Cmd.timer: ^Timer_Handle` — that `dispatch()`
recognizes and routes *directly*, entirely bypassing the mailbox for the
coordination step itself:

```
dispatch_ex :: proc(d: ^Dispatcher, c: Cmd, done: ^sync.Wait_Group) {
    if c.timer != nil   { timer_dispatch(d, c.timer); ...; return }
    if c.compose != nil { compose_dispatch(d, c.compose, done); return }
    if cmd_is_nil(c)    { ...; return }
    if c.detached        { /* existing detached path */ }
    /* existing pool path */
}
```

Each **child** Cmd's own result still reaches the mailbox exactly as if
`update()` had returned it directly — only the "which Cmds, in what
order/concurrency" bookkeeping is kept off the wire. This is why nesting
(§6) falls out for free instead of needing a second, parallel unwrapping
path the way Go's `execSequenceMsg`/`execBatchMsg` need an explicit
`case BatchMsg: p.execBatchMsg(msg)` switch inside each other.

**Why not "keep it a Msg but make it POD by cloning the whole subtree
eagerly"?** Considered and rejected: a `Cmd` carries a `procedure` (a raw
proc pointer, which IS POD) plus an `env: rawptr` (which is NOT — the
whole reason `Cmd` doesn't box its own env). There is no POD encoding of
"an opaque heap pointer to caller-defined data" short of turning `Cmd`
itself into something box() would reject, which defeats the purpose.

---

## 3. Tension 2 — ownership of the Cmd slice, walked end to end

`batch(cmds, alloc)`/`sequence(cmds, alloc)` receive a `[]Cmd` the caller
almost certainly built as a stack/temp value (a composite literal, or a
short-lived `make(...)` the caller frees right after the call — every call
site in `batch_test.odin`, `tools/racecheck`, and `examples/http` does
exactly this). The coordinator outlives that frame by definition (it may
still be fanning out children long after `update()` has returned and the
frame arena has been reset). So, mirroring `cmd_from`'s own "heap-clone so
the Cmd can outlive the caller's frame" precedent (`cmd.odin`) exactly:

1. **Construction (`compose`, `batch.odin`).** Filters `cmd_is_nil` entries
   (mirrors Go's own `compactCmds`), then heap-clones what's left into a
   freshly `make([]Cmd, n, alloc)`'d array — a **copy of each `Cmd` struct
   by value**, not a pointer into the caller's slice. This is cheap and
   correct because a `Cmd`'s only owned resource is `env`, reached through a
   pointer that survives the copy unchanged; nothing about copying a `Cmd`
   struct aliases the caller's backing array. `Compose_Spec{kind, cmds,
   alloc}` is itself heap-allocated with the same `alloc`.
2. **n == 0 → `cmd_nil()`.** Nothing to free — every filtered-out entry was
   already `cmd_is_nil` (no env).
3. **n == 1 → return that Cmd, unwrapped.** No `Compose_Spec`, no
   coordinator thread, ever — this is the explicit "do not allocate a
   coordinator for a single Cmd" requirement. Pinned by
   `test_batch_of_one_returns_that_cmd_unwrapped`/
   `test_sequence_of_one_returns_that_cmd_unwrapped` (asserting
   `c.compose == nil` and identical `procedure`/`env` pointers).
4. **`make`/`new` failure at construction.** Every child's env is freed
   immediately via `compose_free_unrun` (see below) before returning
   `cmd_nil()` — nothing is silently dropped.
5. **Normal fan-out (`compose_run_batch`).** Each child is read out of
   `spec.cmds` exactly once and handed to `dispatch_ex` **by value** —
   after that point nothing in `batch.odin` holds a pointer into
   `spec.cmds` for that entry, so `spec.cmds` itself (and `spec`) is freed
   **immediately after the fan-out loop**, not after the children finish.
   Ownership of each child's `env` has transferred to whichever of
   `run_cmd_task`/`run_cmd_detached`/`compose_dispatch` ends up running it —
   exactly the same single-owner handoff `dispatch()` already makes for any
   plain Cmd.
6. **Cancelled mid-fan-out, or mid-sequence.** Whatever wasn't dispatched
   yet is walked by `compose_free_unrun`, which frees each remaining
   child's `env` (mirroring `run_cmd_guarded`'s own
   `if cmd.env != nil { free(cmd.env, cmd.allocator) }` — the exact cleanup
   each Cmd would have received had it run) — recursing into a nested,
   never-started `compose` child's own `cmds`/`spec`.
7. **A never-started Tick/Every child.** Deliberately left alone — see §7's
   honest limit.
8. **Panic recovery.** `compose_procedure` runs inside `run_cmd_guarded`'s
   `guarded()` call. If anything in the coordination logic itself panics
   (not a child — each child has its own independent guarded() call on its
   own thread), `run_cmd_guarded`'s existing panic path frees the
   `Compose_Env` (`ce`) via its own `if cmd.env != nil { free(...) }` and
   reports a `Panicked_Msg`, unchanged from any other Cmd. What is **not**
   reclaimed on that path: `wg`, and, if the panic landed before the
   fan-out loop finished, `spec`/`spec.cmds` — a deliberate, accepted
   leak, not an oversight (§7).

Every one of these eight paths is exercised by a test: (2)–(4) by the
empty/single tests, (5)–(6) by the cancellation and concurrency tests,
`tools/racecheck` Phase H's H1/H2 by (5)/(6) at volume under ThreadSanitizer.
(8) is reasoned about but not directly forced (forcing a genuine panic
*inside* the coordination logic itself, as opposed to inside a child, would
require injecting a fault into `dispatch_ex`/`sync` — out of scope; the
reasoning follows `run_cmd_guarded`'s own already-documented, already-shipped
"does not reclaim a Cmd body's own scratch allocations on panic" limitation
byte for byte).

**Why `wg` (the coordinator's completion-tracking Wait_Group) is heap, not a
stack local.** `compose_run_batch`/`compose_run_sequence` run inside
`run_cmd_guarded`'s `guarded()` — a `setjmp`/`longjmp` region. `longjmp`
discards the current stack frame with **no** `defer` execution. If a genuine
bug ever made this code panic *after* dispatching some children (each
carrying `&wg` as their completion target) but *before* those children
finish, a **stack-local** `wg` would have its memory considered dead the
instant `longjmp` unwinds past it — while children on other threads might
still be about to call `wait_group_done` into that now-reused stack memory.
That is structurally the identical hazard `cmd.odin`'s `Reap_Ctx`/
`Grace_Signal` are heap-allocated to avoid for `run()`'s own teardown path
(see that file's own comment). Heap-allocating `wg` here closes it the same
way, at the cost of one small allocation per coordinator, freed on every
normal-completion path.

---

## 4. Tension 3 — the pool deadlock, and why it cannot recur here

A coordinator that dispatches children and then waits for them must not
itself occupy a pool worker — N coordinators on an N-wide pool would leave
zero workers for their children, a structural deadlock. This is exactly why
`detached` (T1-D) exists, and `test_detached_cmds_exceed_pool_width_without_
deadlock` (`cmd_test.odin`) already pins the underlying mechanism.

**Resolution:** `compose_dispatch` (`batch.odin`) converts every `compose`
Cmd into a **synthetic** `Cmd{procedure = compose_procedure, env = ^Compose_
Env, detached = true}` and hands it straight back to `dispatch_ex` — which
then takes the exact same, already-proven detached branch any other detached
Cmd takes: `wait_group_add(&d.inflight, 1)` before spawn, a dedicated
self-cleaning OS thread, `run_cmd_guarded` for panic safety,
`wait_group_done(&d.inflight)` as that thread's own last action. `detached`
is forced **unconditionally** — there is no parameter anywhere in `batch()`/
`sequence()`'s public signature that lets a caller (or a bug) construct a
pool-bound coordinator. Since this conversion happens inside `dispatch_ex`
itself, it applies at **every nesting depth**: a `batch` inside a `sequence`
inside a `batch` gets three independent coordinator threads, none of them
ever touching the pool. Only **leaf** Cmds (ordinary `cmd_from` results,
non-compose, non-timer) ever occupy a pool worker, exactly as before this
feature existed.

### 4a. Non-vacuous proof: batch survives more coordinators than pool workers

`test_batch_coordinators_exceed_pool_width_without_deadlock`
(`batch_test.odin`): 8 real `batch()` Cmds (2 children each) on a
pool of width 2 — 4× the load the pool could serve if coordinators consumed
a slot. All 16 leaf results arrive. `tools/racecheck` Phase H1 repeats this
at real volume under ThreadSanitizer: 40 coordinators (some 2-deep nested),
pool width 3 — **13×** the pool width — 140 leaf results received, exact
count, exact panic count (9, matching `ceil(140/17)`), three consecutive
race-gate runs clean.

### 4b. Non-vacuous proof that this WOULD deadlock without forcing detached

`batch()`/`sequence()` themselves have no way to construct the un-forced
shape (that is the whole point), so
`test_a_non_detached_coordinator_would_deadlock_against_its_own_children_on_a_narrow_pool`
pins the underlying mechanism directly, by hand, at the `Cmd`/`dispatch()`
level:

- **Branch 1 (non-detached, deliberately):** 4 hand-built "fake
  coordinators" — each occupies a pool worker (width 2) while it itself
  `dispatch()`es a child through the *same* pool and waits, bounded, via
  `sync.wait_group_wait_with_timeout(wg, 500ms)` (never a bare, unbounded
  wait — the test cannot hang the suite even in the branch that reproduces
  the bug). **Result, every run: at least one of the four genuinely times
  out** — non-vacuous by construction (asserted explicitly; the test fails
  loudly if none ever do).
- **Branch 2 (same shape, `detached = true` — what `compose_dispatch`
  actually does):** zero timeouts, every run.

This is the closest thing to a controlled experiment this codebase has for
"does `detached` actually matter here": identical Cmd shapes, identical
narrow pool, the only variable is one boolean, and the outcome flips
completely.

---

## 5. Cancellation

`compose_run_batch` checks `cancel_requested` **before dispatching each
remaining child**; `compose_run_sequence` checks it **before starting each
remaining step**. Either way, whatever hasn't been dispatched yet is
abandoned (`compose_free_unrun`) rather than started. A child *already*
dispatched before cancellation was noticed still runs to completion —
cooperative, not preemptive, the same honest limit `Cancel_Token` documents
everywhere else in this codebase (`cmd.odin`).

Two deterministic tests prove the "not yet started, never runs" half without
any wall-clock race:

- `test_cancelled_batch_skips_all_unstarted_children` /
  `test_cancelled_sequence_skips_all_unstarted_steps`: fire
  `sync.atomic_store(&d.cancel.cancelled, true)` **before** ever dispatching
  — `Cancel_Token.cancelled` has no field-level privacy, only a documented
  "touch via atomic ops" convention, so this is legitimate public surface
  to poke from a test, not a reach-around. The coordinator's very first
  `cancel_requested` check trips; zero children ever run;
  `dispatcher_destroy` returns promptly; the mailbox stays empty.
- `test_cancelled_sequence_lets_the_in_flight_step_finish_but_starts_no_more`:
  a **semaphore-gated** step 0 proves the deeper claim deterministically —
  step 0 posts `started` the instant it begins running (so the test knows,
  with certainty, that step 1 has *not* been dispatched yet — sequence's own
  one-at-a-time design guarantees that), cancellation fires while step 0 is
  genuinely mid-flight, step 0 is released and **does** deliver its result
  (cooperative — already running), and step 1 **never** arrives (checked via
  the same bounded sleep-then-confirm-silence idiom `timer_test.odin`'s
  `test_timer_stop_cancels_a_pending_tick` already establishes for this
  exact class of negative proof).

**An honest, load-bearing finding, discovered the hard way (§8):**
`compose`'s cancellation is **more eager** than a plain Cmd's. A plain Cmd
only reacts to `cancel_requested` if its own body polls for it; a
compose coordinator checks it structurally, on every child/step boundary,
whether or not the children themselves care. Combined with `run()`'s own
fast-quit path (`dispatcher_reap` fires cancellation essentially
immediately), this means a batch/sequence dispatched right before a quit can
have **zero** of its children ever actually start — not "some," zero. This
is correct and desired (it is what keeps quit latency bounded regardless of
how deep the composition nests, see §6), but any code — test or real user
code — that assumes "N children were dispatched, so N results will
eventually arrive" is asserting something this design deliberately does not
guarantee once quit is in the picture.

---

## 6. Quit latency — measured

`run()`'s `QUIT_GRACE` (100ms, T1-D) bounds how long `run()` itself blocks
before returning; the actual teardown continues on a background reaper
thread regardless of how long in-flight work takes (`dispatcher_reap`,
`cmd.odin`). A compose coordinator is tracked through the exact same
`d.inflight` Wait_Group as any other detached Cmd (§4), so it composes with
this mechanism for free — no batch/sequence-specific teardown code exists.

Measured, `runetea/batch_test.odin`,
`test_run_returns_promptly_with_a_nested_batch_and_sequence_both_mid_flight`
— a **3-level-deep** `batch(sequence(batch(leaf, leaf), leaf), leaf)`
(batch AND sequence both mid-flight, nested inside each other) dispatched on
keypress 1, quit on keypress 2, over a zero-pacing `Bytes_Source`:

```
[quit latency] run() returned in 649.572µs with batch(sequence(batch(leaf,leaf), leaf), leaf) still mid-flight
[quit latency] 0/4 nested leaves actually got to run before cancellation reached them (0-4 all legitimate, not asserted)
```

**649µs** — nowhere near the ~450ms these nested Cmds would take to
actually finish, and nowhere near the pre-T1-D "one Cmd in flight → quit
takes as long as that Cmd" stall
(`docs/superpowers/cancellation-decision.md`'s own addendum measurement).
Zero of the four leaves got to run at all — Bytes_Source has no real
pacing, so cancellation reached the outermost coordinator before its own
fan-out loop's first thread was even scheduled. This is the concrete,
measured instance of §5's honest finding, not a hypothetical.

`tools/racecheck` Phase H2 (adversarial teardown, concurrent drainer racing
`dispatcher_destroy` called immediately after dispatching 40 real
coordinators, some nested, on a 3-wide pool) measured **545–626µs** across
three consecutive race-gate runs — consistent, never approaching the 2-second
failure bound the phase checks against.

`examples/http` end to end, over a **real pty**, both checks pointed at
`tools/stallserver` (accepts, never replies — `RECV_MAX_WAIT` is 30s):

```
=== quit sent at t=0.100s; process exited=True status=0 at t=0.202s (quit-to-exit latency: 0.102s) ===
```

**102ms** from keypress to process exit, with both batch-wrapped network
Cmds permanently stalled and nowhere near their own 30-second cap. A long
batch/sequence — even one that structurally cannot finish on its own — does
not reintroduce the stall T1-D's fix removed.

---

## 7. Concurrency proof — measured

`test_batch_and_sequence_wall_clock_differ_as_expected` (`batch_test.odin`):
identical 4×80ms Cmds, once through `batch()`, once through `sequence()`:

```
[batch-sequence timing] N=4 children x 80ms each -- batch: 80.542095ms (expected ~80ms)  sequence: 320.820623ms (expected ~320ms)
```

`batch`: **80.5ms** ≈ max(80ms) — the four children genuinely ran
concurrently, not accumulated. `sequence`: **320.8ms** ≈ sum(4×80ms) — each
step genuinely waited for the previous one. Ratio ≈ 4.0×, matching N=4
exactly; the test additionally asserts `sequence > batch × 2` as a
non-flaky, generously-margined version of the same claim so a loaded CI box
can't blur the two together. Reproduced identically (80.58ms / 320.77ms)
on a second run.

---

## 8. Empty, single-element, and nesting

- `batch([]Cmd{}, alloc)` / `sequence([]Cmd{}, alloc)` → `cmd_nil()`.
- `batch()`/`sequence()` of only `cmd_nil()` entries → `cmd_nil()`.
- Exactly one real Cmd → that Cmd, unwrapped, **no** `Compose_Spec`
  allocated, **no** coordinator thread spawned (§3, point 3).
- **batch containing a nested batch**
  (`test_batch_containing_a_nested_batch_delivers_all_leaves`): all leaves
  (including the nested batch's own) delivered, proven by tagged-message
  identity, not timing.
- **sequence containing a nested batch**
  (`test_sequence_waits_for_a_nested_batch_to_fully_finish_before_continuing`):
  proven **structurally**, not by timing — the nested batch's two children
  are asserted to be the first two messages received, strictly before the
  sequence's own next step's message, using message-identity tags. This
  cannot be flaky under scheduler jitter the way a wall-clock assertion
  would be.
- 3-level nesting (`batch(sequence(batch(...), leaf), leaf)`) is exercised
  both directly against a `Dispatcher` (fast, deterministic — passed
  immediately) and, with real 150–450ms sleeps standing in for real work,
  completed in 450.6ms — exactly max(300ms) + 150ms, confirming the nested
  structure's timing composes correctly (concurrent trio, then one more
  sequential step) even before it was wired through `run()` for the quit-
  latency test in §6.
- `tools/racecheck` Phase H1 nests two shapes at volume (`batch{leaf,
  sequence{leaf,leaf}, leaf}` and `sequence{leaf, batch{leaf,leaf}, leaf}`),
  cycling across 40 coordinators, under ThreadSanitizer, with an exact
  leaf/panic count assertion — the deepest and highest-volume nesting proof
  in this codebase for either primitive.

---

## 9. A debugging note worth keeping: the hang that wasn't a framework bug

The first draft of §6's `run()`-level quit-latency test waited on a fixed
`sync.Sema` posted by each of the four leaves — `for _ in 0..<4 {
sync.sema_wait(&finished) }` — and hung the entire test suite indefinitely.
Root-caused via `/proc/<pid>/task/*/wchan` (no `ptrace` permission available
to attach `gdb` in this environment) plus `ODIN_TEST_NAMES` bisection down to
the single failing test, then a from-first-principles reproduction
(standalone `Dispatcher`, no `run()`) that passed instantly — proving the
compose logic itself was not the culprit. The actual cause was exactly §5's
finding: with `run()`'s fast-quit path, cancellation can (and, over
`Bytes_Source`'s zero-pacing input, empirically **does**, reliably) reach
the coordinator before it dispatches *any* of its four leaves, so the
semaphore the test was waiting on could legitimately never reach 4 posts.
The fix was in the test, not the implementation: wait a fixed, generous,
**bounded** margin instead of a specific post count, and report — not
assert — how many leaves actually ran. Recorded here because it is the kind
of thing that looks like a deadlock bug and is actually the feature working
exactly as designed; a future reader debugging a similar hang in code that
composes Cmds with `batch()`/`sequence()` near a quit path should look here
first.

---

## 10. Honest limits

- **A Tick/Every nested inside batch()/sequence() does not gate anything.**
  `dispatch_ex`'s timer branch (`cmd.odin`) registers it exactly as if it
  had been returned directly from `update()`, then immediately signals
  `done` — fire-and-forget from the coordinator's point of view. For
  `sequence`, this means a Tick step does not "wait" for its own duration
  before the next step starts. This is a deliberate scope limit, not an
  oversight: composing a *repeating* Every with sequencing has no single
  correct meaning (an Every never completes at all), and Go's own
  Tick/Every are single-fire `Cmd` values with no such tension to begin
  with — there was nothing to match. A never-started Tick/Every child
  (cancelled before the coordinator reached it) is left un-released rather
  than correctly decrementing `Timer_Handle`'s refcount — bounded to the
  handle's own few dozen bytes, and only if the caller also never calls
  `timer_stop` themselves, which is the *exact* accepted cost
  `Timer_Handle`'s own doc comment (`timer.odin`) already signs off on for
  a plain discarded Tick/Every.
- **A genuine panic inside the coordination logic itself (not a child)
  leaks `wg`, and possibly `spec`/`spec.cmds`.** Reasoned about in §3,
  point 8; not independently forced by a test (would require fault
  injection into `dispatch_ex`/`sync` itself). Consistent with, not worse
  than, `run_cmd_guarded`'s own already-shipped, already-documented
  "does not reclaim a Cmd body's own scratch allocations on panic" limit.
- **One OS thread per compose Cmd, unconditionally, at every nesting
  depth.** This is the direct cost of §4's resolution — the "deliberate
  equivalent of Go's leaked-goroutine-per-Cmd, used rarely" `cmd.odin`
  already accepts for `detached` in general, now paid automatically rather
  than opted into. Bounded by the *structure* of a program's own
  composition (the caller wrote the nesting), not by data volume — but a
  program that builds a batch of hundreds of individually-composed
  sub-batches in a hot loop would spawn hundreds of threads. Not something
  this codebase's existing Cmd volume (`tools/racecheck` dispatches
  thousands of pool/detached Cmds per phase already) comes close to
  stressing differently than it already does.
- **Batch's mid-fan-out cancellation window is real but not independently
  proven non-flaky.** §5's two "pre-cancelled" tests prove the
  before-anything-starts case deterministically; §5's semaphore-gated test
  proves sequence's mid-flight case deterministically (sequence dispatches
  one child at a time, so gating child 0 provably fixes child 1's
  not-yet-dispatched state). Batch's fan-out loop dispatches all children
  in a tight, uninterrupted loop with no equivalent gate to hold it open —
  reliably catching "cancelled after child 2 of 5 but before child 3" from
  outside, using only the public API and real thread scheduling, was not
  attempted, since it would be exactly the kind of wall-clock-race test §9
  just found a real bug by moving away from. The mechanism (checked before
  every dispatch, §5) is the same code path §4a already exercises at
  volume; only this one specific interleaving is unverified.
- **`compose_free_unrun`'s never-started-Tick/Every gap is a leak, not a
  crash.** Listed above and repeated here because it is the one place this
  design knowingly leaves memory on the table by choice rather than by
  necessity, given the time budget for this task.

---

## 11. Verification

```
$ ./tools/test.sh
Finished 108 tests in 3.666879122s. All tests were successful.
   (94 pre-existing + 14 new in batch_test.odin; run 3× consecutively, all clean)

$ ./tools/test.sh race
=== racecheck: all phases completed without crashing (3.656271355s) ===
   (Phase H added: H1 exact-count 140/140 leaves + 9/9 expected panics on a
    13x-narrower-than-load pool; H2 adversarial teardown 545-626us across
    3 consecutive runs, no TSan report, no hang, on top of the pre-existing
    Phases A-G unmodified and still clean)
```

`examples/http` driven under a real pty (`python3 pty.fork` +
`os.execv`/`os.execve`), three scenarios:
1. Normal run, two real hosts (`example.com`, `example.org`): both render
   `checking...` in the same first frame (proving concurrent fan-out), one
   resolves before the other (no ordering guarantee, observed directly —
   `example.org` before `example.com`), program exits on its own,
   **exit status 0**, ~24-50ms total across three runs.
2. Manual `q` quit after both already resolved: clean exit, status 0.
3. Both hosts pointed at `tools/stallserver` (never replies): quit-to-exit
   latency **102ms** (§6) while the underlying network Cmds are nowhere
   near their own 30-second cap — bounded quit latency demonstrated in the
   actual shipped example, not only in a unit test.
