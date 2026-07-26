package main

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:thread"
import rt "../../runetea"

// Task 7 extension: a Signal_Watcher runs alongside the key-reading loop
// below. Resize this terminal window (drag an edge, or `tput resize` from
// another pane) and a Window_Size_Msg should print with the new dimensions.
// Verify the reported size matches `tput cols` / `tput lines` run in the
// same window right after a resize. Ctrl-C should print an Interrupt_Msg
// instead of killing the process (SIGINT is blocked and routed through the
// watcher, not delivered with its default disposition) -- press 'q' to
// actually quit.
report_signals :: proc(data: rawptr) {
	m := cast(^rt.Mailbox)data
	for {
		msg, ok := rt.mailbox_recv(m)
		if !ok { return }
		switch v in msg {
		case rt.Window_Size_Msg:
			fmt.printf("[signal] Window_Size_Msg{{w=%d, h=%d}}\r\n", v.w, v.h)
		case rt.Interrupt_Msg:
			fmt.print("[signal] Interrupt_Msg -- Ctrl-C was caught, not delivered as a kill\r\n")
		}
	}
}

main :: proc() {
	fd := posix.FD(os.fd(os.stdin))
	if !rt.term_enter_raw(fd) { fmt.eprintln("not a tty"); os.exit(1) }
	defer rt.term_restore()

	w, h, ok := rt.term_size(fd)
	fmt.printf("size: %dx%d ok=%v\r\n", w, h, ok)
	fmt.print("press keys, 'q' quits -- resize this window or hit Ctrl-C to exercise the signal watcher\r\n")

	m: rt.Mailbox
	if err := rt.mailbox_init(&m, 16); err != nil { fmt.eprintln("mailbox_init:", err); os.exit(1) }
	defer rt.mailbox_destroy(&m)

	sw: rt.Signal_Watcher
	rt.signal_watcher_start(&sw, &m, fd)
	defer rt.signal_watcher_stop(&sw)

	reporter := thread.create_and_start_with_data(&m, report_signals, init_context = context)
	defer {
		rt.mailbox_close(&m)
		thread.destroy(reporter)
	}

	buf: [64]u8
	for {
		n, err := os.read(os.stdin, buf[:])
		if err != nil || n <= 0 { break }
		fmt.printf("read %d bytes: %v\r\n", n, buf[:n])
		if buf[0] == 'q' { break }
	}
}
