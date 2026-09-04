#!/usr/bin/env bash
# RuneTea documentation gate.
#
#   ./tools/doccheck/run.sh          the whole gate (this is what tools/test.sh runs)
#   ./tools/doccheck/run.sh samples  only the markdown code samples
#   ./tools/doccheck/run.sh sweep    only the build sweep
#   ./tools/doccheck/run.sh pty      only the quickstart's real-pty run
#   ./tools/doccheck/run.sh cites    only the docs' source citations
#   ./tools/doccheck/run.sh apidoc   only `odin doc`'s symbol listing
#
# WHY THIS EXISTS. Documentation that does not compile is worse than no
# documentation, because it fails on the reader's first five minutes -- when
# they have no way to tell "the sample is stale" from "I typed it wrong" from
# "this library does not work". Every Odin code block in README.md,
# docs/API.md and docs/LIMITATIONS.md is therefore extracted from the markdown
# and COMPILED by this script, and the quickstart is additionally EXECUTED
# against a real pty and asserted on. A sample cannot drift, because drifting
# fails the gate.
#
# FIVE KINDS OF CHECK, and the reason there are five:
#
#   samples  Every ```odin block in the docs is compiled. Most are fragments
#            (a Msg type, an update proc, a Cmd body); those are wrapped in a
#            fixed preamble and built as their own package, so a renamed proc
#            or a changed signature is a build failure in the doc, not a
#            surprise for the reader.
#   sweep    Every `main` package in examples/ and tools/ is built. The docs
#            point at these; a broken example is a broken doc.
#   pty      examples/quickstart -- the program README.md quotes verbatim --
#            is run under a real pty (tools/ptyrun) with real keystrokes
#            INCLUDING escape sequences and a window resize, its output is
#            replayed through a third-party terminal emulator, and the
#            resulting CELL GRID is compared against the screen README.md
#            prints. This is what makes the "and the output looks like this"
#            half of the quickstart true rather than remembered.
#   cites    docs/LIMITATIONS.md's source citations -- a dozen still written
#            `file.odin:NNN`, a handful as the file-less `` `:NNN` ``
#            shorthand, and the large majority as `` `file.odin, Symbol` `` --
#            the test names all three docs claim pin a behaviour, and every
#            relative link, are resolved against the repository. The symbol
#            form took over because a line number rots on every insertion above
#            it; it only earns that if the NAME is checked too, which is why
#            cite.py greps the symbol rather than stopping at the file. The
#            per-document counts are printed on every run rather than written
#            down here, since they move with the document. See
#            tools/doccheck/cite.py.
#   apidoc   `odin doc runetea` -- the command README.md hands a newcomer for
#            symbol discovery -- must not list test fixtures. See apidoc().
#
# NO SKIPS THAT LOOK LIKE PASSES. A block whose directive this script does not
# understand is a FAILURE, not an ignored block; a `skip` directive must carry
# a reason and is printed loudly on every run. That is the same rule
# tools/test.sh's leak audit applies: an unexplained absence must never be
# indistinguishable from a check that ran.
#
# THIS GATE NEEDS python3 AND pyte, and that is a deliberate reversal.
# tools/difftest/run.sh used to keep its pyte cross-check off the default gate
# with the argument that "the day it is missing, a shelled-out checker becomes a
# skip, and a skip inside a green run is indistinguishable from a pass". That
# argument is against the SKIP, not against the dependency -- so here the
# dependency is taken and the skip is refused: preflight() below exits non-zero
# when either is absent, and so does every script it shells out to. What bought
# the change is that grepping bytes cannot see a frame; see pty()'s own comment
# for the measurement that settled it. (difftest followed onto the gate the same
# day, for the same reason -- see its header.)
set -euo pipefail

ODIN=${ODIN:-/home/denisbytes/odin/odin}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# .superpowers is git-ignored scratch and may be wiped between runs -- same
# assumption tools/test.sh makes about its clang shim. Everything under here is
# regenerated from the markdown on every invocation.
WORK="$ROOT/.superpowers/doccheck"
# The docs whose samples are gated. A file added here is a file whose every
# Odin block must compile from that moment on.
#
# docs/LIMITATIONS.md was missing from this list until 2026-09-03, which made
# README:539's "if you change a public signature, the samples in the docs will
# fail to compile" true of two documents out of three -- and the third is the
# one README:498 calls required reading before adopting.
DOCS=("$ROOT/README.md" "$ROOT/docs/API.md" "$ROOT/docs/LIMITATIONS.md")

# The docs whose CITATIONS are gated -- see the `cites` check. Deliberately the
# same list: a document earns the same scrutiny whichever kind of claim it
# makes.
CITED_DOCS=("${DOCS[@]}")

# Packages whose `odin doc` output is gated -- see the `apidoc` check.
#
# The first two are the ones the docs actually tell a reader to run it on
# (README:553, docs/API.md:21-23). examples/editor/edit joined them on
# 2026-09-04, and the reason it was left out -- "`odin doc` on that package is
# not a documented command anywhere" -- was true and was the wrong test. That
# package exists to be COPIED: examples/editor/main.odin's own header says so,
# and docs/LIMITATIONS.md section 10 is a whole chapter on what a reader
# inherits by copying it. A reader deciding what to keep runs `odin doc` on it
# whether or not a document told them to, and until its test file got
# `#+private` the answer was 40 test procedures and their fixtures mixed in
# with the model. The examples/ packages that are single-file `package main`
# are NOT here: `odin doc` on a program is not a thing anyone does.
DOC_PACKAGES=(runetea runegloss examples/editor/edit)

# A `skip` DIRECTIVE THE DOCUMENT HAS NOT BEEN GIVEN. Format, '|'-separated:
#
#   <doc path relative to the repo root>|<the block's first line>|<reason>
#
# Keyed by the block's FIRST LINE, not by a line number: an edit anywhere else
# in the document must not silently re-point an entry, and an edit to that first
# line SHOULD fail the gate, because the sample changed and somebody has to look
# at it again. A stale entry -- one that matches no block -- is a FAILURE too,
# so this list cannot quietly outlive its reason.
#
# This exists so LIMITATIONS.md could join DOCS immediately rather than after a
# documentation edit landed; each entry is a debt with a name, printed on every
# run exactly like a `skip`, and the fix is to move it INTO the document as a
# real `<!-- doccheck: skip R -->` (or to make the sample compile).
#
# THE LIST IS EMPTY, AND THAT IS THE POINT. Its one entry was LIMITATIONS 1.4's
# fork/exec block, parked because run.sh and the document had different owners
# and neither half of the fix works alone: an entry is keyed on the block's
# FIRST LINE, and it is consulted BEFORE the directive, so adding a
# `<!-- doccheck: skip -->` to the document would have been silently ignored
# while editing the block to compile would have left the entry stale -- which
# is itself a gate failure. Both halves landed together on 2026-09-04, and the
# block now COMPILES rather than being skipped: `runetea.` became `rt.`,
# `posix.execvp(...)` became a real argv, and it is tagged `body` so it is
# built inside a main. Keeping the mechanism with nothing in it is deliberate;
# the next document that joins DOCS mid-flight will need it again.
UNANNOTATED_BLOCKS=()
# How many builds run at once. The samples are independent packages, so this is
# pure wall-clock; 8 keeps a laptop responsive and still finishes the sweep in
# about the time one serial `odin build` of the editor takes.
JOBS=${DOCCHECK_JOBS:-8}

rm -rf "$WORK"
mkdir -p "$WORK"

# --- extraction -------------------------------------------------------------
#
# Blocks are recognised as ```odin ... ``` . An OPTIONAL HTML comment on the
# line immediately above says what kind of block it is; HTML comments are
# invisible in rendered markdown, which is the whole reason the directive lives
# there rather than inside the sample where a reader would have to look at it:
#
#   <!-- doccheck: decl -->    (the DEFAULT, so it is never actually written)
#                              top-level declarations -- types, procs, consts.
#                              Wrapped in a package with a fixed import
#                              preamble and an empty main.
#   <!-- doccheck: body -->    statements. Wrapped in the same preamble plus
#                              `main :: proc() { ... }`, AND given a companion
#                              file defining `Model`/`update`/`view` -- the
#                              three names the quickstart defines -- so that a
#                              sample about wiring (a render mode, a terminal
#                              opt-in) can talk about a Program without first
#                              re-deriving an application. `decl` samples get
#                              no companion, precisely because they routinely
#                              declare those three names themselves.
#                              Both take an optional GROUP NAME argument
#                              (`decl cmds`): blocks sharing a group compile as
#                              one package, so a section's samples can refer to
#                              each other.
#   <!-- doccheck: program --> a complete program, `package main` and all.
#                              Compiled exactly as written.
#   <!-- doccheck: file P -->  the block must be BYTE-IDENTICAL to the repo
#                              file P. Nothing is compiled here -- P is a real
#                              source file built by the sweep -- so this is the
#                              directive that makes "the README quotes a real
#                              program" a checkable claim rather than a promise.
#   <!-- doccheck: skip R -->  not compiled, for reason R. Printed on every run.
extract_blocks() {
	local out_dir="$1"; shift
	mkdir -p "$out_dir"
	awk -v out="$out_dir" '
		function flush_block() {
			n += 1
			id = sprintf("%03d", n)
			printf "%s\t%s\t%d\t%s\n", id, kind, start_line, arg >> (out "/index.tsv")
			close(out "/index.tsv")
			# Truncate first so an EMPTY block still produces a file rather
			# than no file, which downstream would read as "block missing".
			printf "" > (out "/" id ".odin")
			for (i = 1; i <= nlines; i++) print buf[i] >> (out "/" id ".odin")
			close(out "/" id ".odin")
			printf "%s\n", FILENAME > (out "/" id ".src")
			close(out "/" id ".src")
			nlines = 0
		}
		/^<!-- doccheck:/ {
			line = $0
			sub(/^<!-- doccheck:[ \t]*/, "", line)
			sub(/[ \t]*-->[ \t]*$/, "", line)
			kind = line
			arg = ""
			if (match(kind, /[ \t]/)) {
				arg = substr(kind, RSTART + 1)
				kind = substr(kind, 1, RSTART - 1)
			}
			pending = 1
			next
		}
		/^```odin[ \t]*$/ {
			if (!pending) { kind = "decl"; arg = "" }
			pending = 0
			in_block = 1
			start_line = FNR
			nlines = 0
			next
		}
		/^```/ {
			if (in_block) { in_block = 0; flush_block() }
			pending = 0
			next
		}
		{ if (in_block) { nlines += 1; buf[nlines] = $0 } else { pending = 0 } }
	' "$@"
	# awk never creates index.tsv when a document has no blocks at all.
	touch "$out_dir/index.tsv"
}

# The preamble handed to `decl` and `body` samples. Odin permits unused
# imports, so one fixed list serves every fragment and a sample never has to
# carry import boilerplate the reader does not care about. `rt` and `rg` are
# spelled the way every example in this repository spells them, so a fragment
# reads identically in the docs and in a real file.
write_preamble() {
	local file="$1" pkg="$2"
	cat > "$file" <<EOF
package $pkg
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "core:sys/posix"
import rt "../../../runetea"
import rg "../../../runegloss"
EOF
}

# The companion an `body` sample gets: the same three names the quickstart
# defines, with the same signatures, doing nothing. A wiring sample can then
# say `rt.program_init(&p, Model{}, update, view)` and mean exactly what the
# quickstart means by it.
write_common() {
	# Its own imports: Odin resolves imports per FILE, not per package, so this
	# file cannot borrow main.odin's.
	cat > "$1/common.odin" <<EOF
package $2
import "core:mem"
import rt "../../../runetea"
Model  :: struct { count: int }
update :: proc(m: ^Model, msg: any, alloc: mem.Allocator) -> rt.Cmd { return rt.cmd_nil() }
view   :: proc(m: Model, alloc: mem.Allocator) -> string { return "" }
EOF
}

samples() {
	local blocks="$WORK/blocks"
	extract_blocks "$blocks" "${DOCS[@]}"

	local total=0 skipped=0 quoted=0 built=0 unannotated=0
	local buildlist="$WORK/buildlist"
	: > "$buildlist"
	: > "$WORK/unannotated.used"

	while IFS=$'\t' read -r id kind line arg; do
		[ -n "${id:-}" ] || continue
		total=$((total + 1))
		local src; src=$(cat "$blocks/$id.src")
		local where="${src#$ROOT/}:$line"

		# UNANNOTATED_BLOCKS is consulted BEFORE the directive, because the
		# whole point of an entry is that the document carries no directive at
		# all -- the block therefore arrives here as the default `decl`, which
		# would be compiled.
		local first; first=$(head -n 1 "$blocks/$id.odin")
		local ex why=""
		for ex in "${UNANNOTATED_BLOCKS[@]}"; do
			local ex_rest="${ex#*|}"
			if [ "${ex%%|*}" = "${src#$ROOT/}" ] && [ "${ex_rest%%|*}" = "$first" ]; then
				why="${ex_rest#*|}"
				printf '%s|%s\n' "${ex%%|*}" "${ex_rest%%|*}" >> "$WORK/unannotated.used"
				break
			fi
		done
		if [ -n "$why" ]; then
			unannotated=$((unannotated + 1))
			echo "  UNANNOTATED $where  -- $why"
			continue
		fi

		case "$kind" in
		file)
			if [ -z "$arg" ]; then
				echo "doccheck: $where: 'file' directive needs a path" >&2
				return 1
			fi
			if ! diff -u "$ROOT/$arg" "$blocks/$id.odin" > "$WORK/$id.diff"; then
				echo "doccheck: $where: quoted block has DRIFTED from $arg" >&2
				sed 's/^/  /' "$WORK/$id.diff" >&2
				return 1
			fi
			quoted=$((quoted + 1))
			echo "  quote OK   $where  == $arg"
			;;
		skip)
			if [ -z "$arg" ]; then
				echo "doccheck: $where: 'skip' directive needs a reason" >&2
				return 1
			fi
			skipped=$((skipped + 1))
			echo "  SKIPPED    $where  -- $arg"
			;;
		decl|body|program)
			if [ "$kind" = program ]; then
				local dir="$WORK/p_$id"
				mkdir -p "$dir"
				cp "$blocks/$id.odin" "$dir/main.odin"
				printf '%s\t%s\n' "$dir" "$where" >> "$buildlist"
			else
				# An optional GROUP NAME as the directive's argument. Blocks
				# sharing a group compile as ONE package (one file each), which
				# is what lets a run of samples in a single section of the docs
				# refer to each other the way the prose does -- a Cmd body in
				# one block, the batch() that composes it in the next. Without
				# it every block would have to restate its own world, which is
				# exactly the noise a reader skips over.
				# An ungrouped block is its own group, named after the block; the "s"
				# prefix is what keeps a numeric id a legal Odin package name.
				local group="${arg:-s$id}"
				case "$group" in
				[A-Za-z_]*) ;;
				*) echo "doccheck: $where: group name '$group' is not an identifier" >&2; return 1 ;;
				esac
				local dir="$WORK/p_$group" pkg="doccheck_$group"
				if [ ! -d "$dir" ]; then
					mkdir -p "$dir"
					printf 'package %s\nmain :: proc() {}\n' "$pkg" > "$dir/zz_main.odin"
					# The Model/update/view companion goes only to an UNGROUPED
					# `body` sample. A grouped one has its own group-mates to
					# declare whatever it needs, and an ungrouped `decl` sample
					# routinely declares those three names itself.
					if [ "$kind" = body ] && [ -z "$arg" ]; then write_common "$dir" "$pkg"; fi
					printf '%s\t%s\n' "$dir" "$where" >> "$buildlist"
				fi
				write_preamble "$dir/$id.odin" "$pkg"
				if [ "$kind" = body ]; then
					# A named proc rather than main: a group may hold several
					# body samples, and only zz_main.odin declares the entry
					# point.
					printf 'sample_%s :: proc() {\n' "$id" >> "$dir/$id.odin"
					cat "$blocks/$id.odin" >> "$dir/$id.odin"
					printf '}\n' >> "$dir/$id.odin"
				else
					cat "$blocks/$id.odin" >> "$dir/$id.odin"
				fi
			fi
			built=$((built + 1))
			;;
		*)
			echo "doccheck: $where: unknown directive '$kind'" >&2
			return 1
			;;
		esac
	done < "$blocks/index.tsv"

	if [ -s "$buildlist" ]; then
		build_all "$buildlist" "sample"
	fi

	# A stale exemption is as bad as a missing one: it is an unenforced claim
	# sitting in the gate's own configuration, and the day the block it names is
	# fixed or deleted nothing would say so.
	local ex stale=0
	for ex in "${UNANNOTATED_BLOCKS[@]}"; do
		local ex_rest="${ex#*|}"
		local key; key=$(printf '%s|%s' "${ex%%|*}" "${ex_rest%%|*}")
		if ! grep -qxF "$key" "$WORK/unannotated.used"; then
			echo "doccheck: UNANNOTATED_BLOCKS entry matches no block any more: $key" >&2
			echo "  Delete it from tools/doccheck/run.sh, or fix the key if the sample moved." >&2
			stale=$((stale + 1))
		fi
	done
	[ "$stale" -eq 0 ] || return 1

	echo "  $total odin block(s): $built compiled, $quoted quoted verbatim, $skipped skipped, $unannotated unannotated"
	if [ "$total" -eq 0 ]; then
		echo "doccheck: no odin blocks found at all -- the extractor is broken or the docs lost their samples" >&2
		return 1
	fi
	return 0
}

# Builds every "<dir>\t<label>" line of a list file, JOBS at a time, and fails
# if any of them fails. Output for a failing build is printed in full; a
# succeeding one prints one line.
build_all() {
	local list="$1" what="$2"
	local outdir="$WORK/bin"; mkdir -p "$outdir"
	local failed="$WORK/failed.$what"; : > "$failed"

	# A failure is recorded in a FILE rather than in an exit status because
	# every build runs in its own xargs child: a `return 1` in there is
	# invisible here. The file is also what makes the report complete -- all
	# failures are printed, not just the first one to be scheduled.
	DOCCHECK_ODIN="$ODIN" DOCCHECK_OUT="$outdir" DOCCHECK_FAILED="$failed" \
	xargs -a "$list" -P "$JOBS" -I{} bash -c '
		IFS=$'"'"'\t'"'"' read -r dir label <<< "$1"
		name=$(printf "%s" "$dir" | tr "/." "__")
		if out=$("$DOCCHECK_ODIN" build "$dir" -out:"$DOCCHECK_OUT/$name.bin" 2>&1); then
			echo "  build OK   $label"
		else
			echo "  BUILD FAILED  $label  ($dir)"
			printf "%s\n" "$out" | sed "s/^/    /"
			echo "$label" >> "$DOCCHECK_FAILED"
		fi
	' _ {}

	if [ -s "$failed" ]; then
		echo "doccheck: $(wc -l < "$failed") $what build(s) failed:" >&2
		sed 's/^/  /' "$failed" >&2
		return 1
	fi
	return 0
}

sweep() {
	local list="$WORK/sweeplist"; : > "$list"
	local d
	for d in "$ROOT"/examples/*/ "$ROOT"/tools/*/; do
		d="${d%/}"
		[ -f "$d/main.odin" ] || continue
		grep -q '^package main' "$d/main.odin" || continue
		printf '%s\t%s\n' "$d" "${d#$ROOT/}" >> "$list"
	done
	build_all "$list" "sweep"
	echo "  $(wc -l < "$list") program(s) built"
}

# --- the quickstart, run for real -------------------------------------------
#
# WHAT THIS USED TO BE, AND WHY IT WAS NOT A CHECK. Until 2026-09-03 this
# function typed 'j', ' ', 'q' and ran three `grep -qE` over ptyrun's byte dump.
# Three things were wrong with that, and together they made the check unable to
# fail for the reason it existed:
#
#   1. The dump is the WHOLE session with escapes spelled out, so an unanchored
#      grep for "> [x] Buy celery" was satisfied by any frame that ever held
#      those characters -- including one the renderer then failed to erase. The
#      comment here claimed "the assertions are on the LAST frame the program
#      painted"; they were scoped to no frame at all.
#   2. Nothing modelled a terminal, so no assertion was on a SCREEN. A renderer
#      emitting the right text with the wrong cursor motions passed. Measured:
#      with `reachable` in runetea/render.odin changed to `reachable - 2`, this
#      function printed "pty OK ... with the expected frames" and exited 0,
#      while the screen those very bytes produce has four stacked copies of the
#      header above the frame -- a screen that does not match README.md:19-26.
#   3. The three keystrokes were 'j', ' ' and 'q'. No escape sequence was ever
#      sent over the pty, and the window was never resized -- so the decoder's
#      CSI path and the renderer's resize path, two of the three places this
#      library is hardest to get right, were driven by nothing.
#
# All three are fixed below: an arrow key and a resize are in the script, and
# every assertion is an EXACT CELL GRID produced by replaying the captured
# bytes through pyte (tools/doccheck/screen.py), diffed against the screen the
# documentation prints.
#
# WHY EXACT GRIDS AND NOT "CONTAINS". A frame is a position as much as a string.
# Every renderer bug this repository has actually shipped -- the tab-driven
# downward slide, the stale row after a wide cluster on the margin, the rewind
# that stopped short -- put the right characters somewhere wrong, which is
# precisely what a substring check cannot see. Trailing blank rows are dropped
# by screen.py so the expected screens read like the documentation; a blank row
# INSIDE or ABOVE the frame is kept and fails.
pty() {
	local bin="$WORK/bin/quickstart"
	mkdir -p "$WORK/bin"
	"$ODIN" build "$ROOT/examples/quickstart" -out:"$bin"
	"$ODIN" build "$ROOT/tools/ptyrun" -out:"$WORK/bin/ptyrun"

	# down  1b5b42  CSI B, the Down arrow -- the one keystroke here that is an
	#               escape SEQUENCE rather than a byte, and the reason this
	#               script exists in this shape. ptyrun writes a step in one
	#               write(), which is what a terminal emulator does with a
	#               keypress; the old per-byte pacing turned this into a lone
	#               ESC (which the quickstart binds to quit) followed by two
	#               printable characters.
	# toggle  20    space, which checks the highlighted item.
	# grow  r100x30 a real TIOCSWINSZ on the pty. The kernel raises SIGWINCH,
	#               runetea's signal thread turns it into a Window_Size_Msg,
	#               and the renderer repaints at the new width -- a path the
	#               gate never drove before.
	# up    1b5b41  CSI A, back to the first item.
	# quit  71      'q'.
	local out="$WORK/quickstart.pty"
	STEPS="$WORK/quickstart.steps"   # read by expect_screen; see its comment
	if ! PTYRUN_STEPS="$STEPS" "$WORK/bin/ptyrun" "$bin" \
		'down=1b5b42,toggle=20,grow=r100x30,up=1b5b41,quit=71' 80 24 8000 > "$out"; then
		echo "doccheck: the quickstart did not run cleanly under a pty" >&2
		sed 's/^/  /' "$out" >&2
		return 1
	fi

	# The screen the program paints before anybody touches it: the cursor on the
	# first item, nothing checked. The `cursor` line is asserted too -- .Inline
	# owns no part of the screen and must rest the caret on the row below its
	# output, where any other program's would be (see Render_Mode.Inline's note
	# in runetea/render.odin), and a renderer that parked it inside the frame
	# would be invisible to a text-only comparison.
	expect_screen boot --cursor <<'EOF'
What should we buy at the market?

> [ ] Buy carrots
  [ ] Buy celery
  [ ] Buy kohlrabi

Press q to quit.
cursor 0 7 shown
EOF

	# After Down + space -- and the expected screen is not written here. It is
	# READ OUT OF README.md, from the first ```text block in the file
	# (README.md:19-26 as of this writing), and compared against the grid the
	# program actually painted. That is what makes "and the output looks like
	# this" a checked claim rather than a remembered one, and keeping the
	# expectation in one place rather than two means a change to the quickstart's
	# view is a README edit, full stop -- not a README edit plus a second copy
	# in this file that would drift on its own schedule.
	awk '/^```text$/ { f = 1; next } /^```/ { if (f) exit } f' "$ROOT/README.md" > "$WORK/readme.screen"
	if [ ! -s "$WORK/readme.screen" ]; then
		echo "doccheck: README.md has no \`\`\`text block to compare the quickstart against" >&2
		return 1
	fi
	expect_screen toggle < "$WORK/readme.screen"
	echo "  quote OK   that expectation was README.md's own \`\`\`text block, not a copy of it"

	# After the resize. Same eight rows, now on a 100x30 terminal: a repaint
	# that rewound the wrong number of rows for the NEW size, or that left the
	# pre-resize frame behind, shows up here and nowhere else in this suite.
	expect_screen grow <<'EOF'
What should we buy at the market?

  [ ] Buy carrots
> [x] Buy celery
  [ ] Buy kohlrabi

Press q to quit.
EOF

	# After Up: the selection stays on celery, the caret moves back to carrots.
	# Two escape sequences into the run, so a decoder that resynchronised badly
	# on the first one cannot still look right here.
	expect_screen up <<'EOF'
What should we buy at the market?

> [ ] Buy carrots
  [x] Buy celery
  [ ] Buy kohlrabi

Press q to quit.
EOF

	echo "  pty OK     examples/quickstart drove 2 arrow keys, a space, a 100x30 resize and 'q', exited 0"
}

# Compares the replayed screen after step $1 against the expected grid on stdin.
# `--cursor` as $2 adds the caret's position and visibility to both sides.
# Reads $STEPS, which pty() sets to the transcript of the run in progress; this
# helper is only ever meaningful inside a pty() run and `set -u` says so loudly
# if it is called anywhere else.
#
# On failure it prints the diff AND every step's screen, because a wrong screen
# is almost never wrong for the first time at the step that failed -- the frame
# that broke it is usually two steps earlier.
expect_screen() {
	local step="$1"; shift
	local want="$WORK/want.$step" got="$WORK/got.$step"
	cat > "$want"
	if ! python3 "$ROOT/tools/doccheck/screen.py" "$STEPS" --step "$step" "$@" > "$got"; then
		echo "doccheck: could not replay the pty transcript for step '$step'" >&2
		return 1
	fi
	if ! diff -u "$want" "$got" > "$WORK/screen.$step.diff"; then
		echo "doccheck: the screen after step '$step' is not the one the docs describe" >&2
		echo "  (-- what the docs say, ++ what the program actually painted)" >&2
		sed 's/^/  /' "$WORK/screen.$step.diff" >&2
		echo "  every step, replayed:" >&2
		python3 "$ROOT/tools/doccheck/screen.py" "$STEPS" --step all | sed 's/^/    /' >&2
		return 1
	fi
	echo "  screen OK  step '$step' ($(wc -l < "$want") line(s) matched exactly)"
}

# --- source citations -------------------------------------------------------
#
# docs/LIMITATIONS.md's distinguishing virtue is that every claim cites the
# source comment that argues it. Nothing checked those citations until
# 2026-09-03, and one of them rotted in a single commit: `` `:678-686` `` in
# section 2.16 resolved to timer.odin's "CATCHING UP" comment at 60219f3, the
# commit that introduced the document, and pointed at an unrelated
# Timer_Unavailable_Msg comment one commit later at bfed0e8.
#
# What is checkable is stated at length in cite.py, including what is NOT: a
# range check narrows the window on a stale citation, it does not close it.
cites() {
	python3 "$ROOT/tools/doccheck/cite.py" "${CITED_DOCS[@]}"
}

# --- `odin doc` ---------------------------------------------------------------
#
# README:553 and docs/API.md:21-23 point a newcomer at `odin doc runetea` for
# "every public symbol with its doc comment". Odin has no sub-package privacy
# and *_test.odin lives in the package directory, so until 2026-09-03 that
# command answered with 661 symbols of which 458 were declared only in test
# files -- Fetch_Env, Coord_Env, Gate_Env, Half_Mutated, N_PROD, PER,
# cmd_panic_update -- none of them distinguishable from API by name. The
# remedy is a `#+private` tag at the top of every test file, which costs one
# line and nothing else: `odin test` still discovers @(test) procedures in a
# private file (verified), and package-private is what those fixtures already
# were in every sense but the compiler's.
#
# The assertion below is on the OUTPUT, not on the tags, deliberately: it is the
# property the docs promise, and it stays true no matter how a future file
# chooses to achieve it. The tag is only named in the failure message, as the
# cheapest way to satisfy it.
apidoc() {
	local pkg leaked_total=0
	for pkg in "${DOC_PACKAGES[@]}"; do
		local dir="$ROOT/$pkg"
		# A DOC_PACKAGES entry is a repo-relative PATH, so it can contain
		# slashes (examples/editor/edit). Every $WORK file below is named after
		# it, and "$WORK/doc.examples/editor/edit" is a redirect into a
		# directory that does not exist -- a bare "No such file or directory"
		# in the middle of the gate. Flattened once, here, rather than at each
		# of the seven uses.
		local tag="${pkg//\//_}"
		"$ODIN" doc "$dir" > "$WORK/doc.$tag"

		# Top-level declarations, by file class. A name declared in BOTH a test
		# file and a real one is API and must not be reported -- hence the set
		# difference rather than a plain grep of the test files.
		# `|| true` on every grep: an empty result is a legitimate answer here
		# (a test file with no top-level declarations), and grep's exit 1 for it
		# would abort the whole gate under `set -e` as if the tool were broken.
		{ grep -hoE '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*::' "$dir"/*_test.odin || true; } \
			| sed 's/[[:space:]]*::$//' | sort -u > "$WORK/names.test.$tag"
		{ find "$dir" -maxdepth 1 -name '*.odin' ! -name '*_test.odin' -print0 \
			| xargs -0 grep -hoE '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*::' || true; } \
			| sed 's/[[:space:]]*::$//' | sort -u > "$WORK/names.lib.$tag"
		comm -23 "$WORK/names.test.$tag" "$WORK/names.lib.$tag" > "$WORK/names.testonly.$tag"

		# `odin doc` indents every symbol with exactly two TABS; its doc comments
		# are indented deeper, so this cannot pick prose up. The tabs are written
		# with bash's $'...' quoting rather than as \t inside the pattern,
		# because POSIX ERE has no \t escape -- GNU grep reads it as a literal
		# 't' and the check silently matches nothing, which is how this was
		# first written and how it failed loudly on its first run.
		sed -n $'s/^\t\t\\([A-Za-z_][A-Za-z0-9_]*\\).*/\\1/p' "$WORK/doc.$tag" \
			| sort -u > "$WORK/names.doc.$tag"
		comm -12 "$WORK/names.testonly.$tag" "$WORK/names.doc.$tag" > "$WORK/leaked.$tag"

		local n_doc n_test n_leak
		n_doc=$(wc -l < "$WORK/names.doc.$tag")
		n_test=$(wc -l < "$WORK/names.testonly.$tag")
		n_leak=$(wc -l < "$WORK/leaked.$tag")
		if [ "$n_leak" -ne 0 ]; then
			echo "doccheck: \`odin doc $pkg\` lists $n_leak symbol(s) that exist only in test files:" >&2
			sed 's/^/    /' "$WORK/leaked.$tag" >&2
			echo "  Put '#+private' on the first line of the test file that declares each one." >&2
			leaked_total=$((leaked_total + n_leak))
			continue
		fi
		echo "  doc OK     odin doc $pkg: $n_doc symbol(s), 0 of $n_test test-only name(s) leaked"
	done
	[ "$leaked_total" -eq 0 ] || return 1
	return 0
}

# --- preflight ---------------------------------------------------------------
#
# python3 and pyte are HARD requirements of this gate (see the header). They are
# checked once, up front, with a message that says what to install -- rather than
# at first use, where the failure would arrive as a bare non-zero exit in the
# middle of a screen diff and read like a broken renderer.
preflight() {
	if ! command -v python3 > /dev/null 2>&1; then
		echo "doccheck: python3 is required (the pty gate replays frames through a terminal emulator)" >&2
		return 1
	fi
	if ! python3 -c 'import pyte' > /dev/null 2>&1; then
		echo "doccheck: the python module 'pyte' is required: pip install pyte" >&2
		echo "  This is a hard failure and never a skip -- without it the pty gate has" >&2
		echo "  nothing to assert on, and a green run would mean nothing." >&2
		return 1
	fi
}

case "${1:-all}" in
samples) echo "=== doccheck: markdown samples ==="; samples ;;
sweep)   echo "=== doccheck: build sweep ===";      sweep ;;
pty)     preflight; echo "=== doccheck: quickstart on a pty ==="; pty ;;
cites)   preflight; echo "=== doccheck: source citations ==="; cites ;;
apidoc)  echo "=== doccheck: odin doc ==="; apidoc ;;
all)
	preflight
	echo "=== doccheck: markdown samples ==="
	samples
	echo
	echo "=== doccheck: build sweep ==="
	sweep
	echo
	echo "=== doccheck: quickstart on a pty ==="
	pty
	echo
	echo "=== doccheck: source citations ==="
	cites
	echo
	echo "=== doccheck: odin doc ==="
	apidoc
	;;
*)
	echo "usage: $0 [all|samples|sweep|pty|cites|apidoc]" >&2
	exit 2
	;;
esac
