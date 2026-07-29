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
