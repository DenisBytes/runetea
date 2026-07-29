#!/usr/bin/env bash
# RuneTea documentation gate.
#
#   ./tools/doccheck/run.sh          the whole gate (this is what tools/test.sh runs)
#   ./tools/doccheck/run.sh samples  only the markdown code samples
#   ./tools/doccheck/run.sh sweep    only the build sweep
#   ./tools/doccheck/run.sh pty      only the quickstart's real-pty run
#
# WHY THIS EXISTS. Documentation that does not compile is worse than no
# documentation, because it fails on the reader's first five minutes -- when
# they have no way to tell "the sample is stale" from "I typed it wrong" from
# "this library does not work". Every Odin code block in README.md and
# docs/API.md is therefore extracted from the markdown and COMPILED by this
# script, and the quickstart is additionally EXECUTED against a real pty and
# asserted on. A sample cannot drift, because drifting fails the gate.
#
# THREE KINDS OF CHECK, and the reason there are three:
#
#   samples  Every ```odin block in the docs is compiled. Most are fragments
#            (a Msg type, an update proc, a Cmd body); those are wrapped in a
#            fixed preamble and built as their own package, so a renamed proc
#            or a changed signature is a build failure in the doc, not a
#            surprise for the reader.
#   sweep    Every `main` package in examples/ and tools/ is built. The docs
#            point at these; a broken example is a broken doc.
#   pty      examples/quickstart -- the program README.md quotes verbatim --
#            is run under a real pty (tools/ptyrun) with real keystrokes, and
#            its actual frames are asserted. This is what makes the "and the
#            output looks like this" half of the quickstart true rather than
#            remembered.
#
# NO SKIPS THAT LOOK LIKE PASSES. A block whose directive this script does not
# understand is a FAILURE, not an ignored block; a `skip` directive must carry
# a reason and is printed loudly on every run. That is the same rule
# tools/test.sh's leak audit applies: an unexplained absence must never be
# indistinguishable from a check that ran.
set -euo pipefail

ODIN=${ODIN:-/home/denisbytes/odin/odin}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# .superpowers is git-ignored scratch and may be wiped between runs -- same
# assumption tools/test.sh makes about its clang shim. Everything under here is
# regenerated from the markdown on every invocation.
WORK="$ROOT/.superpowers/doccheck"
# The docs whose samples are gated. A file added here is a file whose every
# Odin block must compile from that moment on.
DOCS=("$ROOT/README.md" "$ROOT/docs/API.md")
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

	local total=0 skipped=0 quoted=0 built=0
	local buildlist="$WORK/buildlist"
	: > "$buildlist"

	while IFS=$'\t' read -r id kind line arg; do
		[ -n "${id:-}" ] || continue
		total=$((total + 1))
		local src; src=$(cat "$blocks/$id.src")
		local where="${src#$ROOT/}:$line"

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

	echo "  $total odin block(s): $built compiled, $quoted quoted verbatim, $skipped skipped"
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

# The quickstart, run for real. The keystrokes are hex (see tools/ptyrun): 'j'
# moves down, ' ' toggles, 'q' quits. The assertions are on the LAST frame the
# program painted, which is the one a reader would still be looking at.
pty() {
	local bin="$WORK/bin/quickstart"
	mkdir -p "$WORK/bin"
	"$ODIN" build "$ROOT/examples/quickstart" -out:"$bin"
	"$ODIN" build "$ROOT/tools/ptyrun" -out:"$WORK/bin/ptyrun"

	local out="$WORK/quickstart.pty"
	if ! "$WORK/bin/ptyrun" "$bin" 6a2071 80 24 8000 > "$out"; then
		echo "doccheck: the quickstart did not run cleanly under a pty" >&2
		sed 's/^/  /' "$out" >&2
		return 1
	fi

	local want
	for want in \
		'What should we buy at the market?' \
		'> \[x\] Buy celery' \
		'Press q to quit.'
	do
		if ! grep -qE "$want" "$out"; then
			echo "doccheck: the quickstart's real output is missing /$want/" >&2
			sed 's/^/  /' "$out" >&2
			return 1
		fi
	done
	echo "  pty OK     examples/quickstart typed 'j', ' ', 'q' and exited 0 with the expected frames"
}

case "${1:-all}" in
samples) echo "=== doccheck: markdown samples ==="; samples ;;
sweep)   echo "=== doccheck: build sweep ===";      sweep ;;
pty)     echo "=== doccheck: quickstart on a pty ==="; pty ;;
all)
	echo "=== doccheck: markdown samples ==="
	samples
	echo
	echo "=== doccheck: build sweep ==="
	sweep
	echo
	echo "=== doccheck: quickstart on a pty ==="
	pty
	;;
*)
	echo "usage: $0 [all|samples|sweep|pty]" >&2
	exit 2
	;;
esac
