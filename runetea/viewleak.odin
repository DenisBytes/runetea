package runetea

import "core:fmt"
import "core:mem"

// DETECTING THE VIEW LEAK -- the one thing docs/LIMITATIONS.md 3.15 said
// nothing at the boundary could detect.
//
// THE BUG. `view` is handed a frame arena as a parameter named `alloc`, and
// everything allocated from it is reclaimed wholesale when the frame ends. But
// every allocating call in Odin -- fmt.aprintf, strings.builder_make,
// strings.clone, rg.render -- takes its allocator as an argument with a DEFAULT
// THAT FALLS BACK TO context.allocator. Omit it and the view string is
// heap-allocated and freed by nobody: the loop resets the arena, and the arena
// never held it. It compiles, it renders identically, and it leaks one view per
// frame for the life of the process.
//
// WHY 3.15 CONCLUDED IT WAS UNDETECTABLE, AND WHY THAT WAS WRONG. The check
// that was proposed and rejected was "assert in debug builds that the frame
// arena's high-water mark moved". That really is unsound, and for the reason
// given: a view that returns a constant string, or one built entirely from
// strings.to_string on a builder the model owns, allocates nothing from the
// arena and is perfectly correct. But the arena is the wrong thing to watch.
// The defining property of the bug is not "the arena did not grow" -- it is
// "context.allocator DID". A correct view allocates from `alloc`, or from
// nothing; a leaking view allocates from context.allocator and abandons it.
// Those are distinguishable at the boundary, and this file distinguishes them.
//
// BLOCKS, NOT BYTES, and this is the detail that makes it reliable rather than
// nearly-reliable. Odin's `free(ptr)` reaches an allocator with old_size = 0 --
// the caller frequently does not know the size -- so a byte counter would
// over-count every such free into a phantom leak. Every allocation, however,
// has exactly one matching free, so counting blocks is exact regardless of what
// any caller knew about sizes. Bytes are tracked too, best-effort, but only to
// make the diagnostic concrete; the DECISION is made on the block count.
//
// IT REPORTS, IT NEVER PANICS, AND IT NEVER FAILS A FRAME. A false positive
// here would be far worse than the leak: it would turn a working program into a
// crashing one over a diagnostic. So the worst this can do is print a line and
// set two fields.
//
// THE ONE FALSE-POSITIVE CLASS, AND HOW IT IS FILTERED. A view that lazily
// initialises something process-lifetime on its first call -- a cache, a table
// -- legitimately leaves a block behind, once. That is why the report is gated
// on leaking in MORE THAN ONE frame (see view_leak_report): a one-shot
// initialisation shows as 1 frame out of however many the session painted and
// says nothing, while the actual bug -- a view that leaks a string per frame --
// leaks in every single frame and cannot hide. A view that hands ownership of a
// context.allocator block to something outside itself on every frame would
// still be reported, and that is the right answer: it is indistinguishable from
// the bug from here, and it is a shape a `view` should not have.
View_Leak_Watch :: struct {
	backing: mem.Allocator,

	// Live blocks: incremented on an allocation, decremented on a free. Signed
	// on purpose -- a view that frees a block it did not allocate drives this
	// negative, which is not this detector's business to complain about but is
	// something a reader of the number should be able to see.
	blocks: int,

	// Best-effort, for the diagnostic only. Under-counts whenever a free
	// arrived with old_size = 0, which is exactly why it is not what the
	// decision is made on.
	bytes: int,
}

@(private = "file")
view_leak_alloc_proc :: proc(
	allocator_data: rawptr, mode: mem.Allocator_Mode,
	size, alignment: int, old_memory: rawptr, old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	w := cast(^View_Leak_Watch)allocator_data
	res, err := w.backing.procedure(w.backing.data, mode, size, alignment, old_memory, old_size, loc)
	// Only a SUCCESSFUL operation moves the counters. A failed allocation
	// allocated nothing.
	if err != nil { return res, err }
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		w.blocks += 1
		w.bytes  += size
	case .Free:
		// old_memory == nil is a no-op free, not a block going away.
		if old_memory != nil {
			w.blocks -= 1
			w.bytes  -= old_size
		}
	case .Free_All:
		w.blocks = 0
		w.bytes  = 0
	case .Resize, .Resize_Non_Zeroed:
		// A resize of nil IS an allocation (that is Odin's contract), and a
		// resize to 0 is a free. Anything else keeps the same block and only
		// moves bytes.
		switch {
		case old_memory == nil: w.blocks += 1
		case size == 0:         w.blocks -= 1
		}
		w.bytes += size - old_size
	case .Query_Features, .Query_Info:
		// Pure queries; nothing to account for.
	}
	return res, err
}

// The single-frame threshold below which nothing is reported. See this file's
// header: a view that lazily initialises something process-lifetime leaks one
// block in one frame and is not the bug; a view that forgot to pass `alloc`
// leaks in EVERY frame and cannot get under this.
@(private = "file")
VIEW_LEAK_MIN_FRAMES :: 2

// Called once by each host on its way out. Prints nothing for a correct
// program, which is the overwhelming majority of the reason it can be on by
// default.
//
// CR-LF, and stderr, with the same caveat every other library-emitted
// diagnostic in this package carries: the terminal is still raw here (run()
// does not own it -- 6.9), so a bare \n would step-indent, and a program on the
// alternate screen will have this painted into a buffer that is about to be
// discarded. That is why Program.view_leak_frames exists as well: the FIELDS
// are the reliable channel, and an application that wants the message where a
// user can definitely read it prints them itself after its own term_restore().
@(private = "package")
view_leak_report :: proc(frames, blocks, bytes: int) {
	if frames < VIEW_LEAK_MIN_FRAMES { return }
	fmt.eprintf(
		"\r\nrunetea: view() leaked %d allocation(s) (~%d bytes) across %d frames -- " +
		"an allocating call inside view() or cursor() is using context.allocator " +
		"instead of the `alloc` it was handed, so the frame arena never held it. " +
		"Pass `alloc` explicitly (fmt.aprintf(..., allocator = alloc), " +
		"strings.clone(s, alloc), rg.render(st, s, alloc)). " +
		"See docs/LIMITATIONS.md 3.15.\r\n",
		blocks, bytes, frames)
}

// The allocator to install as context.allocator for the duration of a view.
// Forwards every operation to `w.backing` unchanged -- this is a counter, not a
// policy, and a view that allocates through it gets exactly the memory it would
// have got anyway.
view_leak_watch_allocator :: proc(w: ^View_Leak_Watch) -> mem.Allocator {
	return mem.Allocator{procedure = view_leak_alloc_proc, data = w}
}
