#!/usr/bin/env python3
"""Replay RuneTea's two renderer byte streams through pyte and compare.

THE INVARIANT, and it is the same one runetea/diff_oracle_test.odin checks:

    Replaying the .Diff renderer's bytes through a VT100 must produce exactly
    the same screen -- every cell's character AND every attribute -- and the
    same cursor position as replaying the .Full_Screen repaint's bytes for the
    same frame sequence.

WHY THIS EXISTS WHEN THE ODIN ORACLE ALREADY RUNS ON THE GATE. The in-package
oracle's VT emulator and the diff renderer's own cell model share this
package's terminal primitives (runetea/screen.odin): what \\e[K erases, where a
wide cluster lands, what \\n does on the bottom row. A misconception THERE is
baked into both sides of that comparison and invisible to it. pyte has no
shared code with RuneTea and no shared author, so it sees exactly the class of
bug the other harness cannot.

The comparison is per FRAME, not just at the end of a case: a divergence a
later frame happens to overwrite is still a frame the user saw wrong.

Input is tools/difftest's `dump` output on stdin:

    CASE <seed> <cols> <rows> <frames>
    SIZE <n> <cols> <rows>        (optional, before the frame it applies to)
    REF <n> <hex>
    DIF <n> <hex>
    ...

THE SIZE RECORD is F34's resize prong reaching this side of the process
boundary. Until it existed, this harness ran the generator with `resizes` off
and the whole prong lived only in runetea/diff_oracle_test.odin -- whose VT
model IS the renderer's own screen.odin, i.e. exactly the shared ancestry this
program exists to escape. A resize is the one mutation the generator cannot
perform alone, because the size lives in the harness's Renderer and in these
two pyte screens; the dumper pushes it into the renderers and announces it
here.

BOTH SCREENS ARE RESIZED AND NEITHER IS BLANKED, which is the choice that keeps
the check honest. Blanking (or making fresh screens) would be defensible --
after a resize both renderers repaint, so the next frame is fully determined by
its own bytes -- but it would also erase the one thing worth watching: if .Diff
did NOT repaint after a resize, a blanked screen would show its half-frame
against .Full_Screen's whole one and the divergence would still be caught, but
any disagreement about what SURVIVES a resize would not be. Keeping the content
costs nothing, because the two screens are compared on every frame and are
therefore known to be equal on the way in, and pyte's resize is deterministic
(clip from the top, pad at the bottom and right).

Exit status 0 if every case matched, 1 otherwise. A failing seed can be
replayed in the Odin oracle -- both harnesses drive the same generator.
"""

import sys

try:
    import pyte
except ImportError:  # pragma: no cover
    sys.stderr.write(
        "pyte is not installed (pip install pyte). This checker IS on the default\n"
        "gate, and its absence must never silently turn into a green run -- so\n"
        "this is a hard failure, not a skip.\n")
    sys.exit(2)


class Screen(pyte.Screen):
    """pyte.Screen with one deviation from real terminals corrected.

    pyte's ``erase_in_display`` re-attributes only the cells that already
    EXIST in its sparse per-row dict::

        for y in interval:
            line = self.buffer[y]
            for x in line:            # <-- keys present, not range(columns)
                line[x] = self.cursor.attrs

    A row nothing has ever written to has no keys, so ``\\e[J`` under a
    non-default background leaves it at the DEFAULT attributes. Every real
    terminal fills the erased region with the active background -- that is what
    ED means -- and it is what RuneTea's own model does. Left uncorrected, this
    reports a divergence on every frame whose repaint ends with styling still
    active, which is a bug in the emulator, not in either renderer.

    Corrected here rather than worked around on the RuneTea side (e.g. by
    comparing characters and ignoring attributes) precisely because attributes
    are half of what this harness exists to check: a diff that paints the right
    glyph in the wrong colour must fail.

    Note this does NOT make the comparison weaker in the other direction: both
    streams are replayed through this same class, so the correction cannot mask
    a difference between them -- it only stops pyte from inventing one.
    """

    def erase_in_display(self, how=0, *args, **kwargs):
        if how == 0:
            interval = range(self.cursor.y + 1, self.lines)
        elif how == 1:
            interval = range(self.cursor.y)
        else:
            interval = range(self.lines)

        self.dirty.update(interval)
        for y in interval:
            line = self.buffer[y]
            for x in range(self.columns):
                line[x] = self.cursor.attrs

        if how == 0 or how == 1:
            self.erase_in_line(how)


def make_screen(cols, rows):
    screen = Screen(cols, rows)
    stream = pyte.Stream(screen)
    return screen, stream


def snapshot(screen):
    """Everything the user could see, as a comparable value.

    Cells are taken from pyte's buffer directly rather than from
    ``screen.display``: display joins a row into a string and drops the empty
    'stub' cell a wide character leaves behind, which would hide exactly the
    wide-cell mistakes this is hunting. The full Char tuple is kept, so fg, bg,
    bold, italics, underscore, strikethrough, reverse and blink all participate
    -- a diff that repaints the right glyph in the wrong colour fails here.
    """
    cells = []
    for y in range(screen.lines):
        row = screen.buffer[y]
        for x in range(screen.columns):
            c = row[x]
            cells.append((c.data, c.fg, c.bg, c.bold, c.italics,
                          c.underscore, c.strikethrough, c.reverse, c.blink))
    # The cursor's column is clamped: the model deliberately allows a "pending
    # wrap" state (x == columns) that no absolute cursor move can reproduce and
    # none needs to, because every frame that writes anything issues its own
    # absolute move first. Row, column and visibility are otherwise exact.
    cx = min(screen.cursor.x, screen.columns - 1)
    return cells, (cx, screen.cursor.y, screen.cursor.hidden)


def describe(a, b, cols):
    """First differing cell (or the cursor), in human terms."""
    (ca, cura), (cb, curb) = a, b
    for i, (x, y) in enumerate(zip(ca, cb)):
        if x != y:
            return "cell (row %d, col %d): repaint=%r diff=%r" % (
                i // cols, i % cols, x, y)
    if cura != curb:
        return "cursor: repaint=%r diff=%r" % (cura, curb)
    return "no difference (internal error)"


def main():
    cases = 0
    frames = 0
    failures = []

    screen_ref = stream_ref = screen_dif = stream_dif = None
    cols = rows = 0
    seed = -1
    pending = {}
    resizes = 0

    def compare(n):
        nonlocal frames
        frames += 1
        a = snapshot(screen_ref)
        b = snapshot(screen_dif)
        if a != b:
            failures.append((seed, n, describe(a, b, cols)))

    for line in sys.stdin:
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "CASE":
            seed, cols, rows, _nframes = (int(v) for v in parts[1:5])
            screen_ref, stream_ref = make_screen(cols, rows)
            screen_dif, stream_dif = make_screen(cols, rows)
            pending = {}
            cases += 1
            continue
        if parts[0] == "SIZE":
            # `cols` is also what describe() divides by to name a failing cell,
            # so it has to move with the screen or a post-resize failure would
            # be reported at the wrong coordinates.
            _n, cols, rows = (int(v) for v in parts[1:4])
            screen_ref.resize(rows, cols)
            screen_dif.resize(rows, cols)
            resizes += 1
            continue
        if parts[0] in ("REF", "DIF"):
            n = int(parts[1])
            data = bytes.fromhex(parts[2]) if len(parts) > 2 else b""
            if parts[0] == "REF":
                stream_ref.feed(data.decode("utf-8", "replace"))
                pending[n] = pending.get(n, 0) | 1
            else:
                stream_dif.feed(data.decode("utf-8", "replace"))
                pending[n] = pending.get(n, 0) | 2
            # Compare only once BOTH streams for this frame have been fed.
            if pending[n] == 3:
                compare(n)
            continue

    if failures:
        print("pyte cross-check FAILED: %d of %d frames diverged (%d cases)"
              % (len(failures), frames, cases))
        for seed, n, why in failures[:20]:
            print("  seed=%d frame=%d  %s" % (seed, n, why))
        if len(failures) > 20:
            print("  ... and %d more" % (len(failures) - 20))
        return 1

    # The resize count is printed rather than merely tallied, and it is an
    # assertion in the same sense the corpus's own coverage test is: a
    # generator prong that never fires is a corpus with a longer changelog and
    # no more reach. Zero here means either the dumper stopped passing
    # `resizes = true` or the generator stopped resizing, and both are silent
    # losses of exactly what F34 was about.
    if resizes == 0:
        print("pyte cross-check FAILED: not one SIZE record in %d cases -- the "
              "resize prong is not reaching this harness" % cases)
        return 1

    print("pyte cross-check OK: %d cases, %d frames, %d resize(s), "
          "diff output replays to the same screen as the full repaint"
          % (cases, frames, resizes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
