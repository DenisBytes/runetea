package main

// Direct, isolated proof for spec §6's linchpin claim: "wake_up <- mailbox <-
// thread.Pool (Cmds)" -- i.e. that nbio.wake_up() genuinely unblocks a loop
// thread parked inside nbio.tick() from a DIFFERENT thread, with no I/O
// involved on either side. This is deliberately the smallest possible
// reproduction (no Mailbox, no Dispatcher, no tty) so a positive result can't
// be attributed to anything else in the stack -- runetea/loop_nbio_test.odin
// and the pty-driven examples/http run separately prove the full path built
// on top of this primitive.
//
// Two phases:
//   1. POSITIVE: acquire an event loop, spawn a worker thread that sleeps
//      ~200ms then calls nbio.wake_up(loop), and call nbio.tick() with a
//      generous 5s ceiling. If wake_up genuinely interrupts the blocking
//      wait, tick() returns close to 200ms, not close to 5s.
//   2. NEGATIVE CONTROL: repeat with NO wake_up call at all, same 300ms
//      tick() ceiling. If tick() reliably blocks for the full ceiling here,
//      the positive result above isn't an artifact of tick() returning
//      quickly regardless (e.g. some unrelated ready completion) -- it
//      specifically needed the wake_up call.
import "core:fmt"
import "core:nbio"
import "core:sync"
import "core:thread"
import "core:time"

main :: proc() {
	fmt.println("=== tools/nbiowakecheck ===")

	// --- Phase 1: positive -- wake_up from another thread interrupts tick() ---
	{
		if err := nbio.acquire_thread_event_loop(); err != nil {
			fmt.println("BLOCKED: acquire_thread_event_loop:", err)
			return
		}
		defer nbio.release_thread_event_loop()

		loop := nbio.current_thread_event_loop()
		loop_for_wake = loop

		woke := false
		th := thread.create_and_start_with_data(&woke, proc(data: rawptr) {
			time.sleep(200 * time.Millisecond)
			w := cast(^bool)data
			sync.atomic_store(w, true)
			nbio.wake_up(loop_for_wake)
		}, init_context = context)
		// loop_for_wake is set via a package-global below because
		// create_and_start_with_data's callback signature takes exactly one
		// rawptr; capturing `loop` through `data` would need its own struct,
		// and this file is deliberately minimal.
		_ = th

		start := time.now()
		terr := nbio.tick(5 * time.Second)
		elapsed := time.since(start)

		thread.join(th)
		thread.destroy(th)

		fmt.printfln("phase 1: tick() returned after %v (err=%v, woken_flag=%v)", elapsed, terr, woke)
		if elapsed < 1 * time.Second && woke {
			fmt.println("ANSWER (2b, positive): YES -- nbio.wake_up() from another thread interrupted a blocked nbio.tick()")
		} else {
			fmt.println("ANSWER (2b, positive): NO -- tick() did not return promptly; wake_up did not interrupt the blocking wait")
		}
	}

	// --- Phase 2: negative control -- no wake_up, tick() blocks for its ceiling ---
	{
		if err := nbio.acquire_thread_event_loop(); err != nil {
			fmt.println("BLOCKED: acquire_thread_event_loop (phase 2):", err)
			return
		}
		defer nbio.release_thread_event_loop()

		start := time.now()
		terr := nbio.tick(300 * time.Millisecond)
		elapsed := time.since(start)

		fmt.printfln("phase 2: tick() returned after %v (err=%v)", elapsed, terr)
		if elapsed >= 250 * time.Millisecond {
			fmt.println("ANSWER (2b, negative control): as expected -- with no wake_up, tick() blocks for its own timeout, confirming phase 1 wasn't a fluke")
		} else {
			fmt.println("ANSWER (2b, negative control): SUSPICIOUS -- tick() returned early with nothing to wake it; phase 1 is not trustworthy evidence on its own")
		}
	}
}

// See phase 1's comment: create_and_start_with_data's proc takes one rawptr,
// so the loop pointer this file needs inside that callback is threaded
// through here instead of a second struct field, since it's set once, before
// the thread is spawned, and read once, after -- no concurrent access to
// race.
loop_for_wake: ^nbio.Event_Loop
