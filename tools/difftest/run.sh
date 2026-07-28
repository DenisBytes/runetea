#!/usr/bin/env bash
# The diff renderer's pyte cross-check and byte-count measurements.
#
#   ./tools/difftest/run.sh            replay both byte streams through pyte
#   ./tools/difftest/run.sh measure    print the byte counts
#
# NOT part of ./tools/test.sh, deliberately. This needs python3 + pyte, and
# making a third-party Python module a hard dependency of `odin test` trades one
# risk for a worse one: the day it is missing, a shelled-out checker becomes a
# skip, and a skip inside a green run is indistinguishable from a pass. The
# equivalence invariant itself IS on the gate -- see
# runetea/diff_oracle_test.odin, which asserts it with no external deps -- and
# this is the independent second opinion on top. Same split tools/racecheck
# follows for the sanitizer.
set -euo pipefail

ODIN=${ODIN:-/home/denisbytes/odin/odin}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN=/tmp/runetea-difftest

"$ODIN" build "$ROOT/tools/difftest" -out:"$BIN"

case "${1:-check}" in
check)
	"$BIN" dump | python3 "$ROOT/tools/difftest/check.py"
	;;
measure)
	"$BIN" measure
	;;
*)
	echo "usage: $0 [check|measure]" >&2
	exit 2
	;;
esac
