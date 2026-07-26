# Quit latency and cooperative cancellation — decided and built

**Date:** 2026-07-26
**Status:** Fixed. Structural change to `run()`'s teardown, a `Cancel_Token` threaded
through every Cmd, `examples/http` bounded and cancellable. Regression tests in
place (unit + a dedicated ThreadSanitizer phase); pty-verified before/after
against a real stalled server.
**Toolchain:** Odin `dev-2026-07-nightly:819fdc7`. Linux only.
**Base commit:** `e4a2cfd` ("fix(render): rewind physical rows...")

This is the fourth T1 decision. Read `runetea/cmd.odin` (`Reap_Ctx`,
`dispatcher_reap`, `Cancel_Token`) and `runetea/tea.odin`'s `run()` for the
actual code; this document is the evidence trail — what was tried, what broke,
what the numbers actually are.

---

## 1. The problem, restated

`dispatcher_destroy` called `thread.pool_finish` + `sync.wait_group_wait`, both
fully blocking. `run()`'s teardown ran it synchronously, so `run()` could not
return until every Cmd it had ever dispatched — including one still running —
had finished. Measured (spike-findings.md addendum item 5): one 2-second Cmd in
flight, quit takes 2.000s. `examples/http`'s `check_server` had no socket
timeout at all, so a stalled host blocked forever, and the terminal stayed raw
the whole time regardless of how the user tried to quit — keypress, or an
external SIGINT.

Two things had to be true of the fix at once: **fast** (run() returns quickly
even with a Cmd stuck) and **not corrupting** (the mailbox is a stack local in
run()'s frame today specifically *because* letting run() return early once
already caused a real use-after-free — Task 5, Critical). Getting the first
without breaking the second turned out to need two more iterations than the
initial design, both caught empirically, both recorded below because they are
exactly the kind of mistake this fix could have shipped with.

---

## 2. HALF 1 — the structural fix

### 2.1 What breaks if you just heap-own the mailbox

The prompt posed three shapes: (A) heap-own the mailbox with a refcount and let
the last Cmd free it, (B) a bounded grace period then abandon, (C) something
better. The first thing built was closer to (A) than (B): heap-allocate the
`Mailbox` *and* the `Dispatcher` (its `thread.Pool` has the same "address must
not move while workers reference it" constraint the Mailbox has), hand both off
to a self-cleaning background thread the moment `run()` wants to quit, and
return immediately — `run()` never waits at all.

That is `dispatcher_reap` today, minus the grace period. It is **not** a true
refcount (no atomic count of live producers) — it is closer to (C): the
background reaper thread runs the *exact same* `dispatcher_destroy` +
`mailbox_destroy` sequence that already proved correct (Task 5), just off
run()'s own call stack. The proof is unchanged; only which thread blocks on it
changed. `dispatcher_reap` also fires the Cmd's `Cancel_Token` (§3) and closes
the mailbox *before* handing off, so any Cmd that finishes after this point
gets `.Closed` on its very next `mailbox_send` and discards its result instead
of retrying forever against a mailbox nobody drains anymore — "orphaned
results are discarded," as posed in option A.

Wired into `run()` (heap-allocate `Reap_Ctx{disp, mbox}` instead of two stack
locals, `defer dispatcher_reap(rc)` instead of `defer dispatcher_destroy(&disp)`
+ `defer mailbox_destroy(&mbox)`), `./tools/test.sh` still reported "77 tests,
all successful" — but the per-test memory report told a different story:

```
[WARN] ... test_program_quits_from_an_async_init_cmd_with_no_keypress
        +++ leak       320B @ tea.odin:80:run()
        +++ leak    4.00KiB @ mailbox.odin:24:mailbox_init()
        ... (several more leaks) ...
        +++ bad free        @ queue.odin:87:destroy()
        +++ bad free        @ thread_pool.odin:128:pool_destroy()
        +++ bad free        @ mailbox.odin:48:mailbox_destroy()
        +++ bad free        @ cmd.odin:201:reap_thread()
```

**Root cause:** `odin test` gives each parallel test *task* its own
`mem.Rollback_Stack`-backed allocator (`core/testing/runner.odin`, `task_allocators`)
and explicitly **rotates it to a different test** the instant a test proc
returns. `run()`'s reaper thread inherits `context.allocator` from the test's
own thread (it has to — everything `rc` owns was allocated through that exact
allocator, and Odin's manual allocators require freeing through the same
instance that allocated). If the reaper is still running — even for a
trivially fast case with zero Cmds in flight, since spawning a new OS thread
has real scheduling latency that `run()`'s own return does not — when the test
function returns, the runner can rotate that allocator to a *different* test
before the reaper finishes freeing through it. That is a genuine
memory-corruption hazard, not a test-harness quirk: any caller whose
`context.allocator` has a lifetime shorter than "the rest of the process" hits
the same thing. A normal `main()` binary's allocator is process-lifetime, so
this specific failure mode is invisible there — but `FAIL_ON_BAD_MEMORY`
defaults to `false` in this toolchain's test runner, so it would have shipped
silently.

**Fix:** don't make `dispatcher_reap` unconditionally fire-and-forget. Give it
an optional bounded **grace period**: wait, with a timeout, for the reaper to
actually finish before returning. Confirmed working — a *different*, real bug
surfaced next.

### 2.2 The bug ThreadSanitizer caught

First cut: embed a `sync.Wait_Group` directly in `Reap_Ctx`, signal it as the
reaper thread's last action before `free(rc)`, have `run()` wait on it with
`sync.wait_group_wait_with_timeout`. `./tools/test.sh` was clean. `./tools/test.sh
race` was not:

```
WARNING: ThreadSanitizer: heap-use-after-free (pid=1573372)
  Atomic read of size 8 at 0x7248000002c0 by main thread:
    #0 sync::wait_group_wait_with_timeout .../sync/extended.odin:100:6
    #1 runetea::dispatcher_reap .../runetea/cmd.odin:259:2
    #2 runetea::run ... /runetea/tea.odin:155:8

  Previous write of size 8 at 0x7248000002c0 by thread T1537:
    #0 free
    #1 runtime::heap_free
    #4 runtime::mem_free
    #5 runetea::[cmd.odin]::reap_thread .../runetea/cmd.odin:208:2
SUMMARY: ThreadSanitizer: heap-use-after-free ... in sync::wait_group_wait_with_timeout
```

Real, and non-obvious: `wait_group_done` (the reaper thread) fully *returns*
before `free(rc)` runs — the mutex is unlocked, the broadcast has gone out —
but the *woken waiter* (run()'s thread, blocked in `cond_wait_with_timeout`)
still has to re-acquire that same mutex and re-check the loop condition
(`for atomic_load(&wg.counter) != 0`) before its own call returns. That
re-check touches `wg`'s memory *after* the signaling call has already
returned on the signaler's side. Freeing `rc` — which is where `wg` lived —
immediately after signaling races that in-progress wakeup. This is a known,
general class of bug (signal-then-immediately-destroy a synchronization
primitive) and it is exactly why `sync.Wait_Group`'s own doc comment nowhere
promises "safe to free right after the last `wait_group_done`."

**Fix:** don't put the wait target inside the block that gets freed. `Grace_Signal`
is a **separate** heap allocation (`sem: sync.Sema, refs: int`) with a plain
refcount of 2 — one held by the waiter, one by the reaper. Each side's own
`grace_signal_release` call is always the *last* thing that side does with it;
the refcount guarantees `free(gs)` only happens once **both** sides have
already finished every touch they were ever going to make, regardless of what
`sema_post`/`sema_wait_with_timeout` do internally to hand off the wakeup —
this is the standard fix for the general problem, not a one-off patch.
`atomic_sub`'s return value (verified against this toolchain, not assumed —
see `/tmp/atomic_check.odin`-style probe) is the value *before* the
subtraction, matching LLVM `atomicrmw`/C11 `fetch_sub` convention, so "old
value 1" correctly identifies "I am the second and last releaser."

With that: `./tools/test.sh race` clean across 10 consecutive runs (5 before
adding a dedicated phase for this exact code path, 5 after), and a NEW,
dedicated TSan phase (`tools/racecheck`'s Phase F) drives 150 iterations of
`dispatcher_reap` directly with a deliberate mix — Cmds that finish inside the
grace period, Cmds that deliberately **outlive** it (forcing the true
async-detach path, the only one where anything survives past the call that
owns it), and Cmds racing `cancel_token_fire` against their own cancellation
poll — clean every time.

### 2.3 A THIRD bug, this time in `core:thread` itself

Ten clean runs was not enough. Continuing to run the race gate (to build
confidence before calling this done) turned up a *third*, genuinely different
data race, roughly 1 run in 5-8:

```
WARNING: ThreadSanitizer: data race (pid=1633487)
  Write of size 8 at 0x72440000a298 by thread T1926:
    #0 free
    #6 thread::[thread_unix.odin]::__unix_thread_entry_proc-0 .../thread_unix.odin:65

  Previous atomic write of size 4 at 0x72440000a298 by main thread:
    #0 sync::atomic_sema_post .../sync/primitives_atomic.odin:352
    #2 sync::sema_post .../sync/primitives.odin:509
    #3 thread::[thread_unix.odin]::_start .../thread_unix.odin:130
    #6 runetea::dispatcher_reap .../runetea/cmd.odin:293
SUMMARY: ThreadSanitizer: data race ... in free
```

This one is **in `core:thread` itself**, not this package's code, and it is
inherent to `self_cleanup = true` on *any* thread whose body can finish fast
enough — `dispatcher_reap`'s reaper thread with zero Cmds in flight can, since
`dispatcher_destroy` on an idle pool completes in low microseconds.
`thread.start(t)` (`thread_unix.odin`'s `_start`) does `atomic_or(&t.flags,
{.Started})` **then** `sync.post(&t.start_ok)` — two separate operations, not
one atomic step. The newly created thread's own startup loop
(`for (.Started not_in atomic_load(&t.flags)) { sync.wait(&t.start_ok) }`) can
observe `.Started` already set and skip the wait entirely, running its whole
body and — if `self_cleanup` is set — reaching `free(t, ...)` (which frees
`t.start_ok` along with the rest of the `Thread` struct) **while** `_start`'s
own `sync.post(&t.start_ok)` call is still executing on the calling thread.
Signal-then-immediately-free again, just living one layer down, inside
`core:thread`'s own self-cleanup implementation instead of this file's
`Grace_Signal`. Not something this package can patch (toolchain code); the
existing detached-Cmd path (`dispatch`'s `c.detached` branch,
`run_cmd_detached`) uses the identical API and is exposed to the same
underlying bug, just far less likely to hit it empirically (a Cmd body
almost always takes longer than one `sync.post` call) — left alone, since it
predates this task, was never observed to fail across everything run here,
and reworking it is out of scope.

**Fix:** `dispatcher_reap`'s reaper thread is spawned with `self_cleanup =
false`, and the caller detaches the underlying OS thread itself —
`posix.pthread_detach(t.unix_thread)`, called from `dispatcher_reap`'s own
thread immediately after `create_and_start_with_data` returns. This reclaims
the OS-level thread resources (stack, kernel TCB) without going through
core:thread's racy free path: `pthread_detach` only touches pthread-library
bookkeeping for the OS thread, never the Odin `^Thread` struct's own memory,
so it cannot race anything the spawned thread does with `t.start_ok`. First
attempt (`self_cleanup = false` with no detach at all) traded the data race
for a *worse* problem — TSan's own thread-leak detector flagging every
finished-but-unjoined `pthread_t` (kernel stack and all, not just a small
struct):

```
WARNING: ThreadSanitizer: thread leak (pid=1656150)
  Thread T1893 ... created by main thread at:
    #4 runetea::dispatcher_reap .../runetea/cmd.odin:301
  And 149 more similar thread leaks.
```

— confirming the fix has to be an active `pthread_detach`, not just
"don't self_cleanup." What is still, deliberately, leaked is the small,
fixed-size Odin-level `^Thread` struct itself (a few hundred bytes) —
`thread.destroy(t)` would reclaim that too, but it calls `thread.join(t)`
internally, which would block this call on the very Cmd this whole change
exists to stop waiting for. One leaked struct per `dispatcher_reap` call,
bounded, not proportional to anything this change is trying to bound, and
reclaimed by the OS at process exit regardless.

With both the data race and the thread leak fixed: **`./tools/test.sh race`
clean across 35 consecutive runs** (20 in one batch, 15 in a second,
specifically hunting for recurrence of the ~1-in-5-8 rate the second bug
showed).

### 2.4 Final design

- `Reap_Ctx { disp: Dispatcher, mbox: Mailbox, grace: ^Grace_Signal }` — heap-allocated
  by `run()` instead of two stack locals.
- `dispatcher_reap(rc, grace: time.Duration = 0) -> finished_in_time: bool`:
  fires `rc.disp.cancel` (§3), closes `rc.mbox`, spawns a self-cleaning reaper
  thread that runs the *unchanged* `dispatcher_destroy` + `mailbox_destroy` +
  `free(rc)`, and — only if `grace > 0` — waits up to `grace` via a
  `Grace_Signal` before returning.
- `run()`: `defer dispatcher_reap(rc, QUIT_GRACE)` where `QUIT_GRACE = 100 *
  time.Millisecond`, replacing `defer dispatcher_destroy(&disp)` +
  `defer mailbox_destroy(&mbox)`. **Declaration order matters and is inverted
  from the setup calls**: `dispatcher_reap`'s own precondition (same as
  `dispatcher_destroy`'s always was) is that every *other* producer into the
  mailbox — the reader thread, the `Signal_Watcher` — must already be stopped
  and joined before it runs, so its defer is declared *before*
  `signal_watcher_stop`'s (LIFO: it fires *after*), even though
  `signal_watcher_start` must be *called* before `dispatcher_init` for an
  unrelated reason (blocking signals on the calling thread before other
  threads exist). tea.odin's comments spell this out at the point it matters.
- `dispatcher_destroy` (the original, always-blocking primitive) is
  **unchanged** — still used directly by `cmd_test.odin`'s existing
  synchronous tests, and now also fires the Cancel_Token as its own first
  action, so any caller of it (including `run_nbio`, below) gets Cmds a
  cooperative shot at finishing early even without the async path.
- Orphaned Cmd results are not just discarded, they are **freed**: `run_cmd_task`/
  `run_cmd_detached` now call `box_free(msg, context.allocator)` when
  `deliver_result` reports `.Closed` instead of leaking the `box()` allocation
  — safe because this runs on the same thread that made the allocation, same
  allocator instance, same convention `apply()`'s own `box_free` call already
  relies on.

**`run_nbio` is deliberately NOT given this treatment.** Its `Dispatcher.wake`
hook calls `nbio.wake_up(loop)` after a successful `mailbox_send` from a pool
worker or detached Cmd thread — a resource *outside* the mailbox/dispatcher
pair that an async-detached reaper's residual Cmd could still reach for after
`run_nbio` has already called `nbio.release_thread_event_loop()`. Nothing
proves that window is safe, and closing it would need touching nbio's own
lifecycle, out of scope here. nbio was already decided ABANDON-as-primary
(`nbio-decision.md`); `examples/http` uses `run()`, not `run_nbio`. `run_nbio`
keeps its original, fully synchronous `dispatcher_destroy` + `mailbox_destroy` —
unmodified control flow, still correct, just not fast — and gets the
Cancel_Token plumbing "for free" since `Dispatcher`/`Task_Env`/`dispatch()` are
shared code.

---

## 3. HALF 2 — cooperative cancellation

### 3.1 Where the token lives

`Cancel_Token :: struct { cancelled: bool }`, one per `Dispatcher` (so one per
`run()`/`run_nbio()` session), touched only via `sync.atomic_load`/`atomic_store` —
the same pattern this file already uses for `Reader_Ctx.stop` and
`Signal_Watcher.stop`. `cancel_requested(tok) -> bool` is safe to call with
`tok == nil` (always reports "not cancelled"), so it is safe to sprinkle into
any Cmd regardless of how it was constructed.

It reaches a Cmd as a **second parameter on `Cmd.procedure`**, not through
`env` and not through `cmd_from`'s own argument list:

```odin
Cmd :: struct {
	procedure: proc(env: rawptr, cancel: ^Cancel_Token) -> any,
	...
}
cmd_from :: proc(fn: proc(env: rawptr, cancel: ^Cancel_Token) -> any, env: $E, alloc: mem.Allocator, detached := false) -> Cmd
```

`cmd_from(fn, env, alloc)`'s **call shape is untouched** — still exactly three
required arguments, at every existing call site. What changed is `fn`'s own
required signature, which every Cmd body must update (a mechanical,
one-parameter change — this touched ~12 existing Cmd bodies across the repo, a
find-and-fix, not a redesign). This was the deliberate trade against the two
alternatives the brief posed:

- **A field on `env`**: zero signature change anywhere, but the token has to be
  manually threaded into every `Check_Env{...}`-shaped literal that wants it,
  and is silently absent (nil, meaning "never cancelled") for any Cmd whose
  author forgot. Opt-in by omission is exactly the failure mode this port's
  existing ergonomics comments (env-cloning, `detached`) already worry about.
- **Thread-local, `guarded()`-style** (this codebase's own precedent for
  ambient per-thread state): would let `cmd_from` and `fn` both stay
  completely unchanged. Rejected specifically *because* it is ambient: `run_cmd_task`/
  `run_cmd_detached` would need to set-then-clear it around every single
  invocation on a *reused* pool worker thread, and a mistake there is a silent
  wrong-token bug, not a compile error the way a missing parameter is. Given
  this whole task is explicitly weighed against "a fast quit that corrupts
  memory is strictly worse than a slow correct one," the more explicit,
  harder-to-misuse shape won even though it costs a mechanical signature
  change everywhere.

`Dispatcher.cancel: Cancel_Token` is the actual instance; `Task_Env.cancel: ^Cancel_Token`
is copied from `&d.cancel` at `dispatch()` time — the same established pattern
`wake`/`wake_data` already use. `run_cmd_task`/`run_cmd_detached` call
`te.cmd.procedure(te.cmd.env, te.cancel)`. Nothing about `update()`'s own
signature changed.

### 3.2 The honest limit

**A `Cancel_Token` cannot interrupt a Cmd blocked inside a syscall it never
returns from on its own.** `time.sleep`, a bare `net.recv_tcp` with no
timeout, a blocked `wait()` on a child process — none of these poll anything;
the OS will not wake the thread up just because some other thread flipped a
bool. Polling only works in the gaps *between* bounded operations. This is
stated plainly in `Cancel_Token`'s own doc comment, not just here.

### 3.3 What core:net actually offers

Checked directly against `core/net/socket.odin`, `core/net/socket_linux.odin`,
and `core/sys/posix/sys_socket.odin` on this toolchain — not assumed:

- **`net.set_option(sock, .Receive_Timeout, duration)` / `.Send_Timeout`
  exist and work**, mapping to `setsockopt(SOL_SOCKET, SO_RCVTIMEO/SO_SNDTIMEO,
  ...)` on Linux (`_SOCKET_OPTION_RECEIVE_TIMEOUT :: linux.Socket_Option.RCVTIMEO`).
  This is real, usable socket-timeout support — the missing piece
  `examples/http` needed.
- **Non-blocking sockets exist too** (`net.set_blocking`/`_set_blocking`, an
  `fcntl(O_NONBLOCK)` wrapper) but were not needed here: a short blocking
  timeout, polled in a loop, gives the same responsiveness with much less
  code (no epoll/select layer to add).
- **There is no dial/connect timeout anywhere in `core:net`.**
  `dial_tcp_from_hostname_with_port_override` and friends take no
  timeout/deadline parameter. A connect() to a filtered or black-holed (not
  merely closed/refused) address can still block for the OS's own default TCP
  connect timeout — tens of seconds to minutes on Linux — and neither a
  Cancel_Token nor a socket option can touch it. **This is not fixed here.**
  `check_server`'s own doc comment says so plainly; it is a real, remaining gap
  for a Cmd that dials, not just one that receives.
- **A real, non-hypothetical bug was caught building this**: `SO_RCVTIMEO`
  expiry surfaces through `core:net`'s error mapping as `.Would_Block`
  (`EAGAIN`), **not** `.Timeout` — `.Timeout` is produced only by `ETIMEDOUT`, a
  different, connection-level condition (`core/net/errors_linux.odin`). The
  first version of `check_server` checked `rerr == .Timeout` and, driven live
  under a real pty against `tools/stallserver`, exited in **~80µs** printing
  `error: recv: Would_Block` instead of retrying — worse than doing nothing,
  since it turned "the host is slow" into "the host is broken." Caught by
  actually running the demonstration this document exists to report, not by
  code review; fixed by checking `.Would_Block`.

### 3.4 `examples/http`'s fix

`check_server` now:

1. Sets `.Receive_Timeout`/`.Send_Timeout` to `RECV_POLL = 200ms` right after
   dialing.
2. Loops `recv_tcp`, checking `cancel_requested(cancel)` before every attempt
   and treating `.Would_Block` as "try again," up to an overall
   `RECV_MAX_WAIT = 30s` safety net independent of cancellation (so a Cmd
   whose caller never quits and whose host never replies still terminates on
   its own eventually, rather than polling literally forever).
3. `HOST`/`PORT` are overridable via `RT_HTTP_HOST`/`RT_HTTP_PORT` env vars,
   read once in `main()` — the only thing that changes to point the exact same
   binary at `tools/stallserver` for the demonstration below, with no second
   copy of the example.

Verified the happy path still works (this rewrote the whole recv loop, not
just added a check): against a real local HTTP server and against
`example.com` over the network, both print the correct status and quit
cleanly — see §5.3.

---

## 4. Tests

### 4.1 Unit / functional (`./tools/test.sh`)

**80 tests, all successful** (77 pre-existing + 3 new). The pre-existing
per-test memory-report warnings (leaked `box()` allocations in tests that
don't drain their own mailbox, a leaked panic message in
`guard_assertion_failure`, etc.) are **identical** before and after this
change — confirmed by running `./tools/test.sh` against `git stash`'d
(unmodified) code and diffing the warning set byte-for-byte. Nothing new
leaks or bad-frees.

New tests, each proven non-vacuous by temporarily reverting the exact
mechanism it pins and re-running (not merely inspected):

- `cmd_test.odin::test_dispatcher_reap_does_not_block_the_caller` — dispatches
  a 300ms Cmd, calls `dispatcher_reap(rc, 20ms)`, asserts it returns in
  `< 150ms`. Reverted to a direct `dispatcher_destroy` + `mailbox_destroy`
  call: **fails**, `took 300.280289ms`.
- `cmd_test.odin::test_cancel_token_observed_by_a_polling_cmd` — dispatches a
  Cmd polling `cancel_requested` every 5ms up to 100 iterations, fires
  `dispatcher_reap(rc, 0)` immediately, asserts the Cmd observed cancellation
  within 5 iterations. (Not separately reverted — this one exercises brand
  new machinery with no prior blocking equivalent to fall back to; its
  assertion on `probe.iterations` is what a broken wiring would fail
  directly.)
- `tea_test.odin::test_run_returns_promptly_with_a_slow_cmd_still_in_flight` —
  the end-to-end version at `run()`'s own public boundary: dispatches a 300ms
  Cmd on the first keypress, quits on the second, asserts `run()` returns in
  `< 200ms`. Reverted `tea.odin`'s `defer dispatcher_reap(rc, QUIT_GRACE)` to
  the original `defer dispatcher_destroy(&disp)` + `defer mailbox_destroy(&mbox)`
  pair: **fails**, `took 300.646086ms`.

### 4.2 Race gate (`./tools/test.sh race`)

**Clean across 35 consecutive runs** of the full harness (§2.3), after fixing
both the Grace_Signal UAF (§2.2) and the core:thread self_cleanup race (§2.3)
— the second of those two took over 10 clean runs before it reproduced, which
is why 35 is the number that counts here, not the first clean run.
`tools/racecheck` gained a new **Phase F**, run every time alongside
the existing five phases: 150 iterations of `dispatcher_reap` called directly,
deliberately mixing three outcomes on each iteration — a Cmd slower than the
grace period (forces the true async-detach path), a Cmd racing cancellation
against `cancel_token_fire`, and a Cmd that finishes inside the grace period —
so this is not incidental coverage via `run()`'s own phases (which never
happen to dispatch anything slower than their own tiny grace-covered Cmds),
it targets the exact code path the two bugs above lived in.

```
--- phase F: dispatcher_reap (direct, mixed grace outcomes, cancellation) ---
  dispatcher_reap: 150/150 Cmds completed (async-detach, cancellation, and in-grace outcomes all exercised)
```

---

## 5. Measurements

### 5.1 Quit latency, one 2-second Cmd in flight

The addendum's own benchmark, reproduced exactly (dispatch a Cmd that sleeps
2s on the first keypress, quit on the second, time `run()`):

```
BEFORE: quitbench: run() returned after 2.000780467s (err=nil)
AFTER:  quitbench: run() returned after 100.806013ms (err=nil)
```

AFTER, repeated three more times for consistency: `100.603429ms`,
`100.598019ms`, `100.702096ms` — tightly clustered around `QUIT_GRACE` (100ms)
plus a small constant, exactly as designed: latency is now a **bounded
constant**, not proportional to how long the stuck Cmd takes. **~20x faster.**

### 5.2 The stalled-socket demonstration

`tools/stallserver` (new, committed) listens, accepts, and never replies —
the concrete "stalled host" shape. `tools/httpquitcheck` (new, committed)
drives a target binary under a **real pty** (`posix_openpt`/`grantpt`/
`unlockpt`, not a pipe — the one thing that can actually answer "is the
terminal left raw"), sends either a `'q'` keypress or an external `SIGINT`,
and reports the pty **master's** `tcgetattr` ECHO/ICANON state before and
after — master and slave share one line-discipline instance, so this reflects
exactly what the child did via `tcsetattr` on the slave, without needing the
slave fd itself.

**BEFORE** (unmodified code and library, rebuilt via `git stash`, HOST/PORT
retargeted to the local stall server — same logic, no timeout, no
cancellation, otherwise byte-for-byte the original):

```
$ httpquitcheck http_BEFORE key
pty termios before spawn:  ECHO=true  ICANON=true  (cooked -- default pty state)
pty termios after spawn:   ECHO=false ICANON=false (raw expected -- false/false -- once term_enter_raw has run)
sent: 'q' keypress
RESULT: still running after 8.004370084s (mode=key, target=127.0.0.1:18099) -- HUNG, killing with SIGKILL
pty termios after wait:    ECHO=false ICANON=false (cooked expected -- true/true -- ONLY if term_restore() actually ran before exit)

$ httpquitcheck http_BEFORE sigint
...
sent: SIGINT to the child process
RESULT: still running after 8.003509009s (mode=sigint, ...) -- HUNG, killing with SIGKILL
pty termios after wait:    ECHO=false ICANON=false (...)
```

Confirmed exactly as described: raw mode entered correctly, then **neither
mechanism does anything** — 8+ seconds (the harness's own bounded wait; the
real answer is "forever," since there is no timeout at all) with the terminal
frozen raw, requiring `SIGKILL`, which leaves the terminal **wedged** (still
`false/false` — raw — after the process is gone). This is the entire Tier
1/Tier 2 crash-safety story defeated by the single commonest real hang, proven
live, not asserted.

**AFTER** (current, fixed code):

```
$ httpquitcheck http_AFTER key 127.0.0.1 18099
pty termios before spawn:  ECHO=true  ICANON=true  (cooked)
pty termios after spawn:   ECHO=false ICANON=false (raw)
sent: 'q' keypress
RESULT: exited after 101.440923ms (mode=key, target=127.0.0.1:18099)
pty termios after wait:    ECHO=true  ICANON=true  (cooked -- term_restore() ran)

$ httpquitcheck http_AFTER sigint 127.0.0.1 18099
...
sent: SIGINT to the child process
RESULT: exited after 111.370226ms (mode=sigint, ...)
pty termios after wait:    ECHO=true  ICANON=true  (cooked)
```

Both quit paths now resolve in ~100-110ms (`RECV_POLL`'s 200ms bound would
apply if the Cmd hadn't already noticed via `QUIT_GRACE`/`cancel_requested`
first — the two mechanisms compose exactly as intended, §3.4), and the
terminal is genuinely restored to cooked mode before the process exits —
**not wedged.**

### 5.3 Happy path unaffected

`check_server`'s recv loop changed from one blocking call to a bounded
poll-and-retry loop — worth confirming that didn't break a normal, fast
reply. Against a local server returning `200 OK` immediately:

```
Checking http://127.0.0.1:18100 ...
http://127.0.0.1:18100 -> 200
```

and against the real `example.com` over the network:

```
Checking http://example.com:80 ...
http://example.com:80 -> 200
```

Both quit on their own via `Status_Msg` → `quit_cmd()`, exactly as before.

---

## 6. Scope boundaries — what this does NOT fix

- **`net.dial_tcp_*` has no timeout in `core:net`.** A Cmd blocked in
  `connect()` to a black-holed address is not helped by anything here (§3.3).
- **`run_nbio` keeps its original, fully synchronous teardown** (§2.4) — same
  quit-latency cost it always had. Not the primary path
  (`nbio-decision.md`: ABANDON as primary), and `examples/http` does not use
  it.
- **A Cmd blocked in any other unbounded syscall** (a child process `wait()`,
  a blocking file read on a hung NFS mount, etc.) is not cancellable by this
  mechanism — only Cmds the author has explicitly written with a bounded
  retry loop, like `check_server`'s, can respond to `cancel_requested`
  promptly. The `Cancel_Token` doc comment says this outright; it is not a
  general "make any Cmd cancellable" solution, and cannot be one without OS
  support this toolchain does not expose (thread cancellation via
  `pthread_cancel` was considered and rejected — `thread.Pool`'s own
  `pool_stop_task`/`pool_shutdown` use it and document that it "may leave
  resources unclaimed," e.g. a mutex left locked mid-critical-section — that
  is a strictly worse outcome than the slow-but-correct baseline this whole
  task is measured against).
