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
