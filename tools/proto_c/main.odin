package main

// Prototype/measurement harness for OPTION C (message-ownership decision):
// "a Cmd allocates its message AND all its payload data from one allocator;
// the loop frees that whole group after apply()." Single-threaded, same
// justification as tools/proto_a for eliding the Mailbox/Dispatcher.
//
// Uses the CHEAP arena flavor found in tools/msgbench (a hand-rolled bump
// allocator over one heap buffer, ~95ns/msg) rather than a fresh
// virtual.Arena per message (~16.9us/msg, 456x slower -- see msgbench's own
// output, cited in the decision doc, not reproduced here).
//
// The point of this file is NOT allocation cost (already measured) but the
// two other things Option C changes: the Cmd proc SIGNATURE (every Cmd now
// takes an allocator), and whether grouping the struct + its payload under
// one free call does anything to stop a user from storing a borrowed
// pointer into the model.

import "core:fmt"
import "core:mem"
import "core:strings"

Bump_Arena :: struct { buf: []u8, used: int }

bump_alloc_proc :: proc(data: rawptr, mode: mem.Allocator_Mode,
	size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	a := cast(^Bump_Arena)data
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		align := max(alignment, 1)
		aligned := (a.used + align - 1) & ~(align - 1)
		if aligned + size > len(a.buf) { return nil, .Out_Of_Memory }
		p := a.buf[aligned:aligned+size]
		a.used = aligned + size
		if mode == .Alloc { mem.zero_slice(p) }
		return p, nil
	case .Resize, .Resize_Non_Zeroed:
		// Bump arenas don't support in-place growth of an arbitrary prior
		// allocation -- alloc fresh and copy forward, like every other
		// bump/arena allocator. This is what a growing strings.Builder
		// (fmt.aprintf's backing store) exercises on every reallocation.
		align := max(alignment, 1)
		aligned := (a.used + align - 1) & ~(align - 1)
		if aligned + size > len(a.buf) { return nil, .Out_Of_Memory }
		p := a.buf[aligned:aligned+size]
		if old_memory != nil && old_size > 0 {
			copy(p, ([^]byte)(old_memory)[:min(old_size, size)])
		}
		a.used = aligned + size
		if mode == .Resize && size > old_size { mem.zero_slice(p[old_size:]) }
		return p, nil
	case .Free:
		return nil, nil // bump arenas don't support freeing individual allocations
	case .Free_All:
		a.used = 0
		return nil, nil
	case:
		return nil, .Mode_Not_Implemented
	}
}
bump_allocator :: proc(a: ^Bump_Arena) -> mem.Allocator {
	return mem.Allocator{procedure = bump_alloc_proc, data = a}
}

Err_Msg :: struct { reason: string }

// Cmd signature CHANGE: every Cmd proc now takes the per-message allocator
// as a parameter -- compare to today's `proc(env: rawptr) -> any`
// (cmd.odin). This is the API cost Option C imposes on EVERY Cmd ever
// written, not just ones with an owned payload (examples/simple has none of
// its own Cmds in this spike, but the framework's own quit_run would need
// the same signature change).
check_server :: proc(alloc: mem.Allocator) -> any {
	p, _ := new(Err_Msg, alloc)
	// The payload string now comes from the SAME per-message allocator as
	// the struct -- this is the whole point: one group, one free.
	p.reason = fmt.aprintf("dial: connection refused (attempt %d)", 7, allocator = alloc)
	return p^
}

main :: proc() {
	// --- part 1: leak count, via Tracking_Allocator ---
	{
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		backing_alloc := mem.tracking_allocator(&track)

		backing := make([]u8, 256, backing_alloc)
		arena := Bump_Arena{buf = backing}
		al := bump_allocator(&arena)

		msg := check_server(al)
		e := msg.(Err_Msg)
		fmt.println("model_err before group-free:", e.reason)

		delete(backing, backing_alloc) // "the loop" frees the WHOLE GROUP after apply()
		fmt.printfln("leaked allocations after group-free: %d", len(track.allocation_map))
		mem.tracking_allocator_destroy(&track)
	}

	// --- part 2: dangling demonstration. Odin's default allocator does not
	// give the same simple LIFO same-size reuse a raw glibc malloc/free
	// would (confirmed separately: two back-to-back make([]u8,256)/delete
	// calls landed at different addresses), so rather than assert on a
	// specific allocator's reuse policy, churn a spread of sizes and report
	// whether ANY of them clobbers the dangling pointer's content. The
	// underlying claim being tested -- freeing memory a model has borrowed
	// a pointer into is unsound -- is already proven unconditionally by
	// proto_a's deep-free repro (same mechanism); this is corroboration,
	// not the only evidence.
	{
		backing := make([]u8, 256)
		arena := Bump_Arena{buf = backing}
		al := bump_allocator(&arena)

		msg := check_server(al)
		e := msg.(Err_Msg)
		model_err := e.reason // simulates `m.err = v.reason`, unchanged from examples/http today
		before := strings.clone(model_err) // independent copy, to compare against

		delete(backing) // "the loop" frees the whole group after apply()

		clobbered := false
		for size in 64 ..= 512 {
			c := make([]u8, size)
			for i in 0 ..< len(c) { c[i] = 'Z' }
			if model_err != before { clobbered = true; delete(c); break }
			delete(c)
		}

		if clobbered {
			fmt.println("model_err AFTER group-free + reuse (DANGLING, corrupted):", model_err)
		} else {
			fmt.println("model_err unchanged after churn -- this allocator happened not to reuse")
			fmt.println("the freed block in this run. Freeing it was still a use-after-free by")
			fmt.println("definition (the pointer's backing storage was returned to the allocator")
			fmt.println("while `model_err` still referenced it) -- see proto_a's deep-free repro")
			fmt.println("for an unconditional, reproduced-every-run demonstration of the same")
			fmt.println("mechanism (freeing memory a retained pointer still references).")
		}
		fmt.println("(same hazard as Option A's deep-free flavor: grouping the free does not")
		fmt.println(" stop a caller from retaining a pointer INTO the group)")
	}
}
