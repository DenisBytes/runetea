package main

// Throwaway probe (not part of the RuneTea library, not committed to the
// package under test). This machine has no interactive terminal, so we open
// /dev/ptmx ourselves to get a real pty master/slave pair -- the slave side
// is a genuine character device (major 136 under devpts), the same class of
// fd term.odin drives in production. This answers the one thing Task 6's
// pipe-based nbiocheck cannot: whether nbio's Linux (io_uring) backend can
// actually deliver reads from a tty, not just from a pipe. The Go
// implementation this spike ports from (ultraviolet/poll_bsd.go) explicitly
// calls out /dev/tty as a case where kqueue misbehaves; this checks the
// Linux-only equivalent question for io_uring.
import "core:fmt"
import "core:nbio"
import "core:sys/posix"
import "core:thread"
import "core:time"
import rt "../../runetea"

State :: struct {
	buf:       [64]u8,
	got_read:  bool,
	n:         int,
	timed_out: bool,
	done:      bool,
}

on_read :: proc(op: ^nbio.Operation) {
	s := cast(^State)op.user_data[0]
	n := op.read.read
	if n <= 0 {
		fmt.printfln("  read callback fired with n=%d err=%v", n, op.read.err)
		s.done = true
		return
	}
	s.got_read = true
	s.n = n
	fmt.printfln("  read %d bytes from tty slave: %q", n, string(s.buf[:n]))
	s.done = true
}

on_timeout :: proc(op: ^nbio.Operation) {
	s := cast(^State)op.user_data[0]
	if !s.done {
		fmt.println("  TIMEOUT: no read callback fired within the deadline")
		s.timed_out = true
		s.done = true
	}
}

main :: proc() {
	master := posix.posix_openpt({.RDWR, .NOCTTY})
	if master < 0 {
		fmt.println("BLOCKED: posix_openpt failed:", posix.errno())
		return
	}
	defer posix.close(master)

	if posix.grantpt(master) != .OK {
		fmt.println("BLOCKED: grantpt failed:", posix.errno())
		return
	}
	if posix.unlockpt(master) != .OK {
		fmt.println("BLOCKED: unlockpt failed:", posix.errno())
		return
	}
	name := posix.ptsname(master)
	if name == nil {
		fmt.println("BLOCKED: ptsname failed:", posix.errno())
		return
	}
	fmt.println("slave pty:", name)

	slave := posix.open(name, {.RDWR, .NOCTTY})
	if slave < 0 {
		fmt.println("BLOCKED: open(slave) failed:", posix.errno())
		return
	}
	defer posix.close(slave)

	// Put the slave into the same raw mode term.odin's term_enter_raw puts
	// the real terminal into. Without this the tty line discipline stays in
	// canonical mode and buffers input until a newline -- verified against
	// this exact sandbox with a Python pty.openpty() probe before writing
	// this file: writes without a trailing '\n' never became select()-ready
	// on the slave in canonical mode, purely a line-discipline effect with
	// nothing to do with nbio. Reusing the library's own raw-mode function
	// (rather than reimplementing it here) also means this run doubles as an
	// independent real-pty exercise of term_enter_raw itself.
	if !rt.term_enter_raw(slave) {
		fmt.println("BLOCKED: term_enter_raw on the pty slave failed")
		return
	}
	defer rt.term_restore()

	if err := nbio.acquire_thread_event_loop(); err != nil {
		fmt.println("BLOCKED: acquire_thread_event_loop:", err)
		return
	}
	defer nbio.release_thread_event_loop()

	h, aerr := nbio.associate_handle(uintptr(slave))
	if aerr != nil {
		fmt.println("ANSWER: NO -- associate_handle failed on the tty slave fd:", aerr)
		return
	}

	s := State{}
	op := nbio.read(h, 0, s.buf[:], on_read)
	op.user_data[0] = &s

	top := nbio.timeout(2 * time.Second, on_timeout)
	top.user_data[0] = &s

	msg := "tty-hello"
	written := posix.write(master, raw_data(msg), len(msg))
	fmt.printfln("wrote %d bytes into the pty master", written)

	nbio.run_until(&s.done)

	if s.got_read && string(s.buf[:s.n]) == msg {
		fmt.println("ANSWER: YES -- nbio's Linux backend delivered a read from a real tty (pty slave) character device")
	} else if s.timed_out {
		fmt.println("ANSWER: NO -- nbio never delivered the read before the timeout (possible io_uring/tty misbehavior)")
	} else {
		fmt.println("ANSWER: NO -- read callback fired but did not deliver the expected bytes")
	}

	fmt.println()
	fmt.println("--- Input_Source (loop.odin's Fd_Source, fix round 1) against the same real tty ---")
	check_input_source_against_real_tty()
}

// Fix round 1 added a posix.poll()-before-read() loop and a wake self-pipe
// to Fd_Source (runetea/loop.odin), replacing the original bare
// posix.read() call. loop_test.odin's own tests only exercise that against
// a plain pipe. Since this whole file exists to answer platform questions a
// pipe cannot (tty line discipline, character-device quirks), it is the
// right place to also confirm the NEW poll-based Fd_Source still works
// end-to-end against a real pty slave -- not just that nbio (a completely
// separate code path, sharing no code with loop.odin) still does.
//
// Uses its own fresh pty pair, independent of the one above, so this has no
// interaction with the nbio phase's already-associated slave fd.
check_input_source_against_real_tty :: proc() {
	master := posix.posix_openpt({.RDWR, .NOCTTY})
	if master < 0 {
		fmt.println("BLOCKED: posix_openpt (2nd pty) failed:", posix.errno())
		return
	}
	defer posix.close(master)

	if posix.grantpt(master) != .OK || posix.unlockpt(master) != .OK {
		fmt.println("BLOCKED: grantpt/unlockpt (2nd pty) failed:", posix.errno())
		return
	}
	name := posix.ptsname(master)
	if name == nil {
		fmt.println("BLOCKED: ptsname (2nd pty) failed:", posix.errno())
		return
	}

	slave := posix.open(name, {.RDWR, .NOCTTY})
	if slave < 0 {
		fmt.println("BLOCKED: open(slave) (2nd pty) failed:", posix.errno())
		return
	}
	defer posix.close(slave)

	if !rt.term_enter_raw(slave) {
		fmt.println("BLOCKED: term_enter_raw (2nd pty) failed")
		return
	}
	defer rt.term_restore()

	src, ok := rt.input_source_from_fd(slave)
	if !ok {
		fmt.println("ANSWER: NO -- input_source_from_fd failed on a real tty slave fd")
		return
	}
	defer rt.input_close(&src)

	// Phase 1: a normal blocking read must still deliver real tty bytes
	// through the new poll()-then-read() path.
	sh := Tty_Read_Shared{src = &src}
	th := thread.create_and_start_with_data(&sh, tty_read_worker, init_context = context)

	msg := "input-source-tty"
	written := posix.write(master, raw_data(msg), len(msg))
	fmt.printfln("wrote %d bytes into the 2nd pty master", written)

	thread.destroy(th)

	if sh.ok && !sh.woken && string(sh.buf[:sh.n]) == msg {
		fmt.println("  Fd_Source data-read: YES -- poll()-then-read() still delivers real tty bytes")
	} else {
		fmt.printfln("  Fd_Source data-read: NO -- n=%d ok=%v woken=%v", sh.n, sh.ok, sh.woken)
		return
	}

	// Phase 2: input_wake must cancel a reader blocked on the real tty slave
	// with no data pending -- the exact scenario Task 10's shutdown path
	// depends on, now proven against a character device rather than a pipe.
	sh2 := Tty_Read_Shared{src = &src}
	th2 := thread.create_and_start_with_data(&sh2, tty_read_worker, init_context = context)

	time.sleep(20 * time.Millisecond)  // best-effort window to enter poll()
	rt.input_wake(&src)
	thread.destroy(th2)  // would hang here if the wake pipe didn't work on a real tty

	if sh2.woken && !sh2.ok && sh2.n == 0 {
		fmt.println("  Fd_Source input_wake:  YES -- cancels a reader blocked on a real tty slave")
	} else {
		fmt.printfln("  Fd_Source input_wake:  NO -- n=%d ok=%v woken=%v", sh2.n, sh2.ok, sh2.woken)
	}
}

Tty_Read_Shared :: struct {
	src: ^rt.Input_Source,
	buf: [64]u8,
	n:   int,
	ok:  bool,
	woken: bool,
}

tty_read_worker :: proc(data: rawptr) {
	sh := cast(^Tty_Read_Shared)data
	sh.n, sh.ok, sh.woken = rt.input_read(sh.src, sh.buf[:])
}
