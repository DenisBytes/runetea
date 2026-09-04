#!/usr/bin/env python3
"""Resolve every source citation in a markdown document.

    cite.py <doc.md> [<doc.md> ...]

WHY THIS EXISTS. docs/LIMITATIONS.md is the document README.md calls required
reading before adopting, and its distinguishing virtue is that every claim
cites the source comment that argues it -- when this script was written, ~50
`file.odin:NNN` references plus 14 in a file-less `` `:NNN` `` shorthand; today
mostly `` `file.odin, Symbol` ``, which does not rot on an insertion. (Counts
are printed per document on every run rather than restated here.) Until this
script, none of them was checked by anything, and the decay is not
theoretical: `` `:678-686` ``
in section 2.16 resolved to timer.odin's "CATCHING UP" comment at commit
60219f3, the commit that INTRODUCED the document, and was pointing at an
unrelated Timer_Unavailable_Msg comment one commit later at bfed0e8. A
public-facing citation rotted in a single commit and nothing noticed.

WHAT IS AND IS NOT CHECKABLE, stated plainly because the gap matters:

  CHECKED   the cited file exists, and the cited line range lies inside it.
            That catches a citation into a file that was deleted, renamed or
            shortened -- the failure mode that produced the `:678-686` rot,
            since the arithmetic that moves a comment usually also moves the
            end of the file.
  CHECKED   every `` `test_name` `` the prose claims pins a behaviour is a real
            `@(test)` procedure in this repository. A doc that names a test
            which does not exist is claiming coverage it does not have.
  CHECKED   every `### ` section labelled **FIXED** names at least one such
            test, OR carries an explicit
            `` <!-- doccheck: no-test <reason> --> `` marker. See NO-TEST below.
  CHECKED   every relative markdown link resolves to a path in the repository.
  CHECKED   a citation written `` `file.odin, Symbol` `` names an identifier
            that actually OCCURS in that file. The symbol form was introduced
            when most `file.odin:NNN` citations were rewritten to stop rotting
            on every insertion, and for a while it bought nothing: the file
            half was checked and the symbol half was not, so a name that
            exists nowhere in the repository resolved clean. Three of the 56
            conversions were wrong the day this check was added --
            `signals.odin, STOP_SIGNAL` (the constant is `SIG_WAKE`), and two
            that were rewritten to `batch.odin, compose_run` when the lines
            they replaced were `cmd.odin:651-662` and `batch.odin:249-270`,
            neither of which is a proc called `compose_run`. A citation whose
            symbol does not exist is worse than a line number that has
            drifted: a drifted line still lands in the right file, near the
            right code, and a reader recovers. A wrong name sends the reader
            to grep for something that was never there. Negative control, run
            on a copy of the document: renaming one plain symbol and one
            dot-qualified field to names that do not exist turns this check red
            on both.
  NOT CHECKED, and no script can: whether the lines a citation points at still
            SAY what the sentence around them claims. That is a human reading.
            A range check narrows the window, it does not close it.
  NOT CHECKED whether a `` `file.odin, Symbol` `` citation points at the
            symbol's DECLARATION rather than at a mention of it. The test is a
            word-boundary OCCURRENCE test, deliberately: this document cites
            doc comments at least as often as declarations (`` `runetea/
            cmd.odin, dispatcher_reap` ``'s "WHY self_cleanup = false" is a
            comment, not the proc body), so a declaration-only rule would have
            to be red on those or grow an Odin parser to tell the two apart.
            Occurrence catches the name that is simply not there, which is the
            failure that actually happened; it would not catch a citation
            moved to a file that happens to mention the symbol in passing.

THE NO-TEST MARKER, and why the check is shaped this way. A **FIXED** label is
the strongest claim this document makes -- it says a behaviour a reader may have
seen in an older build is gone -- and the only thing that keeps such a label
from decaying into folklore is a test that would go red if it came back. When
this check was first proposed, 13 of the 26 FIXED sections cited no test at all,
and the honest options were a blanket rule that would have been red on the day
it landed, an allowlist keyed by section number (which goes stale silently), or
no check. What is implemented instead is a rule with ONE escape hatch, written
into the document beside the claim it excuses:

    <!-- doccheck: no-test <reason> -->

Two sections use it, 9.5 and 9.6, and both for the same honest reason: their
subject IS a gate, so there is no library behaviour to pin and an @(test) that
re-ran the gate from inside `odin test` would assert nothing the gate does not
already assert on every run. The marker is NOT a way to be quiet -- its reason is
printed on every run, exactly like a `skip` -- and it is checked in both
directions: a marker on a section that DOES cite a test is a failure (the
exemption outlived its reason), and a marker outside a FIXED section is a failure
(it excuses nothing). Deleting the only test citation from a FIXED section turns
this check red, which is the negative control it was verified with.

THE SHORTHAND. `` (`:NNN`) `` means "the same file as the last one named". The
resolver therefore carries a current-file cursor in document order, set by any
`` `path.ext:NNN` `` citation AND by any bare `` `path.ext` `` mention -- both
forms are used as the antecedent in the document as it stands. Note the file
pattern is anchored to the OPENING backtick only, never to a closing one:
section 5.11's antecedent is written with prose inside the same code span
(``runetea/input.odin, `decode_keys`' lone-ESC note``), and a resolver that
demanded a closing backtick would silently carry the PREVIOUS file forward and
then "resolve" both of that section's shorthands against width.odin -- 871
lines, against line 1263 -- which is the exact species of quiet wrongness this
script exists to end. It was the first thing this script caught. A shorthand
with no antecedent at all is an ERROR, not a skip: it is unresolvable by any
reader too.

Exit 0 if everything resolved, 1 otherwise, with one line per problem.
"""

import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# A citation, a bare file mention, or a shorthand -- one alternation so that
# document ORDER is preserved, which is the whole basis of the shorthand rule.
CITE = re.compile(
    r"`(?P<file>[A-Za-z0-9_][A-Za-z0-9_./-]*\.(?:odin|md|sh|py))"
    r"(?::(?P<a>\d+)(?:-(?P<b>\d+))?)?"
    r"|`:(?P<sa>\d+)(?:-(?P<sb>\d+))?`")

# `file.odin, Symbol` -- the form that replaced most line citations. Only .odin
# is accepted here: a `foo.md, Something` would be prose, not a code citation.
# The symbol may be dot-qualified (`Width_Options.ambiguous_is_wide`,
# `Program.update`), in which case it is the LAST component that has to exist --
# the qualifier is there to tell the reader which struct the field belongs to,
# and Odin writes a field declaration as the bare name.
SYMBOL = re.compile(
    r"`(?P<file>[A-Za-z0-9_][A-Za-z0-9_./-]*\.odin), (?P<sym>[A-Za-z_][A-Za-z0-9_.]*)`")

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

LINK = re.compile(r"\]\((?P<target>[^)\s]+)\)")

TEST_NAME = re.compile(r"`(test_[a-z0-9_]+)`")

# A `### ` heading, and the FIXED label inside one. `## ` closes a section: a
# claim's evidence has to sit under the claim, not two headings away.
SECTION = re.compile(r"^###\s+(?P<title>.+?)\s*$")
NO_TEST = re.compile(r"<!--\s*doccheck:\s*no-test\s+(?P<why>.+?)\s*-->")

TEST_DECL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*::\s*proc\s*\(\s*t:\s*\^testing\.T")


def repo_tests():
    """Every `@(test)` procedure name in the repository."""
    names = set()
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for fn in filenames:
            if not fn.endswith("_test.odin"):
                continue
            with open(os.path.join(dirpath, fn), "r", errors="replace") as f:
                for line in f:
                    m = TEST_DECL.match(line)
                    if m:
                        names.add(m.group(1))
    return names


_lines_cache = {}
_ident_cache = {}


def file_idents(path):
    """Every identifier token in a source file, comments included -- see the
    NOT CHECKED note on why comments count."""
    if path not in _ident_cache:
        full = os.path.join(ROOT, path)
        if not os.path.exists(full) or os.path.isdir(full):
            _ident_cache[path] = None
        else:
            with open(full, "r", errors="replace") as f:
                _ident_cache[path] = set(IDENT.findall(f.read()))
    return _ident_cache[path]


def line_count(path):
    if path not in _lines_cache:
        full = os.path.join(ROOT, path)
        if not os.path.exists(full) or os.path.isdir(full):
            _lines_cache[path] = None
        else:
            with open(full, "r", errors="replace") as f:
                _lines_cache[path] = sum(1 for _ in f)
    return _lines_cache[path]


def fixed_sections(text):
    """(heading line number, heading, body) for every `### ` section, in order.

    Body stops at the next `### ` or at any `## `, so evidence must sit under
    the claim it supports.
    """
    out = []
    cur = None
    for lineno, line in enumerate(text.split("\n"), 1):
        m = SECTION.match(line)
        if m:
            cur = [lineno, m.group("title"), []]
            out.append(cur)
        elif line.startswith("## "):
            cur = None
        elif cur is not None:
            cur[2].append(line)
    return [(ln, title, "\n".join(body)) for ln, title, body in out]


def check_fixed_labels(rel, text, problems):
    """Every **FIXED** section cites a test, or says in writing why it cannot.

    Reported both ways round -- see the NO-TEST note in this file's docstring
    for why an unused exemption is as much a failure as a missing one.
    """
    exempted = 0
    for lineno, title, body in fixed_sections(text):
        is_fixed = "**FIXED**" in title
        cites = TEST_NAME.search(body) is not None
        marker = NO_TEST.search(body)

        if marker and not is_fixed:
            problems.append("%s:%d: a doccheck:no-test marker on a section that is not "
                            "labelled **FIXED** excuses nothing: %s" % (rel, lineno, title))
            continue
        if not is_fixed:
            continue
        if cites and marker:
            problems.append("%s:%d: **FIXED** section cites a test AND carries a "
                            "doccheck:no-test marker -- delete the marker: %s"
                            % (rel, lineno, title))
        elif cites:
            pass
        elif marker:
            exempted += 1
            print("  NO-TEST  %s:%d  %s" % (rel, lineno, marker.group("why")))
        else:
            problems.append("%s:%d: **FIXED** section names no `test_...` and carries no "
                            "<!-- doccheck: no-test <reason> --> marker: %s"
                            % (rel, lineno, title))
    return exempted


def check(doc, tests, problems):
    rel = os.path.relpath(os.path.abspath(doc), ROOT)
    base = os.path.dirname(os.path.abspath(doc))
    current = None          # the shorthand's antecedent
    counted = {"cite": 0, "short": 0, "sym": 0, "test": 0, "link": 0}

    with open(doc, "r", errors="replace") as f:
        text = f.read()

    for lineno, line in enumerate(text.split("\n"), 1):
        for m in CITE.finditer(line):
            if m.group("file"):
                path = m.group("file")
                current = path
                if m.group("a") is None:
                    continue        # a bare mention: sets context, asserts nothing
                counted["cite"] += 1
                a = int(m.group("a"))
                b = int(m.group("b") or a)
                n = line_count(path)
                if n is None:
                    problems.append("%s:%d: cites %s, which does not exist"
                                    % (rel, lineno, path))
                elif not (1 <= a <= b <= n):
                    problems.append("%s:%d: cites %s:%d-%d, but that file has %d lines"
                                    % (rel, lineno, path, a, b, n))
                continue

            counted["short"] += 1
            a = int(m.group("sa"))
            b = int(m.group("sb") or a)
            if current is None:
                problems.append("%s:%d: shorthand `:%d` has no file named before it"
                                % (rel, lineno, a))
                continue
            n = line_count(current)
            if n is None:
                problems.append("%s:%d: shorthand `:%d` resolves to %s, which does not exist"
                                % (rel, lineno, a, current))
            elif not (1 <= a <= b <= n):
                problems.append("%s:%d: shorthand `:%d-%d` resolves to %s, which has %d lines"
                                % (rel, lineno, a, b, current, n))

        for m in SYMBOL.finditer(line):
            counted["sym"] += 1
            path, sym = m.group("file"), m.group("sym")
            idents = file_idents(path)
            if idents is None:
                continue        # the file-existence pass above already said so
            if sym.split(".")[-1] not in idents:
                problems.append("%s:%d: cites %s, %s -- no such name occurs in that file"
                                % (rel, lineno, path, sym))

        for m in TEST_NAME.finditer(line):
            counted["test"] += 1
            if m.group(1) not in tests:
                problems.append("%s:%d: names %s, which is not an @(test) proc anywhere in the repo"
                                % (rel, lineno, m.group(1)))

        for m in LINK.finditer(line):
            t = m.group("target")
            if t.startswith(("http://", "https://", "mailto:", "#")):
                continue
            p = t.split("#", 1)[0]
            if not p:
                continue
            counted["link"] += 1
            if not os.path.exists(os.path.normpath(os.path.join(base, p))):
                problems.append("%s:%d: links to %s, which does not exist"
                                % (rel, lineno, t))

    exempted = check_fixed_labels(rel, text, problems)

    print("  %-24s %3d citation(s), %2d shorthand, %2d symbol(s), %2d test name(s), "
          "%2d local link(s), %d untested FIXED label(s)"
          % (rel, counted["cite"], counted["short"], counted["sym"], counted["test"],
             counted["link"], exempted))


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    tests = repo_tests()
    if not tests:
        sys.stderr.write("cite.py: found no @(test) procedures at all -- the "
                         "scanner is broken, not the docs\n")
        return 2
    problems = []
    for doc in argv[1:]:
        check(doc, tests, problems)
    if problems:
        sys.stderr.write("doccheck: %d unresolved citation(s):\n" % len(problems))
        for p in problems:
            sys.stderr.write("  %s\n" % p)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
