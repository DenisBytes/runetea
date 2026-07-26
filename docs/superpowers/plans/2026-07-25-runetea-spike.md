# RuneTea T0 Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the RuneTea design end-to-end in ~900 LOC by running ports of Bubble Tea's `examples/simple` and `examples/http` in inline mode, breaking every load-bearing assumption before any code exists that would hurt to discard.

**Architecture:** A single-threaded `core:nbio` event loop owns the terminal and all rendering. The TTY fd is associated as an nbio handle; `Tick` becomes an nbio timeout op. Commands run on a bounded `core:thread` pool and post results into a buffered MPSC mailbox, waking the loop via `nbio.wake_up`. Messages are `any` boxed into a per-frame arena, freed wholesale each iteration. Crash safety is two-tier: `setjmp`/`longjmp` recovers panics and assertions; signal handlers restore the terminal for traps that cannot be resumed.

**Tech Stack:** Odin `dev-2026-07-nightly:819fdc7`; `core:nbio`, `core:sync`, `core:thread`, `core:sys/posix`, `core:mem/virtual`, `core:c/libc`, `core:testing`. No third-party dependencies.

## Global Constraints

- **Odin version:** `dev-2026-07-nightly:819fdc7`. Verify with `odin version` before starting.
- **Platform for the spike:** Linux only. Darwin/BSD are v1.0 targets but are not validated here (spec §13.4).
- **LOC ceiling:** ~900 non-test LOC. Exceeding it by >30% means scope has crept — stop and reassess.
- **Time box:** 2 weeks. Kill criteria in Task 11 are binding.
- **Never use an unbuffered `chan.Chan`.** Measured: 371 of 1000 messages lost with 4 producers. Spec §6.
- **Never write `posix.CControl_Flags{.CS8}`.** It silently equals `{.CS7}` (both `0x20`). Use `transmute(posix.CControl_Flags)posix.tcflag_t(posix.CS8)`. Spec §2.
- **Never use `grapheme.Iterator`'s `text` field.** It slices by display-width-as-byte-count and returns invalid UTF-8. Derive spans from consecutive `byte_index`. Spec §2. (Not exercised in the spike, but do not introduce it.)
- **`Msg` is spelled `any` literally** in every signature. `Msg :: any` is rejected by the compiler (`'any' cannot be aliased`). Spec §5.
- **Do not import `core:debug/trace`.** It fails to link (`cannot find -lstdc++exp`). Spec §8.
- **Tests:** `odin test . -define:ODIN_TEST_THREADS=1` from the package directory. Threads pinned to 1 so concurrency tests are deterministic.
- **Commit after every task.** The repo is already initialised at `/home/denisbytes/dev/runetea`.

---

## File Structure

```
runetea/
  mailbox.odin      MPSC mailbox: the primitive everything else sits on
  arena.odin        per-frame arena + `box` helper for Msg payloads
  cmd.odin          Cmd fat pointer, thread pool dispatch
  term.odin         termios raw mode, Term_State singleton, winsize
  guard.odin        two-tier crash safety
  signals.odin      sigwait thread -> mailbox
  loop.odin         nbio event loop, tty reader, Input_Source seam
  input.odin        minimal key decoder (enough for the two examples)
  render.odin       naive inline renderer (rewind + repaint)
  tea.odin          Program, run(), the Update/View cycle
  *_test.odin       one test file per unit above
examples/
  simple/main.odin  port of bubbletea examples/simple
  http/main.odin    port of bubbletea examples/http
tools/
  golden/           byte-stream capture harness
```

Each file has one responsibility and is independently testable without a terminal — that separation is what makes the renderer debuggable later (spec §10).

---

## Task 1: Scaffold and the MPSC mailbox

Everything sits on this primitive. Odin's unbuffered channel is corrupt under multiple producers, so the mailbox is hand-rolled and its correctness test is the first thing written.

**Files:**
- Create: `runetea/mailbox.odin`
- Test: `runetea/mailbox_test.odin`

**Interfaces:**
- Consumes: nothing.
- Produces: `Mailbox` struct; `mailbox_init(m: ^Mailbox, cap: int, allocator := context.allocator) -> mem.Allocator_Error`; `mailbox_destroy(m: ^Mailbox, allocator := context.allocator)`; `mailbox_send(m: ^Mailbox, msg: any) -> bool`; `mailbox_recv(m: ^Mailbox) -> (msg: any, ok: bool)`; `mailbox_try_recv(m: ^Mailbox) -> (msg: any, ok: bool)`; `mailbox_close(m: ^Mailbox)`.

- [ ] **Step 1: Write the failing test**

Create `runetea/mailbox_test.odin`:

```odin
package runetea

import "core:testing"
import "core:thread"
import "core:time"

N_PROD :: 4
PER    :: 250

Prod :: struct { m: ^Mailbox, vals: [PER]int }

@(test)
test_mailbox_no_loss_under_4_producers :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 4096), nil)
	defer mailbox_destroy(&m)

	prods := make([]Prod, N_PROD);        defer delete(prods)
	ts    := make([]^thread.Thread, N_PROD); defer delete(ts)

	for i in 0 ..< N_PROD {
		prods[i].m = &m
		for j in 0 ..< PER { prods[i].vals[j] = i * PER + j }
		th := thread.create(proc(th: ^thread.Thread) {
			p := cast(^Prod)th.data
			for j in 0 ..< PER { _ = mailbox_send(p.m, p.vals[j]) }
		})
		th.data = &prods[i]
		ts[i] = th
		thread.start(th)
	}

	seen := make(map[int]bool); defer delete(seen)
	for _ in 0 ..< N_PROD * PER {
		msg, ok := mailbox_recv(&m)
		if !ok { break }
		if v, is_int := msg.(int); is_int { seen[v] = true }
	}
	for th in ts { thread.join(th); thread.destroy(th) }

	testing.expectf(t, len(seen) == N_PROD * PER,
		"expected %d unique values, got %d (%d lost/duplicated)",
		N_PROD * PER, len(seen), N_PROD * PER - len(seen))
}

@(test)
test_mailbox_reports_full :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 2), nil)
	defer mailbox_destroy(&m)
	testing.expect(t, mailbox_send(&m, 1), "first send should succeed")
	testing.expect(t, mailbox_send(&m, 2), "second send should succeed")
	testing.expect(t, !mailbox_send(&m, 3), "third send should report full")
}

// Regression test for the semaphore-desync defect described on
// mailbox_try_recv. Without the credit consumption there, the recv below
// returns (nil, false) almost immediately instead of blocking for the
// delayed send.
@(test)
test_mailbox_try_recv_keeps_semaphore_in_sync :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 8), nil)
	defer mailbox_destroy(&m)

	testing.expect(t, mailbox_send(&m, 111), "send should succeed")
	v1, ok1 := mailbox_try_recv(&m)
	testing.expect(t, ok1, "try_recv should drain the message")
	testing.expect_value(t, v1.(int), 111)

	// Mailbox is now empty but OPEN. A delayed send must be what wakes recv.
	sender := thread.create(proc(th: ^thread.Thread) {
		time.sleep(50 * time.Millisecond)
		_ = mailbox_send(cast(^Mailbox)th.data, 222)
	})
	sender.data = &m
	thread.start(sender)
	defer { thread.join(sender); thread.destroy(sender) }

	v2, ok2 := mailbox_recv(&m)
	testing.expect(t, ok2, "recv must NOT report closure on an open mailbox")
	testing.expect_value(t, v2.(int), 222)
}

@(test)
test_mailbox_close_wakes_receiver :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 4), nil)
	defer mailbox_destroy(&m)
	mailbox_close(&m)
	_, ok := mailbox_recv(&m)
	testing.expect(t, !ok, "recv on a closed, drained mailbox should report !ok")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: FAIL — `Undeclared name: Mailbox`.

- [ ] **Step 3: Write minimal implementation**

Create `runetea/mailbox.odin`:

```odin
package runetea

import "core:mem"
import "core:sync"

// Buffered MPSC mailbox.
//
// NEVER replace this with an unbuffered core:sync/chan. That implementation has
// a single `unbuffered_data` slot and releases the mutex inside `sync.wait`, so
// a second sender overwrites the slot before the receiver copies it. Measured:
// 4 producers x 250 unique values -> 629 received, 371 lost.
Mailbox :: struct {
	buf:    []any,
	head:   int,        // consumer index
	tail:   int,        // producer index
	len:    int,
	mutex:  sync.Mutex,
	items:  sync.Sema,  // counts queued messages
	closed: bool,
}

mailbox_init :: proc(m: ^Mailbox, cap: int, allocator := context.allocator) -> mem.Allocator_Error {
	assert(cap > 0, "mailbox capacity must be positive")
	m.buf = make([]any, cap, allocator) or_return
	return nil
}

// PRECONDITION: every producer that might call mailbox_send must be stopped
// and joined, and no thread may be inside mailbox_recv / mailbox_try_recv.
// Destroying a mailbox a producer is still sending into is a use-after-free;
// zeroing a mutex out from under a thread that holds it is undefined behavior.
// Task 5's pool and Task 7's signal thread are exactly those producers.
mailbox_destroy :: proc(m: ^Mailbox, allocator := context.allocator) {
	assert(sync.mutex_try_lock(&m.mutex),
		"mailbox_destroy: called while another thread holds the mailbox lock " +
		"(a send/recv is in flight) -- stop and join all producers first")
	sync.mutex_unlock(&m.mutex)
	delete(m.buf, allocator)
	m^ = {}
}

// Returns false if the mailbox is closed or full. Safe from any thread.
mailbox_send :: proc(m: ^Mailbox, msg: any) -> bool {
	sync.mutex_lock(&m.mutex)
	if m.closed || m.len == len(m.buf) {
		sync.mutex_unlock(&m.mutex)
		return false
	}
	m.buf[m.tail] = msg
	m.tail = (m.tail + 1) % len(m.buf)
	m.len += 1
	// Post while STILL HOLDING the lock. Any thread that later takes the mutex
	// and sees this m.len also sees the credit already in the semaphore, which
	// is what lets mailbox_try_recv's sema_wait be provably non-blocking.
	// Posting after the unlock reopens a window where try_recv pops a message
	// whose credit has not landed yet, and then blocks.
	sync.sema_post(&m.items)
	sync.mutex_unlock(&m.mutex)
	return true
}

// Must be called with m.mutex held. Does NOT touch the semaphore -- callers
// keep m.items in lockstep with the buffer.
@(private)
mailbox_pop :: proc(m: ^Mailbox) -> (msg: any, ok: bool) {
	if m.len == 0 { return nil, false }
	msg = m.buf[m.head]
	m.head = (m.head + 1) % len(m.buf)
	m.len -= 1
	return msg, true
}

// Blocks until a message is available. ok=false once closed and drained.
mailbox_recv :: proc(m: ^Mailbox) -> (msg: any, ok: bool) {
	sync.sema_wait(&m.items)
	sync.mutex_lock(&m.mutex)
	defer sync.mutex_unlock(&m.mutex)
	return mailbox_pop(m)
}

// Non-blocking. Used by the event loop's drain fast-path.
//
// CRITICAL: this MUST consume a semaphore credit when it dequeues. An earlier
// version popped without touching m.items, leaving a stale credit behind; a
// later mailbox_recv would then wake on that credit, find len == 0, and report
// ok=false -- "closed" on a mailbox that is open and still working. That is a
// silent event-loop exit, and it reproduces with no threading at all:
//   init -> send(x) -> try_recv() -> recv() returns (nil, false)
mailbox_try_recv :: proc(m: ^Mailbox) -> (msg: any, ok: bool) {
	sync.mutex_lock(&m.mutex)
	msg, ok = mailbox_pop(m)
	sync.mutex_unlock(&m.mutex)
	if ok { sync.sema_wait(&m.items) }   // cannot block; see mailbox_send
	return
}

mailbox_close :: proc(m: ^Mailbox) {
	sync.mutex_lock(&m.mutex)
	m.closed = true
	sync.mutex_unlock(&m.mutex)
	sync.sema_post(&m.items)  // wake the consumer so it observes closure
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: PASS, 4 tests. Reported memory leaks from `thread_unix.odin:_create()` mean a `thread.destroy` is missing — the test above already calls it.

- [ ] **Step 5: Run under the thread sanitizer**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1 -sanitize:thread`
Expected: PASS with no data-race reports. If races appear, the mailbox is wrong — fix before proceeding. Everything else in the spike depends on this.

- [ ] **Step 6: Commit**

```bash
git add runetea/mailbox.odin runetea/mailbox_test.odin
git commit -m "feat(mailbox): buffered MPSC mailbox with no-loss test

Odin's unbuffered chan loses messages under multiple producers
(measured 629/1000). Hand-rolled over sync.Sema + ring + mutex."
```

---

## Task 2: Terminal raw mode and the Term_State singleton

The singleton must exist before crash safety, because signal handlers take no arguments and need process-global access to the saved termios.

**Files:**
- Create: `runetea/term.odin`
- Test: `runetea/term_test.odin`

**Interfaces:**
- Consumes: nothing.
- Produces: `Term_State` struct; global `g_term: Term_State`; `term_enter_raw(fd: posix.FD) -> bool`; `term_restore()`; `term_restore_c()` (`proc "c"`, signal-safe); `term_size(fd: posix.FD) -> (w: int, h: int, ok: bool)`; `Winsize` struct.

- [ ] **Step 1: Write the failing test**

Create `runetea/term_test.odin`:

```odin
package runetea

import "core:testing"
import "core:sys/posix"

// CS8 is 0x30 (multi-bit). posix.CControl_Flags is defined as log2(CS8), which
// truncates to bit 5 -- exactly CS7 (0x20). This test pins the workaround so a
// future refactor cannot silently reintroduce a 7-bit tty.
@(test)
test_cs8_bit_set_is_a_trap :: proc(t: ^testing.T) {
	via_bit_set := transmute(posix.tcflag_t)posix.CControl_Flags{.CS8}
	via_cs7     := transmute(posix.tcflag_t)posix.CControl_Flags{.CS7}
	testing.expect(t, via_bit_set == via_cs7,
		"if this now differs, Odin fixed the bug -- simplify term_enter_raw")

	correct := posix.tcflag_t(posix.CS8)
	testing.expect(t, correct != via_bit_set,
		"the transmute workaround must differ from the bit_set spelling")
}

@(test)
test_term_size_reports_failure_on_non_tty :: proc(t: ^testing.T) {
	// fd 0 under the test runner is not guaranteed to be a tty; the contract is
	// that term_size never panics and reports ok=false when it cannot measure.
	_, _, ok := term_size(posix.FD(-1))
	testing.expect(t, !ok, "term_size on an invalid fd must report ok=false")
}

@(test)
test_restore_is_noop_when_not_raw :: proc(t: ^testing.T) {
	g_term = {}
	term_restore()  // must not crash or touch any fd
	testing.expect(t, !g_term.raw_active, "restore should leave raw_active false")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: FAIL — `Undeclared name: term_size`.

- [ ] **Step 3: Write minimal implementation**

Create `runetea/term.odin`:

```odin
package runetea

import "core:sys/linux"
import "core:sys/posix"

Winsize :: struct {
	ws_row, ws_col, ws_xpixel, ws_ypixel: u16,
}

Term_State :: struct {
	fd:         posix.FD,
	saved:      posix.termios,
	raw_active: bool,
}

// Process-global: signal handlers take no arguments and must reach this.
g_term: Term_State

term_enter_raw :: proc(fd: posix.FD) -> bool {
	if posix.tcgetattr(fd, &g_term.saved) != .OK { return false }

	// ORDERING INVARIANT: raw_active must be true for the ENTIRE interval in
	// which the tty could possibly be raw, and g_term.saved must be valid
	// before raw_active is ever true. saved is valid as of the line above, so
	// flip raw_active on NOW, before tcsetattr touches the terminal. A crash
	// anywhere from here through tcsetattr then sees raw_active == true and
	// restores g_term.saved -- correct whether the tty is still cooked or has
	// just become raw. Setting raw_active only after tcsetattr succeeds leaves
	// a window where the tty is raw but term_restore_c() no-ops, stranding the
	// terminal with no recovery.
	g_term.fd = fd
	g_term.raw_active = true

	raw := g_term.saved

	raw.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
	raw.c_oflag -= {.OPOST}
	raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}

	// Do NOT write CControl_Flags{.CS8}: the enum member is log2(CS8) and CS8
	// (0x30) is multi-bit, so it truncates to bit 5 == CS7 (0x20), silently
	// running the tty at 7-bit character size.
	raw.c_cflag -= transmute(posix.CControl_Flags)posix.tcflag_t(posix.CSIZE)
	raw.c_cflag += transmute(posix.CControl_Flags)posix.tcflag_t(posix.CS8)

	raw.c_cc[.VMIN]  = 1
	raw.c_cc[.VTIME] = 0

	if posix.tcsetattr(fd, .TCSAFLUSH, &raw) != .OK {
		// Roll back: the tty was never actually put into raw mode.
		g_term.raw_active = false
		return false
	}
	return true
}

term_restore :: proc() {
	term_restore_c()
}

// Async-signal-safe: tcsetattr and write(2) only. No allocation, no locks.
term_restore_c :: proc "c" () {
	if !g_term.raw_active { return }
	posix.tcsetattr(g_term.fd, .TCSAFLUSH, &g_term.saved)
	// leave alt screen, show cursor
	seq := "\e[?1049l\e[?25h"
	posix.write(g_term.fd, raw_data(seq), len(seq))
	g_term.raw_active = false
}

// core:sys/posix exposes neither ioctl nor a winsize struct; only the per-OS
// TIOCGWINSZ constant exists. Go through the raw Linux syscall layer.
//
// linux.ioctl returns uintptr, NOT an Errno -- errors are negative returns.
term_size :: proc(fd: posix.FD) -> (w: int, h: int, ok: bool) {
	ws := Winsize{}
	res := linux.ioctl(linux.Fd(fd), linux.TIOCGWINSZ, uintptr(rawptr(&ws)))
	if int(res) < 0 { return 0, 0, false }
	if ws.ws_col == 0 || ws.ws_row == 0 { return 0, 0, false }
	return int(ws.ws_col), int(ws.ws_row), true
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: PASS, 7 tests total.

- [ ] **Step 5: Verify raw mode against a real tty by hand**

Create `tools/rawcheck/main.odin`:

```odin
package main

import "core:fmt"
import "core:os"
import "core:sys/posix"
import rt "../../runetea"

main :: proc() {
	fd := posix.FD(os.fd(os.stdin))
	if !rt.term_enter_raw(fd) { fmt.eprintln("not a tty"); os.exit(1) }
	defer rt.term_restore()

	w, h, ok := rt.term_size(fd)
	fmt.printf("size: %dx%d ok=%v\r\n", w, h, ok)
	fmt.print("press keys, 'q' quits\r\n")

	buf: [64]u8
	for {
		n, err := os.read(os.stdin, buf[:])
		if err != nil || n <= 0 { break }
		fmt.printf("read %d bytes: %v\r\n", n, buf[:n])
		if buf[0] == 'q' { break }
	}
}
```

Run: `odin run tools/rawcheck`
Expected: keys echo as raw byte values with no line buffering; arrow keys show `[27 91 65]`-style sequences; `q` exits and the shell is left usable. **If the shell is wedged after exit, stop and fix before Task 3.**

- [ ] **Step 6: Commit**

```bash
git add runetea/term.odin runetea/term_test.odin tools/rawcheck/main.odin
git commit -m "feat(term): raw mode, Term_State singleton, winsize

Includes the CS8 workaround: posix.CControl_Flags{.CS8} silently
equals {.CS7} because the enum is log2 of a multi-bit constant."
```

---

## Task 3: Two-tier crash safety

Tier 1 recovers panics, `assert`, and failed type assertions via `setjmp`/`longjmp`, letting `run()` return an error. Tier 2 handles what cannot be resumed — bounds traps and nil derefs — by restoring the terminal and dying honestly. **Verified:** bounds violations do *not* reach `assertion_failure_proc`; only the signal handler sees them.

**Files:**
- Create: `runetea/guard.odin`
- Test: `runetea/guard_test.odin`

**Interfaces:**
- Consumes: `term_restore_c` from Task 2.
- Produces: `Panic_Info :: struct { message: string, recovered: bool }`; `guarded(body: proc(ud: rawptr), ud: rawptr, allocator := context.allocator) -> Panic_Info`; `install_crash_handlers()`.

- [ ] **Step 1: Write the failing test**

Create `runetea/guard_test.odin`:

```odin
package runetea

import "core:testing"

@(test)
test_guard_recovers_panic :: proc(t: ^testing.T) {
	info := guarded(proc(ud: rawptr) { panic("boom in user update") }, nil)
	testing.expect(t, info.recovered, "expected recovery from panic")
	testing.expect_value(t, info.message, "boom in user update")
	delete(info.message)
}

@(test)
test_guard_recovers_bad_type_assertion :: proc(t: ^testing.T) {
	info := guarded(proc(ud: rawptr) {
		x: any = int(3)
		_ = x.(f64)   // wrong type -> runtime assertion
	}, nil)
	testing.expect(t, info.recovered, "expected recovery from bad type assertion")
	delete(info.message)
}

@(test)
test_guard_returns_normally_when_no_panic :: proc(t: ^testing.T) {
	hit := false
	info := guarded(proc(ud: rawptr) { (cast(^bool)ud)^ = true }, &hit)
	testing.expect(t, !info.recovered, "should not report recovery")
	testing.expect(t, hit, "body should have run")
}

@(test)
test_guard_restores_assertion_proc :: proc(t: ^testing.T) {
	before := context.assertion_failure_proc
	info := guarded(proc(ud: rawptr) { panic("x") }, nil)
	delete(info.message)
	testing.expect(t, context.assertion_failure_proc == before,
		"guarded must restore the previous assertion_failure_proc")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: FAIL — `Undeclared name: guarded`.

- [ ] **Step 3: Write minimal implementation**

Create `runetea/guard.odin`:

```odin
package runetea

import "base:runtime"
import "core:c/libc"
import "core:mem"
import "core:strings"
import "core:sys/posix"

Panic_Info :: struct {
	message:   string,  // caller owns; delete when done
	recovered: bool,
}

// THREAD-LOCAL, not file-global. Task 5's pool runs user Cmd code and Task 7's
// signal thread both call into this; a shared jmp_buf would let one thread's
// setjmp clobber another's jump target, and a later panic would longjmp into a
// dead stack frame.
@(thread_local, private="file") g_guard:       libc.jmp_buf
@(thread_local, private="file") g_panic_msg:   string
@(thread_local, private="file") g_panic_alloc: mem.Allocator
// Debug-only re-entrancy guard. CAVEAT: compiled out by -disable-assert, which
// silently restores the nesting-corruption bug. Do not ship release builds of
// a TUI with assertions disabled unless you have re-checked this.
@(thread_local, private="file") g_armed: bool

@(private="file")
guard_assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	// MUST clone before jumping: `message` may live in a frame longjmp discards.
	g_panic_msg = strings.clone(message, g_panic_alloc)
	libc.longjmp(&g_guard, 1)
}

// Runs `body`, recovering panics, asserts, and failed type assertions.
//
// longjmp does NOT unwind and does NOT run `defer`. On recovery the caller must
// reset any state `body` owned -- free the frame arena, release held mutexes.
// The per-frame arena (Task 4) makes the memory half of that free.
//
// Bounds violations and nil derefs never reach here; install_crash_handlers
// covers those and they are NOT recoverable.
// NOT nestable on a single thread: the inner setjmp would clobber this
// thread's jump target. The assert below fails loudly instead of corrupting.
guarded :: proc(body: proc(ud: rawptr), ud: rawptr, allocator := context.allocator) -> Panic_Info {
	assert(!g_armed, "guarded() does not support nesting on the same thread")
	g_armed = true
	defer g_armed = false

	prev_proc  := context.assertion_failure_proc
	g_panic_alloc = allocator
	context.assertion_failure_proc = guard_assertion_failure
	defer context.assertion_failure_proc = prev_proc

	if libc.setjmp(&g_guard) == 0 {
		body(ud)
		return Panic_Info{recovered = false}
	}
	return Panic_Info{message = g_panic_msg, recovered = true}
}

@(private="file")
crash_handler :: proc "c" (sig: posix.Signal) {
	term_restore_c()
	// Re-raise with the default disposition so the exit status is honest and
	// core dumps still happen.
	act := posix.sigaction_t{}
	act.sa_handler = auto_cast posix.SIG_DFL
	posix.sigaction(sig, &act, nil)
	posix.raise(sig)
}

// Tier 2. Bounds-check failure is the likeliest TUI crash -- indexing a cell
// buffer during render -- and it traps rather than calling assertion_failure_proc,
// so this is the primary net, not a backstop.
// Statically allocated: a stack-overflow SIGSEGV cannot afford a heap
// allocation at handler time.
@(private="file") g_altstack_buf: [posix.SIGSTKSZ]byte

install_crash_handlers :: proc() {
	// Without an alternate stack, a stack-exhaustion SIGSEGV -- the commonest
	// real cause -- is delivered on the exhausted stack and crash_handler
	// re-faults before term_restore_c() finishes, defeating Tier 2 exactly
	// when it matters. CAVEAT: sigaltstack is PER-THREAD. This installs one on
	// the calling thread only; Task 5's pool threads and Task 7's signal
	// thread get no altstack unless they call this themselves.
	altstack := posix.stack_t{
		ss_sp   = raw_data(g_altstack_buf[:]),
		ss_size = len(g_altstack_buf),
	}
	posix.sigaltstack(&altstack, nil)

	// SIGTERM is included: it is the default signal from kill(1), systemd and
	// `docker stop` -- likelier than SIGBUS/SIGTRAP -- and mid-raw-mode it
	// would otherwise strand the shell.
	sigs := []posix.Signal{
		.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE, .SIGABRT, .SIGTRAP, .SIGHUP, .SIGQUIT, .SIGTERM,
	}
	for sig in sigs {
		act := posix.sigaction_t{}
		act.sa_handler = crash_handler
		act.sa_flags = {.ONSTACK}
		posix.sigaction(sig, &act, nil)
	}
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: PASS, 11 tests total.

- [ ] **Step 5: Verify Tier 2 restores the terminal on an unrecoverable trap**

Create `tools/crashcheck/main.odin`:

```odin
package main

import "core:fmt"
import "core:os"
import "core:sys/posix"
import rt "../../runetea"

main :: proc() {
	fd := posix.FD(os.fd(os.stdin))
	if !rt.term_enter_raw(fd) { fmt.eprintln("not a tty"); os.exit(1) }
	rt.install_crash_handlers()

	fmt.print("entering raw mode + hiding cursor, then indexing out of range\r\n")
	seq := "\e[?25l"
	posix.write(fd, raw_data(seq), len(seq))

	buf := make([]int, 4)
	i := 9
	buf[i] = 1          // bounds violation -> trap -> handler -> restore
	fmt.print("NOT REACHED\r\n")
}
```

Run: `odin run tools/crashcheck; echo "exit=$?"; stty -a | head -1`
Expected: the runtime prints its out-of-range error, the process dies with a non-zero status, **and the shell is left usable with a visible cursor**. Confirm `stty -a` shows `echo` and `icanon` restored. If the shell is wedged, Tier 2 is broken — fix before proceeding.

- [ ] **Step 6: Commit**

```bash
git add runetea/guard.odin runetea/guard_test.odin tools/crashcheck/main.odin
git commit -m "feat(guard): two-tier crash safety

Tier 1: setjmp/longjmp in assertion_failure_proc recovers panic,
assert, and bad type assertions -- run() can return an error.
Tier 2: signal handlers restore the terminal for bounds traps and
nil derefs, which never reach assertion_failure_proc."
```

---

## Task 4: Per-frame arena and Msg boxing

`any` is a borrowed 16-byte `{data, id}`. Returning one that points at a local silently yields garbage — it compiles clean, with no warning, even under `-vet`. The arena makes the lifetime question disappear.

**Files:**
- Create: `runetea/arena.odin`
- Test: `runetea/arena_test.odin`

**Interfaces:**
- Consumes: nothing.
- Produces: `Frame_Arena` struct; `frame_arena_init(fa: ^Frame_Arena) -> mem.Allocator_Error`; `frame_arena_destroy(fa: ^Frame_Arena)`; `frame_allocator(fa: ^Frame_Arena) -> mem.Allocator`; `frame_reset(fa: ^Frame_Arena)`; `box(v: $V, alloc: mem.Allocator) -> any`.

- [ ] **Step 1: Write the failing test**

Create `runetea/arena_test.odin`:

```odin
package runetea

// Odin imports are FILE-scoped, not package-scoped: arena.odin's import of
// core:mem does not cover this file.
import "core:mem"
import "core:testing"

Boxed_A :: struct { n: int }
Boxed_B :: struct { s: string }

@(test)
test_box_survives_the_returning_frame :: proc(t: ^testing.T) {
	fa: Frame_Arena
	testing.expect_value(t, frame_arena_init(&fa), nil)
	defer frame_arena_destroy(&fa)

	// A proc that boxes and returns -- the naive `return v` version yields garbage.
	produce :: proc(alloc: mem.Allocator, n: int) -> any {
		return box(Boxed_A{n = n}, alloc)
	}

	msg := produce(frame_allocator(&fa), 42)
	v, ok := msg.(Boxed_A)
	testing.expect(t, ok, "boxed value must retain its concrete type")
	testing.expect_value(t, v.n, 42)
}

@(test)
test_box_type_switch_discriminates :: proc(t: ^testing.T) {
	fa: Frame_Arena
	testing.expect_value(t, frame_arena_init(&fa), nil)
	defer frame_arena_destroy(&fa)
	al := frame_allocator(&fa)

	msgs := []any{ box(Boxed_A{7}, al), box(Boxed_B{"hi"}, al), box(int(3), al) }
	a_count, b_count, i_count := 0, 0, 0
	for m in msgs {
		switch v in m {
		case Boxed_A: a_count += 1; testing.expect_value(t, v.n, 7)
		case Boxed_B: b_count += 1; testing.expect_value(t, v.s, "hi")
		case int:     i_count += 1; testing.expect_value(t, v, 3)
		}
	}
	testing.expect_value(t, a_count, 1)
	testing.expect_value(t, b_count, 1)
	testing.expect_value(t, i_count, 1)
}

@(test)
test_frame_reset_reaches_steady_state :: proc(t: ^testing.T) {
	fa: Frame_Arena
	testing.expect_value(t, frame_arena_init(&fa), nil)
	defer frame_arena_destroy(&fa)

	first_total: uint
	for frame in 0 ..< 200 {
		al := frame_allocator(&fa)
		for i in 0 ..< 50 { _ = box(Boxed_A{i}, al) }
		if frame == 1 { first_total = fa.arena.total_used }
		if frame == 199 {
			testing.expectf(t, fa.arena.total_used == first_total,
				"arena must reach steady state: frame 1 used %d, frame 199 used %d",
				first_total, fa.arena.total_used)
		}
		frame_reset(&fa)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: FAIL — `Undeclared name: Frame_Arena`.

- [ ] **Step 3: Write minimal implementation**

Create `runetea/arena.odin`:

```odin
package runetea

import "core:mem"
import "core:mem/virtual"

// One arena per event-loop iteration. Every Msg payload and every View string
// is allocated here and released wholesale by frame_reset.
//
// LIFETIME CONTRACT -- read before using frame_allocator():
// frame_reset runs once per iteration, on the main thread, and unconditionally
// reclaims everything allocated from this arena since the last reset, including
// on the crash-recovery path where longjmp has skipped every `defer`. A
// frame_allocator(fa) allocation is therefore good only for the remainder of
// the iteration that made it.
//
// Anything crossing a thread boundary, or that may still be queued in the
// mailbox when the next frame_reset fires, MUST be boxed with
// context.allocator -- never frame_allocator(fa). That covers Task 5's worker
// pool and Task 7's signal-watcher thread.
//
// Note virtual.Arena guards its own bookkeeping with an internal mutex, so
// concurrent box() calls will NOT corrupt it. That makes the naive
// "is it thread-safe?" check pass while this lifetime hazard remains -- a
// stale any.data pointing at reclaimed memory, with any.id still claiming the
// old type. Type confusion, not a torn counter.
//
// This also serves the crash path: longjmp does not run `defer`, so after a
// recovered panic the loop calls frame_reset to reclaim everything the failed
// iteration allocated.
Frame_Arena :: struct {
	arena: virtual.Arena,
}

frame_arena_init :: proc(fa: ^Frame_Arena) -> mem.Allocator_Error {
	return virtual.arena_init_growing(&fa.arena)
}

frame_arena_destroy :: proc(fa: ^Frame_Arena) {
	virtual.arena_destroy(&fa.arena)
}

frame_allocator :: proc(fa: ^Frame_Arena) -> mem.Allocator {
	return virtual.arena_allocator(&fa.arena)
}

frame_reset :: proc(fa: ^Frame_Arena) {
	virtual.arena_free_all(&fa.arena)
}

// Boxes `v` into stable storage and returns an `any` referring to it.
//
// `any` is a BORROWED {data: rawptr, id: typeid}. `return v` from a proc yields
// a pointer into the dead frame -- it compiles clean and produces garbage.
//
// `return p^` is correct and `return p` is not: p is ^V, which converts to an
// `any` whose typeid is ^V and therefore never matches `case V`.
box :: proc(v: $V, alloc: mem.Allocator) -> any {
	p, err := new(V, alloc)
	if err != nil { return nil }
	p^ = v
	return p^
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: PASS, 14 tests total. If `test_frame_reset_reaches_steady_state` fails, the arena is growing without bound — check that `frame_reset` is called every iteration.

- [ ] **Step 5: Confirm the type switch works across package boundaries**

This is the property the whole `Msg` design rests on: user code in *another package* must be able to define its own message type and have it match. Create `tools/msgcheck/main.odin`:

```odin
package main

import "core:fmt"
import rt "../../runetea"

// A message type the library has never heard of.
User_Tick :: struct { n: int }

main :: proc() {
	fa: rt.Frame_Arena
	if err := rt.frame_arena_init(&fa); err != nil { fmt.eprintln(err); return }
	defer rt.frame_arena_destroy(&fa)

	msg := rt.box(User_Tick{n = 99}, rt.frame_allocator(&fa))
	switch v in msg {
	case User_Tick: fmt.println("matched user-defined type, n =", v.n)
	case:           fmt.println("FAILED: fell through to default")
	}
}
```

Run: `odin run tools/msgcheck`
Expected: `matched user-defined type, n = 99`. **If this falls through, the entire Msg design is invalid — stop and reassess.**

- [ ] **Step 6: Commit**

```bash
git add runetea/arena.odin runetea/arena_test.odin tools/msgcheck/main.odin
git commit -m "feat(arena): per-frame arena and Msg boxing

any is a borrowed 16-byte {data,id}; returning one that points at a
local yields garbage silently. box() allocates into the frame arena,
freed wholesale each iteration."
```

---

## Task 5: Cmd fat pointer and thread pool dispatch

Odin has no closures — `return proc() -> int { return n }` fails with `Undeclared name: n`. `Cmd` becomes an explicit `{procedure, env, allocator}` triple. This is the largest permanent ergonomic regression in the port; Task 11 measures it.

**Files:**
- Create: `runetea/cmd.odin`
- Test: `runetea/cmd_test.odin`

**Interfaces:**
- Consumes: `Mailbox` (Task 1), `box`/`frame_allocator` (Task 4).
- Produces: `Cmd` struct (with a `detached` field); `cmd_from(fn: proc(env: rawptr) -> any, env: $E, alloc: mem.Allocator, detached := false) -> Cmd`; `cmd_nil() -> Cmd`; `cmd_is_nil(c: Cmd) -> bool`; `Dispatcher` struct; `dispatcher_init(d: ^Dispatcher, m: ^Mailbox, workers: int)`; `dispatcher_destroy(d: ^Dispatcher)`; `dispatch(d: ^Dispatcher, c: Cmd)`.

- [ ] **Step 1: Write the failing test**

Create `runetea/cmd_test.odin`:

```odin
package runetea

import "core:testing"
import "core:time"

Fetch_Env    :: struct { url: string, delay: time.Duration }
Fetch_Result :: struct { url: string, status: int }

fetch_run :: proc(env: rawptr) -> any {
	e := cast(^Fetch_Env)env
	time.sleep(e.delay)
	return box(Fetch_Result{url = e.url, status = 200}, context.allocator)
}

@(test)
test_cmd_carries_env_without_closures :: proc(t: ^testing.T) {
	c := cmd_from(fetch_run, Fetch_Env{url = "https://example.com", delay = 0}, context.allocator)
	testing.expect(t, !cmd_is_nil(c), "cmd should be populated")

	msg := c.procedure(c.env)
	r, ok := msg.(Fetch_Result)
	testing.expect(t, ok, "expected a Fetch_Result")
	testing.expect_value(t, r.url, "https://example.com")
	testing.expect_value(t, r.status, 200)
	free(c.env, c.allocator)
	free_all(context.allocator)
}

@(test)
test_dispatch_delivers_results_to_mailbox :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 64), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 4)
	defer dispatcher_destroy(&d)

	urls := []string{"a", "b", "c", "d", "e"}
	for u in urls {
		dispatch(&d, cmd_from(fetch_run, Fetch_Env{url = u}, context.allocator))
	}

	seen := make(map[string]bool); defer delete(seen)
	for _ in 0 ..< len(urls) {
		msg, ok := mailbox_recv(&m)
		testing.expect(t, ok, "expected a result")
		if r, is := msg.(Fetch_Result); is { seen[r.url] = true }
	}
	testing.expect_value(t, len(seen), len(urls))
}

@(test)
test_cmd_nil_is_detectable :: proc(t: ^testing.T) {
	testing.expect(t, cmd_is_nil(cmd_nil()), "cmd_nil must be reported as nil")
}

// A coordinator Cmd waits on children it dispatches. On a fixed pool sized N,
// N such coordinators occupy every worker and their children never get one --
// deadlock. Detached Cmds bypass the pool, which is the elastic-overflow path.
// This test pins that: more coordinators than workers must still complete.
Coord_Env :: struct { d: ^Dispatcher, inner: ^Mailbox }

coord_run :: proc(env: rawptr) -> any {
	e := cast(^Coord_Env)env
	// A child unit of work, run inline here to keep the test deterministic;
	// the point under test is that the coordinator itself is not pool-bound.
	return box(Fetch_Result{url = "coord", status = 1}, context.allocator)
}

@(test)
test_detached_cmds_exceed_pool_width_without_deadlock :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 64), nil)
	defer mailbox_destroy(&m)

	d: Dispatcher
	dispatcher_init(&d, &m, 2)      // deliberately narrower than the load
	defer dispatcher_destroy(&d)

	COORDS :: 8                      // 4x the pool width
	for _ in 0 ..< COORDS {
		dispatch(&d, cmd_from(coord_run, Coord_Env{d = &d, inner = &m}, context.allocator, detached = true))
	}

	got := 0
	for _ in 0 ..< COORDS {
		msg, ok := mailbox_recv(&m)
		if !ok { break }
		if _, is := msg.(Fetch_Result); is { got += 1 }
	}
	testing.expect_value(t, got, COORDS)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: FAIL — `Undeclared name: cmd_from`.

- [ ] **Step 3: Write minimal implementation**

Create `runetea/cmd.odin`:

```odin
package runetea

import "core:mem"
import "core:sync"
import "core:thread"

// Go's `type Cmd func() Msg` is a closure. Odin has no closures at all, so the
// captured environment becomes explicit. This is the port's largest permanent
// ergonomic cost and it touches every user program.
Cmd :: struct {
	procedure: proc(env: rawptr) -> any,
	env:       rawptr,
	allocator: mem.Allocator,   // frees env after procedure returns
	detached:  bool,            // bypass the pool -- see dispatch
}

cmd_nil :: proc() -> Cmd { return Cmd{} }

cmd_is_nil :: proc(c: Cmd) -> bool { return c.procedure == nil }

// Heap-clones `env` so the Cmd can outlive the caller's frame.
//
// Set detached=true for a Cmd that itself dispatches and waits on other Cmds.
// Such coordinators must not occupy a pool worker: N coordinators on an N-wide
// pool leaves no worker for their children, which deadlocks. Detached is the
// deliberate equivalent of Go's leaked-goroutine-per-Cmd, used rarely.
cmd_from :: proc(fn: proc(env: rawptr) -> any, env: $E, alloc: mem.Allocator, detached := false) -> Cmd {
	p, err := new(E, alloc)
	if err != nil { return cmd_nil() }
	p^ = env
	return Cmd{procedure = fn, env = rawptr(p), allocator = alloc, detached = detached}
}

Dispatcher :: struct {
	pool:     thread.Pool,
	mailbox:  ^Mailbox,
	inflight: sync.Wait_Group,   // counts detached Cmds not yet finished
}

Task_Env :: struct {
	cmd:      Cmd,
	mailbox:  ^Mailbox,
	inflight: ^sync.Wait_Group,  // detached only; nil for pool tasks
}

dispatcher_init :: proc(d: ^Dispatcher, m: ^Mailbox, workers: int) {
	d.mailbox = m
	thread.pool_init(&d.pool, context.allocator, max(workers, 1))
	thread.pool_start(&d.pool)
}

// pool_finish/pool_destroy genuinely join every pool worker. But a detached
// Cmd runs on a self_cleanup thread that core:thread explicitly FORBIDS
// joining, and is tracked nowhere else. Without inflight, a detached Cmd
// still running -- or mid mailbox_send -- when this returns lets the caller's
// next line (typically mailbox_destroy, per its own documented precondition)
// free the mailbox out from under a live producer: use-after-free on its
// buffer and mutex. Task 10's run() defers exactly that pair.
dispatcher_destroy :: proc(d: ^Dispatcher) {
	thread.pool_finish(&d.pool)
	thread.pool_destroy(&d.pool)
	sync.wait_group_wait(&d.inflight)
}

@(private="file")
run_cmd_task :: proc(task: thread.Task) {
	te := cast(^Task_Env)task.data
	if te.cmd.procedure != nil {
		msg := te.cmd.procedure(te.cmd.env)
		if te.cmd.env != nil { free(te.cmd.env, te.cmd.allocator) }
		if msg != nil { _ = mailbox_send(te.mailbox, msg) }
	}
	// Freed per-task, not accumulated in the Dispatcher: a Dispatcher lives
	// for a whole TUI session, so retaining every completed Task_Env until
	// shutdown grows without bound.
	free(te)
}

@(private="file")
run_cmd_detached :: proc(data: rawptr) {
	te := cast(^Task_Env)data
	inflight := te.inflight        // copy before te is freed
	if te.cmd.procedure != nil {
		msg := te.cmd.procedure(te.cmd.env)
		if te.cmd.env != nil { free(te.cmd.env, te.cmd.allocator) }
		if msg != nil { _ = mailbox_send(te.mailbox, msg) }
	}
	free(te)
	// MUST be the last action: dispatcher_destroy treats this as proof the
	// Cmd is entirely done -- including its mailbox_send -- and unblocks a
	// caller that may destroy the mailbox on its very next line.
	sync.wait_group_done(inflight)
}

dispatch :: proc(d: ^Dispatcher, c: Cmd) {
	if cmd_is_nil(c) { return }

	if c.detached {
		// Elastic overflow: its own thread, self-cleaning, never pool-bound.
		//
		// wait_group_add MUST precede the spawn. The detached thread can run
		// to completion (including its wait_group_done) before this call even
		// returns; add-after-spawn races dispatcher_destroy into seeing a zero
		// count that was never incremented for this Cmd.
		sync.wait_group_add(&d.inflight, 1)
		te := new(Task_Env)
		te^ = Task_Env{cmd = c, mailbox = d.mailbox, inflight = &d.inflight}
		// init_context MUST be passed. Left at its nil default,
		// _select_context_for_thread (core/thread/thread.odin:534) hands the new
		// OS thread runtime.default_context() -- a DIFFERENT context.allocator
		// than the one that allocated te. Freeing te on the other side then
		// mismatches allocators and SIGSEGVs inside libc free(). The pool path
		// does not hit this because pool_do_work sets context.allocator =
		// task.allocator explicitly (thread_pool.odin:363).
		thread.create_and_start_with_data(rawptr(te), run_cmd_detached, init_context = context, self_cleanup = true)
		return
	}

	te := new(Task_Env)
	te^ = Task_Env{cmd = c, mailbox = d.mailbox}
	thread.pool_add_task(&d.pool, context.allocator, run_cmd_task, te)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: PASS, 18 tests total.

- [ ] **Step 5: Run under the thread sanitizer**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1 -sanitize:thread`
Expected: PASS with no data-race reports.

Note the pool is *fixed-size*. A Cmd that itself dispatches and waits on children will deadlock when all workers are occupied by waiting parents. The spike does not implement `batch`/`sequence`, so this cannot occur yet — but record it: spec §6 requires the elastic-overflow path before batching ships.

- [ ] **Step 6: Commit**

```bash
git add runetea/cmd.odin runetea/cmd_test.odin
git commit -m "feat(cmd): closure-free Cmd fat pointer + pool dispatch

Odin has no capturing closures, so Cmd is an explicit
{procedure, env, allocator} triple. Results land in the mailbox."
```

---

## Task 6: nbio event loop and the input source seam

The nbio loop *is* RuneTea's loop. The `Input_Source` indirection exists so the golden harness (Task 11) can drive a Program from a byte slice with no terminal, and so a `posix.poll` fallback can replace nbio wholesale if its kqueue path misbehaves on Darwin.

**Files:**
- Create: `runetea/loop.odin`
- Test: `runetea/loop_test.odin`

**Interfaces:**
- Consumes: `Mailbox` (Task 1).
- Produces: `Input_Source` vtable struct; `input_source_from_fd(fd: posix.FD) -> (Input_Source, bool)`; `input_source_from_bytes(data: []u8) -> Input_Source`; `input_read(src: ^Input_Source, buf: []u8) -> (n: int, ok: bool)`; `input_close(src: ^Input_Source)`.

- [ ] **Step 1: Write the failing test**

Create `runetea/loop_test.odin`:

```odin
package runetea

import "core:testing"
import "core:sys/posix"

@(test)
test_input_source_from_bytes_reads_all :: proc(t: ^testing.T) {
	src := input_source_from_bytes([]u8{'a', 'b', 'c'})
	defer input_close(&src)

	buf: [8]u8
	n, ok := input_read(&src, buf[:])
	testing.expect(t, ok, "read should succeed")
	testing.expect_value(t, n, 3)
	testing.expect_value(t, string(buf[:n]), "abc")

	n2, ok2 := input_read(&src, buf[:])
	testing.expect(t, !ok2 || n2 == 0, "second read should report EOF")
}

@(test)
test_input_source_from_bytes_respects_small_buffer :: proc(t: ^testing.T) {
	src := input_source_from_bytes([]u8{'h', 'e', 'l', 'l', 'o'})
	defer input_close(&src)

	buf: [2]u8
	n, ok := input_read(&src, buf[:])
	testing.expect(t, ok, "read should succeed")
	testing.expect_value(t, n, 2)
	testing.expect_value(t, string(buf[:n]), "he")
}

@(test)
test_input_source_from_fd_reads_a_pipe :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect_value(t, posix.pipe(&fds), posix.result.OK)
	defer { posix.close(fds[0]); posix.close(fds[1]) }

	msg := "xyz"
	posix.write(fds[1], raw_data(msg), len(msg))

	src, ok := input_source_from_fd(fds[0])
	testing.expect(t, ok, "fd source should initialise")
	defer input_close(&src)

	buf: [8]u8
	n, rok := input_read(&src, buf[:])
	testing.expect(t, rok, "read should succeed")
	testing.expect_value(t, n, 3)
	testing.expect_value(t, string(buf[:n]), "xyz")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: FAIL — `Undeclared name: input_source_from_bytes`.

- [ ] **Step 3: Write minimal implementation**

Create `runetea/loop.odin`:

```odin
package runetea

import "core:sys/posix"

// Explicit vtable rather than an interface. Three implementations matter:
//   - fd     : the real tty (and, via nbio, any pollable handle)
//   - bytes  : the golden harness and unit tests, no terminal involved
//   - stream : reserved for core:io.Stream injection (v1.0)
//
// The seam also isolates the one unvalidated platform risk: if nbio's kqueue
// path misbehaves on Darwin /dev/tty, a posix.poll implementation drops in here
// without touching anything above.
Input_Source :: struct {
	self:  rawptr,
	read:  proc(self: rawptr, buf: []u8) -> (n: int, ok: bool),
	close: proc(self: rawptr),
}

input_read :: proc(src: ^Input_Source, buf: []u8) -> (n: int, ok: bool) {
	if src.read == nil { return 0, false }
	return src.read(src.self, buf)
}

input_close :: proc(src: ^Input_Source) {
	if src.close != nil { src.close(src.self) }
}

// --- fd-backed ---

Fd_Source :: struct { fd: posix.FD }

input_source_from_fd :: proc(fd: posix.FD) -> (Input_Source, bool) {
	if fd < 0 { return {}, false }
	s := new(Fd_Source)
	s.fd = fd
	return Input_Source{
		self  = s,
		read  = proc(self: rawptr, buf: []u8) -> (n: int, ok: bool) {
			s := cast(^Fd_Source)self
			got := posix.read(s.fd, raw_data(buf), len(buf))
			if got < 0 { return 0, false }
			return int(got), got > 0
		},
		close = proc(self: rawptr) { free(cast(^Fd_Source)self) },
	}, true
}

// --- byte-slice backed ---

Bytes_Source :: struct { data: []u8, pos: int }

input_source_from_bytes :: proc(data: []u8) -> Input_Source {
	s := new(Bytes_Source)
	s.data = data
	return Input_Source{
		self  = s,
		read  = proc(self: rawptr, buf: []u8) -> (n: int, ok: bool) {
			s := cast(^Bytes_Source)self
			if s.pos >= len(s.data) { return 0, false }
			n = copy(buf, s.data[s.pos:])
			s.pos += n
			return n, n > 0
		},
		close = proc(self: rawptr) { free(cast(^Bytes_Source)self) },
	}
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: PASS, 21 tests total.

- [ ] **Step 5: Verify nbio drives a real fd end to end**

This is the load-bearing platform assumption. Create `tools/nbiocheck/main.odin`:

```odin
package main

import "core:fmt"
import "core:nbio"
import "core:sys/posix"
import "core:time"

State :: struct { buf: [64]u8, reads: int, ticks: int, done: bool }

on_read :: proc(op: ^nbio.Operation) {
	s := cast(^State)op.user_data[0]
	n := op.read.read
	if n <= 0 { s.done = true; return }
	fmt.printfln("  read %d bytes: %q", n, string(s.buf[:n]))
	s.reads += 1
	if s.reads >= 2 { s.done = true }
}

on_tick :: proc(op: ^nbio.Operation) {
	s := cast(^State)op.user_data[0]
	s.ticks += 1
	fmt.println("  tick", s.ticks)
}

main :: proc() {
	if err := nbio.acquire_thread_event_loop(); err != nil { fmt.eprintln(err); return }
	defer nbio.release_thread_event_loop()

	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK { fmt.eprintln("pipe failed"); return }

	h, aerr := nbio.associate_handle(uintptr(fds[0]))
	if aerr != nil { fmt.eprintln("associate_handle:", aerr); return }

	s := State{}
	top := nbio.timeout(10 * time.Millisecond, on_tick)
	top.user_data[0] = &s

	op := nbio.read(h, 0, s.buf[:], on_read)
	op.user_data[0] = &s

	msg := "first"
	posix.write(fds[1], raw_data(msg), len(msg))

	nbio.run_until(&s.done)
	fmt.printfln("loop exited: reads=%d ticks=%d", s.reads, s.ticks)
}
```

Run: `odin run tools/nbiocheck`
Expected: at least one read callback with `"first"`, at least one tick, and a clean exit. This confirms `associate_handle` accepts a non-socket fd and that timeouts and reads coexist on one loop.

- [ ] **Step 6: Commit**

```bash
git add runetea/loop.odin runetea/loop_test.odin tools/nbiocheck/main.odin
git commit -m "feat(loop): Input_Source seam + nbio verification

Vtable seam so the golden harness can drive a Program from bytes with
no terminal, and so a posix.poll backend can replace nbio if its
kqueue path misbehaves on Darwin /dev/tty."
```

---

## Task 7: Signal thread for SIGINT and SIGWINCH

`sigwait` on a dedicated thread rather than a self-pipe. The waiting thread is ordinary — it can take locks and allocate — so there is no async-signal-safety constraint at all. This is a closer analogue of Go's `signal.Notify` than the self-pipe trick.

**Files:**
- Create: `runetea/signals.odin`
- Test: `runetea/signals_test.odin`

**Interfaces:**
- Consumes: `Mailbox` (Task 1), `box` (Task 4), `term_size` (Task 2).
- Produces: `Interrupt_Msg :: struct {}`; `Window_Size_Msg :: struct { w, h: int }`; `Signal_Watcher` struct; `signal_watcher_start(sw: ^Signal_Watcher, m: ^Mailbox, tty: posix.FD)`; `signal_watcher_stop(sw: ^Signal_Watcher)`.

- [ ] **Step 1: Write the failing test**

Create `runetea/signals_test.odin`:

```odin
package runetea

import "core:testing"
import "core:sys/posix"
import "core:time"

@(test)
test_sigwinch_becomes_a_window_size_msg :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	defer mailbox_destroy(&m)

	sw: Signal_Watcher
	signal_watcher_start(&sw, &m, posix.FD(-1))  // invalid fd: size lookup fails, msg still sent
	defer signal_watcher_stop(&sw)

	time.sleep(50 * time.Millisecond)  // let the watcher reach sigwait
	posix.raise(SIGWINCH)

	msg, ok := mailbox_recv(&m)
	testing.expect(t, ok, "expected a message from the signal watcher")
	_, is_size := msg.(Window_Size_Msg)
	testing.expect(t, is_size, "SIGWINCH should produce a Window_Size_Msg")
}

@(test)
test_sigint_becomes_an_interrupt_msg :: proc(t: ^testing.T) {
	m: Mailbox
	testing.expect_value(t, mailbox_init(&m, 16), nil)
	defer mailbox_destroy(&m)

	sw: Signal_Watcher
	signal_watcher_start(&sw, &m, posix.FD(-1))
	defer signal_watcher_stop(&sw)

	time.sleep(50 * time.Millisecond)
	posix.raise(.SIGINT)

	msg, ok := mailbox_recv(&m)
	testing.expect(t, ok, "expected a message from the signal watcher")
	_, is_int := msg.(Interrupt_Msg)
	testing.expect(t, is_int, "SIGINT should produce an Interrupt_Msg")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: FAIL — `Undeclared name: Signal_Watcher`.

- [ ] **Step 3: Write minimal implementation**

Create `runetea/signals.odin`:

```odin
package runetea

import "core:sync"
import "core:sys/posix"
import "core:thread"

Interrupt_Msg   :: struct {}
Window_Size_Msg :: struct { w, h: int }

// SIGWINCH is a BSD extension and is NOT a member of posix.Signal, which stops
// at the POSIX-standard set. The per-platform constant does exist, so cast it.
SIGWINCH :: posix.Signal(posix.SIGWINCH)

Signal_Watcher :: struct {
	thread:  ^thread.Thread,
	mailbox: ^Mailbox,
	tty:     posix.FD,
	running: bool,
	stop:    bool,
}

// Blocks the handled signals process-wide, then waits for them on a dedicated
// ordinary thread. Because sigwait is not a signal handler, this thread may take
// locks and allocate -- no async-signal-safety constraint applies.
//
// Clear this mask before spawning a child process, or $EDITOR inherits it.
signal_watcher_start :: proc(sw: ^Signal_Watcher, m: ^Mailbox, tty: posix.FD) {
	sw.mailbox = m
	sw.tty = tty
	sw.running = true

	set: posix.sigset_t
	posix.sigemptyset(&set)
	posix.sigaddset(&set, .SIGINT)
	posix.sigaddset(&set, .SIGTERM)
	posix.sigaddset(&set, SIGWINCH)
	posix.pthread_sigmask(.BLOCK, &set, nil)   // Sig.BLOCK, not .SIG_BLOCK

	// init_context for the same reason as Task 5's detached dispatch: without
	// it the watcher thread runs under runtime.default_context(), so the
	// messages it boxes below come from a different allocator than the main
	// loop's. See core/thread/thread.odin:534.
	sw.thread = thread.create(proc(th: ^thread.Thread) {
		sw := cast(^Signal_Watcher)th.data
		set: posix.sigset_t
		posix.sigemptyset(&set)
		posix.sigaddset(&set, .SIGINT)
		posix.sigaddset(&set, .SIGTERM)
		posix.sigaddset(&set, SIGWINCH)

		for !sync.atomic_load(&sw.stop) {
			sig: posix.Signal
			// sigwait returns Errno; success is .NONE, not .OK
			if posix.sigwait(&set, &sig) != .NONE { continue }
			switch sig {
			case SIGWINCH:
				w, h, ok := term_size(sw.tty)
				if !ok { w, h = 0, 0 }
				_ = mailbox_send(sw.mailbox, box(Window_Size_Msg{w = w, h = h}, context.allocator))
			case .SIGINT, .SIGTERM:
				_ = mailbox_send(sw.mailbox, box(Interrupt_Msg{}, context.allocator))
			case:
				// not subscribed
			}
		}
	})
	sw.thread.data = sw
	sw.thread.init_context = context
	thread.start(sw.thread)
}

signal_watcher_stop :: proc(sw: ^Signal_Watcher) {
	if !sw.running { return }
	sync.atomic_store(&sw.stop, true)
	posix.raise(SIGWINCH)   // unblock the sigwait so the thread observes stop
	thread.join(sw.thread)
	thread.destroy(sw.thread)
	sw.running = false
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: PASS, 23 tests total.

If `posix.sigwait`'s signature differs from `sigwait(&set, &sig) -> result`, check `core/sys/posix/signal.odin:186` and adjust — this is the one API in the spike most likely to have drifted.

- [ ] **Step 5: Verify SIGWINCH against a real terminal**

Run: `odin run tools/rawcheck` (from Task 2) in one terminal, then resize the window.
Expected: `rawcheck` does not yet print sizes on resize — extend it with a `Signal_Watcher` and confirm a `Window_Size_Msg` arrives with the new dimensions on each resize. Verify the reported size matches `tput cols` / `tput lines`.

- [ ] **Step 6: Commit**

```bash
git add runetea/signals.odin runetea/signals_test.odin
git commit -m "feat(signals): sigwait watcher thread for SIGINT/SIGWINCH

pthread_sigmask + sigwait on an ordinary thread rather than a
self-pipe -- the watcher can take locks and allocate freely."
```

---

## Task 8: Minimal key decoder

Only enough to run the two examples: printable runes, Ctrl-C, Ctrl-D, Enter, Escape, and the four arrow keys. The full CSI/SS3/Kitty decoder is T1/T4 work — resist scope creep here.

**Files:**
- Create: `runetea/input.odin`
- Test: `runetea/input_test.odin`

**Interfaces:**
- Consumes: `box` (Task 4).
- Produces: `Key_Code` enum; `Modifiers` bit_set; `Key_Msg :: struct { kind: Key_Kind, code: Key_Code, r: rune, mods: Modifiers }`; `decode_keys(data: []u8, out: ^[dynamic]Key_Msg) -> (consumed: int)`.

- [ ] **Step 1: Write the failing test**

Create `runetea/input_test.odin`:

```odin
package runetea

import "core:testing"

@(test)
test_decode_printable_runes :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	n := decode_keys(transmute([]u8)string("abc"), &out)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, len(out), 3)
	testing.expect_value(t, out[0].r, 'a')
	testing.expect_value(t, out[2].r, 'c')
	testing.expect_value(t, out[0].code, Key_Code.Rune)
}

@(test)
test_decode_ctrl_c :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	n := decode_keys([]u8{0x03}, &out)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].r, 'c')
	testing.expect(t, .Ctrl in out[0].mods, "ctrl modifier must be set")
}

@(test)
test_decode_arrow_keys :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	n := decode_keys(transmute([]u8)string("\e[A\e[B\e[C\e[D"), &out)
	testing.expect_value(t, n, 12)
	testing.expect_value(t, len(out), 4)
	testing.expect_value(t, out[0].code, Key_Code.Up)
	testing.expect_value(t, out[1].code, Key_Code.Down)
	testing.expect_value(t, out[2].code, Key_Code.Right)
	testing.expect_value(t, out[3].code, Key_Code.Left)
}

@(test)
test_decode_enter_and_escape :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	decode_keys([]u8{'\r'}, &out)
	testing.expect_value(t, out[0].code, Key_Code.Enter)

	clear(&out)
	decode_keys([]u8{0x1b}, &out)
	testing.expect_value(t, out[0].code, Key_Code.Escape)
}

// A partial escape sequence must be held back, not misdecoded as a lone Escape.
// This is the classic bug: a CSI split across two reads becomes ESC + garbage.
@(test)
test_partial_sequence_is_held_back :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	n := decode_keys(transmute([]u8)string("\e["), &out)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, len(out), 0)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: FAIL — `Undeclared name: decode_keys`.

- [ ] **Step 3: Write minimal implementation**

Create `runetea/input.odin`:

```odin
package runetea

import "core:unicode/utf8"

Key_Kind :: enum u8 { Press, Release }

// Collapsed vocabulary: Bubble Tea matches six key/mouse types by method set,
// which Odin cannot express. One struct with a discriminant instead (spec §9).
Key_Code :: enum u8 {
	Rune, Enter, Escape, Backspace, Tab, Space,
	Up, Down, Right, Left,
}

Modifier  :: enum u8 { Ctrl, Alt, Shift }
Modifiers :: bit_set[Modifier; u8]

Key_Msg :: struct {
	kind: Key_Kind,
	code: Key_Code,
	r:    rune,
	mods: Modifiers,
}

// Decodes as many complete keys as `data` contains, appending to `out`.
// Returns the number of bytes consumed; a trailing partial escape sequence is
// left unconsumed so the caller can retry once more bytes arrive.
decode_keys :: proc(data: []u8, out: ^[dynamic]Key_Msg) -> (consumed: int) {
	i := 0
	for i < len(data) {
		b := data[i]

		// CSI sequences: ESC [ <final>
		if b == 0x1b {
			if i + 1 >= len(data) {
				// Lone ESC at the very end of the buffer. Ambiguous: it may be a
				// real Escape or the start of a sequence still in flight. The
				// spike resolves it as Escape; a timer-based disambiguation is
				// T1 work (spec §12).
				append(out, Key_Msg{code = .Escape})
				return i + 1
			}
			if data[i + 1] == '[' {
				if i + 2 >= len(data) { return i }   // incomplete: hold back
				code: Key_Code
				switch data[i + 2] {
				case 'A': code = .Up
				case 'B': code = .Down
				case 'C': code = .Right
				case 'D': code = .Left
				case:
					i += 3   // unrecognised CSI: skip it
					continue
				}
				append(out, Key_Msg{code = code})
				i += 3
				continue
			}
			// ESC followed by a printable byte == Alt+key
			r, w := utf8.decode_rune(data[i + 1:])
			append(out, Key_Msg{code = .Rune, r = r, mods = {.Alt}})
			i += 1 + w
			continue
		}

		switch b {
		case '\r', '\n': append(out, Key_Msg{code = .Enter});     i += 1; continue
		case 0x7f:       append(out, Key_Msg{code = .Backspace}); i += 1; continue
		case '\t':       append(out, Key_Msg{code = .Tab});       i += 1; continue
		case ' ':        append(out, Key_Msg{code = .Space, r = ' '}); i += 1; continue
		}

		// C0 control bytes are Ctrl+letter
		if b < 0x20 {
			append(out, Key_Msg{code = .Rune, r = rune(b + 'a' - 1), mods = {.Ctrl}})
			i += 1
			continue
		}

		r, w := utf8.decode_rune(data[i:])
		if w == 0 { return i }   // incomplete UTF-8: hold back
		append(out, Key_Msg{code = .Rune, r = r})
		i += w
	}
	return i
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: PASS, 28 tests total.

- [ ] **Step 5: Commit**

```bash
git add runetea/input.odin runetea/input_test.odin
git commit -m "feat(input): minimal key decoder for the spike

Printable runes, C0 as Ctrl+letter, Enter/Tab/Backspace/Escape and
the four arrows. Partial sequences are held back rather than
misdecoded. Full CSI/SS3/Kitty decoding is T1/T4 work."
```

---

## Task 9: Naive inline renderer

Track the previous frame's line count, rewind with CUU/EL, repaint. No cell buffer and no diffing — the diff renderer is T3 and needs the golden harness before it can be trusted.

**Files:**
- Create: `runetea/render.odin`
- Test: `runetea/render_test.odin`

**Interfaces:**
- Consumes: nothing.
- Produces: `Renderer` struct; `renderer_init(r: ^Renderer, out: ^strings.Builder)`; `renderer_render(r: ^Renderer, view: string)`; `renderer_clear(r: ^Renderer)`.

- [ ] **Step 1: Write the failing test**

Create `runetea/render_test.odin`:

```odin
package runetea

import "core:strings"
import "core:testing"

@(test)
test_first_render_emits_content_only :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	renderer_render(&r, "hello\nworld")
	testing.expect_value(t, strings.to_string(b), "hello\r\nworld\r\n")
}

@(test)
test_second_render_rewinds_previous_lines :: proc(t: ^testing.T) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	renderer_render(&r, "a\nb")
	strings.builder_reset(&b)
	renderer_render(&r, "c\nd")

	// 2 previous lines -> 2x (cursor-up + erase-line), then the new content
	testing.expect_value(t, strings.to_string(b), "\e[1A\e[2K\e[1A\e[2K" + "c\r\nd\r\n")
}

@(test)
test_identical_frame_costs_a_full_repaint :: proc(t: ^testing.T) {
	// Documents the naive renderer's defining weakness with an exact byte
	// expectation, not a >0 smoke check: an unchanged single-line frame still
	// costs rewind + full content. T3's diff renderer must reduce this to 0
	// bytes, and this test is what will prove it changed.
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b)

	renderer_render(&r, "same")
	strings.builder_reset(&b)
	renderer_render(&r, "same")

	// 1 previous line -> one CUU+EL pair, then the identical content again.
	testing.expect_value(t, strings.to_string(b), "\e[1A\e[2K" + "same\r\n")
	testing.expect_value(t, len(strings.to_string(b)), 14)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: FAIL — `Undeclared name: Renderer`.

- [ ] **Step 3: Write minimal implementation**

Create `runetea/render.odin`:

```odin
package runetea

import "core:strings"

// Naive inline renderer: rewind over the previous frame and repaint.
//
// Deliberately has no cell buffer and no diffing. At 60fps this pushes ~104 KB/s
// for a completely static screen -- fine locally, unusable over ssh. T3 replaces
// it with a diffed cell renderer, gated behind the golden-byte harness because
// that code fails silently and has no oracle (spec §10, §13.1).
Renderer :: struct {
	out:        ^strings.Builder,
	last_lines: int,
}

renderer_init :: proc(r: ^Renderer, out: ^strings.Builder) {
	r.out = out
	r.last_lines = 0
}

renderer_render :: proc(r: ^Renderer, view: string) {
	// Rewind over the previous frame.
	for _ in 0 ..< r.last_lines {
		strings.write_string(r.out, "\e[1A")   // cursor up one line
		strings.write_string(r.out, "\e[2K")   // erase entire line
	}

	lines := strings.split_lines(view)
	defer delete(lines)
	for line in lines {
		strings.write_string(r.out, line)
		strings.write_string(r.out, "\r\n")    // raw mode: OPOST is off
	}
	r.last_lines = len(lines)
}

renderer_clear :: proc(r: ^Renderer) {
	for _ in 0 ..< r.last_lines {
		strings.write_string(r.out, "\e[1A")
		strings.write_string(r.out, "\e[2K")
	}
	r.last_lines = 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: PASS, 31 tests total. If `test_second_render_rewinds_previous_lines` fails on the trailing-newline count, check whether `strings.split_lines` yields a trailing empty element for input ending in `\n` — the test inputs deliberately do not end in a newline to avoid that ambiguity.

- [ ] **Step 5: Commit**

```bash
git add runetea/render.odin runetea/render_test.odin
git commit -m "feat(render): naive inline renderer

Rewind with CUU/EL and repaint. No diffing by design -- T3 replaces
this behind the golden-byte harness."
```

---

## Task 10: Program wiring and examples/simple

First point at which all the pieces run together. `run()` owns the terminal, drives Update/View, and returns an error rather than dying.

**Files:**
- Create: `runetea/tea.odin`, `examples/simple/main.odin`
- Test: `runetea/tea_test.odin`

**Interfaces:**
- Consumes: everything from Tasks 1–9.
- Produces: `Quit_Msg :: struct {}`; `Run_Error` union; `Program($T)` struct; `program_init(p: ^Program($T), model: T, update: proc(model: T, msg: any, alloc: mem.Allocator) -> (T, Cmd), view: proc(model: T, alloc: mem.Allocator) -> string, init_cmd := Cmd{})`; `run(p: ^Program($T), src: ^Input_Source, out: ^strings.Builder, flush_fd: posix.FD = -1) -> Run_Error`; `quit_cmd() -> Cmd`.

- [ ] **Step 1: Write the failing test**

Create `runetea/tea_test.odin`:

```odin
package runetea

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

Counter :: struct { n: int, done: bool }

counter_update :: proc(m: Counter, msg: any, alloc: mem.Allocator) -> (Counter, Cmd) {
	m := m
	switch v in msg {
	case Key_Msg:
		if v.code == .Rune && v.r == 'q' { m.done = true; return m, quit_cmd() }
		m.n += 1
	case Quit_Msg:
		m.done = true
	}
	return m, cmd_nil()
}

counter_view :: proc(m: Counter, alloc: mem.Allocator) -> string {
	return fmt.aprintf("count: %d", m.n, allocator = alloc)
}

@(test)
test_program_processes_keys_and_quits :: proc(t: ^testing.T) {
	src := input_source_from_bytes(transmute([]u8)string("aaq"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Counter)
	program_init(&p, Counter{}, counter_update, counter_view)

	err := run(&p, &src, &b)
	testing.expect(t, err == nil, "run should exit cleanly")
	testing.expect_value(t, p.model.n, 2)
	testing.expect(t, p.model.done, "model should have observed the quit")
}

@(test)
test_program_recovers_from_a_panicking_update :: proc(t: ^testing.T) {
	Boom :: struct { n: int }
	boom_update :: proc(m: Boom, msg: any, alloc: mem.Allocator) -> (Boom, Cmd) {
		panic("user update exploded")
	}
	boom_view :: proc(m: Boom, alloc: mem.Allocator) -> string { return "" }

	src := input_source_from_bytes(transmute([]u8)string("x"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Boom)
	program_init(&p, Boom{}, boom_update, boom_view)

	err := run(&p, &src, &b)
	_, panicked := err.(Panicked_Error)
	testing.expect(t, panicked, "a panicking Update must surface as Panicked_Error, not a crash")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: FAIL — `Undeclared name: Program`.

- [ ] **Step 3: Write minimal implementation**

Create `runetea/tea.odin`:

```odin
package runetea

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"

Quit_Msg :: struct {}

Killed_Error      :: struct {}
Interrupted_Error :: struct {}
Panicked_Error    :: struct { message: string }
Terminal_Error    :: struct { detail: string }

Run_Error :: union { Killed_Error, Interrupted_Error, Panicked_Error, Terminal_Error }

// Parametric over the model rather than an interface. This is STRONGER checking
// than Go's: Go verifies only method-set conformance, not that Update returns
// the same concrete type. The cost is that the model cannot be swapped for a
// different type mid-run -- use a `state` enum, or make T itself a vtable.
Program :: struct($T: typeid) {
	model:    T,
	update:   proc(model: T, msg: any, alloc: mem.Allocator) -> (T, Cmd),
	view:     proc(model: T, alloc: mem.Allocator) -> string,
	init_cmd: Cmd,
	quit:     bool,
}

// init_cmd is Bubble Tea's `Init() Cmd`: the command fired once before the
// first input is read. Without it, any app whose first action is asynchronous
// (fetch, timer, subprocess) can never start.
program_init :: proc(
	p: ^Program($T),
	model: T,
	update: proc(model: T, msg: any, alloc: mem.Allocator) -> (T, Cmd),
	view: proc(model: T, alloc: mem.Allocator) -> string,
	init_cmd := Cmd{},
) {
	p.model    = model
	p.update   = update
	p.view     = view
	p.init_cmd = init_cmd
	p.quit     = false
}

quit_run :: proc(env: rawptr) -> any { return box(Quit_Msg{}, context.allocator) }

quit_cmd :: proc() -> Cmd {
	return Cmd{procedure = quit_run, env = nil, allocator = context.allocator}
}

// Shared state for the guarded Update call. longjmp discards the frame, so the
// inputs and outputs live outside it.
@(private="file")
Step :: struct($T: typeid) {
	p:     ^Program(T),
	msg:   any,
	alloc: mem.Allocator,
	cmd:   Cmd,
}

// flush_fd >= 0 writes each frame to that fd and resets the builder, which is
// what makes the display update live. Pass -1 (the default) to accumulate the
// whole session in the builder instead -- that is what the golden harness reads.
run :: proc(p: ^Program($T), src: ^Input_Source, out: ^strings.Builder, flush_fd: posix.FD = -1) -> Run_Error {
	fa: Frame_Arena
	if err := frame_arena_init(&fa); err != nil {
		return Terminal_Error{detail = "frame arena init failed"}
	}
	defer frame_arena_destroy(&fa)

	mbox: Mailbox
	if err := mailbox_init(&mbox, 256); err != nil {
		return Terminal_Error{detail = "mailbox init failed"}
	}
	defer mailbox_destroy(&mbox)

	disp: Dispatcher
	dispatcher_init(&disp, &mbox, 4)
	defer dispatcher_destroy(&disp)

	r: Renderer
	renderer_init(&r, out)

	// Initial paint, then the init Cmd -- in that order, so an app whose first
	// action is asynchronous still shows its loading state immediately.
	{
		al := frame_allocator(&fa)
		renderer_render(&r, p.view(p.model, al))
		flush_frame(out, flush_fd)
		frame_reset(&fa)
	}
	if !cmd_is_nil(p.init_cmd) { dispatch(&disp, p.init_cmd) }

	// The mailbox is the SINGLE wait point. A reader thread turns bytes into
	// Key_Msgs and pushes them alongside Cmd results, so an async result
	// updates the view with no keypress -- without this, examples/http shows
	// "Checking..." until the user happens to hit a key.
	//
	// The spike reads on a thread rather than through nbio because the loop
	// still owns rendering; Task 6's nbio path replaces this reader in T1.
	rd := Reader_Ctx{src = src, mailbox = &mbox}
	reader := thread.create(reader_thread)
	reader.data = &rd
	thread.start(reader)
	defer {
		sync.atomic_store(&rd.stop, true)
		mailbox_close(&mbox)
		thread.join(reader)
		thread.destroy(reader)
	}

	for !p.quit {
		msg, ok := mailbox_recv(&mbox)
		if !ok { break }   // closed and drained
		if e := apply(p, msg, &fa, &disp, &r, out, flush_fd); e != nil { return e }
	}
	return nil
}

Reader_Ctx :: struct {
	src:     ^Input_Source,
	mailbox: ^Mailbox,
	stop:    bool,
}

@(private="file")
reader_thread :: proc(th: ^thread.Thread) {
	rd := cast(^Reader_Ctx)th.data
	buf: [1024]u8
	keys := make([dynamic]Key_Msg);  defer delete(keys)
	pending: [dynamic]u8;            defer delete(pending)

	for !sync.atomic_load(&rd.stop) {
		n, ok := input_read(rd.src, buf[:])
		if !ok || n == 0 {
			mailbox_close(rd.mailbox)   // EOF: unblock the loop
			return
		}
		append(&pending, ..buf[:n])

		clear(&keys)
		consumed := decode_keys(pending[:], &keys)
		if consumed > 0 { remove_range(&pending, 0, consumed) }

		for k in keys {
			// Boxed on the heap, not the frame arena: this crosses a thread
			// boundary and outlives any single frame.
			if !mailbox_send(rd.mailbox, box(k, context.allocator)) { return }
		}
	}
}

// Writes the accumulated frame to flush_fd and resets the builder. With
// flush_fd < 0 the builder keeps accumulating -- the golden harness reads it.
@(private="file")
flush_frame :: proc(out: ^strings.Builder, flush_fd: posix.FD) {
	if flush_fd < 0 { return }
	s := strings.to_string(out^)
	if len(s) > 0 { posix.write(flush_fd, raw_data(s), len(s)) }
	strings.builder_reset(out)
}

// One Update/View cycle, guarded. Split out so `run` stays readable and so the
// guarded region is exactly the user code, not our loop bookkeeping.
@(private="file")
apply :: proc(p: ^Program($T), msg: any, fa: ^Frame_Arena, disp: ^Dispatcher, r: ^Renderer, out: ^strings.Builder, flush_fd: posix.FD) -> Run_Error {
	if _, is_quit := msg.(Quit_Msg); is_quit { p.quit = true; return nil }
	if _, is_int := msg.(Interrupt_Msg); is_int { return Interrupted_Error{} }

	step := Step(T){p = p, msg = msg, alloc = frame_allocator(fa)}
	info := guarded(proc(ud: rawptr) {
		s := cast(^Step(T))ud
		s.p.model, s.cmd = s.p.update(s.p.model, s.msg, s.alloc)
	}, &step)

	if info.recovered {
		// longjmp ran no defers: reclaim the failed iteration wholesale.
		frame_reset(fa)
		return Panicked_Error{message = info.message}
	}

	if !cmd_is_nil(step.cmd) { dispatch(disp, step.cmd) }

	renderer_render(r, p.view(p.model, frame_allocator(fa)))
	flush_frame(out, flush_fd)
	frame_reset(fa)
	return nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: PASS, 33 tests total.

The `Step(T)`-through-`rawptr` pattern was verified before this plan was written: a parapoly struct passed as `rawptr` into a non-generic callback and recovered with `cast(^Step(T))ud` works, because the proc literal is instantiated inside the generic parent. If it nonetheless fails here, fall back to a monomorphic `Step` holding `p: rawptr` plus a `step_proc: proc(rawptr)` set by `run`, and record the constraint.

- [ ] **Step 5: Port examples/simple and run it**

Read `/home/denisbytes/dev/bubbletea/examples/simple/main.go` first. Create `examples/simple/main.odin`:

```odin
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import rt "../../runetea"

Model :: struct { ticks: int }

update :: proc(m: Model, msg: any, alloc: mem.Allocator) -> (Model, rt.Cmd) {
	m := m
	switch v in msg {
	case rt.Key_Msg:
		if v.code == .Rune && (v.r == 'q' || (v.r == 'c' && .Ctrl in v.mods)) {
			return m, rt.quit_cmd()
		}
		if v.code == .Escape { return m, rt.quit_cmd() }
		m.ticks += 1
	}
	return m, rt.cmd_nil()
}

view :: proc(m: Model, alloc: mem.Allocator) -> string {
	return fmt.aprintf("Hi. This program will exit on 'q'.\n\nKeys pressed: %d\n", m.ticks, allocator = alloc)
}

main :: proc() {
	fd := posix.FD(os.fd(os.stdin))
	if !rt.term_enter_raw(fd) { fmt.eprintln("not a tty"); os.exit(1) }
	defer rt.term_restore()
	rt.install_crash_handlers()

	src, ok := rt.input_source_from_fd(fd)
	if !ok { fmt.eprintln("bad input source"); os.exit(1) }
	defer rt.input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: rt.Program(Model)
	rt.program_init(&p, Model{}, update, view)

	// flush_fd = the tty, so each frame reaches the screen as it is rendered.
	if err := rt.run(&p, &src, &b, fd); err != nil { fmt.eprintln("error:", err) }
}
```

Run: `odin run examples/simple`
Expected: the counter increments **live** on each keypress, `q` and Ctrl-C exit, and the shell is left usable afterwards.

Verify the live update specifically — if output only appears at exit, `flush_frame` is not being reached and the `flush_fd` argument was dropped somewhere between `run` and `apply`.

- [ ] **Step 6: Commit**

```bash
git add runetea/tea.odin runetea/tea_test.odin examples/simple/main.odin
git commit -m "feat(tea): Program, run(), and examples/simple

Parapoly over the root model. Update runs inside the crash guard, so
a panicking user Update surfaces as Panicked_Error rather than a
wedged terminal."
```

---

## Task 11: examples/http, the golden harness, and the kill-criteria review

The measurement task. `examples/http` is the one that exercises the closure-free `Cmd` path, and its line count against the Go original *is* the ergonomic verdict the spike exists to produce.

**Files:**
- Create: `examples/http/main.odin`, `tools/golden/main.odin`, `docs/superpowers/spike-findings.md`
- Test: `runetea/golden_test.odin`

**Interfaces:**
- Consumes: everything above.
- Produces: `docs/superpowers/spike-findings.md` — the go/no-go document.

- [ ] **Step 1: Write the failing golden test**

Create `runetea/golden_test.odin`:

```odin
package runetea

import "core:os"
import "core:strings"
import "core:testing"

// Drives a Program from a fixed byte script with no terminal and compares the
// exact output bytes against a committed golden file. This is the instrument
// the T3 diff renderer will be built inside -- wire it up now, while the
// renderer is simple enough that a mismatch is obviously the test's fault.
//
// Regenerate with: odin test . -define:GOLDEN_UPDATE=true
GOLDEN_UPDATE :: #config(GOLDEN_UPDATE, false)

@(test)
test_golden_simple_session :: proc(t: ^testing.T) {
	src := input_source_from_bytes(transmute([]u8)string("aaq"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Counter)
	program_init(&p, Counter{}, counter_update, counter_view)
	err := run(&p, &src, &b)
	testing.expect(t, err == nil, "run should exit cleanly")

	got := transmute([]u8)strings.to_string(b)
	path := "testdata/simple_session.golden"

	when GOLDEN_UPDATE {
		os.make_directory("testdata")
		testing.expect(t, os.write_entire_file(path, got), "failed to write golden")
		return
	}

	want, ok := os.read_entire_file(path)
	testing.expectf(t, ok, "missing golden %s -- regenerate with -define:GOLDEN_UPDATE=true", path)
	if !ok { return }
	defer delete(want)

	testing.expectf(t, string(got) == string(want),
		"byte mismatch\n got: %q\nwant: %q", string(got), string(want))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd runetea && odin test . -define:ODIN_TEST_THREADS=1`
Expected: FAIL — missing golden file.

- [ ] **Step 3: Generate the golden and verify it locks**

Run:
```bash
cd runetea && odin test . -define:ODIN_TEST_THREADS=1 -define:GOLDEN_UPDATE=true
cd runetea && odin test . -define:ODIN_TEST_THREADS=1
```
Expected: the second run PASSES, 34 tests. Inspect `runetea/testdata/simple_session.golden` with `cat -v` and confirm the escape sequences are what you expect — a golden file nobody has read is not a test.

- [ ] **Step 4: Port examples/http and count the ergonomic cost**

Read `/home/denisbytes/dev/bubbletea/examples/http/main.go` first, then create `examples/http/main.odin`. The point is the `Cmd`: Go writes a closure, RuneTea needs a named env struct plus a named proc plus a `cmd_from` call.

```odin
package main

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/posix"
import rt "../../runetea"

// The Go original fetches https://charm.sh/. Odin core has TCP and DNS
// (core:net) but NO TLS -- core:crypto ships primitives, not the protocol --
// and the plan forbids third-party dependencies. So this does a real HTTP/1.1
// GET over plain http://, which exercises genuine network latency and a real
// blocking Cmd. Record the TLS gap in the findings; it is a v1.0 concern, not
// a spike one.
HOST :: "example.com"
PORT :: 80

// Go: `func checkServer() tea.Msg { ... }` -- a closure over nothing.
// RuneTea: an explicit env struct, because Odin has no closures.
Check_Env :: struct { host: string, port: int }

Status_Msg :: struct { code: int }
Err_Msg    :: struct { reason: string }

check_server :: proc(env: rawptr) -> any {
	e := cast(^Check_Env)env

	sock, derr := net.dial_tcp_from_hostname_with_port_override(e.host, e.port)
	if derr != nil {
		return rt.box(Err_Msg{reason = fmt.aprintf("dial: %v", derr)}, context.allocator)
	}
	defer net.close(sock)

	req := fmt.tprintf("GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", e.host)
	if _, serr := net.send_tcp(sock, transmute([]u8)req); serr != nil {
		return rt.box(Err_Msg{reason = fmt.aprintf("send: %v", serr)}, context.allocator)
	}

	buf: [1024]u8
	n, rerr := net.recv_tcp(sock, buf[:])
	if rerr != nil || n < 12 {
		return rt.box(Err_Msg{reason = fmt.aprintf("recv: %v", rerr)}, context.allocator)
	}

	// "HTTP/1.1 200 OK" -- the status code is bytes 9..12
	code := 0
	for c in buf[9:12] {
		if c < '0' || c > '9' { break }
		code = code * 10 + int(c - '0')
	}
	if code == 0 {
		return rt.box(Err_Msg{reason = "unparseable status line"}, context.allocator)
	}
	return rt.box(Status_Msg{code = code}, context.allocator)
}

Model :: struct { status: int, err: string, done: bool }

update :: proc(m: Model, msg: any, alloc: mem.Allocator) -> (Model, rt.Cmd) {
	m := m
	switch v in msg {
	case rt.Key_Msg:
		if v.code == .Rune && (v.r == 'q' || (v.r == 'c' && .Ctrl in v.mods)) {
			return m, rt.quit_cmd()
		}
	case Status_Msg:
		m.status = v.code; m.done = true
		return m, rt.quit_cmd()
	case Err_Msg:
		m.err = v.reason; m.done = true
		return m, rt.quit_cmd()
	}
	return m, rt.cmd_nil()
}

view :: proc(m: Model, alloc: mem.Allocator) -> string {
	if m.err != "" { return fmt.aprintf("error: %s\n", m.err, allocator = alloc) }
	if m.done      { return fmt.aprintf("http://%s -> %d\n", HOST, m.status, allocator = alloc) }
	return fmt.aprintf("Checking http://%s ...\n", HOST, allocator = alloc)
}

main :: proc() {
	fd := posix.FD(os.fd(os.stdin))
	if !rt.term_enter_raw(fd) { fmt.eprintln("not a tty"); os.exit(1) }
	defer rt.term_restore()
	rt.install_crash_handlers()

	src, ok := rt.input_source_from_fd(fd)
	if !ok { fmt.eprintln("bad input source"); os.exit(1) }
	defer rt.input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	// The initial Cmd. Go: `Init() Cmd { return checkServer }` -- one
	// identifier, because checkServer is already a closure of the right type.
	// RuneTea: cmd_from + a heap-cloned env struct that had to be declared.
	init := rt.cmd_from(check_server, Check_Env{host = HOST, port = PORT}, context.allocator)

	p: rt.Program(Model)
	rt.program_init(&p, Model{}, update, view, init)

	if err := rt.run(&p, &src, &b, fd); err != nil { fmt.eprintln("error:", err) }
}
```

Run: `odin run examples/http`
Expected: shows "Checking http://example.com ..." **immediately**, then the real status code once the request returns, then exits — with no keypress required. If it waits for a keypress, the mailbox is not the single wait point and Task 10's reader thread is wrong.

Requires network access. If the environment is offline, the Err_Msg path exercises the same Cmd machinery — record which path ran.

Then measure:
```bash
wc -l /home/denisbytes/dev/bubbletea/examples/http/main.go examples/http/main.odin
```
**Record both numbers.** This ratio is the ergonomic tax on every user program and it is the single most important output of the spike.

Note: `run()` as written does not yet dispatch an initial Cmd — wire `program_init` to accept one, or call `dispatch` before the loop. Fixing this is part of this step.

- [ ] **Step 5: Write the findings document and apply the kill criteria**

Create `docs/superpowers/spike-findings.md` recording, with real measured values:

1. **Mailbox** — unique values received / sent; `-sanitize:thread` clean? (yes/no)
2. **nbio** — did `associate_handle` + read + timeout work on a real tty (not just a pipe)? Any surprises?
3. **Raw mode** — CS8 workaround needed? Shell left usable after every exit path?
4. **Crash safety** — Tier 1 recovered panic/assert/type-assert? Tier 2 restored the terminal on a bounds trap?
5. **Msg** — did the cross-package type switch match a user-defined type?
6. **Cmd ergonomics** — `examples/http` LOC, Go vs Odin, and the ratio. **Would you write an app this way?**
7. **Parapoly** — did `Program($T)` survive the `rawptr` guard boundary, or was a monomorphic fallback needed?
8. **Total LOC** — `find runetea -name '*.odin' -not -name '*_test.odin' | xargs wc -l`. Against the ~900 target.

Then apply the binding kill criteria from spec §14:

- nbio misbehaves on a real TTY **and** a `posix.poll` fallback also degrades → **stop**
- the mailbox cannot be made `-sanitize:thread` clean within a week → **stop**
- `examples/http` ergonomics are bad enough you would not write an app that way → **stop**

State the go/no-go explicitly in the document. If it is "go", the next plan is T1 (spec §12): a real CSI/SS3 decoder, `batch`/`sequence` with the elastic overflow path, and the alt-screen mode diff.

- [ ] **Step 6: Commit**

```bash
git add examples/http/main.odin runetea/golden_test.odin runetea/testdata/ tools/golden/ docs/superpowers/spike-findings.md
git commit -m "feat(spike): examples/http, golden harness, findings

Closes the T0 spike. Findings document records measured results
against the kill criteria and states go/no-go for T1."
```

---

## Self-Review

**Spec coverage.** Spec §14's ten spike items map to tasks: mailbox → 1; nbio loop + fallback seam → 6; termios + singleton → 2; crash safety → 3; sigwait → 7; Msg arena → 4; Cmd + pool + examples/http → 5, 11; `io.Stream` seam → 6 (as `Input_Source`, generalised beyond `core:io.Stream` so byte-slice sources work without a stream wrapper); naive renderer → 9; golden harness → 11. Spec §2's two Odin bugs are pinned by tests in Tasks 2 and 4. Spec §13's kill criteria are Task 11 Step 5.

**Deliberately out of scope**, deferred to T1+ and noted where they arise: `batch`/`sequence` and the elastic overflow path (Task 5 Step 5); ESC-vs-Alt timing disambiguation (Task 8); mouse, alt screen, and the `View` mode diff (spec §9); the `posix.poll` fallback *implementation* — Task 6 builds the seam it would drop into but does not write the second backend, since the spike is Linux-only.

**Type consistency.** `Mailbox`/`mailbox_*`, `Cmd`/`cmd_*`, `Frame_Arena`/`frame_*`, `Input_Source`/`input_*`, `Renderer`/`renderer_*`, `Program`/`program_init`/`run` are used identically across every task. `box(v, alloc)` takes an explicit allocator everywhere. `Key_Msg` fields (`kind`, `code`, `r`, `mods`) match between Tasks 8, 10, and 11. `Window_Size_Msg{w, h}` matches between Tasks 2 and 7.

**API verification.** Every Odin stdlib signature this plan depends on was checked against `dev-2026-07-nightly:819fdc7` before the plan was written, and the core mechanisms (mailbox, crash guard, arena boxing, nbio fd read, parapoly-through-`rawptr`) were compiled and run. Four signatures were wrong on the first pass and are corrected inline — they are the ones an implementer would otherwise lose an hour to each:

| API | Wrong assumption | Reality |
|---|---|---|
| `linux.ioctl` | returns `Errno` | returns `uintptr`; errors are negative |
| `posix.Signal` | has `.SIGWINCH` | it does not — BSD extension, absent from the POSIX enum. Use `posix.Signal(posix.SIGWINCH)` |
| `posix.pthread_sigmask` | takes `.SIG_BLOCK` | takes `Sig.BLOCK` |
| `posix.sigwait` | returns `result` (`.OK`) | returns `Errno` (`.NONE`) |

`virtual.arena_destroy`, `arena.total_used`, `thread.pool_init(pool, allocator, count)`, `strings.split_lines`, and `sync.atomic_load`/`atomic_store` were all confirmed present with the signatures used here.

**Residual risk:** `nbio` was verified on a pipe, not a TTY. Task 6 Step 5 exercises it on a real terminal — that is the first genuinely new information the spike produces.

---

Plan complete and saved to `docs/superpowers/plans/2026-07-25-runetea-spike.md`.
