package runetea

import "core:mem"
import "core:testing"

Boxed_A :: struct { n: int }
Boxed_B :: struct { s: string }

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

	msgs := []any{ box(Boxed_A{7}, al), box(Boxed_B{"hi"}, al), box(int(3), al) }
	a_count, b_count, i_count := 0, 0, 0
	for m in msgs {
		switch v in m {
		case Boxed_A: a_count += 1; testing.expect_value(t, v.n, 7)
		case Boxed_B: b_count += 1; testing.expect_value(t, v.s, "hi")
		case int:     i_count += 1; testing.expect_value(t, v, 3)
		}
	}
	testing.expect_value(t, a_count, 1)
	testing.expect_value(t, b_count, 1)
	testing.expect_value(t, i_count, 1)
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
