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
