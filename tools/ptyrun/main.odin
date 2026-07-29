package main

// Runs a RuneTea binary under a REAL pty, types at it, and prints back
// everything the program wrote to the terminal.
//
//   ptyrun <binary> <hex-keystrokes> [cols] [rows] [timeout_ms]
//
// The keystrokes are hex so that escape sequences (arrows, Ctrl bytes) go
// through a shell argument without any quoting question: "1b5b41" is Up,
// "71" is 'q'. They are written ONE AT A TIME with a short pause, which is
// what makes this a keyboard rather than a paste -- a whole sequence arriving
// in a single read() would exercise a decoder path a human never produces.
//
// WHY A REAL pty AND NOT A PIPE. tools/ttycheck's own comment makes the
// general case; the specific one here is that a pipe answers `term_size` with
// nothing, and a RuneTea program with no known width renders a DIFFERENT byte
// stream (rows_for_line degrades to one row per logical line; .Diff degrades
// to a full repaint -- see docs/LIMITATIONS.md 3.5, 4.5). A documentation
// checker that drove its samples over a pipe would be verifying output no
// reader will ever see.
//
// The captured bytes are printed to stdout with escapes made visible
// ("\e[2A" rather than a real CSI), because this output is meant to be read,
// grepped and pasted into a report -- writing raw control bytes into the
// parent's own terminal would mean the checker's output rearranges the
// terminal it is being read on.
//
// Exit status: 0 if the child exited 0 within the timeout, 1 otherwise. That
// is what makes this usable as a gate rather than only as a probe -- see
// tools/doccheck/run.sh, which asserts on both the status and the text.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

// core:sys/linux exposes TIOCGWINSZ but not TIOCSWINSZ; 0x5414 is its
// well-known Linux ioctl-number neighbour. Same constant, same reasoning, as
// tools/wincheck.
TIOCSWINSZ :: 0x5414

Winsize :: struct {
	ws_row, ws_col, ws_xpixel, ws_ypixel: u16,
}

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: ptyrun <binary> <hex-keystrokes> [cols] [rows] [timeout_ms]")
		os.exit(2)
	}
	bin  := os.args[1]
	keys, keys_ok := unhex(os.args[2])
	if !keys_ok {
		fmt.eprintfln("ptyrun: keystrokes must be an even-length hex string, got %q", os.args[2])
		os.exit(2)
	}
	defer delete(keys)

	cols       := arg_int(3, 80)
	rows       := arg_int(4, 24)
	timeout_ms := arg_int(5, 5000)

	master := posix.posix_openpt({.RDWR, .NOCTTY})
	if master < 0 {
		fmt.eprintln("ptyrun: posix_openpt failed:", posix.errno())
		os.exit(1)
	}
	defer posix.close(master)
	if posix.grantpt(master) != .OK || posix.unlockpt(master) != .OK {
		fmt.eprintln("ptyrun: grantpt/unlockpt failed:", posix.errno())
		os.exit(1)
	}
	name := posix.ptsname(master)
	if name == nil {
		fmt.eprintln("ptyrun: ptsname failed:", posix.errno())
		os.exit(1)
	}

	// Give the pty a size BEFORE the child is spawned, so its very first
	// term_size() -- which runs inside run(), before any frame is painted --
	// already has an answer. A size delivered later would only reach the
	// program as a Window_Size_Msg on SIGWINCH.
	ws := Winsize{ws_row = u16(rows), ws_col = u16(cols)}
	if res := linux.ioctl(linux.Fd(master), TIOCSWINSZ, uintptr(rawptr(&ws))); int(res) < 0 {
		fmt.eprintln("ptyrun: ioctl(TIOCSWINSZ) failed")
		os.exit(1)
	}

	child := posix.fork()
	if child < 0 {
		fmt.eprintln("ptyrun: fork failed:", posix.errno())
		os.exit(1)
	}
	if child == 0 {
		// setsid() first: the slave becomes this process's controlling
		// terminal only in a fresh session, and without one a program that
		// reads its own tty is reading the harness's instead.
		posix.setsid()
		slave := posix.open(name, {.RDWR})
		if slave < 0 { posix._exit(127) }
		posix.dup2(slave, posix.STDIN_FILENO)
		posix.dup2(slave, posix.STDOUT_FILENO)
		posix.dup2(slave, posix.STDERR_FILENO)
		if slave > 2 { posix.close(slave) }

		bin_c := strings.clone_to_cstring(bin)
		argv  := []cstring{bin_c, nil}
		posix.execv(bin_c, raw_data(argv))
		posix._exit(127) // execv returns only on failure
	}

	// O_NONBLOCK on the master so draining never parks: this loop has to keep
	// reading WHILE it types, because a program that paints a frame per
	// keystroke can fill the pty's buffer, and a full buffer blocks the CHILD's
	// write -- which would deadlock a harness that only read at the end.
	flags := posix.fcntl(master, .GETFL)
	posix.fcntl(master, .SETFL, flags | i32(posix.O_NONBLOCK))

	captured := strings.builder_make()
	defer strings.builder_destroy(&captured)

	// Let the child install its handlers, enter raw mode and paint frame 0.
	settle(master, &captured, 300 * time.Millisecond)

	for k in keys {
		b := [1]u8{k}
		posix.write(master, raw_data(b[:]), 1)
		settle(master, &captured, 80 * time.Millisecond)
	}

	deadline := time.Duration(timeout_ms) * time.Millisecond
	start    := time.now()
	status:  i32
	exited   := false
	for time.since(start) < deadline {
		drain(master, &captured)
		if posix.waitpid(child, &status, {.NOHANG}) == child { exited = true; break }
		time.sleep(10 * time.Millisecond)
	}
	drain(master, &captured)

	fmt.println(escape_visible(strings.to_string(captured)))

	if !exited {
		fmt.eprintfln("ptyrun: child did not exit within %dms -- killing", timeout_ms)
		posix.kill(child, .SIGKILL)
		posix.waitpid(child, &status, {})
		os.exit(1)
	}
	// WIFEXITED/WEXITSTATUS by hand: core:sys/posix has the macros only as
	// platform-specific bit layouts, and the low byte being zero is exactly
	// "exited normally" on Linux.
	if status & 0x7F != 0 {
		fmt.eprintfln("ptyrun: child died on signal %d", status & 0x7F)
		os.exit(1)
	}
	code := (status >> 8) & 0xFF
	if code != 0 {
		fmt.eprintfln("ptyrun: child exited %d", code)
		os.exit(1)
	}
}

@(private = "file")
arg_int :: proc(idx: int, dflt: int) -> int {
	if len(os.args) <= idx { return dflt }
	if n, ok := strconv.parse_int(os.args[idx]); ok { return n }
	return dflt
}

// Reads until EAGAIN. Never blocks -- see the O_NONBLOCK note at the call site.
@(private = "file")
drain :: proc(master: posix.FD, out: ^strings.Builder) {
	buf: [4096]u8
	for {
		n := posix.read(master, raw_data(buf[:]), len(buf))
		if n <= 0 { return }
		strings.write_bytes(out, buf[:n])
	}
}

@(private = "file")
settle :: proc(master: posix.FD, out: ^strings.Builder, d: time.Duration) {
	start := time.now()
	for time.since(start) < d {
		drain(master, out)
		time.sleep(5 * time.Millisecond)
	}
	drain(master, out)
}

@(private = "file")
unhex :: proc(s: string) -> (out: []u8, ok: bool) {
	if len(s) % 2 != 0 { return nil, false }
	buf := make([]u8, len(s) / 2)
	for i in 0 ..< len(buf) {
		hi := nybble(s[i * 2])
		lo := nybble(s[i * 2 + 1])
		if hi < 0 || lo < 0 { delete(buf); return nil, false }
		buf[i] = u8(hi * 16 + lo)
	}
	return buf, true
}

@(private = "file")
nybble :: proc(c: u8) -> int {
	switch {
	case c >= '0' && c <= '9': return int(c - '0')
	case c >= 'a' && c <= 'f': return int(c - 'a') + 10
	case c >= 'A' && c <= 'F': return int(c - 'A') + 10
	}
	return -1
}

// ESC as a literal "\e", every other C0 byte as "\xNN", everything else
// through unchanged. CR is spelled "\r" and LF is left real, so the captured
// frames still read as frames.
@(private = "file")
escape_visible :: proc(s: string) -> string {
	b := strings.builder_make()
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c == 0x1B: strings.write_string(&b, "\\e")
		case c == '\n': strings.write_byte(&b, '\n')
		case c == '\r': strings.write_string(&b, "\\r")
		case c < 0x20 || c == 0x7F: fmt.sbprintf(&b, "\\x%02X", c)
		case: strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}
