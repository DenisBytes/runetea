package main

// Prototype/measurement harness for OPTION A (message-ownership decision,
// docs/superpowers/message-ownership-decision.md): "messages are borrowed;
// the loop frees the box after apply() returns; the user must copy anything
// retained." Single-threaded -- the concurrency machinery (Mailbox,
// Dispatcher) is already proven elsewhere and is identical regardless of
// which ownership scheme wins, so it is deliberately elided here to isolate
// just the allocation-lifetime question this file exists to measure.
//
// Two flavors of "free the box" are tested, because they behave differently:
//   SHALLOW -- free exactly what box() allocated (the top-level struct only).
//   DEEP    -- also walk the struct via reflection and free any owned
//              string/slice fields found, so a Msg with a payload doesn't
//              still leak the payload after the "fix".
// Findings below are collected into the decision doc, not asserted here.

import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"

Err_Msg :: struct { reason: string }

// Mirrors examples/http/check_server: the reason string is a SEPARATE
// allocation from the Err_Msg struct itself (fmt.aprintf makes its own
// allocation; box()'s new(Err_Msg, alloc) only allocates the struct: 16
// bytes for the string header, ptr+len).
produce_err :: proc(alloc: mem.Allocator) -> any {
	p, _ := new(Err_Msg, alloc)
	p.reason = fmt.aprintf("dial: connection refused (attempt %d)", 7, allocator = alloc)
	return p^
}

// SHALLOW free: exactly what a literal reading of "free the box" gives you.
free_shallow :: proc(msg: any, alloc: mem.Allocator) {
	if msg.data != nil { free(msg.data, alloc) }
}

// DEEP free: walk the struct's fields via reflection, free any owned
// string found, then free the struct itself. This is what an implementer
// reaches for when SHALLOW visibly fails to stop the leak (see below).
free_deep :: proc(msg: any, alloc: mem.Allocator) {
	if msg.data == nil { return }
	// Minimal, targeted version for this prototype's one field shape
	// (string fields) -- a general version would recurse the way
	// arena.odin's is_pod_type does for the *type-checking* direction.
	// Good enough to demonstrate the dangling hazard this causes.
	fields := reflect.struct_fields_zipped(msg.id)
	for f in fields {
		if f.type.id == typeid_of(string) {
			fv := reflect.struct_field_value(msg, f)
			s := fv.(string)
			if len(s) > 0 { delete(s, alloc) }
		}
	}
	free(msg.data, alloc)
}

main :: proc() {
	fmt.println("=== Option A prototype: shallow free ===")
	{
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		alloc := mem.tracking_allocator(&track)

		msg := produce_err(alloc)
		e := msg.(Err_Msg)
		fmt.println("reason before free:", e.reason)

		// "the loop" frees the box after apply() returns
		free_shallow(msg, alloc)

		fmt.printfln("leaked allocations after shallow free: %d (%d bytes)",
			len(track.allocation_map), sum_leaked(&track))
		for _, entry in track.allocation_map {
			fmt.printfln("  leak: %d bytes @ %v", entry.size, entry.location)
		}
		// The string's BACKING BYTES were never touched by free_shallow
		// (a totally separate allocation from the struct) -- so a stored
		// copy of the pointer is still valid, just permanently leaked.
		fmt.println("reason after shallow free (still readable, unchanged):", e.reason)
		mem.tracking_allocator_destroy(&track)
	}

	fmt.println("\n=== Option A prototype: deep free (reflection-based) ===")
	{
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		alloc := mem.tracking_allocator(&track)

		msg := produce_err(alloc)
		e := msg.(Err_Msg)               // simulates `switch v in msg { case Err_Msg: ... }`
		model_err := e.reason            // simulates the examples/http bug: `m.err = v.reason`
		fmt.println("model_err before free:", model_err)

		free_deep(msg, alloc)
		fmt.printfln("leaked allocations after deep free: %d", len(track.allocation_map))

		// Force the allocator to reuse the just-freed block, to make the
		// use-after-free OBSERVABLE rather than theoretical.
		clobber := strings.clone("XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX", alloc)
		_ = clobber
		fmt.println("model_err after deep free + a reallocation (DANGLING):", model_err)
		fmt.println("(if this differs from the 'before' line above, the model field is reading freed/reused memory)")

		mem.tracking_allocator_destroy(&track)
	}
}

sum_leaked :: proc(t: ^mem.Tracking_Allocator) -> int {
	n := 0
	for _, e in t.allocation_map { n += e.size }
	return n
}
