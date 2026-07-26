# Message ownership — built, measured, decided

**Date:** 2026-07-26
**Status:** Decided — Msg types must be POD, enforced at every `box()` call.
**Toolchain:** Odin dev-2026-07-nightly:819fdc7. Linux only.

Spike-findings.md's addendum, item 8: "Message ownership is undefined and
`examples/http` has already committed to an answer (it stores a
pool-allocated string straight into the model). Decide borrow-vs-own
**before** T1 writes more examples." This document is that decision, and it
gates every `Cmd`/`Msg` signature written after it.

**The problem, measured, not assumed:** nothing has ever freed a boxed `Msg`.
A test that sends 2001 keys through `run()` (`test_run_survives_a_mailbox_
overflow`, tea_test.odin) leaked **exactly 2001 allocations** before this
work — unbounded over a session's length, not a per-frame cost. The obvious
fix ("free the box after `apply()` is done with it") breaks `examples/http`
as shipped: `case Err_Msg: m.err = v.reason` stores a pointer that came from
`fmt.aprintf` on a **pool worker thread**, a SEPARATE allocation from the one
`box()` makes for the struct itself. Freeing the struct doesn't free that
string; freeing the string (if the fix tries to be thorough about it)
dangles `m.err`. Four designs were evaluated for what a Msg is allowed to
own and who frees what. **The decision: Msg types must be POD (no owned
pointers, anywhere in the field tree) — enforced by `box()` itself, on every
call, so the wrong thing does not silently compile into a leak or a
use-after-free.**

---

## 1. What was built

Four options were prototyped enough to be real (not argued from theory), each
ported against the exact `examples/http` `Err_Msg{reason: string}` case that
motivated this document, then measured.

| File | What |
|---|---|
| `tools/proto_a/main.odin` | Option A (borrowed, loop frees the box) — both a shallow-free and a reflection-based deep-free flavor, against a Tracking_Allocator |
| `tools/proto_c/main.odin` | Option C (per-message arena) — the cheap hand-rolled-bump-allocator flavor, Cmd-signature change, group-free |
| `tools/proto_d/main.odin` | Option D (owned + destructor proc) — a `Mailbox_Entry{msg, destroy}` wrapper, symmetric alloc/free |
| `tools/msgbench/main.odin` | Allocation-cost benchmark: heap new+free vs. a fresh `virtual.Arena` per message vs. a hand-rolled bump arena per message |
| `tools/podcheck/main.odin` | Proves Odin cannot fold a user-defined recursive proc into a `when`/`#assert` compile-time constant, even when the proc's body is built entirely out of const-foldable `intrinsics.type_is_*` calls — the reason Option B's enforcement is a runtime check, not a compile error |
| `runetea/arena.odin` (+111 lines) | `box()` gains a POD check (`is_pod_type`/`is_pod_info`, recursive `runtime.Type_Info` walk) and calls `panic()`, not `assert()`, on failure; `box_free()`, the other half of the contract |
| `runetea/msg.odin` (new, 79 lines) | `Msg_Text` — a fixed-capacity, POD-safe string carrier, with `msg_text_from`/`msg_text_fmt` (truncating constructors) and two accessors: `msg_text_string` (borrows, transient) and `msg_text_clone` (always allocates, the only safe choice for retaining) |
| `runetea/tea.odin` (+15/-1) | `apply()` now `defer box_free(msg, context.allocator)` as its first statement — fires on every exit path exactly once |
| `runetea/loop_nbio.odin` (+35/-8) | Fixed a real bug this work surfaced: `nbio_flush_backlog` sent `Key_Msg` values through an **implicit `any` conversion** pointing into `rc.backlog`'s own dynamic-array storage, never through `box()` — harmless while nothing ever freed a message, a "bad free" (confirmed via Tracking_Allocator) the moment `apply()` started freeing every message. Now boxes each key at decode time, same convention as `tea.odin`'s reader thread |
| `examples/http/main.odin`, `tools/http_nbio/main.odin` | Ported to `Msg_Text` (see §3's diff) |
| `runetea/cmd_test.odin`, `tools/racecheck/main.odin` | Existing non-POD test/harness Msg types (`Fetch_Result{url: string, ...}`, `Cmd_Result{tag: string, ...}`) fixed to comply |

---

## 2. The options, measured

All four were run against the same question: box a message with a
`fmt.aprintf`-produced payload string (mirroring `examples/http`'s
`Err_Msg`), simulate `case Err_Msg: m.err = v.reason` (the actual line
`examples/http` shipped with), then free the message the way that option's
loop would, and observe what happens to `m.err`.

### A. Borrowed — loop frees the box after `apply()`

```
$ /tmp/proto_a
=== Option A prototype: shallow free ===
reason before free: dial: connection refused (attempt 7)
leaked allocations after shallow free: 1 (76 bytes)
  leak: 76 bytes @ .../core/strings/builder.odin(170:11)
reason after shallow free (still readable, unchanged): dial: connection refused (attempt 7)

=== Option A prototype: deep free (reflection-based) ===
model_err before free: dial: connection refused (attempt 7)
leaked allocations after deep free: 0
model_err after deep free + a reallocation (DANGLING): -���$�X�nnection refused (attempt 7)
```

There are two honest readings of "free the box," and they fail differently:

- **Shallow** (free exactly what `box()`'s `new(V, alloc)` allocated — the
  16-byte struct/string-header, nothing else): does not dangle, because the
  payload string is a genuinely separate allocation the free never touches —
  but it also does not fix the leak. For any Msg with an owned payload
  (which is most real Cmd results — error text, HTTP bodies, parsed data),
  the 2001-allocation problem becomes a smaller but still-unbounded leak of
  payload bytes instead.
- **Deep** (also walk the struct via reflection and free any owned
  string/slice found): closes the leak, and dangles `m.err` the moment the
  freed block gets reused — reproduced above, not asserted: `clobber :=
  strings.clone("XXX...")` after the free visibly corrupts the bytes
  `model_err` still points at. It is also unsound as a *general* mechanism:
  reflection cannot tell an owned string (from `fmt.aprintf`) from a
  borrowed one (a string literal field) — freeing the latter is undefined
  behavior, not merely a leak.

**User-facing API cost:** none — this is the "do nothing differently, just
add a free" option. That is exactly its problem: `examples/http` compiles
unchanged and, under the deep-free flavor needed to actually stop the leak,
dangles silently. The discoverability question the spec asked ("is there an
idiom that makes the copy obvious rather than remembered?") has no answer
under A specifically — the type system gives no signal that `v.reason` is
call-scoped; `m.err = v.reason` and `m.err = strings.clone(v.reason, ...)`
are equally well-typed.

**Failure mode when a user gets it wrong: silent corruption (deep free) or a
leak that is merely smaller, not gone (shallow free).** Worst of the four.

### B. POD — no owned pointers, enforced by `box()` — ADOPTED

```
$ /tmp/podcheck
[OK] Key_Msg          is_pod=true (want true)
[OK] Window_Size_Msg  is_pod=true (want true)
[OK] Quit_Msg         is_pod=true (want true)
[OK] Good_With_Text   is_pod=true (want true)
[OK] Good_Union       is_pod=true (want true)
[OK] Bad_String       is_pod=false (want false)
[OK] Bad_Slice        is_pod=false (want false)
[OK] Bad_Pointer      is_pod=false (want false)
[OK] Bad_Nested       is_pod=false (want false)
[OK] Bad_Array        is_pod=false (want false)
[OK] Bad_Union        is_pod=false (want false)
```

Every framework Msg type (`Key_Msg`, `Window_Size_Msg`, `Quit_Msg`,
`Interrupt_Msg`) was already POD before this decision — nobody had to change
them. The cost lands entirely on user Cmd results that want text: a `string`
field must become `Msg_Text` (`runetea/msg.odin`), a 255-byte fixed buffer.

**User-facing API cost — the actual diff to `examples/http`** (full diff is
`git show` on this commit; the load-bearing lines):

```diff
-Err_Msg    :: struct { reason: string }
+Err_Msg :: struct { reason: rt.Msg_Text }

-		return rt.box(Err_Msg{reason = fmt.aprintf("dial: %v", derr)}, context.allocator)
+		return rt.box(Err_Msg{reason = rt.msg_text_fmt("dial: %v", derr)}, context.allocator)

 	case Err_Msg:
-		m.err = v.reason; m.done = true
+		m.err = rt.msg_text_clone(v.reason, context.allocator)
+		m.done = true
 		return m, rt.quit_cmd()
```

One field-type change, `fmt.aprintf` → `rt.msg_text_fmt` at each of the four
call sites (mechanical, same argument list), and one call to
`rt.msg_text_clone` where the model retains the text. 6 substantive lines
changed in a 105-line file.

**Real, measured cost this option pays that the others don't: truncation.**
`Msg_Text` caps a payload at `MSG_TEXT_CAP = 255` bytes; anything longer is
silently cut off (`msg_text_from`/`msg_text_fmt`'s doc comment is explicit
about this — a fallible constructor was rejected specifically because it
would turn every `return box(...)` one-liner into an error-handling
decision). For `examples/http`'s error strings (`"dial: %v"` etc.) this
never bites in practice; for a Cmd that could plausibly return an HTTP body
or a long log line, it would, and that Cmd needs something other than
`Msg_Text` (chunking, an index into an interned table, or accepting
truncation as a stated policy). This is a real, permanent ergonomic
tax — the honest cost of buying "cannot alias" for free with plain value
semantics.

**Is the hazard eliminated or merely relocated?** Eliminated, structurally,
for the payload-vs-box aliasing problem specifically: a POD value has no
address it can leak, so `box_free` freeing the one allocation `box()` ever
made is *always* the complete, correct cleanup — there is no second,
separate allocation to also remember. A narrower version of the same class
of bug is still *possible* if a user manually slices `Msg_Text.buf` (via
`msg_text_string`, the transient/borrowing accessor) and stores the result —
see §5 for why that accessor still exists and how it's fenced.

**Compile-time enforcement was attempted and does not work on this
toolchain — verified, not assumed:**

```
$ /home/denisbytes/odin/odin build tools/podcheck
tools/podcheck/main.odin(57:7) Error: Non-constant condition in 'when' statement
	when is_pod(Good) {
```

`is_pod`'s body is built entirely from `intrinsics.type_is_*` calls, each
individually a compile-time constant when given a concrete `$T`— but Odin
does not fold a *user-defined proc* built out of them into a `when`/`#assert`
constant the way e.g. Zig's `comptime` would. This was checked empirically
before settling for a runtime check, not assumed from documentation.

**Failure mode when a user gets it wrong:** `box()` calls `panic()` (not
`assert()` — see below) the first time it's asked to box a non-POD type.
Confirmed clean and recoverable via `guarded()` in
`test_box_rejects_non_pod_type` (arena_test.odin) — `panic()` routes through
`context.assertion_failure_proc` exactly like `assert()` does, so the same
Tier-1 recovery machinery that already catches a panicking `Update`
(`test_program_recovers_from_a_panicking_update`, tea_test.odin) catches
this too. Outside a `guarded()` context — a Cmd body on a pool worker, which
is where this actually fires in practice, since Cmd bodies run unguarded
(spike-findings.md addendum item 7) — it's an honest, immediate process
abort with the offending type's box() call site in the message. **This is a
programming error, not a runtime data condition, so it should crash loud and
early, not be caught and continued past** — the same philosophy Tier 2 (bounds
violations, `guard.odin`) already applies to bugs that indicate corrupted
program state rather than a recoverable user-code exception. `panic()`, not
`assert()`, specifically because `-disable-assert` is a real release flag
this codebase has already been bitten by once (`guard.odin`'s FIX 3, on
`g_armed`'s re-entrancy guard) — the same lesson applied here without
needing to relearn it.

### C. Per-message arena

```
$ /tmp/msgbench
N = 200000 messages

baseline heap new+free:            7.492053ms total, 37ns/msg
virtual.Arena (4KiB reserve):       3.378959152s total, 16.894µs/msg
bump arena over heap buf (256B):    19.032115ms total, 95ns/msg
```

A fresh `virtual.Arena` per message — the obvious, idiomatic choice given
this codebase already uses `virtual.Arena` for the frame arena — is **456x
slower than a plain heap allocation**, because `virtual.arena_init_growing`
does a real `mmap` and `arena_destroy` a real `munmap`, once per message.
Not affordable at message rates a long-running TUI plausibly sees (every
keypress is a message). A hand-rolled bump allocator over one small heap
buffer is affordable (95ns/msg, ~2.6x baseline for allocating a struct *and*
a payload from the same block) — but has a fixed capacity chosen ahead of
time, trading the same truncate-or-waste tension `Msg_Text` has, just moved
from "255 bytes for text" to "N bytes for the whole message including
struct + payload," and Cmd authors would need to guess N per message type.

**User-facing API cost:** the largest of the four, structurally. Every `Cmd`
proc's signature changes — `proc(env: rawptr) -> any` becomes `proc(env:
rawptr, alloc: mem.Allocator) -> any` — because the arena has to be created
by the *dispatcher*, before the Cmd runs, and handed in. That touches every
Cmd ever written, not just ones with a payload (`quit_run`/`quit_cmd` in
`tea.odin` would need it too, for no benefit — `Quit_Msg` is empty).
`cmd.odin`'s `run_cmd_task`/`run_cmd_detached` would need to own creating and
destroying that arena, and the `Mailbox`'s element type would need to carry
the arena handle alongside the `any` (today it's a bare `[]any`) so the loop
knows what to destroy once `apply()` is done — a worker-thread-owned
resource that a *different* thread (the loop) must tear down once the
message has sat in a queue for an arbitrary amount of time. Real, additional
machinery beyond what B or D need.

**Is the hazard eliminated?** No — logically identical to Option A's
deep-free flavor, just with the free relocated from "per-field, via
reflection" to "the whole arena, in one call." `m.err = v.reason` still
stores a pointer into memory the arena-destroy call reclaims; grouping the
free does not stop the model from having retained a pointer into the group.
Confirmed in `tools/proto_c`: zero leaks after the group-free (Tracking
Allocator: `leaked allocations after group-free: 0`), but the same aliasing
mistake as A is present in the code (not independently reproduced as visible
corruption in every run — glibc's allocator didn't reliably reuse the freed
block in this harness's specific size class — but the mechanism is
identical to A's deep-free case, which *did* reproduce, deterministically,
above; freeing memory a live pointer still references is unsound regardless
of whether a given run happens to show it).

**Failure mode when a user gets it wrong: silent corruption (same as A's
deep-free), plus a new signature every Cmd must carry whether or not it
needs the arena.** Worse than A on API cost, no better on safety.

### D. Owned + destructor

```
$ /tmp/proto_d
model_err before destroy: dial: connection refused (attempt 7)
leaked allocations after destroy+free: 0
model_err AFTER destroy + reuse (DANGLING, corrupted): ps,5�>�/nnection refused (attempt 7)
```

Every Msg type with owned data pairs its `box_owned(v, alloc, destroy_proc)`
call with a `destroy: proc(any, mem.Allocator)` the loop invokes after
`apply()`. This is the most *correct* of the non-POD options in one specific
sense: unlike A's reflection-based deep free, `destroy_proc` is
author-written for its own type, so it can never misfire on a borrowed
string literal the way blind reflection can — it only frees what its author
said to free.

**User-facing API cost:** a new box variant (`box_owned`, not `box`), a
`Mailbox_Entry{msg, destroy}` wrapper that has to travel through the mailbox
instead of a bare `any` (`mailbox.odin`'s buffer type changes shape, same as
C), and a hand-written `destroy` proc per Msg type that owns anything —
for `examples/http`, an `err_msg_destroy :: proc(msg: any, alloc:
mem.Allocator) { e := msg.(Err_Msg); delete(e.reason, alloc) }` the user has
to write and remember to pair with every `Err_Msg` box call.

**Is the hazard eliminated?** No — and the repro above is the cleanest of
the three non-POD options, reproducing every run: `destroy_proc` correctly
and soundly frees exactly `v.reason`'s bytes (zero leak, confirmed), and
`m.err`, still holding that same pointer, reads corrupted memory the instant
something else allocates into the freed slot. D fixes the OWNING side
(no leak, no unsound blind-free) but does nothing for the CONSUMING side
(the model can still store a bare borrow) — it is solving a different half
of the problem than the one `examples/http` actually hit.

**Failure mode when a user gets it wrong: silent corruption**, same tier as
A and C, for more machinery than A and comparable machinery to C.

### Summary

| | API cost vs. today | Hazard eliminated? | Cost/msg (measured) | Wrong-usage failure mode |
|---|---|---|---|---|
| A. Borrowed, loop frees | none | No — leaks (shallow) or dangles (deep) | 37ns (shallow) | **Leak (still) or silent corruption** |
| **B. POD, enforced — ADOPTED** | field-type change + 1 clone call at retention sites | **Yes, structurally** | 37ns (identical to today's box) | **Loud panic, first call, recoverable under guarded()** |
| C. Per-message arena | every Cmd signature changes | No — same class as A | 95ns (bump, capped) / 16.9us (virtual.Arena, disqualified) | Silent corruption |
| D. Owned + destructor | new box variant, mailbox entry wrapper, per-type destroy proc | No — fixes leak, not dangling | not separately benchmarked (same shape as box, plus a destroy call) | Silent corruption |

**Only B changes what "the wrong thing does not compile" can mean given
Odin's actual constant-folding rules (verified above, not assumed) into "the
wrong thing does not run past its first exercise, loudly, at the exact call
site" — and it is the only option where that failure mode covers the WHOLE
hazard class, not just the box's own struct.** A, C, and D all still permit
`m.err = v.<payload>` to compile and silently corrupt later; B does not
permit `v.<payload>` to be a pointer type at all.

---

## 3. What was actually implemented

**`box()`'s new contract** (`runetea/arena.odin`): every `V` passed to
`box(v: $V, alloc: mem.Allocator) -> any` must be POD — recursively, no
`string`/`cstring`/`^T`/`[]T`/`[dynamic]T`/`map`/`any` anywhere in its field
tree. Checked via `is_pod_type`/`is_pod_info`, a recursive walk of
`base:runtime`'s `Type_Info` (handling `Type_Info_Named` unwrapping,
`Struct` field recursion, `Array`/`Enumerated_Array` element recursion, and
`Union` variant recursion). On failure: `panic()`, not `assert()` (survives
`-disable-assert`; see §2's Option B section for why).

**`box_free()`** (`runetea/arena.odin`): the other half — `free(msg.data,
alloc)`. Sound and complete *because of* the POD contract: there is never a
second allocation to also reclaim.

**`Msg_Text`** (`runetea/msg.odin`, new file): a `[255]u8` + `u8` len fixed
buffer. `msg_text_from(s: string)` and `msg_text_fmt(format, ..args)` are
truncating constructors (no fallible-constructor ceremony at every Cmd
return site). Two accessors, deliberately not interchangeable:
`msg_text_string(m: ^Msg_Text) -> string` **borrows** `m^` (safe only for an
immediate, same-expression read — e.g. formatting into a view string) and
`msg_text_clone(m: Msg_Text, alloc) -> string` **always allocates** a fresh,
independent copy (the only safe choice for a model field). Naming them
`_string` (borrow) vs `_clone` (own) is this design's answer to the spec's
own discoverability question — the name says what it does without needing
the doc comment read first.

*A bug caught along the way, worth recording:* the first version of
`msg_text_string` took `m: Msg_Text` **by value** and sliced its own local
copy — which put the returned string's data on `msg_text_string`'s own stack
frame, dangling the instant it returned. Caught immediately (the very first
test that printed the result got back garbage/an empty string), fixed by
taking `m: ^Msg_Text` instead. Recorded in the function's own doc comment —
it is exactly the class of bug this whole document is about, just one level
removed from the Msg/mailbox boundary, and a useful reminder that "borrow a
value parameter's own field" is unsafe in Odin regardless of where it
happens.

**`apply()`** (`runetea/tea.odin`): `defer box_free(msg, context.allocator)`
as its first statement — covers every exit path (Quit_Msg/Interrupt_Msg
short-circuits, the panic-recovered return, the normal end-of-frame return)
exactly once, shared by both `run()` and `run_nbio()` since `apply()` is
package-private and reused verbatim by both hosts.

**A real, pre-existing bug this surfaced and fixed** (`runetea/loop_nbio.odin`):
`nbio_flush_backlog` sent `Key_Msg` values to the mailbox via
`mailbox_send(rc.mailbox, rc.backlog[rc.backlog_pos])` — an **implicit `any`
conversion** pointing directly into `rc.backlog`'s own `[dynamic]Key_Msg`
backing storage, never through `box()`. This happened to work before this
change only because nothing downstream ever freed a message; the moment
`apply()` started calling `box_free` on everything, Tracking_Allocator
reported thousands of `+++ bad free` errors (freeing a pointer into the
middle of an array's buffer, not a `new()`'d block's start address) —
undefined behavior in a real (non-tracking) build, not merely a leak. Fixed
by boxing each `Key_Msg` at decode time (`backlog` is now `[dynamic]any`),
matching `tea.odin`'s reader thread exactly. Also fixed: any backlog entries
still unflushed at shutdown (only reachable if the mailbox closes mid-flush)
are now `box_free`'d in `run_nbio`'s cleanup `defer`, rather than leaked via
`delete(rc.backlog)`, which only reclaims the dynamic array's own slice, not
what each element's `box()` call allocated.

**Test-suite fixes required by the new contract:** `Fetch_Result{url:
string, status: int}` (`runetea/cmd_test.odin`, used by 4 tests) and
`Cmd_Result{tag: string, id: int}` (`tools/racecheck/main.odin`) both boxed a
bare string and would now panic. `Fetch_Result.url` became `Msg_Text`
(compared via `msg_text_string`); `Cmd_Result.tag` was simply dropped — it
was never read downstream, so there was nothing worth converting.

---

## 4. Verification

```
$ ./tools/test.sh
...
Finished 59 tests in 315.249887ms. All tests were successful.
```
59 = the 56 tests present before this work + 3 new (`test_is_pod_type_
classifies_correctly`, `test_box_rejects_non_pod_type`,
`test_box_free_reclaims_the_only_allocation`, all `arena_test.odin`).

```
$ ./tools/test.sh race
--- phase A: mailbox ... ---           6042 messages received
--- phase B: dispatcher ... ---        21500 results drained (20000 pool + 1500 detached)
--- phase C: signal watcher ... ---    2407 messages drained from 3600 signals sent
--- phase D: Program/run() ... ---     30 full run() cycles completed
--- phase E: Program/run_nbio() ... -- 30 full run_nbio() cycles completed
=== racecheck: all phases completed without crashing (2.42424981s) ===
```
Exit code 0. Phases D and E specifically exercise `apply()`'s new
`box_free` call concurrently with other threads still `box()`-ing new
messages, under real ThreadSanitizer — no data race reported.

**Both examples, driven through a real pty** (`pty.fork()` + `os.execv`,
same technique the T0 spike used):

`examples/simple`, keys `a`, `a`, `q`:
```
Hi. This program will exit on 'q'.

Keys pressed: 0
...Keys pressed: 1
...Keys pressed: 2
...Keys pressed: 2   (repainted once more for the 'q' keypress itself, then the async Quit_Msg ends the run)
```

`examples/http` against the live network (`example.com:80`):
```
OUTPUT: b'Checking http://example.com ...\r\n\x1b[1A\x1b[2Khttp://example.com -> 200\r\n'
```
"Checking..." paints immediately, the real HTTP 200 arrives and repaints
with no keypress — the same async-Cmd-with-no-keypress scenario the T0
spike verified, now running through the POD `Status_Msg` path.

`examples/http`'s **error path**, specifically, since that is the exact case
this document is about (a copy of `examples/http` pointed at
`127.0.0.1:1`, an instantly-refused connection):
```
OUTPUT: b'Checking http://127.0.0.1 ...\r\n\x1b[1A\x1b[2Kerror: dial: Refused\r\n'
```
`rt.msg_text_fmt("dial: %v", derr)` on a pool worker thread → `rt.box(Err_Msg{...},
context.allocator)` → mailbox → `apply()` → `rt.msg_text_clone(v.reason,
context.allocator)` into the model → rendered → the original `Err_Msg` box
freed by `apply()`'s deferred `box_free` — end to end, through the real
Dispatcher/Mailbox/apply() machinery, not a prototype.

### The leak, before and after — same test, same message count

`test_run_survives_a_mailbox_overflow` (tea_test.odin): 2000 `'a'` keys + 1
`'q'`, driven through the real `run()` loop.

```
BEFORE (git stash to the pre-existing code):
$ odin test runetea -define:ODIN_TEST_NAMES=runetea.test_run_survives_a_mailbox_overflow
        +++ leak        12B @ 0x... [arena.odin:71:box()]
        ... (2001 lines) ...
Finished 1 test in 19.388108ms. The test was successful.
$ grep -c "+++ leak" output
2001

AFTER (this work):
$ odin test runetea -define:ODIN_TEST_NAMES=runetea.test_run_survives_a_mailbox_overflow
Finished 1 test in 10.538812ms. The test was successful.
$ grep -c "+++ leak" output
0
```

**2001 leaked allocations → 0.** The nbio-hosted equivalent
(`test_run_nbio_survives_a_mailbox_overflow`, same 2001-key scenario through
`run_nbio`) was also checked and is likewise 0 (it was never separately
cited in the original 2001 measurement, but shares the exact mechanism this
fix addresses, and needed the `loop_nbio.odin` fix in §3 to get there).

Whole-suite comparison (56 tests before → 59 after): total `+++ leak` count
across the full suite dropped from **2027 to 17**. All 17 that remain are
attributable to tests that call `Dispatcher`/`Mailbox`/`Signal_Watcher` APIs
**directly**, bypassing `apply()` entirely (they test lower-level plumbing,
never claimed to be leak-free, and leaked the identical amount before this
work), plus `guard.odin`'s own pre-existing panicked-message-clone leak
(present both before and after, unrelated to Msg lifecycle — `guarded()`
clones the panic message into `g_panic_alloc` and nothing currently frees
`Panic_Info.message`, a separate, smaller, already-documented gap this
document does not attempt to close). **Zero `+++ bad free` reports** in the
final state (there were thousands, transiently, while the `loop_nbio.odin`
bug in §3 was still present — confirming that fix, not just papering over
its symptom).

---

## 5. What T1 examples must follow

1. **Every `Cmd`-returned `Msg` type must be POD.** `box()` enforces this;
   design the type this way from the start rather than discovering it via a
   panic. `int`, `bool`, enums, `bit_set`s, fixed arrays of POD, and nested
   structs of POD fields are all fine. `string`, `cstring`, any pointer,
   slice, dynamic array, map, or `any` are not, anywhere in the field tree.
2. **Text payloads use `Msg_Text`**, not `string`. Build one with
   `msg_text_from(s)` or `msg_text_fmt(format, ..args)` — both truncate
   silently past 255 bytes; if a payload can plausibly exceed that, that Cmd
   needs a different design (chunking, an interned-string table), not a
   bigger `Msg_Text`.
3. **Retaining Msg text in a model field:** call `msg_text_clone(v.field,
   alloc)`, always, with an allocator that outlives the current frame
   (`context.allocator`, not `frame_allocator(fa)`). Never call
   `msg_text_string` and store the result — it borrows and is only valid for
   the remainder of the expression that produced it (reading it into a
   `fmt.aprintf`/view call in the same statement is the intended, safe use).
4. **Do not call `free`/`delete` on anything reached through a `Msg` field
   inside `update`.** The loop owns the box and frees it automatically after
   `update` returns; a Msg's fields are borrowed for the duration of that one
   call only, same as `Msg_Text`'s own contract.
5. If a Cmd result legitimately needs more than 255 bytes of text or a
   variable-length collection, that is a signal for a new, deliberately
   designed carrier (interned strings, a bounded ring, pagination) — not a
   reason to reach for a bare `string`/`[]T` field and let `box()`'s panic
   be the first time anyone finds out.

### Known residual gaps (not blockers, recorded honestly)

- **Enforcement is a runtime `panic()`, not a compile error** — verified
  impossible on this toolchain (§2, Option B), not a missed opportunity.
  It fires the first time a bad type is actually boxed, which for a Cmd
  exercised by any test or a single manual run is effectively "on the next
  build+run," but is not a `odin build`-time error the way a real type
  system violation would be.
- **`msg_text_string` still permits the narrow borrow-and-retain mistake** if
  a user bypasses the intended `msg_text_clone` path and manually stores its
  result. This is visibly a different, differently-named call (grep-able,
  not the default/obvious path), unlike Option A's bare `m.err = v.reason`
  which looks identical whether it's safe or not — but it is not airtight;
  Odin has no borrow checker to make it so.
- **Shutdown-time drain leftovers.** If `run()`/`run_nbio()` tear down while
  messages still sit unprocessed in the mailbox (reachable only via an
  unusual shutdown ordering, not the steady-state per-message leak this
  document measures), those specific messages are never handed to `apply()`
  and so never `box_free`'d. `loop_nbio.odin`'s equivalent case (unflushed
  backlog) was fixed in this work (§3); `tea.odin`'s `run()` was not audited
  for the mailbox-buffer case specifically, since — unlike the loop_nbio
  case, found by this work's own testing — it was not observed to occur and
  is bounded by the mailbox's 256-slot capacity (a one-time, process-exit-
  reclaimed cost, not the unbounded-over-session-length class this document
  was scoped to fix). Worth a follow-up pass, not a blocker here.
- **`guard.odin`'s `Panic_Info.message` leak** (the 20B/165B leaks still
  visible in test output) is pre-existing, unrelated to Msg lifecycle, and
  out of this document's scope.
