package main

// Verification binary, not a public example: examples/http ported verbatim
// onto run_nbio instead of run(). This is the scenario that actually
// exercises the linchpin under a real pty: the init Cmd runs on the
// Dispatcher's pool, and its result (Status_Msg/Err_Msg) must reach the
// screen with NO keypress, which for run_nbio means the pool thread's
// mailbox_send + nbio.wake_up genuinely woke a loop thread parked in
// nbio.tick() while driven by a real terminal, not just the headless
// pipe tests in runetea/loop_nbio_test.odin or the isolated
// tools/nbiowakecheck probe.

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/posix"
import rt "../../runetea"

HOST :: "example.com"
PORT :: 80

Check_Env :: struct { host: string, port: int }

Status_Msg :: struct { code: int }
Err_Msg    :: struct { reason: string }

check_server :: proc(env: rawptr) -> any {
	e := cast(^Check_Env)env

	sock, derr := net.dial_tcp_from_hostname_with_port_override(e.host, e.port)
	if derr != nil {
		return rt.box(Err_Msg{reason = fmt.aprintf("dial: %v", derr)}, context.allocator)
	}
	defer net.close(sock)

	req := fmt.tprintf("GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", e.host)
	if _, serr := net.send_tcp(sock, transmute([]u8)req); serr != nil {
		return rt.box(Err_Msg{reason = fmt.aprintf("send: %v", serr)}, context.allocator)
	}

	buf: [1024]u8
	n, rerr := net.recv_tcp(sock, buf[:])
	if rerr != nil || n < 12 {
		return rt.box(Err_Msg{reason = fmt.aprintf("recv: %v", rerr)}, context.allocator)
	}

	code := 0
	for c in buf[9:12] {
		if c < '0' || c > '9' { break }
		code = code * 10 + int(c - '0')
	}
	if code == 0 {
		return rt.box(Err_Msg{reason = "unparseable status line"}, context.allocator)
	}
	return rt.box(Status_Msg{code = code}, context.allocator)
}

Model :: struct { status: int, err: string, done: bool }

update :: proc(m: Model, msg: any, alloc: mem.Allocator) -> (Model, rt.Cmd) {
	m := m
	switch v in msg {
	case rt.Key_Msg:
		if v.code == .Rune && (v.r == 'q' || (v.r == 'c' && .Ctrl in v.mods)) {
			return m, rt.quit_cmd()
		}
	case Status_Msg:
		m.status = v.code; m.done = true
		return m, rt.quit_cmd()
	case Err_Msg:
		m.err = v.reason; m.done = true
		return m, rt.quit_cmd()
	}
	return m, rt.cmd_nil()
}

view :: proc(m: Model, alloc: mem.Allocator) -> string {
	if m.err != "" { return fmt.aprintf("error: %s\n", m.err, allocator = alloc) }
	if m.done      { return fmt.aprintf("http://%s -> %d\n", HOST, m.status, allocator = alloc) }
	return fmt.aprintf("Checking http://%s ...\n", HOST, allocator = alloc)
}

main :: proc() {
	fd := posix.FD(os.fd(os.stdin))
	rt.install_crash_handlers()
	if !rt.term_enter_raw(fd) { fmt.eprintln("not a tty"); os.exit(1) }
	defer rt.term_restore()

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	init := rt.cmd_from(check_server, Check_Env{host = HOST, port = PORT}, context.allocator)

	p: rt.Program(Model)
	rt.program_init(&p, Model{}, update, view, init)

	if err := rt.run_nbio(&p, fd, &b, fd); err != nil { fmt.eprintln("error:", err) }
}
