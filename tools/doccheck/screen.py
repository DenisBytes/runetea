#!/usr/bin/env python3
"""Replay a tools/ptyrun transcript through a real terminal model and print the
SCREEN it produced.

WHY THIS EXISTS. tools/doccheck's pty check used to grep ptyrun's byte dump for
three strings. That dump is the concatenation of every frame in the session
with the escapes spelled out, so a grep for "> [x] Buy celery" is satisfied by
any frame that ever contained those characters -- including one the renderer
then failed to erase. It could therefore not see the entire class of bug the
renderer is most likely to have: right glyphs, wrong PLACE. Demonstrated on
2026-09-03 by changing `reachable` in runetea/render.odin to `reachable - 2`:
the greps all passed and `run.sh pty` printed OK, while the screen the reader
would actually be looking at had four stacked copies of the header above the
frame. Everything this script does exists to make that a failure.

    screen.py <transcript> [--step LABEL|INDEX|all] [--cursor]

The transcript is ptyrun's `$PTYRUN_STEPS` file:

    SIZE <cols> <rows>                       (only where the size changed)
    STEP <index> <label> <hex bytes that step drew>

Bytes are fed CUMULATIVELY -- the screen after step N is the screen after every
byte up to and including step N, which is what the user of a TUI is looking at
when they have pressed N keys. A resize is applied to the model at exactly the
point ptyrun applied it to the pty; nothing in the byte stream says the window
grew, so the transcript has to carry it.

Output is the grid, one line per row, trailing spaces stripped and TRAILING
BLANK ROWS DROPPED. Blank rows in the middle are kept: an empty line inside a
frame is part of the frame, while the unused bottom of an 80x24 screen is not
something a doc block should have to spell out. A stale row left ABOVE or
INSIDE the frame survives both rules and shows up as a diff, which is the whole
point.

WHY pyte AND NOT RuneTea'S OWN MODEL. Same reason tools/difftest/check.py gives
at length: RuneTea's in-package oracle shares runetea/screen.odin's idea of what
\\e[K erases and where a wide cluster lands, so a misconception there is baked
into both sides of that comparison and invisible to it. pyte has no shared code
and no shared author with this repository.

AND WHY THIS ONE *IS* ON THE GATE while difftest is not. difftest's own comment
rejects a Python dependency for `odin test` because "the day it is missing, a
shelled-out checker becomes a skip, and a skip inside a green run is
indistinguishable from a pass". That argument is against the SKIP, not against
the dependency -- and it applies with full force here, which is why the import
below exits 2 with a message rather than degrading into anything. There is no
configuration of this script in which it does not run and the gate still passes.
"""

import sys

try:
    import pyte
except ImportError:  # pragma: no cover
    sys.stderr.write(
        "doccheck/screen.py: pyte is not installed (pip install pyte).\n"
        "This is a HARD FAILURE, never a skip: the pty gate's assertions are\n"
        "on the replayed screen, so without the emulator there is nothing to\n"
        "assert and a green run would mean nothing. See the module docstring.\n")
    sys.exit(2)


def parse(path):
    """-> [(index, label, bytes, size_or_None)] in transcript order."""
    steps = []
    pending_size = None
    with open(path, "r") as f:
        for line in f:
            parts = line.split()
            if not parts:
                continue
            if parts[0] == "SIZE":
                pending_size = (int(parts[1]), int(parts[2]))
                continue
            if parts[0] == "STEP":
                idx, label = int(parts[1]), parts[2]
                # A step that drew nothing has no hex field at all -- that is a
                # legitimate outcome (a keypress the program ignored), not a
                # malformed line, so it must not be an error here.
                data = bytes.fromhex(parts[3]) if len(parts) > 3 else b""
                steps.append((idx, label, data, pending_size))
                pending_size = None
                continue
            raise SystemExit("screen.py: unrecognised transcript line: %r" % line)
    if not steps:
        raise SystemExit("screen.py: transcript %s has no STEP lines" % path)
    if steps[0][3] is None:
        raise SystemExit("screen.py: transcript %s never states a size" % path)
    return steps


def grid(screen):
    rows = []
    for y in range(screen.lines):
        row = screen.buffer[y]
        rows.append("".join(row[x].data for x in range(screen.columns)).rstrip())
    while rows and not rows[-1]:
        rows.pop()
    return rows


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    path = argv[1]
    want = "last"
    show_cursor = False
    i = 2
    while i < len(argv):
        if argv[i] == "--step":
            want = argv[i + 1]
            i += 2
        elif argv[i] == "--cursor":
            show_cursor = True
            i += 1
        else:
            sys.stderr.write("screen.py: unknown argument %r\n" % argv[i])
            return 2

    steps = parse(path)
    cols, rows = steps[0][3]
    screen = pyte.Screen(cols, rows)
    stream = pyte.Stream(screen)

    hit = False
    for idx, label, data, size in steps:
        if size is not None and (size[0], size[1]) != (screen.columns, screen.lines):
            screen.resize(size[1], size[0])
        # "replace" rather than "strict": a transcript is a real terminal's
        # bytes, and a renderer bug that cuts a UTF-8 sequence in half must
        # show up as a mangled CELL, not as a crash in the checker that would
        # look like harness breakage.
        stream.feed(data.decode("utf-8", "replace"))
        if want == "all" or (want == "last" and idx == steps[-1][0]) or want in (label, str(idx)):
            if want == "all":
                print("--- step %d %s (%dx%d) ---"
                      % (idx, label, screen.columns, screen.lines))
            for line in grid(screen):
                print(line)
            if show_cursor:
                print("cursor %d %d %s"
                      % (screen.cursor.x, screen.cursor.y,
                         "hidden" if screen.cursor.hidden else "shown"))
            hit = True
            if want != "all":
                break

    if not hit:
        sys.stderr.write(
            "screen.py: no step named %r in %s (have: %s)\n"
            % (want, path, ", ".join(s[1] for s in steps)))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
