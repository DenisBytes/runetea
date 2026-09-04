#+private
// ^ Every declaration in this file is package-private, so that `odin doc
//   runetea` / `odin doc runegloss` -- the command README.md and docs/API.md
//   hand a newcomer for symbol discovery -- lists the library rather than the
//   test fixtures. Pinned by tools/doccheck/run.sh's `apidoc` check, which is
//   also where the argument for it is written out.
package runetea

import "core:strings"
import "core:testing"

// Msg_Text's cap is intrinsic -- it is what makes the type POD, and POD is what
// lets it cross a Msg boundary at all (arena.odin's MESSAGE OWNERSHIP
// CONTRACT). What is NOT intrinsic is truncation being invisible, and these
// pin the difference.

@(test)
test_msg_text_is_still_pod :: proc(t: ^testing.T) {
	// The `truncated` field must not have cost the type its whole reason to
	// exist. A bool has no pointer in its field tree, so this holds -- but it
	// is one `is_pod_type` call to prove rather than assume.
	testing.expect(t, is_pod_type(Msg_Text), "Msg_Text must stay POD")
}

@(test)
test_msg_text_from_records_whether_it_fitted :: proc(t: ^testing.T) {
	short := msg_text_from("dial: connection refused")
	testing.expect(t, !msg_text_truncated(short), "a short message is not truncated")
	testing.expect_value(t, int(short.len), 24)

	// Exactly at the cap: a full buffer is NOT a truncated one, and an
	// implementation that inferred truncation from `len == MSG_TEXT_CAP` would
	// get this wrong.
	exact := msg_text_from(strings.repeat("x", MSG_TEXT_CAP, context.temp_allocator))
	testing.expect(t, !msg_text_truncated(exact), "an exact fit must not report truncation")
	testing.expect_value(t, int(exact.len), MSG_TEXT_CAP)

	// One byte over.
	over := msg_text_from(strings.repeat("x", MSG_TEXT_CAP + 1, context.temp_allocator))
	testing.expect(t, msg_text_truncated(over), "one byte past the cap must report truncation")
	testing.expect_value(t, int(over.len), MSG_TEXT_CAP)

	// Far over -- an HTTP body, say, which is the realistic way to reach this.
	huge := msg_text_from(strings.repeat("y", 100_000, context.temp_allocator))
	testing.expect(t, msg_text_truncated(huge), "a large payload must report truncation")
	testing.expect_value(t, int(huge.len), MSG_TEXT_CAP)

	free_all(context.temp_allocator)
}

@(test)
test_msg_text_fmt_records_whether_it_fitted :: proc(t: ^testing.T) {
	short := msg_text_fmt("recv: short read (%d bytes)", 12)
	testing.expect(t, !msg_text_truncated(short), "a short formatted message is not truncated")
	s := short
	testing.expect_value(t, msg_text_string(&s), "recv: short read (12 bytes)")

	// fmt.bprintf has no way to say "I wanted more room", which is why
	// msg_text_fmt formats into CAP+1 bytes and keeps CAP. THE EXACT-FIT CASE
	// IS THE ONE THAT PROVES IT: a detector that just checked `len == CAP`
	// would call this truncated, and it is not.
	exact := msg_text_fmt("%s", strings.repeat("z", MSG_TEXT_CAP, context.temp_allocator))
	testing.expect(t, !msg_text_truncated(exact), "an exact formatted fit must not report truncation")
	testing.expect_value(t, int(exact.len), MSG_TEXT_CAP)

	over := msg_text_fmt("%s", strings.repeat("z", MSG_TEXT_CAP + 1, context.temp_allocator))
	testing.expect(t, msg_text_truncated(over), "a formatted message past the cap must report truncation")
	testing.expect_value(t, int(over.len), MSG_TEXT_CAP)

	free_all(context.temp_allocator)
}

@(test)
test_msg_text_truncation_keeps_the_prefix_and_both_accessors_agree :: proc(t: ^testing.T) {
	src := strings.concatenate({"HEAD", strings.repeat("t", 1000, context.temp_allocator)}, context.temp_allocator)
	m := msg_text_from(src)
	mm := m
	borrowed := msg_text_string(&mm)
	cloned := msg_text_clone(m, context.allocator); defer delete(cloned)

	testing.expect_value(t, len(borrowed), MSG_TEXT_CAP)
	testing.expect_value(t, cloned, borrowed)
	testing.expect(t, strings.has_prefix(borrowed, "HEAD"), "truncation must keep the PREFIX")
	testing.expect(t, msg_text_truncated(m), "and must say that it truncated")

	free_all(context.temp_allocator)
}

// A Msg with BOTH shapes an application will actually put in one: a Msg_Text and
// a plain fixed array with its own length. POD, per box()'s MESSAGE OWNERSHIP
// CONTRACT -- neither field is a pointer.
@(private = "file")
Reads_Msg :: struct {
	reason: Msg_Text,
	path:   [16]u8,
	n:      int,
}

// THE TYPE-SWITCH SPELLINGS, pinned.
//
// `switch v in msg` is the control structure every `update` is built out of, and
// its binding is NOT addressable: `msg_text_string(&v.reason)` fails to compile
// with "Cannot take the pointer address of 'v.reason'", and `v.path[:v.n]` fails
// with "value is not addressable". Neither error mentions the fix, so the two
// spellings that DO work are pinned here rather than left to a doc paragraph --
// if a future signature change breaks them, this test stops compiling and the
// suite says so, instead of the next application author discovering it.
//
// This is a COMPILE-SHAPE test as much as a value test: what it asserts is that
// these four lines can be written at all. See Msg_Text's doc comment for why the
// borrowing accessor still takes a pointer, and for the three alternative
// signatures that were measured and rejected.
@(test)
test_msg_text_reads_out_of_a_type_switch_binding :: proc(t: ^testing.T) {
	msg: any = Reads_Msg{
		reason = msg_text_from("dial tcp: connection refused"),
		path   = {'/', 't', 'm', 'p', '/', 'x', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		n      = 6,
	}
	hit := false
	switch v in msg {
	case Reads_Msg:
		hit = true

		// (1) The allocating read, straight off the binding, in one expression.
		// This is what examples/http and tools/http_nbio both use.
		cloned := msg_text_clone(v.reason, context.temp_allocator)
		testing.expect_value(t, cloned, "dial tcp: connection refused")

		// (2) The non-allocating borrow, via a named copy of the field. The
		// copy is what gives the returned string somewhere to point that
		// outlives the call.
		r := v.reason
		testing.expect_value(t, msg_text_string(&r), "dial tcp: connection refused")

		// (3) Any OTHER fixed-array field: one `vv := v` unblocks the whole
		// struct, not just the Msg_Text in it.
		vv := v
		testing.expect_value(t, string(vv.path[:vv.n]), "/tmp/x")

		// (4) The by-value accessors need no copy at all and never did.
		testing.expect(t, !msg_text_truncated(v.reason), "short text is not truncated")
	}
	testing.expect(t, hit, "the type switch must have matched")
	free_all(context.temp_allocator)
}
