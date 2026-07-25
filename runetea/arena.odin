package runetea

import "core:mem"
import "core:mem/virtual"

// One arena per event-loop iteration. Every Msg payload and every View string
// is allocated here and released wholesale by frame_reset.
//
// This also serves the crash path: longjmp does not run `defer`, so after a
// recovered panic the loop calls frame_reset to reclaim everything the failed
// iteration allocated.
Frame_Arena :: struct {
	arena: virtual.Arena,
}

frame_arena_init :: proc(fa: ^Frame_Arena) -> mem.Allocator_Error {
	return virtual.arena_init_growing(&fa.arena)
}

frame_arena_destroy :: proc(fa: ^Frame_Arena) {
	virtual.arena_destroy(&fa.arena)
}

frame_allocator :: proc(fa: ^Frame_Arena) -> mem.Allocator {
	return virtual.arena_allocator(&fa.arena)
}

frame_reset :: proc(fa: ^Frame_Arena) {
	virtual.arena_free_all(&fa.arena)
}

// Boxes `v` into stable storage and returns an `any` referring to it.
//
// `any` is a BORROWED {data: rawptr, id: typeid}. `return v` from a proc yields
// a pointer into the dead frame -- it compiles clean and produces garbage.
//
// `return p^` is correct and `return p` is not: p is ^V, which converts to an
// `any` whose typeid is ^V and therefore never matches `case V`.
box :: proc(v: $V, alloc: mem.Allocator) -> any {
	p, err := new(V, alloc)
	if err != nil { return nil }
	p^ = v
	return p^
}
