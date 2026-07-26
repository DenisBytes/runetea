package main

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/posix"
import rt "../../runetea"

// The Go original fetches https://charm.sh/. Odin core has TCP and DNS
// (core:net) but NO TLS -- core:crypto ships primitives, not the protocol --
// and the plan forbids third-party dependencies. So this does a real HTTP/1.1
// GET over plain http://, which exercises genuine network latency and a real
// blocking Cmd. Record the TLS gap in the findings; it is a v1.0 concern, not
// a spike one.
HOST :: "example.com"
PORT :: 80

// Go: `func checkServer() tea.Msg { ... }` -- a closure over nothing.
// RuneTea: an explicit env struct, because Odin has no closures.
Check_Env :: struct { host: string, port: int }

Status_Msg :: struct { code: int }

// Msg_Text, not string: box()'s MESSAGE OWNERSHIP CONTRACT (runetea/
// arena.odin) requires every boxed Msg to be POD, and check_server runs on a
// Dispatcher pool worker -- a different thread from whichever one eventually
// reads this message -- so `reason` cannot be a bare `string` pointing at a
// separate fmt.aprintf allocation the way it did before the T1
// message-ownership decision (docs/superpowers/message-ownership-decision.md).
Err_Msg :: struct { reason: rt.Msg_Text }

check_server :: proc(env: rawptr) -> any {
	e := cast(^Check_Env)env

	sock, derr := net.dial_tcp_from_hostname_with_port_override(e.host, e.port)
	if derr != nil {
		return rt.box(Err_Msg{reason = rt.msg_text_fmt("dial: %v", derr)}, context.allocator)
	}
	defer net.close(sock)

	req := fmt.tprintf("GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", e.host)
	if _, serr := net.send_tcp(sock, transmute([]u8)req); serr != nil {
		return rt.box(Err_Msg{reason = rt.msg_text_fmt("send: %v", serr)}, context.allocator)
	}

	buf: [1024]u8
	n, rerr := net.recv_tcp(sock, buf[:])
	if rerr != nil || n < 12 {
		return rt.box(Err_Msg{reason = rt.msg_text_fmt("recv: %v", rerr)}, context.allocator)
	}

	// "HTTP/1.1 200 OK" -- the status code is bytes 9..12
	code := 0
	for c in buf[9:12] {
		if c < '0' || c > '9' { break }
		code = code * 10 + int(c - '0')
	}
	if code == 0 {
		return rt.box(Err_Msg{reason = rt.msg_text_from("unparseable status line")}, context.allocator)
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
		// The ONLY way to get a `string` out of a Msg_Text is
		// rt.msg_text_clone, and it always allocates a fresh, independent
		// copy (msg.odin) -- required here specifically: run()'s loop frees
		// this Err_Msg right after update() returns (apply(), tea.odin), so
		// anything retained in the model must not alias the box's storage.
		m.err = rt.msg_text_clone(v.reason, context.allocator)
		m.done = true
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
	// install_crash_handlers BEFORE term_enter_raw, not after: term_enter_raw
	// flips raw_active = true before tcsetattr has actually touched the tty,
	// so a crash landing in that window is only recoverable if a handler
	// already exists to catch it (see install_crash_handlers' doc comment).
	rt.install_crash_handlers()
	if !rt.term_enter_raw(fd) { fmt.eprintln("not a tty"); os.exit(1) }
	defer rt.term_restore()

	src, ok := rt.input_source_from_fd(fd)
	if !ok { fmt.eprintln("bad input source"); os.exit(1) }
	defer rt.input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	// The initial Cmd. Go: `Init() Cmd { return checkServer }` -- one
	// identifier, because checkServer is already a closure of the right type.
	// RuneTea: cmd_from + a heap-cloned env struct that had to be declared.
	init := rt.cmd_from(check_server, Check_Env{host = HOST, port = PORT}, context.allocator)

	p: rt.Program(Model)
	rt.program_init(&p, Model{}, update, view, init)

	if err := rt.run(&p, &src, &b, fd); err != nil { fmt.eprintln("error:", err) }
}
