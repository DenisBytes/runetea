package main

import "core:fmt"
import rt "../../runetea"

// A message type the library has never heard of.
User_Tick :: struct { n: int }

main :: proc() {
	fa: rt.Frame_Arena
	if err := rt.frame_arena_init(&fa); err != nil { fmt.eprintln(err); return }
	defer rt.frame_arena_destroy(&fa)

	msg := rt.box(User_Tick{n = 99}, rt.frame_allocator(&fa))
	switch v in msg {
	case User_Tick: fmt.println("matched user-defined type, n =", v.n)
	case:           fmt.println("FAILED: fell through to default")
	}
}
