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
#   ./tools/test.sh tsan     + thread sanitizer -- USE THIS for concurrent code
#   ./tools/test.sh race     + valgrind helgrind -- NOISY, see below
#
# tsan is the authoritative race check. helgrind is NOT usable as-is: it only
# models pthread primitives, and Odin's sync.Mutex/Sema are futex-based, so it
# cannot see our locks. A clean run reports ~39k "Possible data race ... Locks
# held: none" hits, essentially all inside core:thread's own pool internals.
# Kept only as a fallback if tsan ever regresses, and it would need a
# suppression file before its output means anything.
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
	exec "$ODIN" test . -define:ODIN_TEST_THREADS=1 -sanitize:thread
	;;
race)
	# helgrind needs a binary to re-run, so keep the one `odin test` builds.
	# (-build-mode is a `build`-only flag and is rejected here.)
	"$ODIN" test . -define:ODIN_TEST_THREADS=1 -keep-executable -out:/tmp/runetea-racetest
	exec valgrind --tool=helgrind --error-exitcode=1 /tmp/runetea-racetest
	;;
*)
	echo "usage: $0 [plain|tsan|race]" >&2
	exit 2
	;;
esac
