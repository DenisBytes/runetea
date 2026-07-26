package main

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import rt "../../runetea"

// The Go original fetches https://charm.sh/. Odin core has TCP and DNS
// (core:net) but NO TLS -- core:crypto ships primitives, not the protocol --
// and the plan forbids third-party dependencies. So this does a real HTTP/1.1
// GET over plain http://, which exercises genuine network latency and a real
// blocking Cmd. Record the TLS gap in the findings; it is a v1.0 concern, not
// a spike one.
//
// Overridable via RT_HTTP_HOST/RT_HTTP_PORT so the SAME binary can be pointed
// at a deliberately stalled local server for the quit-latency demonstration
// in docs/superpowers/cancellation-decision.md (tools/stallserver) without a
// second copy of this example. Defaults to the original hardcoded target.
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

// check_server is THE concrete victim this fix targets (spike-findings.md
// addendum item 5): net.recv_tcp had no timeout at all, so a stalled host
// (accepts, never replies) blocked this Cmd -- and, before the T1 structural
// fix, run() itself -- forever. Two independent, complementary mechanisms
// close that gap, and BOTH are needed (see
// docs/superpowers/cancellation-decision.md for why neither alone suffices):
//
//   - RECV_POLL: recv_tcp is called with a SHORT socket timeout
//     (net.set_option(.Receive_Timeout)) instead of one unbounded call, so
//     this Cmd wakes up on its own every 200ms even if the peer never sends
//     a byte -- a hard, unconditional bound on how long the underlying
//     blocking syscall can ever hold this thread, with or without a quit.
//   - cancel_requested(cancel): polled once per wakeup. A Cancel_Token
//     cannot interrupt a blocking recv_tcp call already in progress -- see
//     Cancel_Token's own doc comment (runetea/cmd.odin) -- but it CAN be
//     checked in the gap between one bounded recv_tcp call and the next,
//     which is exactly what the short timeout above creates room for. This
//     is what makes this Cmd notice a user quit within ~RECV_POLL instead of
//     waiting out the full RECV_MAX_WAIT regardless of what the user does.
RECV_POLL     :: 200 * time.Millisecond
RECV_MAX_WAIT :: 30 * time.Second   // hard cap even if the user never quits and the host never replies

check_server :: proc(env: rawptr, cancel: ^rt.Cancel_Token) -> any {
	e := cast(^Check_Env)env

	sock, derr := net.dial_tcp_from_hostname_with_port_override(e.host, e.port)
	if derr != nil {
		return rt.box(Err_Msg{reason = rt.msg_text_fmt("dial: %v", derr)}, context.allocator)
	}
	defer net.close(sock)

	// NOTE, honestly: this bounds recv/send, not dial above. core:net's
	// dial_tcp_* procs take no timeout/deadline parameter at all, so a
	// connect() to a filtered or black-holed (not merely closed) address can
	// still block for the OS's own default connect timeout (tens of seconds
	// to minutes on Linux) with neither this Cancel_Token nor a socket option
	// able to touch it. See the decision doc for the full accounting of what
	// this change does and does not cover.
	net.set_option(sock, .Receive_Timeout, RECV_POLL)
	net.set_option(sock, .Send_Timeout, RECV_POLL)

	req := fmt.tprintf("GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", e.host)
	if _, serr := net.send_tcp(sock, transmute([]u8)req); serr != nil {
		return rt.box(Err_Msg{reason = rt.msg_text_fmt("send: %v", serr)}, context.allocator)
	}

	buf: [1024]u8
	n: int
	rerr: net.TCP_Recv_Error
	waited: time.Duration
	for {
		// Checked BEFORE every attempt, not just the first: this is the loop
		// iteration RECV_POLL's short timeout exists to create, see this
		// proc's own doc comment above.
		if rt.cancel_requested(cancel) {
			return rt.box(Err_Msg{reason = rt.msg_text_from("cancelled")}, context.allocator)
		}
		n, rerr = net.recv_tcp(sock, buf[:])
		if rerr == nil { break }
		// SO_RCVTIMEO expiry surfaces as .Would_Block (EAGAIN/EWOULDBLOCK),
		// NOT .Timeout -- verified against this exact toolchain, not assumed
		// from the doc comments: TCP_Recv_Error's own .Timeout variant is
		// produced only by ETIMEDOUT (core:net/errors_linux.odin), a
		// different, connection-level condition net.set_option's
		// .Receive_Timeout does not raise. Checking .Timeout here instead of
		// .Would_Block was tried first and is a real bug, not a hypothetical
		// one: it made this loop treat the FIRST RECV_POLL expiry as a
		// terminal error ("recv: Would_Block") and return immediately,
		// which is worse than doing nothing -- see
		// docs/superpowers/cancellation-decision.md for how this was caught
		// (a live pty run against tools/stallserver exited in ~80µs instead
		// of blocking, and stderr had the answer).
		if rerr == .Would_Block {
			waited += RECV_POLL
			if waited >= RECV_MAX_WAIT {
				return rt.box(Err_Msg{reason = rt.msg_text_from("recv: timed out waiting for a reply")}, context.allocator)
			}
			continue
		}
		return rt.box(Err_Msg{reason = rt.msg_text_fmt("recv: %v", rerr)}, context.allocator)
	}
	if n < 12 {
		return rt.box(Err_Msg{reason = rt.msg_text_fmt("recv: short read (%d bytes)", n)}, context.allocator)
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

// host/port, not the HOST/PORT constants directly: view() needs to reflect
// whatever main() actually dialed, which may be the RT_HTTP_HOST/RT_HTTP_PORT
// override -- see main()'s own comment. Model is Cmd env's cousin, not a Msg
// (never passed to box()), so a bare `string` field is fine here, unlike
// Err_Msg's Msg_Text above.
Model :: struct { host: string, port: int, status: int, err: string, done: bool }

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
	if m.done      { return fmt.aprintf("http://%s:%d -> %d\n", m.host, m.port, m.status, allocator = alloc) }
	return fmt.aprintf("Checking http://%s:%d ...\n", m.host, m.port, allocator = alloc)
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

	// Overridable target -- see HOST/PORT's own doc comment above. Read once
	// here, not baked into check_server: this is the ONLY thing that changes
	// to point this exact binary at tools/stallserver for the quit-latency
	// demonstration in docs/superpowers/cancellation-decision.md.
	host := HOST
	port := PORT
	if v := os.get_env("RT_HTTP_HOST", context.allocator); v != "" { host = v }
	if v := os.get_env("RT_HTTP_PORT", context.allocator); v != "" {
		if n, ok := strconv.parse_int(v); ok { port = n }
	}

	// The initial Cmd. Go: `Init() Cmd { return checkServer }` -- one
	// identifier, because checkServer is already a closure of the right type.
	// RuneTea: cmd_from + a heap-cloned env struct that had to be declared.
	init := rt.cmd_from(check_server, Check_Env{host = host, port = port}, context.allocator)

	p: rt.Program(Model)
	rt.program_init(&p, Model{host = host, port = port}, update, view, init)

	if err := rt.run(&p, &src, &b, fd); err != nil { fmt.eprintln("error:", err) }
}
