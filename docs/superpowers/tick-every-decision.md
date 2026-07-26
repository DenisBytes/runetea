# Tick and Every — a dedicated nbio timer thread, decided and measured

**Date:** 2026-07-26
**Status:** Landed. First T1 feature.
**Toolchain:** Odin dev-2026-07-nightly:819fdc7. Linux only.

T1's stated deliverable is "spinners, prompts, menus, long tasks with live
status." Without a timer primitive none of the first three are possible —
there is no way to make anything happen without a keypress or a completed
network Cmd. This task adds `tick`/`every` (`runetea/timer.odin`), reusing
the T1-A decision's own explicit recommendation
(`docs/superpowers/nbio-decision.md` §4): a narrow, tty-free use of
`core:nbio` for timers only, feeding the *existing* mailbox, with the event
loop (`tea.odin`'s `run()`) completely untouched.

---

## 1. What was built

| File | What |
|---|---|
| `runetea/timer.odin` (new) | `tick`, `every`, `timer_stop`, `Timer_Fn`, `Timer_Handle`, `Timer_Service` — the dedicated timer thread and its wire-up |
| `runetea/cmd.odin` (+~20 lines) | `Cmd.timer: ^Timer_Handle` field; `dispatch()` special-cases it; `Dispatcher.timers: Timer_Service` field; `dispatcher_destroy` stops it last; `cmd_is_nil` fixed to check `.timer` too (see §5); `deliver_result` widened to package-visible for reuse |
| `runetea/timer_test.odin` (new) | 9 tests: firing, repetition, cancellation (both orders), teardown-while-pending, two independent Dispatchers, and two full `Program`/`run()` integration tests |
| `tools/racecheck/main.odin` (+~140 lines) | Phase G: concurrent multi-thread dispatch, cancellation racing fires, 40 create/destroy rounds each tearing down while repeating `Every`s are still mid-fire |
| `tools/timercheck/main.odin` (new) | Standalone timing-accuracy measurement tool (§7 below) |
| `examples/spinner/main.odin` (new) | The iconic T1 deliverable — an animated braille spinner driven by `tick`, quitting on `q` |

Nothing in `run()`, `run_nbio()`, or the mailbox's own send/recv API changed.
The only touch to code outside `timer.odin` is `cmd.odin`, and every change
there is additive (a new struct field, a new early-return branch, one bug
fix to an existing predicate that the new field exposed — see §5).

---

## 2. Design question (a): where does the timer thread live?

**Owned by `Dispatcher`** (`Dispatcher.timers: Timer_Service`), lazily started
on the first `tick()`/`every()` ever dispatched through it, torn down as the
last step of `dispatcher_destroy`.

Three places were live options: `run()` itself, a standalone package-level
singleton, or the `Dispatcher`. `run()` was rejected outright — the task's
own framing ("do not touch the event loop; do not make `run()` depend on
nbio") is a hard constraint, and it turned out unnecessary anyway: nothing
about starting a timer thread requires touching `tea.odin` at all, since
`dispatcher_init`/`dispatcher_destroy`/`dispatcher_reap` already run inside
`run()`'s own teardown sequence untouched. A standalone package-level
singleton was rejected because this project runs many independent `run()`
sessions in one process (every test in `runetea_test.odin`, every
`tools/racecheck` phase) — a shared global would need to be re-pointed at a
new `Mailbox` each session, and a Tick/Every left over from a *previous*
session (or racing a *concurrent* one, which the race gate specifically
exercises) would silently write into a stale or already-freed `Mailbox`.
Scoping it to `Dispatcher` gives it the exact same lifetime guarantee the
pool and `Signal_Watcher` already have, for free:

- **Cannot outlive the mailbox.** `dispatcher_destroy` calls
  `timer_service_stop` as its *last* line, after `thread.pool_finish`/
  `pool_destroy` and `sync.wait_group_wait(&d.inflight)` have already
  proven every pool worker and every detached Cmd is done. That ordering is
  load-bearing, not cosmetic: a detached Cmd is explicitly allowed to call
  `dispatch()` itself (`cmd.odin`'s own doc comment on `detached`), so only
  once `wait_group_wait` has returned can `dispatcher_destroy` be sure
  nothing can still call `timer_dispatch` and race the timer thread's own
  shutdown.
- **Reaches the existing non-blocking teardown for free.** `dispatcher_reap`
  (the non-blocking path `run()` actually uses, T1-D) hands its `Reap_Ctx`
  to a background thread that calls `dispatcher_destroy` — which now also
  stops the timer thread — so `run()`'s own `QUIT_GRACE` bound and
  allocator-rotation-safety story apply to the timer thread with zero
  additional code in `tea.odin`.
- **Lazy, not eager.** A program that never calls `tick`/`every` never pays
  for the thread, the `nbio.acquire_thread_event_loop()` call, or (in the
  rare case it fails) the failure path. This matters because
  `dispatcher_init` is called unconditionally by every `run()`/`run_nbio()`
  session, including every existing example and test.

---

## 3. Design question (b): cancellation

**Yes — both a pending `Tick` and a repeating `Every` are stoppable, via a
refcounted `Timer_Handle` returned alongside the `Cmd`.**

"A timer that cannot be stopped is a leak with a nicer name" is taken
literally for `Every`: nothing else in this design ever stops a repeating
timer short of the whole session quitting. A spinner that should stop
animating once a load finishes (without quitting the *program*) needs a way
to say so, and Go's Bubble Tea has no answer to this at all (see §4's own
discussion of what Go's `Tick`/`Every` actually are) — this is a genuine
capability RuneTea's port adds, not a gap it merely papers over.

`tick`/`every` both return `(Cmd, ^Timer_Handle)`. `timer_stop(h)` sets a
cooperative `cancelled` flag — best-effort, same class as `Cancel_Token`
(`cmd.odin`): if the timer thread has already begun firing at the instant
`timer_stop` runs, the message may still be delivered; there is no way to
un-send something already in flight.

`Timer_Handle` is refcounted exactly like `cmd.odin`'s own `Grace_Signal`,
for the identical reason: `refs` starts at 2 (one for the caller, released
by `timer_stop`; one for the timer subsystem itself, released once the
timer is naturally done — fired-and-not-repeating, cancelled, or the
Mailbox has closed). Whichever side's release brings it to 0 frees it. This
is not incidental reuse of a pattern for its own sake — it is the same
signal-then-free hazard `Grace_Signal`'s own comment documents (a woken
waiter can still be touching shared memory after the signaling call has
already returned), applied to a second, structurally identical problem.

**Honest limit:** a `Tick`/`Every` still pending at the *exact* moment the
whole session quits has its `Timer_Handle` leaked — `core:nbio`'s own
`_destroy` silently discards any still-pending operation on loop teardown
(no callback, no removal hook exposed for a bulk sweep), so there is no
window to call `timer_handle_release` for it. This is bounded (at most one
leaked handle per still-pending timer at quit time, a few dozen bytes each)
and does not grow with session length — an acceptable, deliberate tradeoff,
not a leak that matters in practice, but a real one, not something this
design silently gets right.

---

## 4. Design question (c): mailbox Full when a timer fires

**Retry, never drop** — the same policy `cmd.odin`'s `deliver_result` (pool
and detached Cmd results) and `signals.odin`'s `send_or_retry`
(`Window_Size_Msg`/`Interrupt_Msg`) already use. `timer_fire` (the callback
that runs on the timer thread) calls `deliver_result` directly — widened
from `@(private="file")` to `@(private="package")` in `cmd.odin` for this
reuse, rather than duplicating the retry-on-Full/discard-on-Closed logic a
third time.

The task's own framing poses this as a judgment call — "a spinner dropping
a frame is fine; a timeout silently never firing is not" — and the honest
answer is that **the timer subsystem cannot tell those two cases apart.**
`Timer_Fn` has no way to say "I am cosmetic, drop me under pressure" versus
"I am load-bearing, retry me." Given that, defaulting to the *general*
codebase policy (retry) is the only choice that cannot silently break the
load-bearing case, and it costs nothing in the common one: a spinner Tick
firing every 80–100ms into a 256-slot mailbox that's actually being drained
every frame essentially never observes Full in practice (confirmed
empirically — `tools/timercheck`, §7, never had to retry across thousands
of fires).

Retrying *inside* an nbio callback is safe here specifically because the
timer thread is not the mailbox's consumer — `run()`'s main loop, on a
*different* thread, keeps draining concurrently, so a `thread.yield()` spin
inside `deliver_result` makes real progress instead of self-deadlocking. (This
is the exact hazard `loop_nbio.odin`'s own `nbio_flush_backlog` comment
documents for a *different* case — `run_nbio`'s single-threaded design,
where retrying inside a callback genuinely would self-deadlock. The timer
thread does not share that constraint because it is not the drainer.)

---

## 5. Design question (d): does Every drift?

**No — by construction, in the common case; it resyncs (skips, never
bursts) if it ever falls behind.**

`Timer_Handle.target: time.Tick` tracks the *intended* next-fire instant,
advanced by exactly `h.dur` each rearm (`timer_rearm`, computed from the
*previous* target, never from `time.tick_now()` at rearm time). As long as
one cycle (`fn` + `deliver_result`) finishes faster than the interval, this
has **zero accumulated drift** regardless of how long any individual fire's
own processing took — confirmed at 20ms and 100ms intervals over 3–5
seconds (§7): mean drift 0.00% in both cases, stddev under 0.11ms.

If a fire's own processing (in practice, a `Full`-mailbox retry) ever takes
long enough that the naively-advanced target is already in the past by the
time `timer_rearm` runs, it resyncs to `now + h.dur` instead of scheduling a
near-zero or negative wait. **This causes at most one skipped interval,
never a burst of queued catch-up fires** — the right choice for anything
driving a visible animation or a periodic status update, where "fire
everything you missed, all at once" would look like the UI jumping forward
rather than ticking steadily.

### Does `Every` align to wall-clock multiples of the interval, like Go's?

**No — a deliberate divergence.** Go's `Every` (`commands.go`) computes
`n.Truncate(duration).Add(duration).Sub(n)` so that, e.g., two independent
`Every(time.Second, ...)` calls started at slightly different real moments
converge on firing at the same wall-clock instant (":00 seconds", not
"whenever each one happened to start"). Three things, together, argue
against keeping this:

1. **It needs `time.Now()` (`CLOCK_REALTIME`)**, which spec §9 explicitly
   calls out as the wrong clock for this exact subsystem ("Use
   `time.tick_now()`... **not** `time.now()`... which jumps with NTP").
   `timer.odin` calls `time.tick_now()` exactly once per fire, everywhere,
   with no exception carved out for alignment — a stronger, simpler
   guarantee than adding one narrow, "provably safe" use of wall-clock time
   just for this feature.
2. **Go's `Every` and RuneTea's `every` are not the same primitive to begin
   with.** Go's `Every`/`Tick` are *both* single-fire — see `commands.go`'s
   own doc comment: "Beginners' note: `Every` sends a single message and
   won't automatically dispatch messages at an interval." Repetition in Go
   is purely a documented convention (reissue the Cmd from `Update`).
   RuneTea's `every` auto-repeats on its own, via the dedicated timer
   thread, independent of `Update` ever running again — already a more
   fundamental divergence than wall-clock alignment. Preserving Go's
   *secondary* cross-instance-synchronization property once the *primary*
   mechanism has already changed isn't obligatory.
3. **It isn't needed by T1's own deliverable.** The spinner example uses
   `tick`, not `every`, for exactly the reason above — see
   `examples/spinner/main.odin`'s own comment. Nothing in this task's scope
   needs two independent `Every`s to tick in lockstep.

The honest cost: two `every(time.Second, ...)` calls started microseconds
apart will *not* necessarily land on the same wall-clock second the way
Go's would. Each is internally drift-free relative to its *own* start, not
synchronized to any other timer or to the wall clock. Recorded here as a
real, considered tradeoff, not an oversight.

---

## 6. `cmd_is_nil` had to change — a bug caught before it shipped

`Cmd.timer: ^Timer_Handle` is `nil` for every existing Cmd (`procedure` is
still the field that matters for those), so the obvious-looking
`cmd_is_nil :: proc(c: Cmd) -> bool { return c.procedure == nil }` silently
reports `true` for *every* Cmd `tick()`/`every()` ever produce — because
those Cmds have `procedure == nil` by construction (they never run through
`run_cmd_task`/`run_cmd_detached` at all).

That matters beyond symmetry: both `apply()` and `run()`'s own init path
(`tea.odin`) guard their `dispatch()` call with `if !cmd_is_nil(cmd) {
dispatch(...) }`. With the naive predicate, a `Cmd` from `tick()`/`every()`
returned from `update()` or passed as `init_cmd` would never even reach
`dispatch()` — silently dropped one layer above the bug this document is
otherwise about. Caught by `runetea/timer_test.odin`'s own integration
tests (`test_tick_drives_a_program_through_run`,
`test_every_drives_a_program_through_run_without_reissue`) failing with
`fires == 0` before the fix. `cmd_is_nil` now checks `c.timer == nil` too.

---

## 7. Measured timing accuracy

`tools/timercheck` (standalone, no terminal, `Dispatcher` driven directly).
Two repeated runs shown; both consistent:

```
--- Tick accuracy: 40 one-shot Ticks of 50ms each ---
  error vs requested duration (ms): min=0.073 max=0.350 mean=0.132
--- Tick accuracy: 15 one-shot Ticks of 200ms each ---
  error vs requested duration (ms): min=0.075 max=0.173 mean=0.131
--- Every accuracy: firing every 20ms for 3s ---
  fires=150 requested_interval=20.000ms min=19.481ms max=20.523ms mean=20.001ms stddev=0.105ms
  mean drift from requested interval: 0.0008ms/fire (0.00%)
--- Every accuracy: firing every 100ms for 5s ---
  fires=50 requested_interval=100.000ms min=99.936ms max=100.101ms mean=100.003ms stddev=0.029ms
  mean drift from requested interval: 0.0025ms/fire (0.00%)
```

Second run:

```
--- Tick accuracy: 40 one-shot Ticks of 50ms each ---
  error vs requested duration (ms): min=0.071 max=0.429 mean=0.131
--- Tick accuracy: 15 one-shot Ticks of 200ms each ---
  error vs requested duration (ms): min=0.086 max=0.175 mean=0.121
--- Every accuracy: firing every 20ms for 3s ---
  fires=150 requested_interval=20.000ms min=19.734ms max=20.263ms mean=20.000ms stddev=0.057ms
  mean drift from requested interval: 0.0004ms/fire (0.00%)
--- Every accuracy: firing every 100ms for 5s ---
  fires=50 requested_interval=100.000ms min=99.866ms max=100.133ms mean=100.003ms stddev=0.049ms
  mean drift from requested interval: 0.0029ms/fire (0.00%)
```

Sub-millisecond error throughout (worst single sample: 0.43ms late on a
50ms Tick, i.e. under 1% — nowhere near the "consistently 30% late" bar the
task set for "not usable for animation"). `Every`'s mean drift rounds to
0.00% at both tested intervals, confirming §5's target-based rearm design
works as intended, not just in theory.

---

## 8. Two real bugs found and fixed by the race gate

Both of these were caught *only* by `tools/racecheck`'s new Phase G — the
task's own instruction that "this adds a new thread, so the race gate is
essential" was not a formality. Both required design changes, not just code
fixes; each is preserved in `timer.odin`'s own comments at the exact call
site.

**Bug 1 — cross-thread `nbio.timeout` + `op.user_data[0] = h` is unsafe.**
The first working version called `nbio.timeout(dur, cb, l=loop)` (returning
`^Operation`) and set `op.user_data[0] = h` afterward — natural-looking, and
correct for a *same-thread* call (`core:nbio`'s own documented guarantee:
"the operation returned... is at least valid till the end of the current
tick"). But `timer_dispatch` runs on whatever thread called `dispatch()`,
almost never the timer thread itself — a genuinely cross-thread submission.
For a short duration, the timer thread can dequeue, execute, complete, *and
recycle* the operation before the submitting thread's separate
`op.user_data[0] = h` write ever executes, racing `container/pool`'s own
`put()` (which `memset`s the recycled struct) against that write. Fixed by
switching to `nbio.timeout_poly(dur, h, cb, l=loop)`, which sets user data
*before* the (possibly cross-thread) `exec()` call inside it — closing the
window entirely, both for this cross-thread call site and for
`timer_rearm`'s same-thread one (kept consistent deliberately, not just
where TSan happened to catch it).

**Bug 2 — a genuine data race inside `core:nbio` itself, side-stepped, not
patched.** With multiple driver threads calling `dispatch()` concurrently
against the *same* Dispatcher (Phase G's own point), TSan caught
`core:nbio/mpsc.odin`'s `mpsc_enqueue`: `assert(mpscq.buffer[head &
mpscq.mask] == nil)` is a plain, non-atomic read one instruction before an
atomic RMW on the *same* ring slot, and it can race `mpsc_dequeue`'s own
atomic write to that slot on the consumer thread when the ring wraps under
load. This is a bug in this exact nbio nightly's own multi-producer queue,
not something reachable from this package (`core:` is the shared toolchain,
not vendored into this repo). Worked around by never calling into nbio's
own cross-thread queue at all: `timer_dispatch` appends the handle to
`Timer_Service.pending` under a plain `sync.Mutex` and calls `nbio.wake_up`
(proven safe for concurrent multi-threaded use — a plain `write(2)` to an
eventfd, independently serialized by the kernel, touching no nbio-internal
shared state); the timer thread itself drains `pending` and calls
`nbio.timeout_poly` **only from its own thread**, so the one nbio entry
point that touches the buggy assert is never exercised cross-thread at all.

**Bug 3 — `nbio.wake_up` racing the timer thread's own shutdown.** Even
after fixing bugs 1–2, the race gate still failed: `timer_service_stop` set
an atomic `stop` flag, then called `nbio.wake_up(loop)` — two separate
steps. The timer thread's `tick()` call can return for a completely
unrelated, legitimate reason (some other `Every`'s own timeout firing) at
basically the same instant, observe the just-set flag on its own very next
iteration, and proceed straight to `nbio.release_thread_event_loop()`
(which frees `loop.wake` and zeroes the whole `Event_Loop`) — all *before*
`timer_service_stop`'s own subsequent `wake_up(loop)` call has executed,
racing that call against the free. Fixed by sharing `Timer_Service`'s
existing `start_mu` between both sides: `timer_service_stop` now sets
`stop_requested` *and* calls `wake_up` inside one critical section, and the
timer thread's own loop condition reads `stop_requested` under the *same*
lock — which guarantees the timer thread cannot observe `stop_requested ==
true`, and therefore cannot reach `release_thread_event_loop()`, until that
whole critical section (`wake_up` included) has fully finished.

All three were reproduced deterministically (every run, before the fix;
zero occurrences in 13 consecutive `./tools/test.sh race` runs after) —
this section is a direct, complete account of what the race gate actually
found, not a summary written after the fact.

---

## 9. Verification

**1. `./tools/test.sh`**
```
Finished 94 tests in 1.546847742s. All tests were successful.
```
94 = 85 pre-existing + 9 new (`runetea/timer_test.odin`). Some pre-existing,
harmless per-test allocator-tracking leak warnings remain (unchanged from
before this task, e.g. `thread_unix.odin:91` thread-struct leaks the
existing suite already had) — informational only, not failures; see
`tools/test.sh`'s own comment on `odin test`'s memory tracking.

**2. `./tools/test.sh race`**
```
--- phase G: Tick/Every timer thread (concurrent dispatch, cancellation racing fires, destroy while an Every is pending) ---
  timers: 40 create/destroy rounds completed (4 drivers x 20 Ticks + 6 never-stopped Everys per round), 3280 total fires drained before each round's teardown
=== racecheck: all phases completed without crashing (3.6s) ===
```
13 consecutive clean runs (exit 0, zero TSan reports) after the three fixes
in §8 — up from a 100% reproduction rate beforehand.

**3. Timing accuracy** — §7 above. Sub-millisecond Tick error; 0.00% mean
`Every` drift at both 20ms and 100ms intervals over 3–5 second windows.

**4. `examples/spinner` under a real pty** (`python3 pty.fork()` +
`os.execv`, matching every other pty verification in this project) — driven
with **zero keypresses** for 2.2 seconds:
```
0.002 ⠋ Loading forever... press 'q' to quit
0.103 ⠙ ...   0.203 ⠹ ...   0.303 ⠸ ...   0.403 ⠼ ...   0.504 ⠴ ...
0.604 ⠦ ...   0.704 ⠧ ...   0.805 ⠇ ...   0.905 ⠏ ...   1.005 ⠋ ...  (wraps)
... (23 frames total, ~100ms apart, cycling 0..9 repeatedly)
```
`termios` during the run: `ECHO=False ICANON=False` (raw mode confirmed).
Then `q` sent: one already-in-flight frame arrives, then **exit status 0,
not signaled**; `termios` immediately after exit: `ECHO=True ICANON=True`
— terminal fully restored.

**5. Teardown while a repeating `Every` is still pending** — proven two
ways: `runetea/timer_test.odin`'s
`test_dispatcher_destroy_tears_down_a_pending_every` (destroys mid-repeat,
asserts `dispatcher_destroy` returns in well under 2s — no hang) and
`tools/racecheck`'s Phase G, which does exactly this 40 times per run,
every run, under ThreadSanitizer — clean across all 13 runs in §9.2.

---

## 10. Honest limits, stated directly

- A `Tick`/`Every` still pending at the exact instant the session quits
  leaks its `Timer_Handle` (§3) — bounded, one-time, does not grow with
  session length, not a correctness issue.
- `every` does not align to wall-clock multiples of its interval the way
  Go's does (§5) — two independent `Every`s will not necessarily tick in
  lockstep with each other, only internally drift-free relative to their
  own start.
- `deliver_result`'s retry-on-Full policy (§4) cannot distinguish a
  cosmetic Tick from a load-bearing one; retry is the only generically-safe
  default, but a caller that genuinely wants "drop under pressure" has no
  way to ask for it today.
- The timer subsystem's failure path (`nbio.acquire_thread_event_loop`
  itself failing on the timer thread) is best-effort: every future
  `tick()`/`every()` on that `Dispatcher` silently never fires, with no
  error surfaced to the caller beyond that silence. Not observed in
  practice on this toolchain/platform; recorded because it's a real,
  reachable path in the code, not because it was ever triggered.
