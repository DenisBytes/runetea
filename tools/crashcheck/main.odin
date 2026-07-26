package main

import "core:fmt"
import "core:os"
import "core:sys/posix"
import rt "../../runetea"

main :: proc() {
	fd := posix.FD(os.fd(os.stdin))
	// install_crash_handlers BEFORE term_enter_raw -- see the required-order
	// note on install_crash_handlers' doc comment (FIX 4, final fix-wave
	// report). This tool exists to demonstrate crash recovery, so it should
	// not itself demonstrate the wrong order.
	rt.install_crash_handlers()
	if !rt.term_enter_raw(fd) { fmt.eprintln("not a tty"); os.exit(1) }

	// Deliberately does NOT hide the cursor here: term_restore_c only undoes
	// what the framework actually sets (FIX 5, final fix-wave report), which
	// as of T0 is termios raw mode only. Hiding the cursor from this
	// standalone demo would leave the real terminal's cursor invisible after
	// the process exits, since nothing -- neither this tool nor
	// term_restore_c -- would ever show it again.
	fmt.print("entering raw mode, then indexing out of range\r\n")

	buf := make([]int, 4)
	i := 9
	buf[i] = 1          // bounds violation -> trap -> handler -> restore
	fmt.print("NOT REACHED\r\n")
}
