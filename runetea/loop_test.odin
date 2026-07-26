package runetea

import "core:testing"
import "core:sys/posix"

@(test)
test_input_source_from_bytes_reads_all :: proc(t: ^testing.T) {
	src := input_source_from_bytes([]u8{'a', 'b', 'c'})
	defer input_close(&src)

	buf: [8]u8
	n, ok := input_read(&src, buf[:])
	testing.expect(t, ok, "read should succeed")
	testing.expect_value(t, n, 3)
	testing.expect_value(t, string(buf[:n]), "abc")

	n2, ok2 := input_read(&src, buf[:])
	testing.expect(t, !ok2 || n2 == 0, "second read should report EOF")
}

@(test)
test_input_source_from_bytes_respects_small_buffer :: proc(t: ^testing.T) {
	src := input_source_from_bytes([]u8{'h', 'e', 'l', 'l', 'o'})
	defer input_close(&src)

	buf: [2]u8
	n, ok := input_read(&src, buf[:])
	testing.expect(t, ok, "read should succeed")
	testing.expect_value(t, n, 2)
	testing.expect_value(t, string(buf[:n]), "he")
}

@(test)
test_input_source_from_fd_reads_a_pipe :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect_value(t, posix.pipe(&fds), posix.result.OK)
	defer { posix.close(fds[0]); posix.close(fds[1]) }

	msg := "xyz"
	posix.write(fds[1], raw_data(msg), len(msg))

	src, ok := input_source_from_fd(fds[0])
	testing.expect(t, ok, "fd source should initialise")
	defer input_close(&src)

	buf: [8]u8
	n, rok := input_read(&src, buf[:])
	testing.expect(t, rok, "read should succeed")
	testing.expect_value(t, n, 3)
	testing.expect_value(t, string(buf[:n]), "xyz")
}
