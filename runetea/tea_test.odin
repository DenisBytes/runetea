#+private
// ^ Every declaration in this file is package-private, so that `odin doc
//   runetea` / `odin doc runegloss` -- the command README.md and docs/API.md
//   hand a newcomer for symbol discovery -- lists the library rather than the
//   test fixtures. Pinned by tools/doccheck/run.sh's `apidoc` check, which is
//   also where the argument for it is written out.
package runetea

import "core:c/libc"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

Counter :: struct { n: int, done: bool }

counter_update :: proc(m: ^Counter, msg: any, alloc: mem.Allocator) -> Cmd {
	switch v in msg {
	case Key_Msg:
		if v.code == .Rune && v.r == 'q' { m.done = true; return quit_cmd() }
		m.n += 1
	case Quit_Msg:
		m.done = true
	}
	return cmd_nil()
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
	boom_update :: proc(m: ^Boom, msg: any, alloc: mem.Allocator) -> Cmd {
		panic("user update exploded")
	}
	boom_view :: proc(m: Boom, alloc: mem.Allocator) -> string { return "" }

	src := input_source_from_bytes(transmute([]u8)string("x"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Boom)
	program_init(&p, Boom{}, boom_update, boom_view)

	err := run(&p, &src, &b)
	pe, panicked := err.(Panicked_Error)
	defer delete(pe.message, context.allocator) // the caller owns it -- see Panicked_Error's own doc comment (tea.odin)
	testing.expect(t, panicked, "a panicking Update must surface as Panicked_Error, not a crash")
}

// THE COST OF THE POINTER-BASED update SIGNATURE, PINNED AS A TEST.
//
// Program.update takes ^T rather than T -- see its own comment (tea.odin) for
// the build-time measurements that bought that. What it cost is a real safety
// property: with the old by-value signature, apply_msg (then apply) did
// `p.model, cmd = p.update(p.model, ...)`, and guarded()'s longjmp SKIPPED
// that assignment, so a panicking update left p.model holding the last good
// state by construction. With a pointer, update writes into p.model directly,
// so a panic partway through leaves the model HALF-MUTATED.
//
// This test asserts that weaker reality rather than leaving it undocumented.
// `Half_Mutated` carries an explicit invariant -- a == b, always -- and the
// update below breaks it deliberately: it performs the first write, then
// panics before the second. After recovery the model is observably
// inconsistent, and this test says so out loud.
//
// Deliberately an EXACT equality assertion (a == 1, b == 0), not a permissive
// "either value is fine". This is documentation of observed behaviour, and a
// test that accepts every answer documents nothing. If a future change
// restores the old guarantee -- an opt-in snapshot mechanism, say -- this test
// SHOULD fail, and that failure is the signal to update the story in
// Program.update's comment, apply_msg's comment, and
// docs/superpowers/tier1-coverage-decision.md §5. It is not a signal to
// loosen the assertion here.
//
// The counterpart still holds and is asserted alongside: the PROCESS survives,
// run() returns Panicked_Error carrying the panic text, and the session ends
// (it does not loop back into update with the damaged model).
Half_Mutated :: struct {
	a: int,
	b: int,   // INVARIANT: b == a at every point an outside observer can look
}

half_mutated_update :: proc(m: ^Half_Mutated, msg: any, alloc: mem.Allocator) -> Cmd {
	if _, is_key := msg.(Key_Msg); is_key {
		m.a += 1
		panic("update exploded between two writes")
		// m.b += 1 -- NEVER RUNS, and that is the entire point. longjmp jumps
		// straight out of this proc back into apply_msg: no statement after the
		// panic runs, no `defer` registered in this frame runs, and no
		// hand-rolled `m^ = snapshot` restore line would run either. That is
		// why the mitigation for this is STRUCTURAL (do the fallible work
		// first, write into m^ last) and not a rollback an app can write.
	}
	return cmd_nil()
}

half_mutated_view :: proc(m: Half_Mutated, alloc: mem.Allocator) -> string { return "" }

@(test)
test_a_recovered_update_panic_can_leave_the_model_half_mutated :: proc(t: ^testing.T) {
	src := input_source_from_bytes(transmute([]u8)string("x"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Half_Mutated)
	program_init(&p, Half_Mutated{}, half_mutated_update, half_mutated_view)

	err := run(&p, &src, &b)
	pe, panicked := err.(Panicked_Error)
	defer delete(pe.message, context.allocator) // the caller owns it -- see Panicked_Error's own doc comment (tea.odin)

	// Still guaranteed, unchanged by the signature change:
	testing.expect(t, panicked, "a panicking Update must still surface as Panicked_Error, not a crash")
	testing.expect(t, strings.contains(pe.message, "update exploded between two writes"),
		"Panicked_Error must still carry the panic text")

	// No longer guaranteed, and this is what that looks like:
	testing.expectf(t, p.model.a == 1,
		"the write that happened BEFORE the panic is visible in p.model: a = %d, want 1 "+
		"(under the old by-value signature this was 0 -- longjmp skipped apply_msg's assignment)", p.model.a)
	testing.expectf(t, p.model.b == 0,
		"the write that would have happened AFTER the panic did not: b = %d, want 0", p.model.b)
	testing.expectf(t, p.model.a != p.model.b,
		"Half_Mutated's own a == b invariant is BROKEN after a recovered update panic (a = %d, b = %d) -- "+
		"Tier 1 guarantees the process survives, NOT that the model is consistent. See Program.update (tea.odin).",
		p.model.a, p.model.b)
}

// T1 extension (docs/superpowers/tier1-coverage-decision.md): View was one of
// the two unguarded user-code call sites spike-findings.md §4/addendum item 7
// flagged. The view here succeeds on the FIRST call (n == 0, the initial
// paint) and panics starting on the SECOND (n == 1, after the one keypress
// this test sends) -- deliberately, so this test exercises the loop's
// guarded_render call specifically (the steady-state path), not just
// run()'s initial-paint call site, while still proving the initial paint
// itself renders normally (no regression there).
@(test)
test_program_recovers_from_a_panicking_view :: proc(t: ^testing.T) {
	View_Boom :: struct { n: int }
	view_boom_update :: proc(m: ^View_Boom, msg: any, alloc: mem.Allocator) -> Cmd {
		if _, is_key := msg.(Key_Msg); is_key { m.n += 1 }
		return cmd_nil()
	}
	view_boom_view :: proc(m: View_Boom, alloc: mem.Allocator) -> string {
		if m.n > 0 { panic("view exploded") }
		return fmt.aprintf("count: %d", m.n, allocator = alloc)
	}

	src := input_source_from_bytes(transmute([]u8)string("x"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(View_Boom)
	program_init(&p, View_Boom{}, view_boom_update, view_boom_view)

	err := run(&p, &src, &b)
	pe, panicked := err.(Panicked_Error)
	defer delete(pe.message, context.allocator) // the caller owns it -- see Panicked_Error's own doc comment (tea.odin)
	testing.expect(t, panicked, "a panicking View must surface as Panicked_Error, not a crash")

	// Constraint d's decision, pinned: the loop does not go blank or freeze
	// on the last good frame -- it renders a diagnostic naming the panic
	// before returning, and that diagnostic is what actually reached the
	// output builder (flush_fd < 0 here, so run() accumulates every frame
	// into `b` rather than writing to a real fd -- see flush_frame's own
	// doc comment).
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "view panicked"),
		"the last frame flushed before returning should show a diagnostic, not go blank")
	testing.expect(t, strings.contains(out, "view exploded"),
		"the diagnostic should carry the actual panic message, not a generic placeholder")
}

// Companion to test_program_recovers_from_a_panicking_view: pins the OTHER
// call site guarded_render covers -- run()'s own initial paint, called
// before the mailbox loop (and therefore before apply_msg) ever runs. Panics
// on the very first view() call, with no keypress sent at all, so this can
// only pass if guarded_render's coverage genuinely extends to that call site
// and not just the steady-state one's.
@(test)
test_program_recovers_from_a_panicking_initial_view :: proc(t: ^testing.T) {
	Init_View_Boom :: struct {}
	init_view_boom_update :: proc(m: ^Init_View_Boom, msg: any, alloc: mem.Allocator) -> Cmd {
		return cmd_nil()
	}
	init_view_boom_view :: proc(m: Init_View_Boom, alloc: mem.Allocator) -> string {
		panic("initial view exploded")
	}

	fds: [2]posix.FD
	testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
	read_fd, write_fd := fds[0], fds[1]
	defer posix.close(write_fd)
	defer posix.close(read_fd)

	src, ok := input_source_from_fd(read_fd)
	testing.expect(t, ok, "input_source_from_fd should succeed")
	defer input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Init_View_Boom)
	program_init(&p, Init_View_Boom{}, init_view_boom_update, init_view_boom_view)

	err := run(&p, &src, &b)
	pe, panicked := err.(Panicked_Error)
	defer delete(pe.message, context.allocator) // the caller owns it -- see Panicked_Error's own doc comment (tea.odin)
	testing.expect(t, panicked, "a panicking initial View must surface as Panicked_Error, not a crash, and must not hang waiting for input that never comes")

	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "initial view exploded"),
		"the diagnostic for the initial paint's own panic should still reach the output")
}

// T1 extension: a Cmd's own procedure panicking must NOT force run() to end
// (design decision b, tier1-coverage-decision.md) -- it is delivered as an
// ordinary Panicked_Msg through the mailbox, exactly like any other Cmd
// result, and the APP decides what to do with it. This model quits only once
// it has actually observed the Panicked_Msg, so a clean `err == nil` return
// is only possible if the message genuinely arrived -- proving delivery, not
// just "the process didn't crash".
Cmd_Panic_Model :: struct { got_panic_msg: bool }

panicking_pool_cmd_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	panic("pool cmd exploded")
}

cmd_panic_update :: proc(m: ^Cmd_Panic_Model, msg: any, alloc: mem.Allocator) -> Cmd {
	switch v in msg {
	case Key_Msg:
		return cmd_from(panicking_pool_cmd_run, struct{}{}, context.allocator)
	case Panicked_Msg:
		m.got_panic_msg = true
		return quit_cmd()
	}
	return cmd_nil()
}

cmd_panic_view :: proc(m: Cmd_Panic_Model, alloc: mem.Allocator) -> string { return "" }

@(test)
test_program_survives_a_panicking_cmd :: proc(t: ^testing.T) {
	// A real pipe, not input_source_from_bytes -- same reasoning as
	// test_program_quits_from_an_async_init_cmd_with_no_keypress above:
	// Bytes_Source hits EOF (and closes the mailbox) the instant its one
	// byte is consumed, which can race ahead of the async Panicked_Msg this
	// test needs to actually observe, closing the mailbox before the pool
	// worker's result arrives and giving a false-clean `err == nil` with
	// got_panic_msg still false. An open pipe with nothing further written
	// never produces that spurious EOF; the run only ends via the model's
	// own quit_cmd() once it has genuinely seen the Panicked_Msg.
	fds: [2]posix.FD
	testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
	read_fd, write_fd := fds[0], fds[1]
	defer posix.close(write_fd)
	defer posix.close(read_fd)

	src, ok := input_source_from_fd(read_fd)
	testing.expect(t, ok, "input_source_from_fd should succeed")
	defer input_close(&src)

	one_key := [1]u8{'x'}
	testing.expect(t, posix.write(write_fd, raw_data(one_key[:]), 1) == 1, "write should succeed")

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Cmd_Panic_Model)
	program_init(&p, Cmd_Panic_Model{}, cmd_panic_update, cmd_panic_view)

	err := run(&p, &src, &b)
	testing.expect(t, err == nil, "run should exit cleanly once the app quits in reaction to Panicked_Msg -- a Cmd panic must not force Panicked_Error the way an update/view panic does")
	testing.expect(t, p.model.got_panic_msg, "a panicking pool Cmd must reach update() as a Panicked_Msg, not vanish or hang")
}

// Regression: an init Cmd that resolves to Quit_Msg -- with NO keypress ever
// sent -- must actually end run(). This is the spec's marquee scenario for
// the mailbox-as-single-wait-point design ("an async result updates the view
// with no keypress"), and box()'s zero-size hazard (see cmd_test.odin) broke
// it completely: Quit_Msg is itself `struct {}`, so its boxed `any` compared
// equal to nil and was silently dropped by run_cmd_task's `if msg != nil`
// gate, hanging run() forever on mailbox_recv.
//
// Deliberately uses a real pipe (Fd_Source), NOT input_source_from_bytes:
// Bytes_Source hits EOF the instant its data is exhausted, which closes the
// mailbox and ends the loop for a reason UNRELATED to the async Quit_Msg --
// exactly the false-positive that let this bug hide behind
// test_program_processes_keys_and_quits above (its "aaq" stream hits EOF at
// the same moment quit_cmd() is dispatched, so that test passes via the
// EOF-closes-mailbox path regardless of whether the Quit_Msg round-trip
// works). An open pipe with nothing ever written to it never produces EOF,
// so this test can only pass if the async Quit_Msg is genuinely delivered.
@(test)
test_program_quits_from_an_async_init_cmd_with_no_keypress :: proc(t: ^testing.T) {
	Idle :: struct {}
	idle_update :: proc(m: ^Idle, msg: any, alloc: mem.Allocator) -> Cmd { return cmd_nil() }
	idle_view   :: proc(m: Idle, alloc: mem.Allocator) -> string { return "" }
	quit_now    :: proc(env: rawptr, cancel: ^Cancel_Token) -> any { return box(Quit_Msg{}, context.allocator) }

	fds: [2]posix.FD
	testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
	read_fd, write_fd := fds[0], fds[1]
	defer posix.close(write_fd)
	defer posix.close(read_fd)

	src, ok := input_source_from_fd(read_fd)
	testing.expect(t, ok, "input_source_from_fd should succeed")
	defer input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Idle)
	program_init(&p, Idle{}, idle_update, idle_view,
		Cmd{procedure = quit_now, env = nil, allocator = context.allocator})

	err := run(&p, &src, &b)
	testing.expect(t, err == nil, "run should exit cleanly from an async Quit_Msg with no keypress")
}

// Regression for FIX 1 (final fix-wave report): mailbox_send returned a
// single `bool` for two different conditions -- CLOSED and FULL -- and
// tea.odin's reader thread treated both as terminal, returning WITHOUT
// calling mailbox_close on Full. run()'s main loop then drained whatever was
// already queued and blocked forever in mailbox_recv: no keyboard, no EOF,
// no error, unkillable except by an external signal. Confirmed reproducible
// with an update proc doing nothing but `n += 1`: 500 keys exits cleanly,
// 1000 hangs. This test feeds well past that -- 2000 'a's -- through a
// Bytes_Source, whose reads are instant with no real-tty pacing, so the
// reader thread races far ahead of the one-message-at-a-time main loop and
// reliably overflows the 256-slot mailbox run() allocates internally
// (reader_thread's own buf is 1024 bytes, so the very first read already
// decodes ~1024 keys against that 256-slot cap).
//
// run() itself is what would hang, so it is driven on a background thread
// here and given a generous bounded wait rather than called directly -- a
// regression must FAIL this test observably within a few seconds, not wedge
// the entire suite. (Verified non-vacuous by temporarily reverting just the
// tea.odin half of FIX 1 and re-running this test under `timeout`: it hung
// past the timeout, as expected -- see the final fix-wave report.)
Overflow_Harness :: struct {
	src:  Input_Source,
	b:    strings.Builder,
	err:  Run_Error,
	done: bool,
}

@(test)
test_run_survives_a_mailbox_overflow :: proc(t: ^testing.T) {
	N :: 2000
	data := make([]u8, N + 1); defer delete(data)
	for i in 0 ..< N { data[i] = 'a' }
	data[N] = 'q'   // final key quits, so run() has a defined end if it doesn't hang

	h: Overflow_Harness
	h.src = input_source_from_bytes(data)
	h.b = strings.builder_make()

	th := thread.create(proc(th: ^thread.Thread) {
		h := cast(^Overflow_Harness)th.data
		p: Program(Counter)
		program_init(&p, Counter{}, counter_update, counter_view)
		h.err = run(&p, &h.src, &h.b)
		sync.atomic_store(&h.done, true)
	})
	th.data = &h
	// MUST inherit this thread's context (in particular context.allocator):
	// run() allocates internally (mailbox_init, frame_arena_init, its own
	// reader/pool/watcher threads), and letting it fall back to
	// runtime.default_context() mixes allocators under odin test's
	// Tracking_Allocator -- the exact hazard dispatch()'s own doc comment in
	// cmd.odin documents and guards against for detached Cmds.
	th.init_context = context
	thread.start(th)

	start := time.now()
	timeout :: 5 * time.Second
	for !sync.atomic_load(&h.done) {
		if time.since(start) > timeout {
			testing.expect(t, false,
				"run() did not complete within 5s of a 2000-key burst into a 256-slot mailbox -- "+
				"this is FIX 1's full-vs-closed deadlock (mailbox.odin/tea.odin) regressing")
			// Deliberately do not join: the background thread is wedged
			// inside run()'s mailbox_recv and will never return on its own
			// if this branch is reached. Leaking it here is what makes the
			// failure observable instead of hanging the whole test binary.
			return
		}
		time.sleep(10 * time.Millisecond)
	}

	thread.join(th)
	thread.destroy(th)
	input_close(&h.src)
	strings.builder_destroy(&h.b)

	testing.expect(t, h.err == nil, "run should exit cleanly once the transiently-full mailbox drains")
}

// THE structural fix this whole change exists to make (T1,
// docs/superpowers/cancellation-decision.md): run() must return promptly
// even while a Cmd is still running, instead of blocking in dispatcher_destroy
// until that Cmd finishes -- the addendum's measured "one 2-second Cmd in
// flight -> quit takes 2.000s". This end-to-end test pins the fix at run()'s
// own public boundary, not just at dispatcher_reap's level (cmd_test.odin
// already covers that directly) -- dispatches a 300ms Cmd on the first
// keypress, quits on the second, and asserts run() returns in well under
// 300ms. Non-vacuous: verified by temporarily reverting tea.odin's
// `defer dispatcher_reap(rc, QUIT_GRACE)` back to the original
// `defer dispatcher_destroy(&disp)` + `defer mailbox_destroy(&mbox)` pair and
// re-running -- elapsed then measures >= 300ms and the assertion below fails,
// exactly as expected (see docs/superpowers/cancellation-decision.md for the
// actual recorded numbers, before and after).
Slow_Quit_Env :: struct { finished: ^sync.Sema }

slow_quit_cmd_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	e := cast(^Slow_Quit_Env)env
	time.sleep(300 * time.Millisecond)
	// Signaled purely so this TEST can wait deterministically for the Cmd to
	// actually finish before returning -- see the test's own trailing
	// comment. The Msg itself is expected to be discarded: by the time this
	// Cmd resolves, run() has long since quit and closed the mailbox.
	sync.sema_post(e.finished)
	return box(Empty_Result{}, context.allocator)
}

Slow_Quit_Model :: struct { armed: bool, finished: ^sync.Sema }

slow_quit_update :: proc(m: ^Slow_Quit_Model, msg: any, alloc: mem.Allocator) -> Cmd {
	if _, is_key := msg.(Key_Msg); is_key {
		if !m.armed {
			m.armed = true
			return cmd_from(slow_quit_cmd_run, Slow_Quit_Env{finished = m.finished}, context.allocator)
		}
		return quit_cmd()
	}
	return cmd_nil()
}

slow_quit_view :: proc(m: Slow_Quit_Model, alloc: mem.Allocator) -> string { return "" }

@(test)
test_run_returns_promptly_with_a_slow_cmd_still_in_flight :: proc(t: ^testing.T) {
	finished: sync.Sema

	// "aq": 'a' dispatches the 300ms Cmd (first keypress), 'q' quits
	// (second) -- both already queued by the reader thread well before the
	// Cmd has any chance to finish, so it is still genuinely running when
	// run()'s main loop breaks out on Quit_Msg.
	src := input_source_from_bytes(transmute([]u8)string("aq"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Slow_Quit_Model)
	program_init(&p, Slow_Quit_Model{finished = &finished}, slow_quit_update, slow_quit_view)

	start := time.now()
	err := run(&p, &src, &b)
	elapsed := time.since(start)

	testing.expect(t, err == nil, "run should exit cleanly")
	testing.expectf(t, elapsed < 200 * time.Millisecond,
		"run() should return well before its 300ms Cmd finishes (QUIT_GRACE is 100ms) -- took %v", elapsed)

	// Let the Cmd itself finish, and give the trailing background teardown
	// (dispatcher_destroy + mailbox_destroy + free inside the reaper thread
	// dispatcher_reap spawned) a fixed margin, before this test function
	// returns: the SAME per-task Tracking_Allocator hazard
	// test_dispatcher_reap_does_not_block_the_caller documents (cmd_test.odin)
	// applies here too, one level up, since run() now tears its Dispatcher/
	// Mailbox down through that identical path.
	sync.sema_wait(&finished)
	time.sleep(150 * time.Millisecond)
}

// T1-K, end to end: the terminal's answer to term_enter_raw's keyboard query
// has to reach update() as a Msg, not just be understood by the decoder.
// It travels a different path from a Key_Msg -- decode_keys reports it on a
// second output stream, and BOTH event-loop hosts have to box and forward it --
// so it is exercised through run() and run_nbio() alike here.
Enh_Model :: struct { seen: int, flags: Kitty_Flags, keys: int }

enh_update :: proc(m: ^Enh_Model, msg: any, alloc: mem.Allocator) -> Cmd {
	switch v in msg {
	case Keyboard_Enhancements_Msg:
		m.seen += 1
		m.flags = v.flags
	case Key_Msg:
		m.keys += 1
		if v.code == .Rune && v.r == 'q' { return quit_cmd() }
	}
	return cmd_nil()
}

enh_view :: proc(m: Enh_Model, alloc: mem.Allocator) -> string { return "" }

@(test)
test_keyboard_enhancements_msg_reaches_update :: proc(t: ^testing.T) {
	// CSI ? 3 u -- "disambiguation and event types are on" -- then a keypress
	// to end the session. The key is there to prove the reply does not swallow
	// what follows it.
	script := "\e[?3uq"
	want := Kitty_Flags{.Disambiguate, .Report_Event_Types}

	{
		fds: [2]posix.FD
		testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
		posix.write(fds[1], raw_data(script), len(script))
		posix.close(fds[1])

		src, ok := input_source_from_fd(fds[0])
		testing.expect(t, ok, "input_source_from_fd should succeed")
		b := strings.builder_make(); defer strings.builder_destroy(&b)

		p: Program(Enh_Model)
		program_init(&p, Enh_Model{}, enh_update, enh_view)
		err := run(&p, &src, &b)
		input_close(&src)
		posix.close(fds[0])

		testing.expect(t, err == nil, "run should exit cleanly")
		testing.expectf(t, p.model.seen == 1, "run(): update saw %d enhancement msgs, want 1", p.model.seen)
		testing.expectf(t, p.model.flags == want, "run(): flags %v, want %v", p.model.flags, want)
		testing.expectf(t, p.model.keys == 1, "run(): update saw %d keys, want 1", p.model.keys)
	}

	{
		fds: [2]posix.FD
		testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
		posix.write(fds[1], raw_data(script), len(script))
		posix.close(fds[1])

		b := strings.builder_make(); defer strings.builder_destroy(&b)
		p: Program(Enh_Model)
		program_init(&p, Enh_Model{}, enh_update, enh_view)
		err := run_nbio(&p, fds[0], &b)
		posix.close(fds[0])

		testing.expect(t, err == nil, "run_nbio should exit cleanly")
		testing.expectf(t, p.model.seen == 1, "run_nbio(): update saw %d enhancement msgs, want 1", p.model.seen)
		testing.expectf(t, p.model.flags == want, "run_nbio(): flags %v, want %v", p.model.flags, want)
		testing.expectf(t, p.model.keys == 1, "run_nbio(): update saw %d keys, want 1", p.model.keys)
	}
}

// T1-L, end to end: a paste has to reach update() as Paste_Start_Msg, the
// pasted characters, then Paste_End_Msg -- IN THAT ORDER. Order is the whole
// reason decode_keys reports paste boundaries as POSITIONED markers rather
// than on a second unordered stream the way it reports the keyboard-
// enhancement reply: an app that switches into a bulk-insert mode on
// Paste_Start needs the message before the first pasted character, not after
// the last. Both event-loop hosts have to interleave them, so both are driven
// here.
Paste_Log_Model :: struct {
	log: [64]u8,
	n:   int,
}

@(private = "file")
paste_log :: proc(m: ^Paste_Log_Model, ch: u8) {
	if m.n < len(m.log) { m.log[m.n] = ch; m.n += 1 }
}

paste_log_update :: proc(m: ^Paste_Log_Model, msg: any, alloc: mem.Allocator) -> Cmd {
	switch v in msg {
	case Paste_Start_Msg: paste_log(m, 'S')
	case Paste_End_Msg:   paste_log(m, 'E')
	case Key_Msg:
		if v.pasted {
			paste_log(m, 'p')
		} else {
			paste_log(m, 'k')
			if v.code == .Rune && v.r == 'q' { return quit_cmd() }
		}
	}
	return cmd_nil()
}

paste_log_view :: proc(m: Paste_Log_Model, alloc: mem.Allocator) -> string { return "" }

@(test)
test_bracketed_paste_reaches_update_in_order :: proc(t: ^testing.T) {
	// A normal key, then a paste whose content contains an arrow sequence and a
	// newline (neither may become Up or Enter), then a normal key that quits.
	script := "a\e[200~x\e[A\ny\e[201~q"
	want   := "kSppppppEk"   // k S p(x) p(ESC) p([) p(A) p(\n) p(y) E k(q)

	{
		fds: [2]posix.FD
		testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
		posix.write(fds[1], raw_data(script), len(script))
		posix.close(fds[1])

		src, ok := input_source_from_fd(fds[0])
		testing.expect(t, ok, "input_source_from_fd should succeed")
		b := strings.builder_make(); defer strings.builder_destroy(&b)

		p: Program(Paste_Log_Model)
		program_init(&p, Paste_Log_Model{}, paste_log_update, paste_log_view)
		err := run(&p, &src, &b)
		input_close(&src)
		posix.close(fds[0])

		testing.expect(t, err == nil, "run should exit cleanly")
		testing.expectf(t, string(p.model.log[:p.model.n]) == want,
			"run(): update saw %q, want %q", string(p.model.log[:p.model.n]), want)
	}

	{
		fds: [2]posix.FD
		testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
		posix.write(fds[1], raw_data(script), len(script))
		posix.close(fds[1])

		b := strings.builder_make(); defer strings.builder_destroy(&b)
		p: Program(Paste_Log_Model)
		program_init(&p, Paste_Log_Model{}, paste_log_update, paste_log_view)
		err := run_nbio(&p, fds[0], &b)
		posix.close(fds[0])

		testing.expect(t, err == nil, "run_nbio should exit cleanly")
		testing.expectf(t, string(p.model.log[:p.model.n]) == want,
			"run_nbio(): update saw %q, want %q", string(p.model.log[:p.model.n]), want)
	}
}

// T2-B, end to end: a mouse report and a focus event have to reach update() IN
// THEIR PLACE in the key stream, not bolted on at the end of the batch. That is
// the whole reason decode_keys reports them as POSITIONED markers on the same
// list bracketed paste uses (input.odin's Input_Marker) rather than on a second
// unordered stream the way it reports the keyboard-enhancement reply: a user
// who clicks to place the caret and then types expects the click first, and one
// 1024-byte read can hold both. Both event-loop hosts have to interleave them,
// so both are driven here.
//
// The script also mixes the two mouse encodings deliberately -- SGR for the
// click, legacy/X10 for the release, with an 0x1B in the legacy payload -- so
// this exercises the whole path a real terminal drives, including the three raw
// bytes that are not CSI grammar.
Mouse_Log_Model :: struct {
	log: [64]u8,
	n:   int,
	// The last click's coordinates, so this proves the decoded VALUES survive
	// the box/mailbox round trip and not merely that a message of the right
	// type arrived.
	x, y: int,
}

@(private = "file")
mouse_log :: proc(m: ^Mouse_Log_Model, ch: u8) {
	if m.n < len(m.log) { m.log[m.n] = ch; m.n += 1 }
}

mouse_log_update :: proc(m: ^Mouse_Log_Model, msg: any, alloc: mem.Allocator) -> Cmd {
	switch v in msg {
	case Focus_Msg: mouse_log(m, 'F')
	case Blur_Msg:  mouse_log(m, 'B')
	case Mouse_Msg:
		switch v.kind {
		case .Press:   mouse_log(m, 'P'); m.x, m.y = v.x, v.y
		case .Release: mouse_log(m, 'R')
		case .Motion:  mouse_log(m, 'M')
		case .Wheel:   mouse_log(m, 'W')
		}
	case Key_Msg:
		mouse_log(m, 'k')
		if v.code == .Rune && v.r == 'q' { return quit_cmd() }
	}
	return cmd_nil()
}

mouse_log_view :: proc(m: Mouse_Log_Model, alloc: mem.Allocator) -> string { return "" }

@(test)
test_mouse_and_focus_reach_update_in_order :: proc(t: ^testing.T) {
	// key, SGR press at (10,5), key, legacy release (with 0x1B as the Cy byte),
	// wheel up, focus in, focus out, then the quit key.
	script := "a\e[<0;10;5Mb\e[M#*\e\e[<64;1;1M\e[I\e[Oq"
	want   := "kPkRWFBk"

	{
		fds: [2]posix.FD
		testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
		posix.write(fds[1], raw_data(script), len(script))
		posix.close(fds[1])

		src, ok := input_source_from_fd(fds[0])
		testing.expect(t, ok, "input_source_from_fd should succeed")
		b := strings.builder_make(); defer strings.builder_destroy(&b)

		p: Program(Mouse_Log_Model)
		program_init(&p, Mouse_Log_Model{}, mouse_log_update, mouse_log_view)
		err := run(&p, &src, &b)
		input_close(&src)
		posix.close(fds[0])

		testing.expect(t, err == nil, "run should exit cleanly")
		testing.expectf(t, string(p.model.log[:p.model.n]) == want,
			"run(): update saw %q, want %q", string(p.model.log[:p.model.n]), want)
		testing.expectf(t, p.model.x == 9 && p.model.y == 4,
			"run(): the click landed at (%d,%d), want (9,4)", p.model.x, p.model.y)
	}

	{
		fds: [2]posix.FD
		testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
		posix.write(fds[1], raw_data(script), len(script))
		posix.close(fds[1])

		b := strings.builder_make(); defer strings.builder_destroy(&b)
		p: Program(Mouse_Log_Model)
		program_init(&p, Mouse_Log_Model{}, mouse_log_update, mouse_log_view)
		err := run_nbio(&p, fds[0], &b)
		posix.close(fds[0])

		testing.expect(t, err == nil, "run_nbio should exit cleanly")
		testing.expectf(t, string(p.model.log[:p.model.n]) == want,
			"run_nbio(): update saw %q, want %q", string(p.model.log[:p.model.n]), want)
		testing.expectf(t, p.model.x == 9 && p.model.y == 4,
			"run_nbio(): the click landed at (%d,%d), want (9,4)", p.model.x, p.model.y)
	}
}

// T2-C: a resize must update BOTH renderer dimensions, through the real
// apply_msg() path rather than by calling renderer_set_* directly -- the height
// half is new, and the thing that could plausibly break is the wiring in
// apply_msg, not the setter. Driven with a boxed Window_Size_Msg because that is
// exactly what signals.odin's SIGWINCH branch puts in the mailbox (apply_msg
// box_free's it).
@(test)
test_window_size_msg_updates_both_renderer_dimensions :: proc(t: ^testing.T) {
	fa: Frame_Arena
	testing.expect(t, frame_arena_init(&fa) == nil, "frame arena init should succeed")
	defer frame_arena_destroy(&fa)

	mbox: Mailbox
	testing.expect(t, mailbox_init(&mbox, 8) == nil, "mailbox init should succeed")
	defer mailbox_destroy(&mbox)
	disp: Dispatcher
	dispatcher_init(&disp, &mbox, 1)
	defer dispatcher_destroy(&disp)

	b := strings.builder_make(); defer strings.builder_destroy(&b)
	r: Renderer
	renderer_init(&r, &b, 20, 5, .Full_Screen)

	p: Program(Counter)
	program_init(&p, Counter{}, counter_update, counter_view)

	apply_msg(&p, box(Window_Size_Msg{w = 80, h = 24}, context.allocator), &fa, &disp, &r)
	testing.expect_value(t, r.term_width, 80)
	testing.expect_value(t, r.term_height, 24)

	// signals.odin's "the ioctl failed" sentinel is w == h == 0, and it must not
	// clobber a previously-known-good size -- the same rule the width has always
	// followed, now asserted for the height as well.
	apply_msg(&p, box(Window_Size_Msg{w = 0, h = 0}, context.allocator), &fa, &disp, &r)
	testing.expect_value(t, r.term_width, 80)
	testing.expect_value(t, r.term_height, 24)
}

// ============================================================================
// BUG 1: flush_frame was a single, unlooped posix.write whose result was
// discarded.
//
// write(2) may transfer fewer bytes than asked and report success. The tail of
// the frame was then silently dropped -- possibly MID-ESCAPE-SEQUENCE, leaving
// the terminal reading the next frame's bytes as arguments to a sequence that
// was never finished. term.odin's sticky cursor_hidden flag existed partly to
// work around this exact call.
//
// FORCING A SHORT WRITE. A pipe whose write end is O_NONBLOCK returns a PARTIAL
// count once its (64 KiB by default) buffer fills, rather than blocking -- which
// is precisely the shape of the real hazard on a congested tty. Writing a
// quarter of a megabyte through one guarantees it.
// ============================================================================

@(private = "file")
Drain_Ctx :: struct {
	fd:   posix.FD,
	got:  [dynamic]u8,
	want: int,
}

// Reads until EOF, until `want` bytes have arrived, or until the writer has
// been silent for a second -- so that a FAILING run reports a byte count
// instead of hanging the suite.
@(private = "file")
drain_body :: proc(th: ^thread.Thread) {
	dc := cast(^Drain_Ctx)th.data
	buf: [4096]u8
	for len(dc.got) < dc.want {
		pfd := posix.pollfd{fd = dc.fd, events = {.IN}}
		if posix.poll(&pfd, 1, 1000) <= 0 { return }   // timeout or error: stop
		n := posix.read(dc.fd, raw_data(buf[:]), len(buf))
		if n <= 0 { return }                            // EOF or error: stop
		append(&dc.got, ..buf[:n])
	}
}

@(test)
test_flush_frame_writes_the_whole_frame_through_a_short_writing_fd :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	if !testing.expect(t, posix.pipe(&fds) == .OK, "could not open a pipe") { return }
	defer posix.close(fds[0])

	// Non-blocking WRITE end: once the pipe buffer is full, write(2) transfers
	// what it can and returns that count instead of blocking. That is the short
	// write, delivered on demand.
	fl := transmute(posix.O_Flags)posix.fcntl(fds[1], .GETFL)
	posix.fcntl(fds[1], .SETFL, fl + {.NONBLOCK})

	// A quarter of a megabyte -- comfortably past any pipe buffer. The content
	// is a repeating pattern so a truncation anywhere is a length mismatch, and
	// the payload is deliberately made of escape sequences: dropping the tail of
	// THIS frame cuts an escape in half, which is the failure the fix is for.
	frame := strings.builder_make(); defer strings.builder_destroy(&frame)
	for i in 0 ..< 16384 {
		strings.write_string(&frame, "\e[1;31mxxxxxxxx\e[0m")
		_ = i
	}
	want := strings.builder_len(frame)
	testing.expect(t, want > 128 * 1024, "the frame must be bigger than any pipe buffer")

	dc := Drain_Ctx{fd = fds[0], want = want}
	defer delete(dc.got)
	th := thread.create(drain_body)
	defer thread.destroy(th)
	th.data = &dc
	th.init_context = context
	thread.start(th)

	expected := strings.clone(strings.to_string(frame)); defer delete(expected)

	err := flush_frame(&frame, fds[1])
	testing.expectf(t, err == nil, "flush_frame reported %v on a healthy pipe", err)

	posix.close(fds[1])   // EOF, so the reader stops without waiting out its poll
	thread.join(th)

	// THE ASSERTION THE BUG FAILS: with one unlooped write only the first
	// pipe-buffer's worth ever arrives.
	testing.expectf(t, len(dc.got) == want,
		"flush_frame delivered %d of %d bytes -- the tail of the frame was dropped", len(dc.got), want)
	testing.expect(t, string(dc.got[:]) == expected, "the delivered bytes are not the frame")

	// And the builder is emptied exactly once, whatever happened.
	testing.expect_value(t, strings.builder_len(frame), 0)
}

// The other half of the policy: a write that CANNOT succeed must end the
// session with a diagnosis, not spin and not crash. Writing to a read-only fd
// fails with EBADF every time, on every platform, with no signal involved
// (unlike a closed pipe, whose EPIPE is preceded by a SIGPIPE that would kill
// the test runner).
@(test)
test_write_all_reports_an_unrecoverable_error_with_its_errno :: proc(t: ^testing.T) {
	fd := posix.open("/dev/null", {})   // RDONLY is the default/zero flag set
	if !testing.expect(t, fd >= 0, "could not open /dev/null") { return }
	defer posix.close(fd)

	err := write_all(fd, "\e[?25l")
	te, is_terminal := err.(Terminal_Error)
	if !testing.expectf(t, is_terminal, "a failed write must surface as Terminal_Error, got %v", err) { return }
	// The errno is the whole point of carrying one: "write failed" cannot be
	// acted on, "write failed: EBADF" can.
	testing.expect_value(t, te.errno, posix.Errno.EBADF)
	testing.expect(t, te.detail != "", "a Terminal_Error must say what failed")
}

// THE ERROR MUST REACH THE APPLICATION, not merely exist. flush_frame's
// Terminal_Error is only worth returning if run() actually propagates it, so
// this drives a whole session against an unwritable flush fd and asserts on
// what run() hands back. Without the propagation the session would go on
// painting frames nobody receives, forever, which is the silent-degradation
// failure this codebase refuses.
@(test)
test_run_ends_with_a_terminal_error_when_the_frame_cannot_be_written :: proc(t: ^testing.T) {
	// run() starts a Signal_Watcher whenever flush_fd >= 0, which blocks
	// RuneTea's signals on THIS pool worker for the rest of the suite -- see
	// signals_test.odin's own note. Undo it on the way out.
	defer signal_unblock_for_child()

	// Read-only: every write to it fails with EBADF, deterministically and with
	// no signal involved.
	null_ro := posix.open("/dev/null", {})
	if !testing.expect(t, null_ro >= 0, "could not open /dev/null") { return }
	defer posix.close(null_ro)

	// run() returns from the initial paint, before the reader thread exists, so
	// nothing ever closes this source on its own -- hence the explicit close,
	// same as every other run()-based test in this file.
	src := input_source_from_bytes(transmute([]u8)string("q"))
	defer input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)
	p: Program(Counter)
	program_init(&p, Counter{}, counter_update, counter_view)

	err := run(&p, &src, &b, null_ro)
	te, is := err.(Terminal_Error)
	if !testing.expectf(t, is, "expected a Terminal_Error out of run(), got %v", err) { return }
	testing.expect_value(t, te.errno, posix.Errno.EBADF)
}

// ============================================================================
// FRAME COALESCING (run()).
//
// run() used to be `for !p.quit { msg := mailbox_recv(); apply(msg) }` with
// apply() rendering and flushing unconditionally: one full view + render +
// write(2) PER MESSAGE. A paste is delivered by a real terminal as a single
// write(2) of hundreds of bytes, so the output amplification was brutal --
// 1,332 bytes in produced 1,045,721 bytes out over ~1,700 syscalls on the
// probe in scratchpad/scratch-frames/amp. See apply_msg's own comment for the
// full table.
//
// The two properties the fix has to hold simultaneously are asserted together
// here on purpose, because either one alone is trivially satisfiable by a
// broken implementation: paint fewer frames (drop messages -> passes), and
// deliver every message in order (paint per message -> passes).
// ============================================================================

Burst_Log :: struct {
	seen: strings.Builder,
	done: bool,
}

burst_update :: proc(m: ^Burst_Log, msg: any, alloc: mem.Allocator) -> Cmd {
	if v, is_key := msg.(Key_Msg); is_key {
		if v.code == .Rune && v.r == '!' { m.done = true; return quit_cmd() }
		if v.code == .Rune { strings.write_rune(&m.seen, v.r) }
	}
	return cmd_nil()
}

// One "<n>" token per frame, so counting frames in the accumulated builder is
// a substring count rather than an escape-sequence parse.
burst_view :: proc(m: Burst_Log, alloc: mem.Allocator) -> string {
	return fmt.aprintf("<%d>", strings.builder_len(m.seen), allocator = alloc)
}

@(test)
test_run_coalesces_a_burst_into_far_fewer_frames_without_losing_a_message :: proc(t: ^testing.T) {
	N :: 200
	payload := strings.builder_make(); defer strings.builder_destroy(&payload)
	for i in 0 ..< N { strings.write_rune(&payload, rune('a' + i % 26)) }
	want := strings.clone(strings.to_string(payload)); defer delete(want)
	strings.write_rune(&payload, '!')   // the quit key

	src := input_source_from_bytes(transmute([]u8)strings.to_string(payload))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Burst_Log)
	program_init(&p, Burst_Log{seen = strings.builder_make()}, burst_update, burst_view)
	// The MODEL's builder, not the local it was copied from: update() writes
	// through p.model, so p.model.seen owns whatever buffer the appends grew
	// into and the local's original 16-byte one is long gone.
	defer strings.builder_destroy(&p.model.seen)

	err := run(&p, &src, &b)
	testing.expect(t, err == nil, "run should exit cleanly")

	// EVERY message, IN ORDER. Coalescing is about paints, not messages.
	testing.expectf(t, strings.to_string(p.model.seen) == want,
		"update() did not see all %d keys in order -- got %d chars: %q",
		N, strings.builder_len(p.model.seen), strings.to_string(p.model.seen))
	testing.expect(t, p.model.done, "model should have observed the quit key")

	// One frame per message would be N + 2 (the initial paint, N keys, and the
	// quit key -- Quit_Msg itself never painted a frame of its own). The
	// threshold is deliberately loose rather than an exact count: how many
	// batches the reader thread's single 201-byte read is split into is a
	// scheduling question, not a contract, and a test that pinned it exactly
	// would be a flake generator. What IS a contract is the order of
	// magnitude: a burst that arrives in one read() must not cost one frame
	// per key.
	frames := strings.count(strings.to_string(b), "<")
	testing.expectf(t, frames <= 20,
		"run() painted %d frames for a %d-key burst delivered in one read (pre-coalescing: %d) -- frames are not being coalesced",
		frames, N, N + 2)
	testing.expectf(t, frames >= 1, "run() painted %d frames -- it must still paint", frames)
}

// The `dirty` rule, pinned: a message that never reaches update() must not
// cause a paint. Quit_Msg and Interrupt_Msg are both handled before update()
// in apply_msg, and painting on them would append a duplicate of the frame
// already on screen to the end of every session -- a visibly repeated block in
// .Inline mode, and a wasted view + render + write(2) in all three.
//
// A single '!' is the whole script, and that makes the assertion exact rather
// than a bound. '!' reaches update (it returns quit_cmd()), so it paints, but
// it writes nothing to the log, so the frame it paints is another <0>. The
// Quit_Msg the dispatched Cmd then produces arrives in a batch of its own --
// it comes off a pool thread after update has already returned -- and must add
// no third frame. Even in the case where it did coalesce into the same batch
// the answer is still exactly two frames, so this pins the rule without
// depending on scheduling either way.
@(test)
test_a_quit_msg_adds_no_frame_of_its_own :: proc(t: ^testing.T) {
	src := input_source_from_bytes(transmute([]u8)string("!"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Burst_Log)
	program_init(&p, Burst_Log{seen = strings.builder_make()}, burst_update, burst_view)
	// The MODEL's builder, not the local it was copied from: update() writes
	// through p.model, so p.model.seen owns whatever buffer the appends grew
	// into and the local's original 16-byte one is long gone.
	defer strings.builder_destroy(&p.model.seen)

	testing.expect(t, run(&p, &src, &b) == nil, "run should exit cleanly")
	testing.expect(t, p.model.done, "model should have observed the quit key")

	// The initial paint, then the frame '!' produced, and nothing else --
	// .Inline's one-row rewind between them.
	testing.expect_value(t, strings.to_string(b), "<0>\r\n\e[1A\e[2K<0>\r\n")
}

// The crash guard has to survive the update/paint split. apply_msg keeps the
// update guard; guarded_render keeps the view guard; they were already two
// SEQUENTIAL guarded() calls rather than a nested pair, so moving the second
// out to the caller must change nothing -- including when the panic lands in
// the MIDDLE of a coalesced batch, which is the case that did not exist before
// (there was no such thing as a batch).
//
// "aXq": 'a' is applied, 'X' panics, 'q' is never applied. The frame that
// would have shown 'a' is deliberately never painted -- the batch did not
// complete and run() is returning Panicked_Error.
Boom_Mid :: struct { seen: int }

boom_mid_update :: proc(m: ^Boom_Mid, msg: any, alloc: mem.Allocator) -> Cmd {
	if v, is_key := msg.(Key_Msg); is_key {
		if v.code == .Rune && v.r == 'X' { panic("update exploded mid-batch") }
		m.seen += 1
	}
	return cmd_nil()
}

boom_mid_view :: proc(m: Boom_Mid, alloc: mem.Allocator) -> string { return "" }

@(test)
test_a_panic_midway_through_a_coalesced_batch_still_recovers :: proc(t: ^testing.T) {
	src := input_source_from_bytes(transmute([]u8)string("aXq"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Boom_Mid)
	program_init(&p, Boom_Mid{}, boom_mid_update, boom_mid_view)

	err := run(&p, &src, &b)
	pe, panicked := err.(Panicked_Error)
	defer delete(pe.message, context.allocator)   // the caller owns it -- Panicked_Error's own doc comment
	testing.expect(t, panicked, "a panicking update inside a coalesced batch must still surface as Panicked_Error")
	testing.expectf(t, p.model.seen == 1,
		"the message BEFORE the panicking one must still have been applied -- update saw %d, want 1", p.model.seen)
}

// ============================================================================
// F17: run() returning while a background reaper still owns the caller's
// allocations, with no signal.
// ============================================================================

// `defer dispatcher_reap(rc, QUIT_GRACE)` discarded the bool that says whether
// teardown actually finished. When it did not, run() returned nil while a
// DETACHED reaper thread was still freeing ~7 KiB across ~17 allocations made
// through the caller's context.allocator -- and a caller that scopes an
// allocator to the run() call and reclaims it on the next line gets a
// deterministic SIGSEGV, not a phantom leak report. Program.reaper_pending is
// the signal; this is the test that it is set, and the one below that it is
// NOT set in the common case (a bool that is always true would be useless).
//
// Reuses Slow_Quit_Model above: 'a' dispatches a 300 ms Cmd, 'q' quits. 300 ms
// is comfortably past QUIT_GRACE (100 ms), so the reap is guaranteed to time
// out.
@(test)
test_run_reports_a_pending_reaper_when_a_cmd_outlives_the_grace :: proc(t: ^testing.T) {
	finished: sync.Sema

	src := input_source_from_bytes(transmute([]u8)string("aq"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Slow_Quit_Model)
	program_init(&p, Slow_Quit_Model{finished = &finished}, slow_quit_update, slow_quit_view)

	testing.expect(t, run(&p, &src, &b) == nil, "run should exit cleanly")
	testing.expect(t, p.reaper_pending,
		"run() returned with a 300ms Cmd still in flight past the 100ms grace -- reaper_pending must say so, "+
		"or the caller has no way to know its allocator is still in use")

	// Same trailing wait test_run_returns_promptly_with_a_slow_cmd_still_in_
	// flight documents: let the Cmd and the background teardown finish before
	// odin test rotates this task's Tracking_Allocator.
	sync.sema_wait(&finished)
	time.sleep(150 * time.Millisecond)
}

@(test)
test_run_reports_no_pending_reaper_when_nothing_is_in_flight :: proc(t: ^testing.T) {
	src := input_source_from_bytes(transmute([]u8)string("aaq"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Counter)
	program_init(&p, Counter{}, counter_update, counter_view)

	testing.expect(t, run(&p, &src, &b) == nil, "run should exit cleanly")
	testing.expect(t, !p.reaper_pending,
		"teardown was fully synchronous here -- reaper_pending must be false, or it says nothing useful when it is true")
}

// ============================================================================
// F31: a finished session has to be able to become a process exit status.
// ============================================================================

// Every shipped example ended `if err := rt.run(...); err != nil {
// fmt.eprintln("error:", err) }` and then fell off the end of main, so a
// Terminal_Error or a Panicked_Error exited 0 -- indistinguishable from a
// clean quit to any supervisor or CI job, and (because stderr may have gone to
// the alternate screen the terminal then discarded) possibly invisible to the
// human too. exit_code is the affordance that makes the right shape one call.
//
// The mapping is asserted exhaustively, including nil, because the failure
// this fixes is precisely a variant silently coming out as 0.
@(test)
test_exit_code_maps_every_run_error_to_a_nonzero_status :: proc(t: ^testing.T) {
	nothing: Run_Error
	testing.expect_value(t, exit_code(nothing), 0)
	testing.expect_value(t, exit_code(Interrupted_Error{}), 130)
	testing.expect_value(t, exit_code(Panicked_Error{message = "boom"}), 1)
	testing.expect_value(t, exit_code(Terminal_Error{detail = "gone"}), 1)
	testing.expect_value(t, exit_code(Killed_Error{}), 1)
}

// ============================================================================
// The reader thread owns the message it is holding until the mailbox takes it.
//
// reader_send's `case .Closed: return true` dropped that message on the floor:
// mailbox_send returns .Closed WITHOUT storing anything, so the box() the
// reader made a line earlier had no owner left and nothing ever freed it.
// cmd.odin's run_cmd_task and run_cmd_detached already box_free on the
// identical outcome, with a comment saying why it is safe; this was the third
// consumer, and the only one that owed the free and did not pay it.
//
// The window is small but completely ordinary: any session that quits while
// more input is still queued. The script here makes it deterministic -- the
// FIRST key quits and 2,000 more follow, so run()'s teardown is guaranteed to
// close the mailbox while the reader is mid-burst.
//
// Counted through a local Tracking_Allocator rather than left to odin test's
// per-task one, the same way timer_test.odin's timer_leak_count does it, and
// filtered to arena.odin because box() is the only thing that allocates there:
// every boxed Msg a session creates must be gone by the time run() returns.
// dispatcher_reap's one documented ^Thread leak lives in cmd.odin/thread_unix
// and is deliberately not counted.
@(private = "file")
box_leak_count :: proc(track: ^mem.Tracking_Allocator) -> int {
	n := 0
	for _, entry in track.allocation_map {
		if strings.contains(entry.location.file_path, "arena.odin") { n += 1 }
	}
	return n
}

Reader_Drop_Harness :: struct {
	src:  Input_Source,
	b:    strings.Builder,
	err:  Run_Error,
	done: bool,
}

@(test)
test_the_reader_frees_the_message_it_still_holds_when_the_mailbox_closes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	N :: 2000
	data := make([]u8, N + 1); defer delete(data)
	data[0] = 'q'                                  // quits immediately
	for i in 1 ..= N { data[i] = 'a' }             // ... with 2,000 keys still to come

	h: Reader_Drop_Harness
	h.src = input_source_from_bytes(data)

	{
		context.allocator = mem.tracking_allocator(&track)
		h.b = strings.builder_make()

		th := thread.create(proc(th: ^thread.Thread) {
			h := cast(^Reader_Drop_Harness)th.data
			p: Program(Counter)
			program_init(&p, Counter{}, counter_update, counter_view)
			h.err = run(&p, &h.src, &h.b)
			sync.atomic_store(&h.done, true)
		})
		th.data = &h
		th.init_context = context   // see Overflow_Harness for why this must be inherited
		thread.start(th)

		start := time.now()
		timeout :: 5 * time.Second
		for !sync.atomic_load(&h.done) {
			if time.since(start) > timeout {
				testing.expect(t, false, "run() did not complete within 5s")
				return
			}
			time.sleep(10 * time.Millisecond)
		}
		thread.join(th)
		thread.destroy(th)
		strings.builder_destroy(&h.b)
	}
	input_close(&h.src)

	testing.expect(t, h.err == nil, "run should exit cleanly")
	testing.expectf(t, box_leak_count(&track) == 0,
		"%d boxed Msg allocation(s) outlived run() -- the reader dropped what it was holding when the mailbox closed",
		box_leak_count(&track))
}

// ============================================================================
// F53, the renderer half: a session at a terminal that declares no
// capabilities must paint no escape sequences.
//
// term_enter_raw's opt-ins were gated on term_supports_escapes() by the
// term-guard wave, and the verdict is asserted for them in term_test.odin. This
// asserts the other half, end to end through run(), because the gate is wired
// in guarded_render rather than in renderer_init (see Renderer.plain for why)
// and a field nobody sets is a field that does nothing.
// ============================================================================

// Local copies of term_test.odin's helpers, which are @(private="file") there.
// A second three-line copy is cheaper than widening that file's surface, and
// these are the whole of the coupling: the value of TERM, and putting it back.
@(private = "file")
save_term :: proc() -> (val: string, had: bool) {
	v := libc.getenv("TERM")
	if v == nil { return "", false }
	return strings.clone(string(v)), true
}

@(private = "file")
set_term :: proc(v: string) {
	cv := strings.clone_to_cstring(v)
	defer delete(cv)
	posix.setenv("TERM", cv, true)
}

@(private = "file")
restore_term :: proc(val: string, had: bool) {
	defer delete(val)
	if !had {
		posix.unsetenv("TERM")
		return
	}
	set_term(val)
}

@(private = "file")
run_counter_script :: proc(script: string) -> string {
	src := input_source_from_bytes(transmute([]u8)script)
	defer input_close(&src)
	b := strings.builder_make()

	p: Program(Counter)
	program_init(&p, Counter{}, counter_update, counter_view)
	_ = run(&p, &src, &b)
	return strings.to_string(b)
}

@(test)
test_a_dumb_terminal_gets_a_session_with_no_escape_sequences :: proc(t: ^testing.T) {
	saved, had := save_term()
	defer restore_term(saved, had)

	// The control first, and it matters: it proves the assertion below is about
	// TERM and not about this script simply never producing an escape. "aaq"
	// is the golden session -- two increments then a quit -- so the capable
	// terminal sees .Inline's rewind pair between the two frames.
	set_term("xterm-256color")
	capable := run_counter_script("aaq")
	defer delete(capable)
	testing.expectf(t, strings.contains(capable, "\e[1A\e[2K"),
		"the control must actually rewind, or the dumb case proves nothing; got %q", capable)

	for term in ([?]string{"dumb", ""}) {
		set_term(term)
		got := run_counter_script("aaq")
		defer delete(got)
		testing.expectf(t, !strings.contains(got, "\e"),
			"TERM=%q: run() painted %q -- a terminal that declares no capabilities must see no ESC at all", term, got)
		// Not merely escape-free: still a correct transcript, with the frames
		// APPENDED because the rewind that would have replaced them is itself
		// the thing that may not be written.
		testing.expectf(t, got == "count: 0\r\ncount: 2\r\n",
			"TERM=%q: the frames must still be the views, in order; got %q", term, got)
	}

	posix.unsetenv("TERM")
	none := run_counter_script("aaq")
	defer delete(none)
	testing.expectf(t, !strings.contains(none, "\e"),
		"no TERM at all: run() painted %q", none)
}

// ============================================================================
// F08: a Cmd that breaks the MESSAGE OWNERSHIP CONTRACT must not be a silent
// no-op.
//
// box() refuses a non-POD Msg with a panic; that panic is raised on a pool
// worker, recovered by run_cmd_guarded, and demoted to a Panicked_Msg. This
// model has NO `case Panicked_Msg` -- which is exactly the shape of every
// shipped example, and of README.md's canonical update switch, whose
// `case rt.Panicked_Msg:` has an empty body. Before the escalation in
// apply_msg the Cmd's result simply never arrived: run() returned nil, the
// process exited 0, and nothing anywhere named the offending type.
// ============================================================================

Bad_Payload_Msg :: struct { reason: string }   // a `string` field: not POD, on purpose

@(private = "file")
non_pod_cmd_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	return box(Bad_Payload_Msg{reason = "this cannot be a Msg"}, context.allocator)
}

@(private = "file")
non_pod_update :: proc(m: ^Counter, msg: any, alloc: mem.Allocator) -> Cmd {
	// Deliberately NO case Panicked_Msg. That is the finding.
	if k, is_key := msg.(Key_Msg); is_key && k.code == .Rune {
		return cmd_from(non_pod_cmd_run, struct{}{}, context.allocator)
	}
	return cmd_nil()
}

// Driven on a thread with a deadline rather than inline, and that is not
// boilerplate: the PRE-FIX behaviour of this exact program is not a wrong
// answer, it is NO answer. The Cmd's result never arrives, this model never
// quits, and the pipe never reaches EOF -- so run() sits in mailbox_recv
// forever. A test whose failure mode is "the suite hangs" is a test nobody can
// read, so the deadline turns it back into an assertion.
@(private = "file")
Non_Pod_Harness :: struct {
	src:  Input_Source,
	b:    strings.Builder,
	err:  Run_Error,
	done: bool,
}

@(test)
test_a_cmd_that_boxes_a_non_pod_msg_ends_the_session_loudly :: proc(t: ^testing.T) {
	// A real pipe rather than input_source_from_bytes, for the reason
	// test_program_survives_a_panicking_cmd gives: a Bytes_Source hits EOF the
	// instant its one byte is consumed and closes the mailbox, which can beat
	// the pool worker's report to the queue -- and deliver_report drops a report
	// onto a closed mailbox. That race is itself the KNOWN GAP recorded in
	// apply_msg's comment; this test is about the reachable half.
	fds: [2]posix.FD
	testing.expect(t, posix.pipe(&fds) == .OK, "pipe should succeed")
	read_fd, write_fd := fds[0], fds[1]
	defer posix.close(write_fd)
	defer posix.close(read_fd)

	h: Non_Pod_Harness
	ok: bool
	h.src, ok = input_source_from_fd(read_fd)
	testing.expect(t, ok, "input_source_from_fd should succeed")
	defer input_close(&h.src)
	h.b = strings.builder_make(); defer strings.builder_destroy(&h.b)

	one_key := [1]u8{'x'}
	testing.expect(t, posix.write(write_fd, raw_data(one_key[:]), 1) == 1, "write should succeed")

	th := thread.create(proc(th: ^thread.Thread) {
		h := cast(^Non_Pod_Harness)th.data
		p: Program(Counter)
		program_init(&p, Counter{}, non_pod_update, counter_view)
		h.err = run(&p, &h.src, &h.b)
		sync.atomic_store(&h.done, true)
	})
	th.data = &h
	th.init_context = context   // see Overflow_Harness for why this must be inherited
	thread.start(th)

	start := time.now()
	for !sync.atomic_load(&h.done) {
		if time.since(start) > 5 * time.Second {
			testing.expect(t, false,
				"run() never returned: the Cmd's contract violation was reported into an update() with no case for it and nothing else happened -- which is the finding")
			return
		}
		time.sleep(10 * time.Millisecond)
	}
	thread.join(th)
	thread.destroy(th)

	pe, panicked := h.err.(Panicked_Error)
	defer delete(pe.message, context.allocator)   // the caller owns it -- Panicked_Error's own doc comment

	testing.expectf(t, panicked,
		"a Cmd that boxes a non-POD Msg must end run() with Panicked_Error, not return %v and leave the app to wonder where its result went", h.err)
	testing.expectf(t, strings.contains(pe.message, "Bad_Payload_Msg"),
		"the error must name the offending type -- that is the one fact the user needs; got %q", pe.message)
	testing.expectf(t, strings.contains(pe.message, "tea_test.odin"),
		"the error must name the box() call site; got %q", pe.message)
	testing.expect_value(t, exit_code(h.err), 1)
}

// ============================================================================
// The frame arena's LIFETIME CONTRACT (arena.odin) after coalescing.
//
// That contract used to read "a frame_allocator(fa) allocation is only good for
// the remainder of the ITERATION that made it", which was exact while apply()
// ended in a render: one message in, one paint out, one frame_reset. run() and
// run_nbio now apply a whole batch and paint once, so the reset that reclaims
// what the first message allocated fires only after the LAST message of the
// batch. The lifetime got strictly LONGER -- nothing that was safe became
// unsafe -- but a lifetime rule that overstates is one callers learn to
// distrust, so the sentence was corrected to say FRAME.
//
// This is the sentence made checkable. The arena is a bump allocator: after a
// reset the next allocation lands back at the same address, and without one it
// does not. So "two consecutive messages saw different addresses" is precisely
// "no frame_reset ran between them", which is the whole claim.
//
// It is NOT a fail-before test for that edit -- the edit is to a comment, and
// the behaviour it now describes arrived with coalescing. It is here so that a
// future change which quietly moves frame_reset back onto the per-message path
// fails a test instead of silently making the documentation wrong again.
// ============================================================================

@(private = "file")
Arena_Lifetime_Model :: struct {
	prev:       uintptr,
	msgs:       int,
	same_frame: int,   // consecutive pairs whose allocations both stood: no reset between them
	resets:     int,   // ... and pairs where the bump pointer went back to the arena's base
}

@(private = "file")
arena_lifetime_update :: proc(m: ^Arena_Lifetime_Model, msg: any, alloc: mem.Allocator) -> Cmd {
	k, is_key := msg.(Key_Msg)
	if !is_key { return cmd_nil() }
	if k.code == .Rune && k.r == 'q' { return quit_cmd() }

	// One byte, so two allocations in the same frame are one byte apart and a
	// reset is unmistakable: virtual.arena_free_all hands the SAME base address
	// back on the next allocation (verified directly -- four reset/alloc rounds
	// on a growing arena return one identical pointer), so "the address did not
	// advance" is exactly "a frame_reset ran between these two messages".
	p, _ := new(u8, alloc)
	cur := uintptr(rawptr(p))
	if m.msgs > 0 {
		if cur > m.prev { m.same_frame += 1 } else { m.resets += 1 }
	}
	m.prev  = cur
	m.msgs += 1
	return cmd_nil()
}

@(private = "file")
arena_lifetime_view :: proc(m: Arena_Lifetime_Model, alloc: mem.Allocator) -> string { return "" }

@(test)
test_the_frame_arena_is_reclaimed_once_per_frame_not_once_per_message :: proc(t: ^testing.T) {
	// MORE than COALESCE_BUDGET (== MAILBOX_CAP == 256), so BOTH halves of the
	// claim are exercised in one run: a burst this size is guaranteed to fold
	// many messages into one frame (or the budget would not bound anything) and
	// guaranteed to take more than one frame (or the budget would not be a
	// budget). How the reader thread's timing splits it is not fixed, which is
	// why both assertions are "at least one" rather than exact counts.
	N :: 600
	script := make([]u8, N + 1); defer delete(script)
	for i in 0 ..< N { script[i] = 'a' }
	script[N] = 'q'

	src := input_source_from_bytes(script)
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Arena_Lifetime_Model)
	program_init(&p, Arena_Lifetime_Model{}, arena_lifetime_update, arena_lifetime_view)
	testing.expect(t, run(&p, &src, &b) == nil, "the session should end cleanly")

	testing.expect_value(t, p.model.msgs, N)
	// PER FRAME: consecutive messages inside a batch keep their allocations, so
	// the bump pointer advances. If frame_reset had stayed on the per-message
	// path this would be 0 and the contract's "frame" would mean "message".
	testing.expectf(t, p.model.same_frame > 0,
		"the arena was reset between every pair of messages (same_frame=%d resets=%d)",
		p.model.same_frame, p.model.resets)
	// ... BUT STILL ONCE PER FRAME. A run in which the bump pointer never goes
	// back is a frame arena that is never reclaimed, which is the other way to
	// get this wrong.
	testing.expectf(t, p.model.resets > 0,
		"the arena was never reclaimed across %d messages (same_frame=%d)", N, p.model.same_frame)
}

// ============================================================================
// F15, THE HALF THE FIRST WAVE MISSED: the three thread.create sites that are
// not Cmds.
//
// cmd.odin's detached spawn was nil-checked and the hang it caused went away.
// This one was not, so under the very same pthread_create failure run() stopped
// hanging and started SEGFAULTING instead, at `reader.data = &rd` -- one line
// after a thread.create that had silently returned nil. A crash is not a fix
// for a hang; both leave the terminal raw and the second one takes the caller's
// process with it.
//
// Driven through g_thread_force_create_failure (cmd.odin) rather than an
// rlimit, for the reason that hook exists: RLIMIT_NPROC cannot be applied to
// one test without breaking the rest of the binary, and the pre-fix symptom is
// a segfault, which cannot be asserted on from inside the process it kills.
// ============================================================================

@(test)
test_a_failed_reader_thread_ends_run_with_a_terminal_error :: proc(t: ^testing.T) {
	src := input_source_from_bytes(transmute([]u8)string("aaq"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Counter)
	program_init(&p, Counter{}, counter_update, counter_view)

	sync.atomic_store(&g_thread_force_create_failure, true)
	err := run(&p, &src, &b)
	sync.atomic_store(&g_thread_force_create_failure, false)

	te, is := err.(Terminal_Error)
	if !testing.expect(t, is, "a reader thread that cannot start must end run() with a Terminal_Error, not a SIGSEGV") { return }
	testing.expectf(t, strings.contains(te.detail, "reader"),
		"the error must name what could not be started, got %q", te.detail)
	// The initial paint still happened -- the failure is after it -- so this
	// also pins that the early return does not skip renderer/arena teardown.
	testing.expect(t, strings.contains(strings.to_string(b), "count: 0"), "the initial frame should still have been painted")
}

// ============================================================================
// F07: passing update()'s own `alloc` to a Cmd constructor.
//
// `update` is handed exactly one allocator and it is spelled `alloc`; every Cmd
// constructor takes an allocator as its last argument; so `return
// cmd_from(fn, env, alloc)` is the obvious move. It compiles clean and it is a
// use-after-free: the env is cloned into the frame arena, which guarded_render
// reclaims at the end of this same frame, before the worker thread reads it.
// virtual.Arena zeroes reused blocks, so the Cmd body reads a deterministically
// ZEROED env -- measured 3/3 as tag="" len=0 where "PAYLOAD!" was expected,
// with run() returning nil and the process exiting 0. Silent in release and in
// -debug alike.
//
// The refusal is a panic inside update(), which apply_msg already runs under
// guarded(), so it lands as Panicked_Error -> exit status 1 rather than as a
// process abort. See cmd.odin's THE FRAME ALLOCATOR IS NOT A Cmd ALLOCATOR for
// why the check is armed per frame and not compile-time gated.
// ============================================================================

@(private = "file")
Frame_Alloc_Env :: struct { tag: [8]u8 }

@(private = "file")
frame_alloc_cmd_run :: proc(env: rawptr, cancel: ^Cancel_Token) -> any {
	return box(Quit_Msg{}, context.allocator)
}

@(private = "file")
Frame_Alloc_Model :: struct { n: int }

@(private = "file")
frame_alloc_view :: proc(m: Frame_Alloc_Model, alloc: mem.Allocator) -> string { return "x" }

@(test)
test_a_cmd_from_given_updates_own_frame_allocator_is_refused :: proc(t: ^testing.T) {
	update :: proc(m: ^Frame_Alloc_Model, msg: any, alloc: mem.Allocator) -> Cmd {
		// THE BUG, verbatim: `alloc` is the frame arena.
		return cmd_from(frame_alloc_cmd_run, Frame_Alloc_Env{tag = {'P','A','Y','L','O','A','D','!'}}, alloc)
	}

	src := input_source_from_bytes(transmute([]u8)string("x"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Frame_Alloc_Model)
	program_init(&p, Frame_Alloc_Model{}, update, frame_alloc_view)

	err := run(&p, &src, &b)
	pe, panicked := err.(Panicked_Error)
	defer delete(pe.message, context.allocator) // the caller owns it -- see Panicked_Error's own doc comment
	if !testing.expect(t, panicked, "a Cmd built from update()'s frame allocator must end the session, not run against a zeroed env") { return }
	testing.expectf(t, strings.contains(pe.message, CMD_ALLOC_CONTRACT_PANIC),
		"the refusal must carry the contract marker so it can be told from an app's own panic, got %q", pe.message)
	testing.expectf(t, strings.contains(pe.message, "cmd_from"),
		"the refusal must name the constructor that was misused, got %q", pe.message)
	testing.expectf(t, strings.contains(pe.message, "tea_test.odin"),
		"the refusal must name the caller's own file, not this package's, got %q", pe.message)
}

// The other side of the same check, and the one that keeps it honest: an
// ordinary Cmd built with context.allocator INSIDE update -- i.e. while the
// frame guard is armed -- must be untouched by any of this.
@(test)
test_a_cmd_from_given_context_allocator_inside_update_still_runs :: proc(t: ^testing.T) {
	update :: proc(m: ^Frame_Alloc_Model, msg: any, alloc: mem.Allocator) -> Cmd {
		if m.n > 0 { return cmd_nil() }
		m.n += 1
		return cmd_from(frame_alloc_cmd_run, Frame_Alloc_Env{}, context.allocator)
	}

	src := input_source_from_bytes(transmute([]u8)string("x"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Frame_Alloc_Model)
	program_init(&p, Frame_Alloc_Model{}, update, frame_alloc_view)

	err := run(&p, &src, &b)
	testing.expect(t, err == nil, "a correctly-allocated Cmd must still run: the guard compares the ARENA, not the allocator kind")
	testing.expect_value(t, p.model.n, 1)
}
