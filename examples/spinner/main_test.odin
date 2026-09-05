#+private
package main

// Unit tests for the spinner example.
//
// WHY AN EXAMPLE HAS TESTS AT ALL. Every one of these examples is copied by
// somebody as the starting point for a real program -- examples/editor/edit
// exists as its own package for exactly that reason -- and until v1.0-audit
// the only one anybody checked was the editor. F47's minimum-size work is the
// case in point: the fix that landed here first was reasoned about ("a one-row
// frame fits any terminal that exists") and was wrong, and no test could have
// disagreed with it because there were none.
//
// `#+private` on a `package main` test file is belt and braces rather than a
// requirement -- nothing imports a main package -- but it keeps these files
// the same shape as runetea's and runegloss's, which needed it (F42).
//
// The `main` proc in main.odin is simply not called: `odin test` supplies its
// own entry point. Verified on this toolchain before these files were written.

import "core:strings"
import "core:testing"
import rt "../../runetea"

// The same measurement render_inline makes: logical lines, each costing the
// physical rows the terminal will actually give it, with the trailing empty
// element of a "...\n"-terminated view dropped (it is a terminator, not a row).
// Deliberately rt.rows_for_line rather than a count of '\n' -- a line that
// wraps costs more than one row, and a minimum that ignored that would be
// right only for content that happens to fit.
@(private = "file")
frame_rows :: proc(v: string, w: int) -> int {
	lines := strings.split_lines(v, context.temp_allocator)
	if len(lines) > 1 && lines[len(lines) - 1] == "" { lines = lines[:len(lines) - 1] }
	rows := 0
	for line in lines { rows += rt.rows_for_line(line, w) }
	return rows
}

// THE CONSTANT THAT WAS WRONG, pinned to the renderer's own arithmetic rather
// than to the number 2.
//
// .Inline terminates every line it paints with "\r\n", the last one included,
// so a frame of R rows occupies R+1 terminal rows -- the R it paints plus the
// one its cursor ends on, which is where the next frame's rewind starts
// counting \e[1A\e[2K pairs from. A minimum that forgot the +1 certified a
// terminal as big enough and then let the top row scroll into scrollback,
// permanently: r.last_rows clamps to term_height-1, so no later rewind can
// reach a row that has left the viewport.
//
// Measured before this test was written, on a real pty at 60 columns: at one
// row this program's screen is blank for the whole session.
@(test)
test_the_spinners_minimum_height_leaves_a_row_for_inlines_terminator :: proc(t: ^testing.T) {
	m: Model
	m.term_w = 100   // wide enough that nothing wraps and nothing is dropped
	rows := frame_rows(view(m, context.temp_allocator), m.term_w)
	testing.expectf(t, MIN_ROWS == rows + 1,
		"MIN_ROWS is %d for a %d-row frame; .Inline needs one more row than it paints, so it must be %d",
		MIN_ROWS, rows, rows + 1)
	free_all(context.temp_allocator)
}

// F47's height half for a program whose view is ALREADY one row: there is no
// smaller frame to fall back to, so the minimum-height state is to stop
// animating rather than to paint something different.
//
// Before this, a one-row terminal got 44 bytes and a timer wakeup ten times a
// second for the life of the session, and showed none of it -- the write
// scrolls itself off the screen. Measured on a real pty: 1330 bytes in 1.5 s
// at one row before, 0 bytes after.
@(test)
test_a_height_below_the_inline_minimum_stops_the_animation_tick :: proc(t: ^testing.T) {
	m := Model{term_w = 100, term_h = 24, animating = true}

	// A tick at a workable height reissues its successor, which is what keeps
	// the animation running at all. Built from the temp allocator so the
	// Timer_Handle this constructs -- and never dispatches, because there is
	// no Dispatcher here -- is reclaimed with free_all rather than leaked into
	// the suite's leak audit.
	{
		context.allocator = context.temp_allocator
		cmd := update(&m, Spin_Tick_Msg{}, context.temp_allocator)
		testing.expect(t, !rt.cmd_is_nil(cmd), "at 24 rows a tick must reissue the next one")
		testing.expect_value(t, m.frame, 1)
	}

	// Shrink to the one height at which no .Inline frame can be seen.
	update(&m, rt.Window_Size_Msg{w = 100, h = 1}, context.temp_allocator)
	{
		context.allocator = context.temp_allocator
		cmd := update(&m, Spin_Tick_Msg{}, context.temp_allocator)
		testing.expect(t, rt.cmd_is_nil(cmd), "at one row the tick must NOT reissue -- nothing it paints can be seen")
		testing.expect(t, !m.animating, "the tick that declined to reissue must record that it stopped")
		testing.expectf(t, m.frame == 1, "the frame counter must not advance while paused, got %d", m.frame)
	}
	free_all(context.temp_allocator)
}

// The other half of the same contract, and the one that would turn the fix
// above into a hang: a paused program has no timer in flight, so the ONLY
// thing that can ever call update() again is input -- and a user who cannot
// see the hint cannot know to press anything. The resize has to restart it,
// and it has to issue exactly one Tick, because the animation's invariant is
// one Spin_Tick_Msg outstanding at a time.
@(test)
test_a_resize_back_above_the_minimum_reissues_exactly_one_tick :: proc(t: ^testing.T) {
	m := Model{term_w = 100, term_h = 1, animating = false}

	{
		context.allocator = context.temp_allocator
		cmd := update(&m, rt.Window_Size_Msg{w = 100, h = 24}, context.temp_allocator)
		testing.expect(t, !rt.cmd_is_nil(cmd), "growing back above MIN_ROWS must restart the animation")
		testing.expect(t, m.animating, "the restart must be recorded")
	}
	// A SECOND resize while already running must NOT issue another one: two
	// outstanding Ticks each reissuing their own successor is a permanent
	// doubling of the frame rate, once per SIGWINCH, and a terminal being
	// dragged emits a great many of those.
	{
		context.allocator = context.temp_allocator
		cmd := update(&m, rt.Window_Size_Msg{w = 90, h = 30}, context.temp_allocator)
		testing.expect(t, rt.cmd_is_nil(cmd), "a resize while already animating must not add a second Tick")
	}
	free_all(context.temp_allocator)
}

// The ioctl-failure sentinel, which reaches update() unfiltered
// (docs/LIMITATIONS.md 3.16). A 0 means "unknown", and treating it as "zero
// rows tall" would stop the animation on every program that never gets a real
// size -- which is every program run without a tty.
@(test)
test_a_zero_sized_window_message_never_pauses_the_spinner :: proc(t: ^testing.T) {
	m := Model{term_w = 100, term_h = 24, animating = true}
	update(&m, rt.Window_Size_Msg{w = 0, h = 0}, context.temp_allocator)
	testing.expect_value(t, m.term_h, 24)
	{
		context.allocator = context.temp_allocator
		cmd := update(&m, Spin_Tick_Msg{}, context.temp_allocator)
		testing.expect(t, !rt.cmd_is_nil(cmd), "a 0x0 sentinel must not stop the animation")
	}
	free_all(context.temp_allocator)
}

// ============================================================================
// docs/LIMITATIONS.md 11.3, WCAG 2.2.2 (Pause, Stop, Hide): this program used to
// reissue its Tick forever with no way to stop it short of quitting, and that
// matters beyond one example -- the reissue-from-update pattern here is the one
// the README and docs/API.md §4 present as THE way to animate, so it is what
// gets copied into progress bars, live log tails and clocks, which are not
// decorative.
// ============================================================================

@(test)
test_the_pause_key_stops_and_restarts_the_animation :: proc(t: ^testing.T) {
	m := Model{term_w = 100, term_h = 24, animating = true, interval = FRAME_INTERVAL}

	// PAUSING DOES NOT CANCEL THE TICK IN FLIGHT -- there is nothing to cancel,
	// since rt.tick hands back no handle. It sets the flag; the Spin_Tick_Msg
	// branch is what declines to reissue. So the keypress itself returns nil.
	{
		context.allocator = context.temp_allocator
		cmd := update(&m, rt.Key_Msg{code = .Rune, r = 'p'}, context.temp_allocator)
		testing.expect(t, m.paused, "'p' must set the paused flag")
		testing.expect(t, rt.cmd_is_nil(cmd), "pausing issues no Cmd of its own")
	}

	// The Tick already in flight arrives, and is the one that actually stops
	// the animation -- and it must NOT advance the frame, so that resuming
	// picks the glyph up where it stopped rather than jumping.
	before := m.frame
	{
		context.allocator = context.temp_allocator
		cmd := update(&m, Spin_Tick_Msg{}, context.temp_allocator)
		testing.expect(t, rt.cmd_is_nil(cmd), "a paused program must stop reissuing -- that IS the pause")
		testing.expect(t, !m.animating, "and must record that nothing is outstanding")
		testing.expect_value(t, m.frame, before)
	}

	// Resuming issues exactly one Tick. Two would permanently double the frame
	// rate, which is the same invariant the resize path protects.
	{
		context.allocator = context.temp_allocator
		cmd := update(&m, rt.Key_Msg{code = .Rune, r = ' '}, context.temp_allocator)
		testing.expect(t, !m.paused, "space must toggle back out of paused")
		testing.expect(t, !rt.cmd_is_nil(cmd), "resuming must restart the animation")
		testing.expect(t, m.animating, "the restart must be recorded")
	}
	{
		context.allocator = context.temp_allocator
		cmd := update(&m, rt.Key_Msg{code = .Rune, r = 'p'}, context.temp_allocator)
		testing.expect(t, m.paused, "and pausing again must still work")
		testing.expect(t, rt.cmd_is_nil(cmd), "still no Cmd from the keypress itself")
	}
	free_all(context.temp_allocator)
}

// The reason `paused` is a SEPARATE field from `animating` rather than one flag
// doing both jobs: they are stopped for different reasons and only one of them
// is the user's. A resize must not restart an animation the user stopped, which
// is the specific way a Pause control usually breaks.
@(test)
test_a_resize_does_not_resume_an_animation_the_user_paused :: proc(t: ^testing.T) {
	m := Model{term_w = 100, term_h = 24, animating = false, paused = true, interval = FRAME_INTERVAL}
	{
		context.allocator = context.temp_allocator
		cmd := update(&m, rt.Window_Size_Msg{w = 100, h = 40}, context.temp_allocator)
		testing.expect(t, rt.cmd_is_nil(cmd),
			"a resize must not restart what the user paused -- only what the height guard stopped")
		testing.expect(t, !m.animating, "and must not claim a Tick is outstanding")
		testing.expect(t, m.paused, "the user's choice survives the resize")
	}
	free_all(context.temp_allocator)
}

// A pasted 'p' is text, not a command -- the same rule the quit binding already
// follows (F37). Pausing on pasted text would be the same bug in a new place.
@(test)
test_pasted_text_never_pauses_the_spinner :: proc(t: ^testing.T) {
	m := Model{term_w = 100, term_h = 24, animating = true, interval = FRAME_INTERVAL}
	{
		context.allocator = context.temp_allocator
		update(&m, rt.Key_Msg{code = .Rune, r = 'p', pasted = true}, context.temp_allocator)
		testing.expect(t, !m.paused, "a pasted 'p' must not pause")
	}
	free_all(context.temp_allocator)
}
