#!/usr/bin/env bash
# RuneTea test runner.
#
# Odin invokes `clang` as its linker driver. Ubuntu 22.04 ships clang-14, whose
# compiler-rt predates the __tsan_memcpy/__tsan_memset symbols that Odin's
# LLVM-20 codegen emits -- so `-sanitize:thread` fails to LINK with the system
# default. Prepending a shim that resolves `clang` to clang-18 fixes it with no
# system changes and no sudo.
#
#   ./tools/test.sh          plain test run
#   ./tools/test.sh tsan     + thread sanitizer, but see the WARNING below --
#                              it does NOT detect races on this toolchain
#   ./tools/test.sh race     the real race gate -- USE THIS for concurrent code
#
# `race` builds and runs tools/racecheck, a standalone `main` program, under
# ThreadSanitizer -- NOT `odin test -sanitize:thread` (see the WARNING in the
# `tsan` case below for why: that mode never reports anything on this
# toolchain, verified 2026-07-26). helgrind was tried as a substitute before
# that and is not usable either: it only understands pthread_mutex/pthread_cond,
# and Odin's sync.Mutex/Sema are raw futex syscalls, invisible to it -- a clean
# run reported ~39k "Possible data race ... Locks held: none" hits, virtually
# all inside core:thread's own pool internals, none of them real.
set -euo pipefail

ODIN=${ODIN:-/home/denisbytes/odin/odin}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$ROOT/.superpowers/toolchain"
PKG="$ROOT/runetea"

# (Re)create the shim; .superpowers is git-ignored scratch and may be wiped.
if [ -x /usr/bin/clang-18 ]; then
	mkdir -p "$SHIM"
	ln -sf /usr/bin/clang-18   "$SHIM/clang"
	ln -sf /usr/bin/clang++-18 "$SHIM/clang++"
	export PATH="$SHIM:$PATH"
else
	echo "warning: clang-18 not found; -sanitize:thread will fail to link" >&2
fi

mode=${1:-plain}
cd "$PKG"

case "$mode" in
plain)
	exec "$ODIN" test . -define:ODIN_TEST_THREADS=1
	;;
tsan)
	# WARNING (verified 2026-07-26): `odin test -sanitize:thread` does NOT
	# detect data races on this toolchain. Proven with a deliberate 4-thread
	# unsynchronized counter:
	#   odin build  + -sanitize:thread -> SUMMARY: data race, exit 66   (works)
	#   odin test   + -sanitize:thread -> no report, exit 0, "successful"
	# The race physically occurred in both (392997 of 400000 increments landed).
	# Under default ASLR it also prints "ThreadSanitizer: memory layout is
	# incompatible, possibly due to high-entropy ASLR" and disables itself.
	#
	# So this mode is NOT a race gate. It is kept only because it still catches
	# allocator/CHECK failures (that is how Task 5's init_context crash
	# surfaced). Use `./tools/test.sh race` for actual race detection.
	echo "NOTE: this mode does not detect data races -- see comment in tools/test.sh." >&2
	echo "      Use './tools/test.sh race' for a real race gate." >&2
	exec setarch "$(uname -m)" -R "$ODIN" test . -define:ODIN_TEST_THREADS=1 -sanitize:thread
	;;
race)
	# tools/racecheck/main.odin is a standalone `main` program (not an `odin
	# test` package -- see the WARNING above for why that mode is unusable)
	# that drives RuneTea's Mailbox, Dispatcher and Signal_Watcher under real
	# concurrency: multiple producers plus a dual recv/try_recv consumer plus
	# a concurrent mailbox_close, a loaded Dispatcher torn down while pool and
	# detached Cmds are still in flight, and a Signal_Watcher bombarded with
	# signals and stopped while its mailbox is still being drained.
	#
	# `odin build -sanitize:thread` DOES report races reliably on this
	# toolchain (unlike `odin test`, verified above) and the resulting binary
	# exits 66 on a TSan report -- confirmed against a deliberate
	# unsynchronized counter injected into this exact harness on 2026-07-26,
	# see racecheck-report.md. `setarch -R` avoids TSan's ASLR self-disable.
	# No error-exitcode flag needed: TSan's own non-zero exit IS the gate.
	BIN=/tmp/runetea-racecheck
	"$ODIN" build "$ROOT/tools/racecheck" -out:"$BIN" -sanitize:thread -debug
	exec setarch "$(uname -m)" -R "$BIN"
	;;
*)
	echo "usage: $0 [plain|tsan|race]" >&2
	exit 2
	;;
esac
