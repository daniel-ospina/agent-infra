#!/usr/bin/env bash
# mtime-probe-portability.test.sh — pins the mtime probe in the two scripts
# agent-infra#3434 left behind, so the BSD-first spelling cannot come back.
#
# Run: bash scripts/mtime-probe-portability.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. Hermetic: every log and
# lock is a fixture in a temp directory, and the scripts are driven with `HOME`
# pointed there, so no real state is read or written. Host facilities used:
# `mktemp`, `grep`, `basename`, `date`, `touch`, and `bash -n`.
#
# WHY THIS SUITE EXISTS — the gate could not see the bug it is about.
# `scripts/check-portability-traps.sh`'s `stat-c-gnu` rule (`:1371`) fires on
# `stat -c` WITHOUT an `-f` counterpart. A ONE-SIDED BSD-first `stat -f %m`
# matches no rule at all (`:1344` blesses the two-sided chain), so the gate
# returns "✅ no NEW cross-platform traps" on the broken code. Measured:
#
#   $ git show origin/main:scripts/monitor-worker.sh > /tmp/pitfall/scripts/monitor-worker.sh
#   $ bash scripts/check-portability-traps.sh --root /tmp/pitfall --targets …
#   …(75 baseline-shrink rows elided)…
#   ✅ no NEW cross-platform traps (0 grandfathered across 0 file/rule pairs)   rc=0
#
# …for a line that aborts on every Linux box. A gate blind in this direction
# cannot pin the fix, so the pin lives here instead. Issue #3434 records the
# gap; the rule to close it is the mirror of `stat-c-gnu`.
#
# ⛔ THE SHAPE: `stat -f %m` is BSD-only. On GNU coreutils `-f` is `--file-system`,
# so `stat -f %m PATH` prints a whole filesystem block to STDOUT and exits 1.
# Inside a SINGLE `$( … || … )` substitution the GNU fallback APPENDS the epoch to
# that block, so the variable is non-numeric and the arithmetic either aborts
# (`File: unbound variable`, under `set -u`) or yields a nonsense age.
#
# ⛔ WHY BOTH ARMS: the two failure modes are opposite. A probe that silently
# yields 0 makes every log look infinitely OLD; a probe that silently yields `now`
# makes every log look fresh for ever. A fresh-only suite therefore passes on a
# probe that hardcodes `now`, so the suite also ages a log and requires STALE.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR="$SCRIPT_DIR/monitor-worker.sh"
LANE_SCAN="$SCRIPT_DIR/lane-scan-fallback.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_contains()     { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi }
assert_not_contains() { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi }
assert_eq()           { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi }

for f in "$MONITOR" "$LANE_SCAN"; do
    [ -f "$f" ] || { echo "❌ missing $f"; exit 1; }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/mtime-probe-portability.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# ⛔ THE EXECUTED VIEW IS `grep -v '^[[:space:]]*#'`, NOT `grep -v '^#'`. A
# COLUMN-0-only strip leaves an INDENTED comment in the view — and the probe in
# `lane-scan-fallback.sh` sits inside an `if`, so a comment written next to it is
# indented by construction. Measured: an indented `# … date -r …` over a probe
# replaced with a non-`date -r` reader passed BOTH arms under the old strip.
executed_view() { grep -v '^[[:space:]]*#' "$1"; }

echo
echo "── executed-view pins (the rationale MAY name the trap; executed code may not) ──"
for f in "$MONITOR" "$LANE_SCAN"; do
    name="$(basename "$f")"
    assert_not_contains "$(executed_view "$f")" 'stat -f %m' \
        "$name reads no mtime with the BSD-only 'stat -f %m'"
    assert_contains "$(executed_view "$f")" 'date -r' \
        "$name reads mtime with a form that works on GNU and BSD"
done

echo
echo "── the shipped probe actually dates a real file (no non-numeric value) ──"
FRESH="$T/fresh.log"
printf 'stage: working\n[task-heartbeat] tick\n' > "$FRESH"
probe="$(date -r "$FRESH" +%s 2>/dev/null || echo 0)"
case "${probe:-}" in
    ''|*[!0-9]*) bad "date -r <path> +%s yielded a NON-NUMERIC value on this host: [$probe]";;
    *)           ok "date -r <path> +%s yields a numeric epoch ($probe)";;
esac
if [ "${probe:-0}" -gt 0 ] 2>/dev/null; then ok "the epoch is a real timestamp, not the 0 fallback"; else bad "the epoch fell back to 0 — the probe failed"; fi

echo
echo "── monitor-worker.sh: a FRESH log must read ALIVE (the pre-fix script aborted) ──"
out="$(bash "$MONITOR" "$FRESH" 60 2>&1)"; rc=$?
assert_eq "$rc" 0 "a fresh log exits 0"
assert_contains "$out" 'worker is ALIVE' "a fresh log is reported ALIVE"
assert_not_contains "$out" 'unbound variable' "the arithmetic did not die on a non-numeric operand"

echo
echo "── monitor-worker.sh: an AGED log must read STALE (a probe hardcoding now cannot pass both) ──"
OLD="$T/old.log"
printf 'stage: sleeping\n' > "$OLD"
# Backdate the mtime well past the bound. ⛔ `touch -d <relative>` is GNU-ONLY:
# BSD `touch -d` goes to `stime_darg`, which strptime()s an ABSOLUTE
# `%Y-%m-%d[ T]%H:%M:%S` and errors on anything else (Apple file_cmds
# touch/touch.c:103-106, :345-352; FreeBSD usr.bin/touch/touch.c:305-345). So the
# portable spelling is the ABSOLUTE `-t` form, with each host computing it.
touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)" "$OLD" 2>/dev/null \
  || touch -d '2 hours ago' "$OLD" 2>/dev/null || true
out="$(bash "$MONITOR" "$OLD" 60 2>&1)"; rc=$?
assert_eq "$rc" 1 "an aged log exits 1 (STALE)"
assert_contains "$out" 'appears STALE' "an aged log is reported STALE"

echo
echo "── lane-scan-fallback.sh: the LOCK AGE is computed (behavioural, not textual) ──"
# ⛔ THIS ARM EXISTS BECAUSE THE TEXT PINS ARE NOT ENOUGH (agent-infra#3509 review).
# Dropping the `+%s` from the shipped probe keeps every textual pin green while
# reintroducing the exact `File: unbound variable` abort this branch fixes — measured.
# A FRESH lock makes the script take its fast `already running` branch, so the
# probe runs end-to-end and nothing heavy is reached.
LH="$T/lane-home"
mkdir -p "$LH/.pi/agent/state/lane-scan-fallback.lock"
HOME="$LH" bash "$LANE_SCAN" >/dev/null 2>&1; rc=$?
LLOG="$LH/.pi/agent/state/orchestrator-heartbeat.log"
assert_eq "$rc" 0 "a FRESH lock exits 0 (the age was computable)"
assert_contains "$(cat "$LLOG" 2>/dev/null)" 'already running (lock 0s old)' \
    "the lock age is computed as a real number (0s), not a filesystem block"
assert_not_contains "$(cat "$LLOG" 2>/dev/null)" 'unbound variable' \
    "the lock age arithmetic did not die"

echo
echo "── the two scripts still parse ──"
for f in "$MONITOR" "$LANE_SCAN"; do
    if bash -n "$f" 2>/dev/null; then ok "$(basename "$f") parses"; else bad "$(basename "$f") does not parse"; fi
done

echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  ✅ all checks passed"; exit 0; fi
echo "  ❌ $FAIL check(s) failed"; exit 1
