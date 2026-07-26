package main

// Real-pty verification for the T1 crash-recovery extension (docs/superpowers/
// tier1-coverage-decision.md): guarded() now wraps View (both call sites --
// run()'s initial paint and apply()'s per-iteration render, via the shared
// guarded_render helper, tea.odin) and Cmd procedures (run_cmd_guarded,
// cmd.odin) in addition to Update, which was all Tier 1 covered before this
// change (spike-findings.md §4). Three modes, selected by argv[1]:
//
//   view-panic  -- a View that panics on its second call. Demonstrates Tier 1
//                  RECOVERING: run() returns Panicked_Error, the terminal's
//                  line discipline is restored, and a diagnostic frame (not
//                  a blank screen or silently-stale content -- constraint d)
//                  actually reaches the far end of a real pty. Runs in this
//                  same process: nothing crashes, so there is nothing to fork.
//
//   view-bounds -- a View that indexes out of bounds on its first call.
//                  Demonstrates Tier 1 correctly NOT catching this (bounds
//                  traps bypass assertion_failure_proc entirely -- verified
//                  in T0, unchanged by wrapping View in guarded()) and Tier 2
//                  still catching it: the process dies BY SIGNAL, honestly,
//                  with the terminal's line discipline restored first. Forks,
//                  because this mode's whole point is that the process does
//                  not survive.
//
//   cmd-bounds  -- an init Cmd, running on a POOL WORKER thread, that indexes
//                  out of bounds. Same Tier 2 proof as view-bounds, but for
//                  the OTHER call site guard.odin/cmd.odin now wraps in
//                  guarded() (run_cmd_guarded) -- confirming that guarding
//                  Cmd execution for PANICS does not somehow also intercept
//                  or change what happens for a hardware/runtime bounds trap
//                  on a background thread. Also forks.
//
// Uses the same real-pty technique as tools/ttycheck (posix_openpt/grantpt/
// unlockpt/ptsname/open, not a pipe): a genuine character device, the same
// class of fd term.odin drives in production, not a simulation.
//
// The bounds modes fork rather than running crashcheck-style in a single
// process: the crashing "framework" side of the test is the CHILD (so a
// bug that turns Tier 2 into a hang or a silent swallow cannot wedge this
// harness itself -- the parent bounds its wait), and the PARENT is an
// independent OBSERVER that re-opens the pty's slave path by name AFTER the
// child forks, rather than sharing the child's own fd -- so termios
// inspection after the crash reads the ACTUAL kernel-level tty state a real
// external terminal-watching process would see, not something the crashed
// process's own (possibly-corrupted) fd table would report.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import rt "../../runetea"

Pty :: struct {
	master:     posix.FD,
	slave:      posix.FD,
	slave_path: string, // cloned from ptsname(); valid independent of `slave` itself
}

open_pty :: proc() -> (pty: Pty, ok: bool) {
	pty.master = posix.posix_openpt({.RDWR, .NOCTTY})
	if pty.master < 0 {
		fmt.println("BLOCKED: posix_openpt failed:", posix.errno())
		return
	}
	if posix.grantpt(pty.master) != .OK {
		fmt.println("BLOCKED: grantpt failed:", posix.errno())
		posix.close(pty.master)
		return
	}
	if posix.unlockpt(pty.master) != .OK {
		fmt.println("BLOCKED: unlockpt failed:", posix.errno())
		posix.close(pty.master)
		return
	}
	name := posix.ptsname(pty.master)
	if name == nil {
		fmt.println("BLOCKED: ptsname failed:", posix.errno())
		posix.close(pty.master)
		return
	}
	pty.slave_path = strings.clone(string(name)) // ptsname's buffer is reused by later calls -- clone now
	pty.slave = posix.open(name, {.RDWR, .NOCTTY})
	if pty.slave < 0 {
		fmt.println("BLOCKED: open(slave) failed:", posix.errno())
		posix.close(pty.master)
		delete(pty.slave_path)
		return
	}
	return pty, true
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: tier1check <view-panic|view-bounds|cmd-bounds>")
		os.exit(2)
	}
	switch os.args[1] {
	case "view-panic":  mode_view_panic()
	case "view-bounds": mode_view_bounds()
	case "cmd-bounds":  mode_cmd_bounds()
	case:
		fmt.eprintln("unknown mode:", os.args[1])
		os.exit(2)
	}
}

// --- view-panic: Tier 1 recovers -----------------------------------------

View_Panic_Model :: struct { n: int }

vp_update :: proc(m: View_Panic_Model, msg: any, alloc: mem.Allocator) -> (View_Panic_Model, rt.Cmd) {
	m := m
	if _, is_key := msg.(rt.Key_Msg); is_key { m.n += 1 }
	return m, rt.cmd_nil()
}

// Succeeds on the initial paint (n == 0), panics starting on the second call
// (n == 1, after the one keypress this mode sends) -- exercises apply()'s
// guarded_render call, the steady-state path, while also proving the
// initial paint itself still renders correctly (no regression there).
vp_view :: proc(m: View_Panic_Model, alloc: mem.Allocator) -> string {
	if m.n > 0 { panic("tier1check: view exploded") }
	return fmt.aprintf("count: %d", m.n, allocator = alloc)
}

mode_view_panic :: proc() {
	pty, ok := open_pty()
	if !ok { os.exit(1) }
	defer posix.close(pty.master)
	defer posix.close(pty.slave)
	defer delete(pty.slave_path)

	// install_crash_handlers BEFORE term_enter_raw -- required order (FIX 4,
	// final fix-wave report; guard.odin's own doc comment on
	// install_crash_handlers).
	rt.install_crash_handlers()
	if !rt.term_enter_raw(pty.slave) {
		fmt.println("BLOCKED: term_enter_raw failed")
		os.exit(1)
	}
	defer rt.term_restore()

	src, sok := rt.input_source_from_fd(pty.slave)
	if !sok {
		fmt.println("BLOCKED: input_source_from_fd failed")
		os.exit(1)
	}
	defer rt.input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: rt.Program(View_Panic_Model)
	rt.program_init(&p, View_Panic_Model{}, vp_update, vp_view)

	// Written into the pty's line discipline AFTER term_enter_raw, so it is
	// immediately readable (VMIN=1/VTIME=0) rather than buffered pending a
	// newline the way canonical mode would hold it -- exactly what a real
	// keypress into a raw-mode terminal looks like from the far end.
	one := [1]u8{'x'}
	posix.write(pty.master, raw_data(one[:]), 1)

	err := rt.run(&p, &src, &b, pty.slave)
	_, panicked := err.(rt.Panicked_Error)
	fmt.printfln("run() returned: %v", err)

	// run() itself does NOT restore the terminal on a Panicked_Error return
	// -- by design, that is the CALLER's job (examples/simple's own `defer
	// rt.term_restore()` right after term_enter_raw is the pattern this
	// mirrors), exactly the same as a clean quit. Calling it explicitly here
	// -- rather than waiting for this proc's own deferred term_restore() to
	// fire on return -- simulates that caller-side defer firing right after
	// run() returns, which is the moment a real caller's termios check would
	// actually happen. term_restore_c is idempotent (raw_active-gated), so
	// this does not conflict with the defer already registered above.
	rt.term_restore()

	// Whatever run() flushed to pty.slave is relayed by the kernel's pty
	// driver out through pty.master -- the same path a real terminal
	// emulator reads from -- so this is what a user would actually have
	// seen on screen, not an internal buffer this process happens to own.
	buf: [4096]u8
	n := posix.read(pty.master, raw_data(buf[:]), len(buf))
	if n > 0 {
		fmt.printfln("bytes seen on the pty master side (%d):\n%q", n, string(buf[:n]))
	} else {
		fmt.println("bytes seen on the pty master side: (none)")
	}

	t: posix.termios
	posix.tcgetattr(pty.slave, &t)
	echo_on   := .ECHO in t.c_lflag
	icanon_on := .ICANON in t.c_lflag
	fmt.printfln("post-run termios: ECHO=%v ICANON=%v (both should be TRUE -- cooked mode restored)", echo_on, icanon_on)

	if !panicked {
		fmt.println("FAIL: run() did not return Panicked_Error")
		os.exit(1)
	}
	if n <= 0 || !strings.contains(string(buf[:max(n, 0)]), "view panicked") {
		fmt.println("FAIL: expected a '[view panicked: ...]' diagnostic frame on the pty, got none")
		os.exit(1)
	}
	if !echo_on || !icanon_on {
		fmt.println("FAIL: terminal line discipline was not restored")
		os.exit(1)
	}
	fmt.println("PASS: view panic recovered under a real pty -- terminal restored, diagnostic reached the screen, run() returned cleanly")
}

// --- shared: fork, wait bounded, report ----------------------------------

// Waits up to `timeout` for `pid` to die, polling WNOHANG rather than
// blocking forever -- a bug that turned Tier 2 into a hang (rather than an
// honest process death) must fail this harness observably, not wedge it.
wait_bounded :: proc(pid: posix.pid_t, timeout: time.Duration) -> (status: i32, exited: bool) {
	start := time.now()
	for time.since(start) < timeout {
		st: i32
		w := posix.waitpid(pid, &st, {.NOHANG})
		if w == pid {
			return st, true
		}
		time.sleep(5 * time.Millisecond)
	}
	return 0, false
}

// --- view-bounds: Tier 2 still catches what Tier 1 structurally cannot ---

Bounds_View_Model :: struct {}

bv_update :: proc(m: Bounds_View_Model, msg: any, alloc: mem.Allocator) -> (Bounds_View_Model, rt.Cmd) {
	return m, rt.cmd_nil()
}

bv_view :: proc(m: Bounds_View_Model, alloc: mem.Allocator) -> string {
	buf := make([]int, 4, alloc)
	i := 9
	buf[i] = 1   // bounds violation -> trap, bypasses assertion_failure_proc entirely -- NOT caught by guarded_render's guarded() call
	return "NOT REACHED"
}

mode_view_bounds :: proc() {
	pty, ok := open_pty()
	if !ok { os.exit(1) }

	pid := posix.fork()
	switch pid {
	case -1:
		fmt.println("FAIL: fork failed:", posix.errno())
		os.exit(1)

	case 0:
		// CHILD: plays the role of the framework process. Deliberately does
		// NOT defer rt.term_restore() here -- the whole point of this mode is
		// that Tier 2's SIGNAL PATH (crash_handler -> term_restore_c) is what
		// restores the terminal, not an orderly Odin `defer` this crash never
		// reaches (the trap does not unwind the stack).
		posix.close(pty.master)
		rt.install_crash_handlers()
		if !rt.term_enter_raw(pty.slave) { posix._exit(1) }

		src, sok := rt.input_source_from_fd(pty.slave)
		if !sok { posix._exit(1) }

		b := strings.builder_make()

		p: rt.Program(Bounds_View_Model)
		rt.program_init(&p, Bounds_View_Model{}, bv_update, bv_view)

		rt.run(&p, &src, &b, pty.slave)   // never returns: bv_view traps on the very first call (run()'s initial paint)
		posix._exit(1)                     // NOT REACHED if Tier 2 fired as expected

	case:
		// PARENT: independent observer.
		posix.close(pty.slave)

		status, exited := wait_bounded(pid, 5 * time.Second)
		if !exited {
			fmt.println("FAIL: child did not die within 5s -- Tier 2 turned a bounds trap into a hang, not an honest crash")
			posix.kill(pid, .SIGKILL)
			os.exit(1)
		}

		signaled := posix.WIFSIGNALED(status)
		sig := posix.WTERMSIG(status) if signaled else posix.Signal(0)
		fmt.printfln("child exit status: WIFSIGNALED=%v signal=%v WIFEXITED=%v exit_code=%v",
			signaled, sig, posix.WIFEXITED(status), posix.WEXITSTATUS(status) if posix.WIFEXITED(status) else 0)

		// Independent fd, opened by PATH after the fork -- not the child's
		// own `pty.slave` (which died with the child's process, though the
		// device itself persists) -- so this reads the tty's actual
		// kernel-level line discipline state, the same way a real external
		// terminal-watching process would.
		observer := posix.open(strings.clone_to_cstring(pty.slave_path), {.RDWR, .NOCTTY})
		ok2 := observer >= 0
		echo_on, icanon_on := false, false
		if ok2 {
			t: posix.termios
			posix.tcgetattr(observer, &t)
			echo_on   = .ECHO in t.c_lflag
			icanon_on = .ICANON in t.c_lflag
			posix.close(observer)
		}
		fmt.printfln("post-crash termios (independent observer fd): opened=%v ECHO=%v ICANON=%v (both should be TRUE)", ok2, echo_on, icanon_on)

		posix.close(pty.master)
		delete(pty.slave_path)

		if !signaled {
			fmt.println("FAIL: expected the child to die BY SIGNAL (bounds trap), it did not")
			os.exit(1)
		}
		if !ok2 || !echo_on || !icanon_on {
			fmt.println("FAIL: terminal line discipline was not restored across the crash")
			os.exit(1)
		}
		fmt.println("PASS: bounds violation in View bypassed Tier 1, hit Tier 2 -- process died honestly by signal, terminal restored")
	}
}

// --- cmd-bounds: Tier 2 still catches a bounds trap on a POOL thread -----

Bounds_Cmd_Model :: struct {}

bc_update :: proc(m: Bounds_Cmd_Model, msg: any, alloc: mem.Allocator) -> (Bounds_Cmd_Model, rt.Cmd) {
	return m, rt.cmd_nil()
}

bc_view :: proc(m: Bounds_Cmd_Model, alloc: mem.Allocator) -> string { return "" }

bounds_cmd_run :: proc(env: rawptr, cancel: ^rt.Cancel_Token) -> any {
	buf := make([]int, 4)
	i := 9
	buf[i] = 1   // bounds violation on a POOL WORKER thread -> trap, bypasses run_cmd_guarded's guarded() call entirely
	return rt.box(rt.Quit_Msg{}, context.allocator)   // NOT REACHED
}

mode_cmd_bounds :: proc() {
	pty, ok := open_pty()
	if !ok { os.exit(1) }

	pid := posix.fork()
	switch pid {
	case -1:
		fmt.println("FAIL: fork failed:", posix.errno())
		os.exit(1)

	case 0:
		posix.close(pty.master)
		rt.install_crash_handlers()
		if !rt.term_enter_raw(pty.slave) { posix._exit(1) }

		src, sok := rt.input_source_from_fd(pty.slave)
		if !sok { posix._exit(1) }

		b := strings.builder_make()

		p: rt.Program(Bounds_Cmd_Model)
		// Dispatched as the init Cmd -- runs on a POOL WORKER thread
		// immediately, with no keypress needed, the moment run() starts.
		rt.program_init(&p, Bounds_Cmd_Model{}, bc_update, bc_view,
			rt.Cmd{procedure = bounds_cmd_run, env = nil, allocator = context.allocator})

		rt.run(&p, &src, &b, pty.slave)   // never returns: the init Cmd traps on a pool worker thread
		posix._exit(1)                     // NOT REACHED if Tier 2 fired as expected

	case:
		posix.close(pty.slave)

		status, exited := wait_bounded(pid, 5 * time.Second)
		if !exited {
			fmt.println("FAIL: child did not die within 5s -- Tier 2 turned a bounds trap on a pool worker into a hang, not an honest crash")
			posix.kill(pid, .SIGKILL)
			os.exit(1)
		}

		signaled := posix.WIFSIGNALED(status)
		sig := posix.WTERMSIG(status) if signaled else posix.Signal(0)
		fmt.printfln("child exit status: WIFSIGNALED=%v signal=%v", signaled, sig)

		observer := posix.open(strings.clone_to_cstring(pty.slave_path), {.RDWR, .NOCTTY})
		ok2 := observer >= 0
		echo_on, icanon_on := false, false
		if ok2 {
			t: posix.termios
			posix.tcgetattr(observer, &t)
			echo_on   = .ECHO in t.c_lflag
			icanon_on = .ICANON in t.c_lflag
			posix.close(observer)
		}
		fmt.printfln("post-crash termios (independent observer fd): opened=%v ECHO=%v ICANON=%v (both should be TRUE)", ok2, echo_on, icanon_on)

		posix.close(pty.master)
		delete(pty.slave_path)

		if !signaled {
			fmt.println("FAIL: expected the child to die BY SIGNAL (bounds trap on a pool worker), it did not")
			os.exit(1)
		}
		if !ok2 || !echo_on || !icanon_on {
			fmt.println("FAIL: terminal line discipline was not restored across the crash")
			os.exit(1)
		}
		fmt.println("PASS: bounds violation in a Cmd (pool worker thread) bypassed Tier 1, hit Tier 2 -- process died honestly by signal, terminal restored")
	}
}
