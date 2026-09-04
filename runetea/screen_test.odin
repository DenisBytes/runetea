#+private
// ^ Every declaration in this file is package-private, so that `odin doc
//   runetea` / `odin doc runegloss` -- the command README.md and docs/API.md
//   hand a newcomer for symbol discovery -- lists the library rather than the
//   test fixtures. Pinned by tools/doccheck/run.sh's `apidoc` check, which is
//   also where the argument for it is written out.
package runetea

import "core:testing"

// ============================================================================
// THE CELL GRID'S OWN TESTS.
//
// Most of what screen.odin does is scored against pyte by the oracle
// (diff_oracle_test.odin) and the fuzzer (tools/difftest), which is the right
// way to test a terminal model: an independent implementation disagreeing is
// worth more than any assertion written from the same misunderstanding. This
// file is for the cases the oracle CANNOT reach -- inputs the .Diff view
// contract forbids, so the corpus never generates them, but which a release
// build with the contract assertion compiled out can still deliver.
// ============================================================================

// A tab was the one cluster whose width depends on WHERE it is, and
// screen_write_plain used to hand cluster_next a column that had nothing to do
// with the cursor.
//
// Two ways the two diverged, both exercised below:
//
//   * The cursor did not start at column 0. screen_write is called with
//     whatever position the previous write left, and the iterator always
//     started at opts.start_col (0 in every renderer call site).
//   * An escape split the line. screen_write hands each PLAIN SEGMENT to
//     screen_write_plain separately, so a styled line makes a fresh iterator --
//     starting again at 0 -- for text that lands halfway across the row.
//
// The old code then called screen_put(span, 8) and the grid recorded a single
// cell claiming to be eight columns wide, which is not a thing a terminal can
// show and not a thing the emitter can paint back. The fix is two lines: keep
// ci.col in step with the cursor, and treat HT as the cursor move it is.
//
// UNREACHABLE THROUGH THE SUPPORTED PATH -- contract.odin's Control_Byte rule
// rejects a tab in a .Diff view, and DIFF_STRICT fires on it in a plain
// `odin build`. That is exactly why the assertions here drive screen_write
// directly rather than through a Program: the point is what the model does when
// the guard is not there, which is the state -o:speed ships in.
@(test)
test_a_tab_is_measured_from_the_cursor_column_and_paints_no_cell :: proc(t: ^testing.T) {
	st, lt: Style_Table
	style_table_init(&st); defer style_table_destroy(&st)
	style_table_init(&lt); defer style_table_destroy(&lt)
	scratch: [dynamic]u8; defer delete(scratch)

	{
		// A tab written at column 3 advances to the next stop (8), not by a
		// whole tab_stop. Measured from 0 it came back 8 and parked the cursor
		// at 11.
		s: Screen
		screen_init(&s, 20, 2, &st, &lt); defer screen_destroy(&s)
		screen_goto(&s, 3, 0)
		screen_write(&s, "\t", &scratch)

		testing.expect_value(t, s.x, 8)
		c := screen_at(&s, 3, 0)
		testing.expectf(t, c.len == 0 && c.width == 1,
			"HT paints nothing -- the cell it started on must still be blank; got len=%d width=%d", c.len, c.width)
	}

	{
		// The escape-split case. "ab" leaves the cursor at 2; the fresh
		// iterator for the segment after the SGR used to measure the tab from
		// 0, so the 'c' landed at column 10 instead of 8.
		s: Screen
		screen_init(&s, 20, 2, &st, &lt); defer screen_destroy(&s)
		screen_write(&s, "ab\e[31m\tc", &scratch)

		testing.expect_value(t, s.x, 9)
		testing.expectf(t, cell_bytes(&s, screen_at(&s, 8, 0)) == "c",
			"the cluster after the tab belongs at the tab stop; column 8 holds %q", cell_bytes(&s, screen_at(&s, 8, 0)))
		for x in 2 ..< 8 {
			c := screen_at(&s, x, 0)
			testing.expectf(t, c.len == 0 && c.width == 1,
				"the columns a tab passes over are skipped, not painted; column %d holds %q at width %d",
				x, cell_bytes(&s, c), c.width)
		}
	}
}

// The pending-wrap state (x == cols) is the one place the column a cluster is
// MEASURED at and the column it is PLACED at are not the same number: the next
// printable cluster resolves the wrap to column 0 of the following row before
// it lands. screen_write_plain feeds the iterator the placed column, so a tab
// arriving in that state advances from 0 and not from `cols`.
@(test)
test_a_tab_in_the_pending_wrap_state_measures_from_the_next_row :: proc(t: ^testing.T) {
	st, lt: Style_Table
	style_table_init(&st); defer style_table_destroy(&st)
	style_table_init(&lt); defer style_table_destroy(&lt)
	scratch: [dynamic]u8; defer delete(scratch)

	s: Screen
	screen_init(&s, 4, 3, &st, &lt); defer screen_destroy(&s)
	screen_write(&s, "abcd", &scratch)         // fills the row: pending wrap
	testing.expect_value(t, s.x, 4)
	testing.expect_value(t, s.y, 0)

	screen_write(&s, "\t", &scratch)
	testing.expect_value(t, s.y, 1)
	// tab_stop is 8 and the row is 4 wide, so the stop is past the margin and
	// the cursor clamps to `cols` -- the same clamp screen_put applies to a
	// wide cluster written in the last column.
	testing.expect_value(t, s.x, 4)
	// The old code reached the right cursor by accident (it measured 8 from a
	// column it had invented and then clamped), but it got there through
	// screen_put, so it left a width-8 cell behind on the row it wrapped onto.
	c := screen_at(&s, 0, 1)
	testing.expectf(t, c.len == 0 && c.width == 1,
		"the wrapped-onto row must be untouched; column 0 holds %q at width %d", cell_bytes(&s, c), c.width)
}
