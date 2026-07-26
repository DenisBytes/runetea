package main

// Standalone benchmark (odin build, not odin test) measuring the real cost of
// candidate per-message allocation strategies for the T1 message-ownership
// decision. Not part of the runetea package; a throwaway measurement tool,
// same convention as tools/msgcheck etc.

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:time"

Small_Msg :: struct { code: int, tag: [16]u8 }

N :: 200_000

// --- baseline: one heap alloc + one heap free per message (Option A/B/D shape) ---
bench_heap :: proc() -> time.Duration {
	start := time.now()
	for i in 0 ..< N {
		p := new(Small_Msg)
		p.code = i
		free(p)
	}
	return time.since(start)
}

// --- Option C, flavor 1: virtual.Arena (growing), small reserve, per message ---
bench_virtual_arena :: proc(reserved: uint) -> time.Duration {
	start := time.now()
	for i in 0 ..< N {
		a: virtual.Arena
		if err := virtual.arena_init_growing(&a, reserved); err != nil {
			fmt.eprintln("arena init failed:", err)
			continue
		}
		al := virtual.arena_allocator(&a)
		p, _ := new(Small_Msg, al)
		p.code = i
		// simulate a second, payload allocation from the SAME arena (the
		// whole point of Option C: message struct + payload share one group)
		buf, _ := mem.alloc_bytes(64, allocator = al)
		_ = buf
		virtual.arena_destroy(&a)
	}
	return time.since(start)
}

// --- Option C, flavor 2: hand-rolled bump allocator over one heap buffer ---
Bump_Arena :: struct {
	buf:  []u8,
	used: int,
}

bump_alloc_proc :: proc(allocator_data: rawptr, mode: mem.Allocator_Mode,
	size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	a := cast(^Bump_Arena)allocator_data
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		align := max(alignment, 1)
		aligned := (a.used + align - 1) & ~(align - 1)
		if aligned + size > len(a.buf) { return nil, .Out_Of_Memory }
		p := a.buf[aligned:aligned+size]
		a.used = aligned + size
		if mode == .Alloc { mem.zero_slice(p) }
		return p, nil
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

bench_bump_arena :: proc(cap: int) -> time.Duration {
	start := time.now()
	for i in 0 ..< N {
		backing := make([]u8, cap)
		a := Bump_Arena{buf = backing}
		al := bump_allocator(&a)
		p, _ := new(Small_Msg, al)
		p.code = i
		buf, _ := mem.alloc_bytes(64, allocator = al)
		_ = buf
		delete(backing)
	}
	return time.since(start)
}

main :: proc() {
	fmt.printfln("N = %d messages\n", N)

	d0 := bench_heap()
	fmt.printfln("baseline heap new+free:            %v total, %v/msg", d0, d0 / N)

	d1 := bench_virtual_arena(4096)
	fmt.printfln("virtual.Arena (4KiB reserve):       %v total, %v/msg", d1, d1 / N)

	d2 := bench_bump_arena(256)
	fmt.printfln("bump arena over heap buf (256B):    %v total, %v/msg", d2, d2 / N)
}
