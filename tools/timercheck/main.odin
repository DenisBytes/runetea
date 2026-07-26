package main

// Measures real Tick/Every firing accuracy -- verification item 3 for the
// Tick/Every task: "measure actual fire intervals for a Tick and an Every
// over several seconds and report the real numbers plus drift."
//
// Two measurements, both against a Dispatcher directly (no terminal, no
// Program/run() involved -- this is purely about the timer subsystem's own
// precision):
//
//   1. TICK: dispatch N independent, back-to-back one-shot Ticks of the
//      same duration, each timed from ITS OWN dispatch() call to when its
//      message arrives. Reports min/max/mean absolute error against the
//      requested duration.
//   2. EVERY: dispatch one repeating Every and measure the wall-clock gap
//      between consecutive fires over several seconds, reporting min/max/
//      mean interval and total drift (last fire's target vs its actual
//      time, accumulated).
import "core:fmt"
import "core:math"
import "core:os"
import "core:time"
import rt "../../runetea"

Tick_Sample_Msg :: struct { requested_ns: i64 }

tick_sample_fn :: proc(env: rawptr, t: time.Tick) -> any {
	e := cast(^time.Duration)env
	return rt.box(Tick_Sample_Msg{requested_ns = i64(e^)}, context.allocator)
}

measure_tick :: proc(d: ^rt.Dispatcher, m: ^rt.Mailbox, dur: time.Duration, samples: int) {
	fmt.printfln("--- Tick accuracy: %d one-shot Ticks of %v each ---", samples, dur)

	errs := make([]f64, samples); defer delete(errs)
	for i in 0 ..< samples {
		start := time.tick_now()
		cmd, h := rt.tick(dur, tick_sample_fn, dur, context.allocator)
		rt.dispatch(d, cmd)
		_, ok := rt.mailbox_recv(m)
		if !ok { fmt.eprintln("mailbox closed early"); os.exit(1) }
		elapsed := time.tick_diff(start, time.tick_now())
		errs[i] = time.duration_milliseconds(elapsed - dur)
		rt.timer_stop(h)
	}

	min_e, max_e, sum := errs[0], errs[0], 0.0
	for e in errs {
		if e < min_e { min_e = e }
		if e > max_e { max_e = e }
		sum += e
	}
	mean := sum / f64(samples)
	fmt.printfln("  error vs requested duration (ms): min=%.3f max=%.3f mean=%.3f", min_e, max_e, mean)
}

measure_every :: proc(d: ^rt.Dispatcher, m: ^rt.Mailbox, dur: time.Duration, run_for: time.Duration) {
	fmt.printfln("--- Every accuracy: firing every %v for %v ---", dur, run_for)

	cmd, h := rt.every(dur, tick_sample_fn, dur, context.allocator)
	start := time.tick_now()
	rt.dispatch(d, cmd)

	intervals := make([dynamic]f64); defer delete(intervals)
	prev := start
	fire_count := 0
	for {
		if time.tick_diff(start, time.tick_now()) >= run_for { break }
		_, ok := rt.mailbox_recv(m)
		if !ok { break }
		now := time.tick_now()
		append(&intervals, time.duration_milliseconds(time.tick_diff(prev, now)))
		prev = now
		fire_count += 1
	}
	rt.timer_stop(h)

	// Drain anything already in flight after timer_stop, briefly, so a
	// leftover fire doesn't confuse a LATER measurement sharing the same
	// mailbox (not needed here since each measurement gets its own, but
	// cheap and harmless).
	time.sleep(20 * time.Millisecond)
	for { if _, ok := rt.mailbox_try_recv(m); !ok { break } }

	if len(intervals) == 0 {
		fmt.eprintln("no Every fires observed")
		os.exit(1)
	}

	min_i, max_i, sum := intervals[0], intervals[0], 0.0
	for iv in intervals {
		if iv < min_i { min_i = iv }
		if iv > max_i { max_i = iv }
		sum += iv
	}
	mean := sum / f64(len(intervals))

	variance := 0.0
	for iv in intervals { variance += (iv - mean) * (iv - mean) }
	variance /= f64(len(intervals))
	stddev := math.sqrt(variance)

	requested_ms := time.duration_milliseconds(dur)
	fmt.printfln("  fires=%d requested_interval=%.3fms min=%.3fms max=%.3fms mean=%.3fms stddev=%.3fms",
		fire_count, requested_ms, min_i, max_i, mean, stddev)
	fmt.printfln("  mean drift from requested interval: %.4fms/fire (%.2f%%)",
		mean - requested_ms, 100.0 * (mean - requested_ms) / requested_ms)
}

main :: proc() {
	m: rt.Mailbox
	if err := rt.mailbox_init(&m, 64); err != nil {
		fmt.eprintln("mailbox_init failed:", err)
		os.exit(1)
	}
	defer rt.mailbox_destroy(&m)

	d: rt.Dispatcher
	rt.dispatcher_init(&d, &m, 2)
	defer rt.dispatcher_destroy(&d)

	measure_tick(&d, &m, 50 * time.Millisecond, 40)
	measure_tick(&d, &m, 200 * time.Millisecond, 15)

	measure_every(&d, &m, 20 * time.Millisecond, 3 * time.Second)
	measure_every(&d, &m, 100 * time.Millisecond, 5 * time.Second)
}
