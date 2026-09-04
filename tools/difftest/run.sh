#!/usr/bin/env bash
# The diff renderer's pyte cross-check and byte-count measurements.
#
#   ./tools/difftest/run.sh            replay both byte streams through pyte
#   ./tools/difftest/run.sh measure    print the byte counts
#
# ON ./tools/test.sh SINCE 2026-09-03, and this comment used to say the
# opposite. The old argument was that python3 + pyte must not become a hard
# dependency of the suite, "because the day it is missing, a shelled-out checker
# becomes a skip, and a skip inside a green run is indistinguishable from a
# pass". That was an argument against the SKIP, not against the dependency --
# and it was answered when the documentation gate started replaying the
# quickstart's frames through pyte (tools/doccheck/screen.py) and refusing to
# run at all without it. With one checker already failing loudly on a missing
# module, keeping a second one off the gate bought nothing and cost the whole
# independent opinion. The measured price of adding it is ~3s wall clock for
# 200 cases and 1639 frames.
#
# The equivalence invariant is ALSO asserted with no external dependency at all,
# by runetea/diff_oracle_test.odin. That one shares this package's terminal
# primitives with the renderer it checks; this one shares nothing with it. Both
# run. Contrast tools/racecheck, which stays a separate mode for a different
# reason entirely: ThreadSanitizer needs its own build of the binary, not merely
# another tool on the machine.
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
