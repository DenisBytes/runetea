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
