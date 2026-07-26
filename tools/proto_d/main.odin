package main

// Prototype/measurement harness for OPTION D (message-ownership decision):
// "messages may own data and carry a destroy proc the loop calls."
// Single-threaded, same justification as tools/proto_a for eliding the
// Mailbox/Dispatcher (this file is only about allocation lifetime, and the
// concurrency plumbing is unaffected by which ownership scheme is chosen).

import "core:fmt"
import "core:mem"
import "core:strings"

Err_Msg :: struct { reason: string }

// The extra machinery: every Msg type that owns data must pair its box call
// with a matching destroy proc. Mirrors what a real Mailbox_Entry wrapper
// (mailbox.odin's `buf: []any` would become `buf: []Mailbox_Entry`) would
// carry alongside the `any` through the queue.
Mailbox_Entry :: struct {
	msg:     any,
	destroy: proc(msg: any, alloc: mem.Allocator), // nil = nothing to release
}

box_owned :: proc(v: $V, alloc: mem.Allocator, destroy: proc(any, mem.Allocator) = nil) -> Mailbox_Entry {
	p, _ := new(V, alloc)
	p^ = v
	return Mailbox_Entry{msg = p^, destroy = destroy}
}

err_msg_destroy :: proc(msg: any, alloc: mem.Allocator) {
	e := msg.(Err_Msg)
	if len(e.reason) > 0 { delete(e.reason, alloc) }
}

check_server :: proc(alloc: mem.Allocator) -> Mailbox_Entry {
	reason := fmt.aprintf("dial: connection refused (attempt %d)", 7, allocator = alloc)
	return box_owned(Err_Msg{reason = reason}, alloc, err_msg_destroy)
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	al := mem.tracking_allocator(&track)

	entry := check_server(al)
	e := entry.msg.(Err_Msg)
	model_err := e.reason // simulates `m.err = v.reason`, unchanged from examples/http today
	before := strings.clone(model_err, context.allocator)
	fmt.println("model_err before destroy:", model_err)

	// "the loop", after apply() returns: release the payload (destroy),
	// THEN free the box itself -- symmetric with box_owned, no reflection
	// needed, and (unlike Option A's reflection-based deep free) it only
	// ever frees exactly what the Cmd author told it to via `destroy`,
	// which is sound in general (Option A's version would blindly free
	// EVERY string field, including a string LITERAL field, which is
	// undefined behavior -- Option D's author-supplied destroy proc cannot
	// make that mistake for a type it wasn't written to handle).
	if entry.destroy != nil { entry.destroy(entry.msg, al) }
	if entry.msg.data != nil { free(entry.msg.data, al) }

	fmt.printfln("leaked allocations after destroy+free: %d", len(track.allocation_map))

	clobbered := false
	for size in 8 ..= 512 {
		c := make([]u8, size, al)
		for i in 0 ..< len(c) { c[i] = 'Z' }
		if before != model_err { clobbered = true; delete(c, al); break }
		delete(c, al)
	}
	if clobbered {
		fmt.println("model_err AFTER destroy + reuse (DANGLING, corrupted):", model_err)
	} else {
		fmt.println("model_err unchanged after churn in this run -- see proto_a's deep-free repro")
		fmt.println("for an unconditional reproduction of the same underlying mechanism: freeing")
		fmt.println("memory a retained pointer still references is unsound regardless of whether")
		fmt.println("it manifests as visible corruption on any particular run.")
	}
	fmt.println("Option D's destroy proc is CORRECT (frees exactly what it should, matches its")
	fmt.println("own box_owned allocation, no leak) but does NOT stop `m.err = v.reason` from")
	fmt.println("dangling -- same hazard class as Options A and C, just with sound, non-reflective")
	fmt.println("cleanup on the OWNING side instead of the CONSUMING side's mistake.")

	mem.tracking_allocator_destroy(&track)
}
