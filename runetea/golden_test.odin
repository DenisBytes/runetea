package runetea

import "core:os"
import "core:strings"
import "core:testing"

// Drives a Program from a fixed byte script with no terminal and compares the
// exact output bytes against a committed golden file. This is the instrument
// the T3 diff renderer will be built inside -- wire it up now, while the
// renderer is simple enough that a mismatch is obviously the test's fault.
//
// Regenerate with: odin test . -define:GOLDEN_UPDATE=true
GOLDEN_UPDATE :: #config(GOLDEN_UPDATE, false)

@(test)
test_golden_simple_session :: proc(t: ^testing.T) {
	src := input_source_from_bytes(transmute([]u8)string("aaq"))
	defer input_close(&src)
	b := strings.builder_make(); defer strings.builder_destroy(&b)

	p: Program(Counter)
	program_init(&p, Counter{}, counter_update, counter_view)
	err := run(&p, &src, &b)
	testing.expect(t, err == nil, "run should exit cleanly")

	got := transmute([]u8)strings.to_string(b)
	path := "testdata/simple_session.golden"

	when GOLDEN_UPDATE {
		os.make_directory("testdata")
		werr := os.write_entire_file(path, got)
		testing.expect(t, werr == nil, "failed to write golden")
		return
	}

	want, rerr := os.read_entire_file(path, context.allocator)
	testing.expectf(t, rerr == nil, "missing golden %s -- regenerate with -define:GOLDEN_UPDATE=true", path)
	if rerr != nil { return }
	defer delete(want)

	testing.expectf(t, string(got) == string(want),
		"byte mismatch\n got: %q\nwant: %q", string(got), string(want))
}
