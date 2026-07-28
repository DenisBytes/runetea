package runetea

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
// property: with the old by-value signature, apply() did
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
// Program.update's comment, apply()'s comment, and
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
		// straight out of this proc back into apply(): no statement after the
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
		"(under the old by-value signature this was 0 -- longjmp skipped apply()'s assignment)", p.model.a)
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
// this test sends) -- deliberately, so this test exercises apply()'s
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
// before the mailbox loop (and therefore before apply()) ever runs. Panics
// on the very first view() call, with no keypress sent at all, so this can
// only pass if guarded_render's coverage genuinely extends to that call site
// and not just apply()'s.
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
