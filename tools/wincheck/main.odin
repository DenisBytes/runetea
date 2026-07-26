package main

// Automated stand-in for Task 7's brief Step 5 ("resize the window, watch
// rawcheck print the new size"). This sandbox has no interactive terminal to
// drag a window edge in, so this exercises the same real code path
// end-to-end against a real pty instead: term_size()'s actual
// ioctl(TIOCGWINSZ) syscall against a genuine character-device tty, which
// the unit tests in signals_test.odin deliberately never touch (they pass
// posix.FD(-1) specifically to exercise the "lookup fails, message still
// sent" branch, per the brief). Modeled on tools/ttycheck, which answered
// the analogous real-tty question for nbio.
//
// Sequence: open a real pty pair, put the slave in raw mode (matching
// term_enter_raw's real usage), start a Signal_Watcher on the slave fd, set
// a NEW size on the pty via ioctl(TIOCSWINSZ) on the master, then signal the
// watcher's own thread directly (pthread_kill(sw.native, SIGWINCH) -- the
// same targeted-delivery mechanism signals.odin's stop path and this
// package's tests use, and for the same reason: no session/controlling-
// terminal setup exists here for the kernel to auto-deliver SIGWINCH to a
// foreground process group). Confirms the Window_Size_Msg that comes back
// carries the size actually now sitting on the pty, read via the real
// ioctl, not a canned value.
import "core:fmt"
import "core:sys/linux"
import "core:sys/posix"
import rt "../../runetea"

// core:sys/linux only exposes TIOCGWINSZ (0x5413); TIOCSWINSZ is its
// well-known Linux ioctl-number neighbor, 0x5414, and isn't exposed anywhere
// in core:sys -- same situation term.odin's own comment on TIOCGWINSZ
// describes for the getter.
TIOCSWINSZ :: 0x5414

main :: proc() {
	master := posix.posix_openpt({.RDWR, .NOCTTY})
	if master < 0 { fmt.println("BLOCKED: posix_openpt failed:", posix.errno()); return }
	defer posix.close(master)

	if posix.grantpt(master) != .OK || posix.unlockpt(master) != .OK {
		fmt.println("BLOCKED: grantpt/unlockpt failed:", posix.errno())
		return
	}
	name := posix.ptsname(master)
	if name == nil { fmt.println("BLOCKED: ptsname failed:", posix.errno()); return }

	slave := posix.open(name, {.RDWR, .NOCTTY})
	if slave < 0 { fmt.println("BLOCKED: open(slave) failed:", posix.errno()); return }
	defer posix.close(slave)

	if !rt.term_enter_raw(slave) { fmt.println("BLOCKED: term_enter_raw on the pty slave failed"); return }
	defer rt.term_restore()

	// Baseline: an unconfigured pty starts at 0x0, which term_size already
	// treats as failure (ws_col/ws_row == 0 check) -- set an initial real
	// size first so the "before" state is itself a valid, non-zero size.
	initial := rt.Winsize{ws_row = 24, ws_col = 80}
	if res := linux.ioctl(linux.Fd(master), TIOCSWINSZ, uintptr(rawptr(&initial))); int(res) < 0 {
		fmt.println("BLOCKED: initial ioctl(TIOCSWINSZ) failed")
		return
	}

	w0, h0, ok0 := rt.term_size(slave)
	fmt.printfln("initial size via term_size: %dx%d ok=%v", w0, h0, ok0)
	if !ok0 || w0 != 80 || h0 != 24 {
		fmt.println("ANSWER: NO -- term_size did not read back the initial real ioctl size")
		return
	}

	m: rt.Mailbox
	if err := rt.mailbox_init(&m, 4); err != nil { fmt.println("BLOCKED: mailbox_init:", err); return }
	defer rt.mailbox_destroy(&m)

	sw: rt.Signal_Watcher
	rt.signal_watcher_start(&sw, &m, slave)
	defer rt.signal_watcher_stop(&sw)

	// Now resize for real, to a size distinguishable from the initial one,
	// and let the watcher's real ioctl(TIOCGWINSZ) discover it.
	resized := rt.Winsize{ws_row = 40, ws_col = 120}
	if res := linux.ioctl(linux.Fd(master), TIOCSWINSZ, uintptr(rawptr(&resized))); int(res) < 0 {
		fmt.println("BLOCKED: resize ioctl(TIOCSWINSZ) failed")
		return
	}

	if posix.pthread_kill(sw.native, rt.SIGWINCH) != .NONE {
		fmt.println("BLOCKED: pthread_kill(SIGWINCH) failed")
		return
	}

	msg, ok := rt.mailbox_recv(&m)
	if !ok { fmt.println("ANSWER: NO -- mailbox closed without a message"); return }
	ws, is_size := msg.(rt.Window_Size_Msg)
	if !is_size {
		fmt.println("ANSWER: NO -- watcher sent something other than a Window_Size_Msg:", msg)
		return
	}

	fmt.printfln("Window_Size_Msg from the watcher: w=%d h=%d", ws.w, ws.h)
	if ws.w == 120 && ws.h == 40 {
		fmt.println("ANSWER: YES -- SIGWINCH drove a real ioctl(TIOCGWINSZ) lookup and the watcher reported the new real size")
	} else {
		fmt.printfln("ANSWER: NO -- expected w=120 h=40, got w=%d h=%d", ws.w, ws.h)
	}
}
