package main

// Deliberately stalled TCP server for the quit-latency demonstration in
// docs/superpowers/cancellation-decision.md: listens, accepts every
// connection, and then never reads or writes another byte on it. This is
// the concrete shape of "a stalled host" spike-findings.md addendum item 5
// names -- examples/http's check_server (and tools/http_nbio's copy) do a
// real GET against it and, before the T1 fix, would block forever in
// net.recv_tcp with no way for run() to notice.
//
// Usage: tools/stallserver [port]  (default 18080)

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"

main :: proc() {
	port := 18080
	if len(os.args) > 1 {
		if p, ok := strconv.parse_int(os.args[1]); ok { port = p }
	}

	ep := net.Endpoint{address = net.IP4_Loopback, port = port}
	sock, err := net.listen_tcp(ep)
	if err != nil {
		fmt.eprintln("stallserver: listen failed:", err)
		os.exit(1)
	}
	defer net.close(sock)

	fmt.printfln("stallserver: listening on 127.0.0.1:%d -- accepts connections and never replies", port)

	for {
		client, _, aerr := net.accept_tcp(sock)
		if aerr != nil {
			fmt.eprintln("stallserver: accept failed:", aerr)
			continue
		}
		fmt.println("stallserver: accepted a connection, holding it open with no reply")
		// Deliberately never read or written to, and deliberately never
		// closed: the whole point is a client-side net.recv_tcp that has
		// nothing to wake it except its own timeout/cancellation -- closing
		// or resetting this end would send a FIN/RST that unblocks the
		// client's recv_tcp for a completely different reason than what
		// this tool exists to demonstrate. This process is short-lived
		// (started and killed by the harness driving the demonstration), so
		// leaking the client handle for the life of the process is fine.
	}
}
