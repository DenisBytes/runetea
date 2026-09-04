package runetea

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"

// One arena per FRAME (see the LIFETIME CONTRACT below for why that is no
// longer the same thing as one arena per event-loop iteration). Every Msg
// payload and every View string is allocated here and released wholesale by
// frame_reset.
//
// This also serves the crash path: longjmp does not run `defer`, so after a
// recovered panic the loop calls frame_reset to reclaim everything the failed
// iteration allocated.
//
// MEMORY ONLY -- frame_reset says nothing about MODEL state. Since update
// takes ^T (tea.odin's Program.update), a panic partway through update leaves
// p.model half-mutated, and no amount of arena reclaim undoes that. Do not
// read "the failed iteration is reclaimed wholesale" as "the iteration had no
// effect": it had no effect on the HEAP, and possibly a large one on the
// model. See Program.update's own comment and
// docs/superpowers/tier1-coverage-decision.md §5.
//
// LIFETIME CONTRACT: frame_reset runs once per FRAME, on the main thread, and
// unconditionally reclaims (memory_block_dealloc) everything allocated from
// this arena since the last reset -- including on the crash-recovery path
// above, where longjmp has skipped every `defer` that might otherwise have
// kept something alive longer. A frame_allocator(fa) allocation is good until
// the next frame_reset, and no longer.
//
// A FRAME IS NOT A MESSAGE, since coalescing. This sentence used to say "only
// good for the remainder of the ITERATION that made it", and that was exact
// while apply() ended in a render: one message in, one paint out, one reset.
// run() and run_nbio now apply a whole BATCH -- up to COALESCE_BUDGET messages
// (tea.odin) -- and paint once at the end, so the reset that reclaims what the
// first message's update() allocated fires only after the LAST message of the
// batch has been applied and the view has run. The lifetime got strictly
// LONGER, so nothing that was safe under the old sentence became unsafe under
// this one and no caller had to change; the sentence was simply stricter than
// the truth, and a lifetime rule that overstates is one callers learn to
// distrust. What did NOT change is where the reset lives: guarded_render
// (tea.odin) calls frame_reset on every one of its exit paths, the successful
// one and the view-panicked one alike, so "once per frame" is unconditional
// rather than a property of the happy path.
//
// The arena is virtual.arena_init_growing, so the higher per-batch high-water
// mark has no cap to run into: a batch that allocates more than a message did
// grows the arena and hands the blocks back at the same single reset.
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

// THE FIRST BYTES OF box()'s REFUSAL, as a named constant rather than a literal
// buried in the format string, because tea.odin's apply_msg matches on it and a
// coupling between two files should be visible from both ends.
//
// WHY THERE IS A MARKER AT ALL. This panic is raised on a pool worker or a
// detached Cmd thread, recovered by run_cmd_guarded (cmd.odin) and delivered to
// the application as a Panicked_Msg -- the SAME Msg type that carries an
// ordinary panic from inside a Cmd body. Those two are not the same kind of
// event and must not have the same consequence:
//
//   AN ORDINARY Cmd PANIC is a runtime condition. The app decides what it
//   means, the session continues, and cmd.odin's design decision b (Panicked_Msg
//   rather than a session-ending error) is right about it.
//   A REFUSED box() IS A CONTRACT VIOLATION -- the program asked the framework
//   to do something the framework has told it, in this file and in
//   docs/API.md, that it will not do. There is nothing for an application to
//   decide and nothing for it to recover: that Cmd's result will never arrive,
//   and it will never arrive again on the next attempt either.
//
// Without a marker the two are indistinguishable downstream (both are a
// Msg_Text), which is exactly why the second one used to be as ignorable as the
// first. See apply_msg (tea.odin) for what happens to it now and for the
// alternatives that were weighed.
@(private = "package")
BOX_CONTRACT_PANIC :: "box(): "

// True iff `text` is the panic box() raises for a non-POD Msg -- i.e. the panic
// text that reached us through a Panicked_Msg was a MESSAGE-CONTRACT violation
// and not an application's own panic. A prefix test rather than a substring
// search on purpose: an app is free to panic with any text it likes, including
// text quoting this one, and a report is only ours if OUR words come first.
@(private = "package")
is_box_contract_panic :: proc(text: string) -> bool {
	return len(text) >= len(BOX_CONTRACT_PANIC) && text[:len(BOX_CONTRACT_PANIC)] == BOX_CONTRACT_PANIC
}

// MESSAGE OWNERSHIP CONTRACT (T1 decision, docs/superpowers/message-ownership-
// decision.md): every Msg type boxed through this proc must be POD -- no
// `string`, `cstring`, `^T`, `[]T`, `[dynamic]T`, `map`, or `any`, anywhere in
// its field tree, recursively. box() enforces this at the top of every call
// (see is_pod_type below), so it is not a rule callers must remember; it is
// checked every time.
//
// Why: run()'s (and run_nbio()'s) event loop frees the box exactly once,
// right after apply() finishes with it (tea.odin's apply() defers a
// box_free call as its first statement) -- see
// Frame_Arena's LIFETIME CONTRACT above for why that free cannot happen any
// sooner, and cmd.odin/signals.odin for why every cross-thread Msg lands
// here via context.allocator rather than frame_allocator(fa). If a Msg were
// allowed to carry an owned pointer (e.g. a `string` from `fmt.aprintf`),
// that payload would be a SEPARATE allocation from the one box() makes --
// freeing the box does not free it, so it would either leak forever
// (freeing only the struct) or, if something also freed the payload, dangle
// under a `case Err_Msg: m.err = v.reason`-shaped model assignment the
// instant the loop's free runs (measured both ways: tools/proto_a). POD
// closes this off structurally: every boxed value is copied by value
// wherever it goes, so there is no separate payload to leak, and nothing to
// dangle -- copying a POD value can never alias the box's storage.
//
// This does cost real ergonomics for text payloads (error messages, HTTP
// bodies): a `string` field must become a fixed-capacity Msg_Text (msg.odin)
// with truncation, and retaining it in a model requires msg_text_clone --
// which is also the ONLY way to get a `string` out of a Msg_Text, so there is
// no accidental-borrow path to begin with. See the decision doc for the
// measured cost against examples/http and the alternatives that were tried
// and rejected (a per-message arena and an owned+destructor scheme both still
// permit exactly the same dangling assignment; POD is the one design that
// removes the hazard rather than documenting or relocating it).
//
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
// consumed within the same FRAME that created it -- which, since coalescing,
// may span several messages. Box with context.allocator (or another allocator
// that outlives the frame) for anything crossing a thread boundary or headed
// for the mailbox queue -- Task 5's worker pool and Task 7's signal-watcher
// thread both need this.
box :: proc(v: $V, alloc: mem.Allocator, loc := #caller_location) -> any {
	// A `panic()`, not `assert()`: -disable-assert strips assert() (see
	// guard.odin's own FIX 3 for the exact same lesson learned once already
	// in this codebase, about g_armed's re-entrancy guard) but NOT panic(),
	// so this check survives a release build. It fires on the FIRST call
	// with a bad V -- at the box() call site inside the offending Cmd, with
	// V's name in the message -- not silently later as a leak or a
	// use-after-free discovered by some unrelated symptom.
	//
	// THE TYPE NAME AND THE CALL SITE ARE IN THE TEXT, not merely promised
	// by it. This comment and docs/API.md:379 both said the panic names your
	// type; for a long time it did not -- the message was a fixed string with
	// no %v in it at all, so the one fact a reader needs (WHICH Msg is not
	// POD, and where it was boxed) was the one fact it withheld. Worse, that
	// panic is raised on a pool worker, recovered by run_cmd_guarded
	// (cmd.odin), and arrives as a Panicked_Msg whose text was therefore
	// interchangeable between every non-POD Msg in the program.
	//
	// `loc` is threaded through the FORMAT STRING rather than passed as
	// panic's own `loc` parameter, and that is not redundancy: guard.odin's
	// guard_assertion_failure clones only `message` and discards the
	// runtime.Source_Code_Location it is handed, so a location passed the
	// ordinary way is thrown away before it can reach the Panicked_Msg. Both
	// facts lead the message so they survive Msg_Text's 255-byte truncation
	// (msg.odin).
	if !is_pod_type(typeid_of(V)) {
		fmt.panicf(
			BOX_CONTRACT_PANIC + "Msg type %v boxed at %v is not POD -- it has a string/pointer/slice/map/any field, directly or nested. See arena.odin's MESSAGE OWNERSHIP CONTRACT and msg.odin's Msg_Text.",
			typeid_of(V), loc)
	}
	p, err := new(V, alloc)
	if err != nil { return nil }
	p^ = v
	return p^
}

// The other half of box()'s contract: frees exactly what box() allocated.
// Called exactly once per message, from apply() (tea.odin), after the
// message has been fully consumed -- see MESSAGE OWNERSHIP CONTRACT above
// for why this alone is always sufficient: every boxed Msg is POD, so there
// is never a second, separate payload allocation this would need to also
// free, and never anything a caller could still be borrowing a pointer into.
//
// Safe to call with a nil-data `any` (mem_free is documented to no-op on a
// nil ptr) -- which is exactly what a boxed zero-sized Msg (Quit_Msg,
// Interrupt_Msg) produces, per cmd.odin's own msg.id-vs-msg comment: new()
// legitimately returns nil for a zero-sized allocation, so there was never
// anything to free for those types in the first place.
box_free :: proc(msg: any, alloc: mem.Allocator) {
	free(msg.data, alloc)
}

// True iff `id` contains no `string`, `cstring`, `^T`, `[]T`, `[dynamic]T`,
// `map`, or `any` anywhere in its field tree -- i.e. every value of this type
// can be freely copied (assignment, return, struct-embed) without ever
// aliasing the source's storage. This is box()'s enforcement mechanism (see
// its MESSAGE OWNERSHIP CONTRACT comment above) and is exported so a Msg
// type can be checked directly, e.g. in a test.
//
// RUNTIME, not compile-time, and that is a real, verified limitation, not a
// stylistic choice: Odin's `when`/`#assert` require a compile-time constant
// condition, and while individual `intrinsics.type_is_*` calls qualify, a
// user-defined recursive proc built entirely out of them does not -- Odin
// does not fold arbitrary proc calls into compile-time constants the way
// e.g. Zig's comptime does. Confirmed empirically (tools/podcheck: `when
// is_pod(Good) { ... }` fails to compile with "Non-constant condition in
// 'when' statement" even though is_pod's body is built entirely out of
// intrinsics.type_is_* calls) before settling for a runtime check called
// from every box(). See the decision doc for the full repro.
is_pod_type :: proc(id: typeid) -> bool {
	return is_pod_info(type_info_of(id))
}

@(private = "file")
is_pod_info :: proc(ti: ^runtime.Type_Info) -> bool {
	if ti == nil { return true }
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		return is_pod_info(v.base)
	case runtime.Type_Info_Pointer, runtime.Type_Info_Multi_Pointer,
	     runtime.Type_Info_String, runtime.Type_Info_Slice,
	     runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Map,
	     runtime.Type_Info_Any, runtime.Type_Info_Soa_Pointer:
		return false
	case runtime.Type_Info_Struct:
		types := v.types[:v.field_count]
		for t in types {
			if !is_pod_info(t) { return false }
		}
		return true
	case runtime.Type_Info_Array:
		return is_pod_info(v.elem)
	case runtime.Type_Info_Enumerated_Array:
		return is_pod_info(v.elem)
	case runtime.Type_Info_Union:
		for t in v.variants {
			if !is_pod_info(t) { return false }
		}
		return true
	}
	// Integer, Rune, Float, Complex, Quaternion, Boolean, Enum, Bit_Set,
	// Bit_Field, Simd_Vector, Matrix, Procedure, Type_Id -- none of these
	// carry an owned heap allocation, so all pass.
	return true
}
