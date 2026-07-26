package runetea

import "core:mem"
import "core:testing"

Boxed_A :: struct { n: int }
// Msg_Text, not string: box()'s MESSAGE OWNERSHIP CONTRACT requires every
// boxed type to be POD (see arena.odin), and a bare `string` field is
// exactly what that contract forbids -- see test_box_rejects_non_pod_type
// below for the enforcement itself.
Boxed_B :: struct { s: Msg_Text }

@(test)
test_box_survives_the_returning_frame :: proc(t: ^testing.T) {
	fa: Frame_Arena
	testing.expect_value(t, frame_arena_init(&fa), nil)
	defer frame_arena_destroy(&fa)

	// A proc that boxes and returns -- the naive `return v` version yields garbage.
	produce :: proc(alloc: mem.Allocator, n: int) -> any {
		return box(Boxed_A{n = n}, alloc)
	}

	msg := produce(frame_allocator(&fa), 42)
	v, ok := msg.(Boxed_A)
	testing.expect(t, ok, "boxed value must retain its concrete type")
	testing.expect_value(t, v.n, 42)
}

@(test)
test_box_type_switch_discriminates :: proc(t: ^testing.T) {
	fa: Frame_Arena
	testing.expect_value(t, frame_arena_init(&fa), nil)
	defer frame_arena_destroy(&fa)
	al := frame_allocator(&fa)

	msgs := []any{ box(Boxed_A{7}, al), box(Boxed_B{msg_text_from("hi")}, al), box(int(3), al) }
	a_count, b_count, i_count := 0, 0, 0
	for m in msgs {
		switch v in m {
		case Boxed_A: a_count += 1; testing.expect_value(t, v.n, 7)
		case Boxed_B: b_count += 1; s := v.s; testing.expect_value(t, msg_text_string(&s), "hi")
		case int:     i_count += 1; testing.expect_value(t, v, 3)
		}
	}
	testing.expect_value(t, a_count, 1)
	testing.expect_value(t, b_count, 1)
	testing.expect_value(t, i_count, 1)
}

Not_Pod_String  :: struct { reason: string }
Not_Pod_Nested  :: struct { inner: struct { p: ^int } }

@(test)
test_is_pod_type_classifies_correctly :: proc(t: ^testing.T) {
	testing.expect(t, is_pod_type(typeid_of(Boxed_A)), "int field must be POD")
	testing.expect(t, is_pod_type(typeid_of(Key_Msg)), "Key_Msg (the framework's own Msg type) must be POD")
	testing.expect(t, is_pod_type(typeid_of(Msg_Text)), "Msg_Text must be POD -- it is the whole point of the type")
	testing.expect(t, is_pod_type(typeid_of(Boxed_B)), "a struct embedding only POD fields must be POD")
	testing.expect(t, !is_pod_type(typeid_of(Not_Pod_String)), "a bare string field must be rejected")
	testing.expect(t, !is_pod_type(typeid_of(Not_Pod_Nested)), "a pointer nested inside an anonymous struct field must be rejected")
}

// Regression for the T1 message-ownership decision
// (docs/superpowers/message-ownership-decision.md): box() must reject a
// non-POD Msg type LOUDLY -- a panic, not a silent leak or a later dangling
// read -- and it must do so via `panic()` rather than `assert()` so the
// check survives a -disable-assert build (the same lesson guard.odin's own
// FIX 3 already learned once for g_armed's re-entrancy guard).
//
// Driven through guarded() rather than called directly so this is a clean,
// recoverable regression test rather than a crash of the whole test binary
// -- panic() routes through context.assertion_failure_proc exactly like
// assert() does (see runtime's panic implementation), so guarded()'s
// longjmp-based recovery catches it the same way
// test_program_recovers_from_a_panicking_update (tea_test.odin) already
// proves it catches a panicking Update.
@(test)
test_box_rejects_non_pod_type :: proc(t: ^testing.T) {
	Step :: struct { boxed: any }
	step: Step
	info := guarded(proc(ud: rawptr) {
		s := cast(^Step)ud
		s.boxed = box(Not_Pod_String{reason = "leaks or dangles either way"}, context.allocator)
	}, &step)

	testing.expect(t, info.recovered, "box() must panic on a non-POD Msg type, not silently box it")
	testing.expect(t, step.boxed == nil, "the guarded body must not have completed box()")
}

@(test)
test_box_free_reclaims_the_only_allocation :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	al := mem.tracking_allocator(&track)

	msg := box(Boxed_A{n = 9}, al)
	testing.expect_value(t, len(track.allocation_map), 1)

	box_free(msg, al)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_frame_reset_reaches_steady_state :: proc(t: ^testing.T) {
	fa: Frame_Arena
	testing.expect_value(t, frame_arena_init(&fa), nil)
	defer frame_arena_destroy(&fa)

	first_total: uint
	for frame in 0 ..< 200 {
		al := frame_allocator(&fa)
		for i in 0 ..< 50 { _ = box(Boxed_A{i}, al) }
		if frame == 1 { first_total = fa.arena.total_used }
		if frame == 199 {
			testing.expectf(t, fa.arena.total_used == first_total,
				"arena must reach steady state: frame 1 used %d, frame 199 used %d",
				first_total, fa.arena.total_used)
		}
		frame_reset(&fa)
	}
}
