#+private
// ^ Every declaration in this file is package-private, so that `odin doc
//   runetea` / `odin doc runegloss` -- the command README.md and docs/API.md
//   hand a newcomer for symbol discovery -- lists the library rather than the
//   test fixtures. Pinned by tools/doccheck/run.sh's `apidoc` check, which is
//   also where the argument for it is written out.
package runetea

import "core:os"
import "core:path/filepath"
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
	// RESOLVED AGAINST THIS SOURCE FILE, NOT THE PROCESS'S CWD. It used to be
	// the bare relative "testdata/simple_session.golden", which made the whole
	// test a function of where the shell happened to be: `odin test runetea`
	// from the repository root and `odin test .` from inside runetea/ are the
	// two spellings in this project's own docs and scripts, and only the second
	// one found the file. The first reported "missing golden -- regenerate with
	// -define:GOLDEN_UPDATE=true", which is the single worst diagnostic this
	// test could produce: it names a command that, run from that same cwd,
	// WRITES A NEW GOLDEN INTO THE WRONG DIRECTORY and turns a byte mismatch
	// into a green run. #location().file_path is filled in by the compiler with
	// this file's own path, so the golden is found from any cwd and can only
	// ever be regenerated next to itself.
	dir  := filepath.dir(#location().file_path)   // a slice of the literal; no allocation
	path := strings.concatenate({dir, "/testdata/simple_session.golden"}, context.temp_allocator)

	when GOLDEN_UPDATE {
		os.make_directory(strings.concatenate({dir, "/testdata"}, context.temp_allocator))
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
