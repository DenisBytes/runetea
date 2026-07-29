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

# --- leak audit -------------------------------------------------------------
#
# `odin test`'s tracking allocator prints a `+++ leak` line per outstanding
# allocation, but it does NOT fail the run for them: before 2026-07-27 this
# suite printed ~79-81 of them on every green run, and a suite that always
# reports leaks cannot report a NEW one. That is not hypothetical -- it is
# exactly how tick()'s per-fire Timer_Handle + fn_env leak survived four
# feature commits unnoticed, hiding in plain sight among 49 box() lines from
# tests that drained a Mailbox without box_free'ing what they drained.
#
# So the audit below turns the leak report into a real gate: every leak site
# must be on ALLOWED_LEAK_SITES, or the run fails no matter what odin test
# itself thought.
#
# ALLOWED_LEAK_SITES matches by SITE, not by count, deliberately. Pinning an
# exact number would make every new run()-based test a spurious failure, and
# the one allowed site is bounded by construction anyway (see below), so a
# count regression there is not a thing that can happen. What the audit is
# actually for is a leak appearing somewhere NEW, which is what every real
# regression in this codebase's history has looked like.
#
# The single entry:
#
#   thread_unix.odin:91:_create  -- one Odin ^Thread struct (256B) per
#     dispatcher_reap call, i.e. one per run()/run_nbio() session, i.e. one
#     per run()-based test. DELIBERATE and documented at length in cmd.odin
#     ("WHY self_cleanup = false"): self_cleanup = true has a genuine race in
#     core:thread itself, which ThreadSanitizer catches reproducibly, and
#     thread.destroy() would reclaim the struct only by join()ing the very
#     Cmd that dispatcher_reap exists to stop waiting for. dispatcher_reap
#     detaches the OS thread by hand (pthread_detach) so the kernel-level
#     stack/TCB ARE reclaimed; what leaks is a fixed-size struct, once per
#     session, reclaimed by the OS at process exit. Not proportional to
#     session length, message count, or anything else that grows.
ALLOWED_LEAK_SITES='thread_unix\.odin:[0-9]+:_create'

# Runs `odin test`, streams its output unchanged, then audits the leak lines.
# Exits non-zero if odin test failed OR if any leak appeared at an unexpected
# site. Prints the full by-site breakdown either way -- a green run should
# show exactly the allowed line and nothing else, so "what clean looks like"
# is visible rather than something you have to know.
run_with_leak_audit() {
	local out status
	out=$(mktemp)
	set +e
	"$@" 2>&1 | tee "$out"
	status=${PIPESTATUS[0]}
	set -e

	echo
	echo "--- leak audit (see tools/test.sh) ---"
	# Strip the varying heap address so identical sites collapse into one row.
	local sites
	sites=$(grep -E '^\s+\+\+\+ leak' "$out" | sed -E 's/.*@ 0x[0-9A-F]+ //' | sort | uniq -c | sort -rn || true)
	if [ -z "$sites" ]; then
		echo "  no leaks reported at all"
	else
		echo "$sites" | sed 's/^/  /'
	fi

	local unexpected
	unexpected=$(echo "$sites" | grep -Ev "$ALLOWED_LEAK_SITES" | grep -E '\S' || true)
	rm -f "$out"

	if [ -n "$unexpected" ]; then
		echo
		echo "LEAK AUDIT FAILED: leak(s) at unexpected site(s):" >&2
		echo "$unexpected" | sed 's/^/  /' >&2
		echo "If one of these is genuinely deliberate and bounded, add it to" >&2
		echo "ALLOWED_LEAK_SITES in tools/test.sh WITH the justification -- do not" >&2
		echo "just widen the pattern." >&2
		return 1
	fi
	echo "  OK: every leak site is on the allowlist"
	return "$status"
}

mode=${1:-plain}
cd "$PKG"

case "$mode" in
plain)
	run_with_leak_audit "$ODIN" test . -define:ODIN_TEST_THREADS=1

	# examples/editor's model/update/view live in their own package
	# (examples/editor/edit) precisely so they can be driven through the real
	# rt.run() loop from scripted input bytes -- an example that only exists
	# as a binary is validated by nobody. It CANNOT live in runetea's own test
	# package: edit imports runetea, so a runetea test importing edit would be
	# an import cycle. Hence a second `odin test` invocation rather than more
	# files in $PKG.
	#
	# Same leak audit, same allowlist: these tests call run(), so they produce
	# the same one-^Thread-per-session leak documented above and nothing else.
	# cwd matters -- the golden test reads testdata/ relative to it.
	echo
	echo "=== examples/editor/edit ==="
	cd "$ROOT/examples/editor/edit"
	run_with_leak_audit "$ODIN" test . -define:ODIN_TEST_THREADS=1

	# runegloss is a SIBLING PACKAGE that imports runetea (for display_width --
	# there is exactly one implementation of it in this repo, in
	# runetea/width.odin, and runegloss measures everything with it). The
	# import is one-directional, so this could in principle have lived in
	# $PKG's own test run -- it does not, for the same reason edit does not:
	# runegloss imports runetea, so a runetea test importing runegloss would be
	# an import cycle.
	#
	# Same leak audit, same allowlist, and here the allowlist should be
	# entirely unused: nothing in runegloss starts a thread or calls run(), and
	# render() allocates only from the allocator it is handed. A green run
	# prints "no leaks reported at all" for this package.
	echo
	echo "=== runegloss ==="
	cd "$ROOT/runegloss"
	run_with_leak_audit "$ODIN" test . -define:ODIN_TEST_THREADS=1
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
	run_with_leak_audit setarch "$(uname -m)" -R "$ODIN" test . -define:ODIN_TEST_THREADS=1 -sanitize:thread
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
