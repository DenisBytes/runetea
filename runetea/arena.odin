package runetea

import "core:mem"
import "core:mem/virtual"

// One arena per event-loop iteration. Every Msg payload and every View string
// is allocated here and released wholesale by frame_reset.
//
// This also serves the crash path: longjmp does not run `defer`, so after a
// recovered panic the loop calls frame_reset to reclaim everything the failed
// iteration allocated.
//
// LIFETIME CONTRACT: frame_reset runs once per iteration, on the main thread,
// and unconditionally reclaims (memory_block_dealloc) everything allocated
// from this arena since the last reset -- including on the crash-recovery
// path above, where longjmp has skipped every `defer` that might otherwise
// have kept something alive longer. A frame_allocator(fa) allocation is only
// good for the remainder of the iteration that made it.
//
// Anything that crosses a thread boundary, or that may still be sitting
// unprocessed in the mailbox when the next frame_reset fires, MUST be boxed
// with context.allocator instead -- never frame_allocator(fa). This includes
// messages produced by Task 5's worker pool and Task 7's signal-watcher
// thread: both box into the shared Mailbox from a thread other than the one
// that will call frame_reset, so a message still queued at the next reset
// would have its any.data pointer reclaimed out from under it -- a
// use-after-free that pairs a stale typeid with someone else's bytes, not
// just torn bookkeeping.
//
// virtual.Arena serializes arena_alloc/arena_free_all/arena_destroy with an
// internal sync.Mutex, so concurrent box() calls from multiple threads cannot
// corrupt the arena's own bookkeeping -- but that only protects the arena's
// internals. It says nothing about how long a given allocation stays valid,
// so it does not make cross-thread or cross-frame use of frame_allocator(fa)
// safe.
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
//
// `alloc` is the caller's choice, and that choice matters: see Frame_Arena's
// LIFETIME CONTRACT above. Box with frame_allocator(fa) only for a payload
// consumed within the same loop iteration that created it. Box with
// context.allocator (or another allocator that outlives the frame) for
// anything crossing a thread boundary or headed for the mailbox queue --
// Task 5's worker pool and Task 7's signal-watcher thread both need this.
box :: proc(v: $V, alloc: mem.Allocator) -> any {
	p, err := new(V, alloc)
	if err != nil { return nil }
	p^ = v
	return p^
}
