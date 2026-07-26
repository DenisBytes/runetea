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
Input_Source :: struct {
	self:  rawptr,
	read:  proc(self: rawptr, buf: []u8) -> (n: int, ok: bool),
	close: proc(self: rawptr),
}

input_read :: proc(src: ^Input_Source, buf: []u8) -> (n: int, ok: bool) {
	if src.read == nil { return 0, false }
	return src.read(src.self, buf)
}

input_close :: proc(src: ^Input_Source) {
	if src.close != nil { src.close(src.self) }
}

// --- fd-backed ---

Fd_Source :: struct { fd: posix.FD }

input_source_from_fd :: proc(fd: posix.FD) -> (Input_Source, bool) {
	if fd < 0 { return {}, false }
	s := new(Fd_Source)
	s.fd = fd
	return Input_Source{
		self  = s,
		read  = proc(self: rawptr, buf: []u8) -> (n: int, ok: bool) {
			s := cast(^Fd_Source)self
			got := posix.read(s.fd, raw_data(buf), len(buf))
			if got < 0 { return 0, false }
			return int(got), got > 0
		},
		close = proc(self: rawptr) { free(cast(^Fd_Source)self) },
	}, true
}

// --- byte-slice backed ---

Bytes_Source :: struct { data: []u8, pos: int }

input_source_from_bytes :: proc(data: []u8) -> Input_Source {
	s := new(Bytes_Source)
	s.data = data
	return Input_Source{
		self  = s,
		read  = proc(self: rawptr, buf: []u8) -> (n: int, ok: bool) {
			s := cast(^Bytes_Source)self
			if s.pos >= len(s.data) { return 0, false }
			n = copy(buf, s.data[s.pos:])
			s.pos += n
			return n, n > 0
		},
		close = proc(self: rawptr) { free(cast(^Bytes_Source)self) },
	}
}
