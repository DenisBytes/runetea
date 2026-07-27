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
// batch() DEMONSTRATION (docs/superpowers/batch-sequence-decision.md): this
// example now checks TWO hosts CONCURRENTLY via a single `rt.batch(...)` Cmd
// returned from Init, rather than firing one Cmd -- the whole point of this
// file existing in its extended form. Both checks start together; whichever
// finishes first updates its own line immediately, and the program only
// quits once BOTH are done (or the user quits manually) -- results arrive in
// whatever order the network actually returns them, exactly batch()'s
// documented "no ordering guarantee" contract, made visible on a real
// terminal instead of only in a unit test.
//
// Overridable via RT_HTTP_HOST/RT_HTTP_PORT (host 1) and RT_HTTP_HOST2/
// RT_HTTP_PORT2 (host 2) so the SAME binary can be pointed at a deliberately
// stalled local server for the quit-latency demonstration in
// docs/superpowers/cancellation-decision.md (tools/stallserver) without a
// second copy of this example. Defaults to two distinct real hosts so the
// concurrency is genuine, not simulated.
HOST  :: "example.com"
PORT  :: 80
HOST2 :: "example.org"
PORT2 :: 80

// Go: `func checkServer() tea.Msg { ... }` -- a closure over nothing.
// RuneTea: an explicit env struct, because Odin has no closures. `idx`
// (0 or 1) is new for the batch() extension -- it is how a Status_Msg/Err_Msg
// tells update() WHICH of the two concurrent checks it belongs to, since
// batch() gives no ordering guarantee about which one's result arrives
// first.
Check_Env :: struct { host: string, port: int, idx: int }

Status_Msg :: struct { idx: int, code: int }

// Msg_Text, not string: box()'s MESSAGE OWNERSHIP CONTRACT (runetea/
// arena.odin) requires every boxed Msg to be POD, and check_server runs on a
// Dispatcher pool worker -- a different thread from whichever one eventually
// reads this message -- so `reason` cannot be a bare `string` pointing at a
// separate fmt.aprintf allocation the way it did before the T1
// message-ownership decision (docs/superpowers/message-ownership-decision.md).
Err_Msg :: struct { idx: int, reason: rt.Msg_Text }

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
//     Doubly relevant now that check_server runs as a batch() child: quitting
//     mid-check must not leave either host's Cmd running longer than it
//     would standalone.
RECV_POLL     :: 200 * time.Millisecond
RECV_MAX_WAIT :: 30 * time.Second   // hard cap even if the user never quits and the host never replies

check_server :: proc(env: rawptr, cancel: ^rt.Cancel_Token) -> any {
	e := cast(^Check_Env)env

	sock, derr := net.dial_tcp_from_hostname_with_port_override(e.host, e.port)
	if derr != nil {
		return rt.box(Err_Msg{idx = e.idx, reason = rt.msg_text_fmt("dial: %v", derr)}, context.allocator)
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
		return rt.box(Err_Msg{idx = e.idx, reason = rt.msg_text_fmt("send: %v", serr)}, context.allocator)
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
			return rt.box(Err_Msg{idx = e.idx, reason = rt.msg_text_from("cancelled")}, context.allocator)
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
				return rt.box(Err_Msg{idx = e.idx, reason = rt.msg_text_from("recv: timed out waiting for a reply")}, context.allocator)
			}
			continue
		}
		return rt.box(Err_Msg{idx = e.idx, reason = rt.msg_text_fmt("recv: %v", rerr)}, context.allocator)
	}
	if n < 12 {
		return rt.box(Err_Msg{idx = e.idx, reason = rt.msg_text_fmt("recv: short read (%d bytes)", n)}, context.allocator)
	}

	// "HTTP/1.1 200 OK" -- the status code is bytes 9..12
	code := 0
	for c in buf[9:12] {
		if c < '0' || c > '9' { break }
		code = code * 10 + int(c - '0')
	}
	if code == 0 {
		return rt.box(Err_Msg{idx = e.idx, reason = rt.msg_text_from("unparseable status line")}, context.allocator)
	}
	return rt.box(Status_Msg{idx = e.idx, code = code}, context.allocator)
}

// One slot per concurrent check. Cmd env's cousin, not a Msg (never passed
// to box()), so a bare `string` field is fine here, unlike Err_Msg's
// Msg_Text above.
Check_Slot :: struct { host: string, port: int, status: int, err: string, done: bool }

Model :: struct { checks: [2]Check_Slot }

// `m` is a POINTER: mutate it in place, return only the Cmd. See
// rt.Program.update (runetea/tea.odin).
update :: proc(m: ^Model, msg: any, alloc: mem.Allocator) -> rt.Cmd {
	switch v in msg {
	case rt.Key_Msg:
		if v.code == .Rune && (v.r == 'q' || (v.r == 'c' && .Ctrl in v.mods)) {
			return rt.quit_cmd()
		}
	case Status_Msg:
		m.checks[v.idx].status = v.code
		m.checks[v.idx].done = true
		if all_checks_done(m^) { return rt.quit_cmd() }
	case Err_Msg:
		// The ONLY way to get a `string` out of a Msg_Text is
		// rt.msg_text_clone, and it always allocates a fresh, independent
		// copy (msg.odin) -- required here specifically: run()'s loop frees
		// this Err_Msg right after update() returns (apply(), tea.odin), so
		// anything retained in the model must not alias the box's storage.
		m.checks[v.idx].err = rt.msg_text_clone(v.reason, context.allocator)
		m.checks[v.idx].done = true
		if all_checks_done(m^) { return rt.quit_cmd() }
	}
	return rt.cmd_nil()
}

all_checks_done :: proc(m: Model) -> bool {
	for c in m.checks { if !c.done { return false } }
	return true
}

view :: proc(m: Model, alloc: mem.Allocator) -> string {
	sb := strings.builder_make(alloc)
	for c in m.checks {
		if c.err != "" {
			fmt.sbprintfln(&sb, "http://%s:%d -> error: %s", c.host, c.port, c.err)
		} else if c.done {
			fmt.sbprintfln(&sb, "http://%s:%d -> %d", c.host, c.port, c.status)
		} else {
			fmt.sbprintfln(&sb, "http://%s:%d -> checking...", c.host, c.port)
		}
	}
	return strings.to_string(sb)
}

main :: proc() {
	fd := posix.FD(os.fd(os.stdin))
	// install_crash_handlers BEFORE term_enter_raw, not after: term_enter_raw
	// flips raw_active = true before tcsetattr has actually touched the tty,
	// so a crash landing in that window is only recoverable if a handler
	// already exists to catch it (see install_crash_handlers' doc comment).
	rt.install_crash_handlers()
	// Opt IN to the Kitty keyboard protocol's disambiguation flag. The default
	// is {} -- touch nothing -- because the application owns the terminal here,
	// not the framework (rt.run() never enters raw mode itself). With
	// .Disambiguate the terminal stops collapsing Ctrl+I onto Tab, Ctrl+M onto
	// Enter and Ctrl+[ onto Escape, so those become distinguishable keypresses
	// instead of a Legacy_Key_Encoding coin-flip; a terminal that does not
	// speak the protocol ignores the sequence and everything keeps working on
	// the legacy encoding.
	//
	// Deliberately NOT .Report_Event_Types: with event types on, every key
	// arrives twice (press and release), and this update() -- like most
	// straightforward Bubble Tea-shaped apps -- does not filter on
	// Key_Msg.kind, so it would count each keystroke twice. Opting into that
	// is a decision an app makes together with the matching `if key.kind !=
	// .Press { ... }` check.
	//
	// The matching pop is written by rt.term_restore() below, and by the
	// crash-signal path -- exactly once between them, whichever runs.
	if !rt.term_enter_raw(fd, {.Disambiguate}) { fmt.eprintln("not a tty"); os.exit(1) }
	defer rt.term_restore()

	src, ok := rt.input_source_from_fd(fd)
	if !ok { fmt.eprintln("bad input source"); os.exit(1) }
	defer rt.input_close(&src)

	b := strings.builder_make(); defer strings.builder_destroy(&b)

	// Overridable targets -- see HOST/PORT/HOST2/PORT2's own doc comment
	// above. Read once here, not baked into check_server: this is the ONLY
	// thing that changes to point this exact binary at tools/stallserver for
	// the quit-latency demonstration in docs/superpowers/cancellation-
	// decision.md.
	host1, port1 := HOST, PORT
	if v := os.get_env("RT_HTTP_HOST", context.allocator); v != "" { host1 = v }
	if v := os.get_env("RT_HTTP_PORT", context.allocator); v != "" {
		if n, ok := strconv.parse_int(v); ok { port1 = n }
	}
	host2, port2 := HOST2, PORT2
	if v := os.get_env("RT_HTTP_HOST2", context.allocator); v != "" { host2 = v }
	if v := os.get_env("RT_HTTP_PORT2", context.allocator); v != "" {
		if n, ok := strconv.parse_int(v); ok { port2 = n }
	}

	// THE batch() demonstration: both checks are handed to update()'s
	// Init Cmd together, as a single rt.batch(...) -- from update()'s point
	// of view this is exactly one Cmd, same as returning check1 alone would
	// have been, but it runs check1 and check2 CONCURRENTLY, and either one's
	// result reaches update() the moment it completes, independent of the
	// other. Go: `Init() Cmd { return checkServer }` -- one identifier,
	// because checkServer is already a closure of the right type. RuneTea:
	// cmd_from + a heap-cloned env struct per check, composed with batch().
	cmds := []rt.Cmd{
		rt.cmd_from(check_server, Check_Env{host = host1, port = port1, idx = 0}, context.allocator),
		rt.cmd_from(check_server, Check_Env{host = host2, port = port2, idx = 1}, context.allocator),
	}
	init := rt.batch(cmds, context.allocator)

	p: rt.Program(Model)
	rt.program_init(&p, Model{checks = {
		0 = Check_Slot{host = host1, port = port1},
		1 = Check_Slot{host = host2, port = port2},
	}}, update, view, init)

	if err := rt.run(&p, &src, &b, fd); err != nil { fmt.eprintln("error:", err) }
}
