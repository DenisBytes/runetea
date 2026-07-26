package main

// Drives a target binary (a build of examples/http, or the faithful "before"
// variant docs/superpowers/cancellation-decision.md describes -- same logic,
// HOST/PORT pointed locally) under a REAL pty, against a stalled server
// (tools/stallserver), and measures the actual quit latency this whole T1
// change exists to fix.
//
// Real /dev/ptmx, not a pipe -- same reasoning as tools/ttycheck: this is
// the one thing a pipe cannot answer (whether the terminal is genuinely left
// raw/cooked), and it is exactly the terminal-state claim
// spike-findings.md addendum item 5 makes ("a stalled host freezes the UI
// with the terminal still raw").
//
// Usage: httpquitcheck <binary> <key|sigint> [host] [port]
//   key:    writes 'q' to the pty master (the child's stdin) and times how
//           long the child takes to exit.
//   sigint: sends SIGINT directly to the child process and times the same.
//
// In both modes, reports the pty MASTER's own termios (ECHO/ICANON) right
// after the child has had a moment to enter raw mode, and again after the
// child has exited (or the bounded wait gives up) -- master and slave share
// one underlying tty line-discipline instance, so tcgetattr on the master
// reflects whatever the child did via tcsetattr on the slave (term.odin's
// term_enter_raw/term_restore), without this harness needing the slave fd
// itself once the child has taken it over.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: httpquitcheck <binary> <key|sigint> [host] [port]")
		os.exit(2)
	}
	bin := os.args[1]
	mode := os.args[2]
	host := len(os.args) > 3 ? os.args[3] : "127.0.0.1"
	port := len(os.args) > 4 ? os.args[4] : "18099"

	master := posix.posix_openpt({.RDWR, .NOCTTY})
	if master < 0 {
		fmt.eprintln("BLOCKED: posix_openpt failed:", posix.errno())
		os.exit(1)
	}
	defer posix.close(master)
	if posix.grantpt(master) != .OK || posix.unlockpt(master) != .OK {
		fmt.eprintln("BLOCKED: grantpt/unlockpt failed:", posix.errno())
		os.exit(1)
	}
	name := posix.ptsname(master)
	if name == nil {
		fmt.eprintln("BLOCKED: ptsname failed:", posix.errno())
		os.exit(1)
	}

	before: posix.termios
	posix.tcgetattr(master, &before)
	fmt.printfln("pty termios before spawn:  ECHO=%-5v ICANON=%-5v (cooked -- default pty state)",
		.ECHO in before.c_lflag, .ICANON in before.c_lflag)

	child := posix.fork()
	if child == 0 {
		posix.setsid()
		slave := posix.open(name, {.RDWR})
		if slave < 0 { posix._exit(127) }
		posix.dup2(slave, posix.STDIN_FILENO)
		posix.dup2(slave, posix.STDOUT_FILENO)
		posix.dup2(slave, posix.STDERR_FILENO)
		if slave > 2 { posix.close(slave) }

		host_c := strings.clone_to_cstring(host)
		port_c := strings.clone_to_cstring(port)
		posix.setenv(cstring("RT_HTTP_HOST"), host_c, true)
		posix.setenv(cstring("RT_HTTP_PORT"), port_c, true)

		bin_c := strings.clone_to_cstring(bin)
		argv := []cstring{bin_c, nil}
		posix.execv(bin_c, raw_data(argv))
		posix._exit(127)   // execv only returns on failure
	}

	// Give the child a moment to install crash handlers, enter raw mode, do
	// its initial paint, and dispatch check_server against the stalled
	// server -- long enough that the "raw" snapshot below is not a race
	// against the child's own startup.
	time.sleep(300 * time.Millisecond)

	raw: posix.termios
	posix.tcgetattr(master, &raw)
	fmt.printfln("pty termios after spawn:   ECHO=%-5v ICANON=%-5v (raw expected -- false/false -- once term_enter_raw has run)",
		.ECHO in raw.c_lflag, .ICANON in raw.c_lflag)

	start := time.now()
	switch mode {
	case "key":
		q := []u8{'q'}
		posix.write(master, raw_data(q), 1)
		fmt.println("sent: 'q' keypress")
	case "sigint":
		posix.kill(child, .SIGINT)
		fmt.println("sent: SIGINT to the child process")
	case:
		fmt.eprintln("unknown mode (want key|sigint):", mode)
		os.exit(2)
	}

	// Bounded: generous enough to show a real hang clearly (the whole point
	// of the "before" run) without hanging this harness itself forever.
	TIMEOUT :: 8 * time.Second
	status: i32
	exited := false
	for time.since(start) < TIMEOUT {
		wpid := posix.waitpid(child, &status, {.NOHANG})
		if wpid == child {
			exited = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	elapsed := time.since(start)

	after: posix.termios
	posix.tcgetattr(master, &after)

	if exited {
		fmt.printfln("RESULT: exited after %v (mode=%s, target=%s:%s)", elapsed, mode, host, port)
	} else {
		fmt.printfln("RESULT: still running after %v (mode=%s, target=%s:%s) -- HUNG, killing with SIGKILL", elapsed, mode, host, port)
		posix.kill(child, .SIGKILL)
		posix.waitpid(child, &status, {})
	}
	fmt.printfln("pty termios after wait:    ECHO=%-5v ICANON=%-5v (cooked expected -- true/true -- ONLY if term_restore() actually ran before exit)",
		.ECHO in after.c_lflag, .ICANON in after.c_lflag)
}
