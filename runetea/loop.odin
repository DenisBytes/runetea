package runetea

import "core:sys/posix"

// Explicit vtable rather than an interface. Three implementations matter:
//   - fd     : the real tty (and, via nbio, any pollable handle)
//   - bytes  : the golden harness and unit tests, no terminal involved
//   - stream : reserved for core:io.Stream injection (v1.0)
//
// The seam also isolates the one unvalidated platform risk: if nbio's kqueue
// path misbehaves on Darwin /dev/tty, a posix.poll implementation drops in here
// without touching anything above.
//
// read() reports three independent outcomes, not two, because a blocked
// reader can become unblocked for two UNRELATED reasons that a caller (Task
// 10's reader thread) must be able to tell apart: the source ran out of
// data (EOF -- input is gone, a real end condition) versus input_wake() was
// called from another thread (shutdown requested -- expected, not an
// error). Overloading (0, false) for both would make a clean quit
// indistinguishable from input dying mid-program.
//   got data:  n > 0, ok = true,  woken = false
//   EOF:       n = 0,  ok = false, woken = false
//   woken:     n = 0,  ok = false, woken = true
Input_Source :: struct {
	self:  rawptr,
	read:  proc(self: rawptr, buf: []u8) -> (n: int, ok: bool, woken: bool),
	close: proc(self: rawptr),
	wake:  proc(self: rawptr),
}

input_read :: proc(src: ^Input_Source, buf: []u8) -> (n: int, ok: bool, woken: bool) {
	if src.read == nil { return 0, false, false }
	return src.read(src.self, buf)
}

input_close :: proc(src: ^Input_Source) {
	if src.close != nil { src.close(src.self) }
}

// Unblocks a thread currently parked inside input_read(src, ...), called
// from a DIFFERENT thread (typically the main thread signaling shutdown to
// a dedicated reader thread). See Fd_Source's wake pipe below for why this
// is safe to call concurrently with an in-flight read.
input_wake :: proc(src: ^Input_Source) {
	if src.wake != nil { src.wake(src.self) }
}

// --- fd-backed ---

// wake_r/wake_w are a self-pipe used only for cancellation. fd_source_read's
// poll() call always watches wake_r alongside the real data fd; input_wake
// writes one byte to wake_w, which wakes a thread parked in that poll()
// immediately, regardless of whether more input ever arrives on fd. Without
// this, a thread blocked reading a real tty has nothing that can interrupt
// it -- the normal case when a user quits via a UI action rather than a
// keypress, which would otherwise hang a caller's thread.join() forever.
//
// fd, wake_r, and wake_w are all set exactly once, in input_source_from_fd,
// and never mutated afterward. That is what makes calling input_wake (pure
// write) from one thread safe while another thread is inside fd_source_read
// (poll + read) on the same source: there is no mutable shared state to
// race on, and a write of 1 byte to a pipe is atomic per POSIX (well under
// PIPE_BUF).
Fd_Source :: struct {
	fd:     posix.FD,
	wake_r: posix.FD,
	wake_w: posix.FD,
}

input_source_from_fd :: proc(fd: posix.FD) -> (Input_Source, bool) {
	if fd < 0 { return {}, false }
	wake_fds: [2]posix.FD
	if posix.pipe(&wake_fds) != .OK { return {}, false }

	// wake_r MUST be non-blocking. fd_source_read's drain loop below reads
	// wake_r until it comes up empty (posix.pipe fds are blocking by
	// default) -- with a blocking fd, the read that drains the LAST queued
	// byte doesn't return 0, it blocks waiting for the next one, since
	// wake_w stays open for the source's whole lifetime. That deadlocked
	// the drain loop outright the first time this was tested end-to-end
	// (confirmed via /proc/<pid>/task/*/wchan showing a worker thread
	// parked in the kernel's pipe_read, not poll).
	flags := posix.fcntl(wake_fds[0], .GETFL)
	if flags < 0 || posix.fcntl(wake_fds[0], .SETFL, transmute(posix.O_Flags)flags + {.NONBLOCK}) < 0 {
		posix.close(wake_fds[0])
		posix.close(wake_fds[1])
		return {}, false
	}

	s := new(Fd_Source)
	s.fd     = fd
	s.wake_r = wake_fds[0]
	s.wake_w = wake_fds[1]
	return Input_Source{
		self  = s,
		read  = fd_source_read,
		close = fd_source_close,
		wake  = fd_source_wake,
	}, true
}

// posix.read/posix.poll are bare libc bindings (core:sys/posix/unistd.odin,
// poll.odin) with no EINTR retry of their own. A blocking read/poll on a tty
// interrupted by a signal before any data transfers returns -1/EINTR -- this
// is normal, expected behavior, not an error. Task 7 installs a SIGWINCH
// handler that fires repeatedly while a user drags a window edge; without
// the retries below, the very first resize during the program's lifetime
// would silently kill input for the rest of the run. Retrying is done here,
// inside the loop, rather than by masking the signal on this thread: masking
// would be an undocumented, fragile coupling to thread-creation/signal-mask
// inheritance order that a later task could easily break without noticing.
@(private = "file")
fd_source_read :: proc(self: rawptr, buf: []u8) -> (n: int, ok: bool, woken: bool) {
	s := cast(^Fd_Source)self
	for {
		pfds := [2]posix.pollfd{
			{fd = s.fd,     events = {.IN}},
			{fd = s.wake_r, events = {.IN}},
		}
		pres := posix.poll(&pfds[0], posix.nfds_t(len(pfds)), -1)
		if pres < 0 {
			if posix.errno() == .EINTR { continue }
			return 0, false, false
		}

		if pfds[1].revents & {.IN, .HUP, .ERR} != {} {
			// Drain every queued wake byte. Without this, several input_wake
			// calls that land before the reader is scheduled would leave
			// bytes queued that fire a spurious extra wake on some later,
			// unrelated read.
			drain: [64]u8
			for {
				got := posix.read(s.wake_r, raw_data(drain[:]), len(drain))
				if got <= 0 { break }
			}
			return 0, false, true
		}

		if pfds[0].revents & {.IN, .HUP, .ERR, .NVAL} != {} {
			got := posix.read(s.fd, raw_data(buf), len(buf))
			if got < 0 {
				if posix.errno() == .EINTR { continue }
				return 0, false, false
			}
			return int(got), got > 0, false
		}
		// Neither fd actually had anything -- re-poll.
	}
}

@(private = "file")
fd_source_close :: proc(self: rawptr) {
	s := cast(^Fd_Source)self
	// Only the wake pipe is owned by this source -- s.fd belongs to the
	// caller (e.g. stdin) and is never closed here, same contract the
	// original implementation and its tests already relied on.
	posix.close(s.wake_r)
	posix.close(s.wake_w)
	free(s)
}

@(private = "file")
fd_source_wake :: proc(self: rawptr) {
	s := cast(^Fd_Source)self
	b := [1]u8{1}
	posix.write(s.wake_w, raw_data(b[:]), 1)
}

// --- byte-slice backed ---

Bytes_Source :: struct { data: []u8, pos: int }

input_source_from_bytes :: proc(data: []u8) -> Input_Source {
	s := new(Bytes_Source)
	s.data = data
	return Input_Source{
		self  = s,
		read  = bytes_source_read,
		close = bytes_source_close,
		wake  = bytes_source_wake,
	}
}

@(private = "file")
bytes_source_read :: proc(self: rawptr, buf: []u8) -> (n: int, ok: bool, woken: bool) {
	s := cast(^Bytes_Source)self
	if s.pos >= len(s.data) { return 0, false, false }
	n = copy(buf, s.data[s.pos:])
	s.pos += n
	return n, n > 0, false
}

@(private = "file")
bytes_source_close :: proc(self: rawptr) { free(cast(^Bytes_Source)self) }

// Never blocks, so there is nothing to cancel.
@(private = "file")
bytes_source_wake :: proc(self: rawptr) {}
