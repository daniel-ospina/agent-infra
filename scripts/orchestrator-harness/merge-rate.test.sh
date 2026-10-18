#!/usr/bin/env bash
# merge-rate.test.sh — offline suite for merge-rate.sh.
#
# HERMETIC: throwaway $O with fixture lane logs and state files. No network, no gh, no tmux.
# The point of each case is the CLASSIFICATION and the honest arithmetic, because the whole value of
# the number is that it cannot be quietly wrong in the flattering direction.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/merge-rate.sh"
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
[ -s "$SCRIPT" ] || { bad "merge-rate.sh is missing or empty"; exit 1; }
mkdir -p "$T/o/logs" "$T/o/state"
say() { O="$T/o" bash "$SCRIPT" "$@"; }
field() { # field <json> <key>
  printf '%s' "$1" | sed -nE "s/.*\"$2\":(\"[^\"]*\"|null|[0-9]+).*/\1/p" | tr -d '"'
}

# ── fixtures: every spelling the harness has emitted, plus the hard cases ───────────────────────
# 1 PR_OPENED (the fleet's dominant end state, verbatim from a real lane log)
cat > "$T/o/logs/lane-101.log" <<'EOF'
[timeout] agent pid=1 wall_limit=2400s elapsed=100s rc=0
**Issue #101** — status: **PR_OPENED**
- Branch: `feat/101` · PR: https://github.com/o/r/pull/91 (open, not merged)
EOF
# 2 MERGED, written by a lane that stayed for the merge phase
printf '**Issue #102** — status: **MERGED** (sha deadbeef)\n' > "$T/o/logs/lane-102.log"
# 3 a RE-DISPATCHED issue: an early PR_OPENED followed by MERGED — ONE lane, ended MERGED
printf '**Issue #103** — status: **PR_OPENED**\n' > "$T/o/logs/lane-103.log"
printf '**Issue #103** — status: **MERGED** (sha cafebabe)\n' >> "$T/o/logs/lane-103.log"
# 4 ALREADY_FIXED (a good no-PR outcome; must not be counted as an opened PR)
printf '**STATUS: ALREADY_FIXED** (no PR, no code change)\n' > "$T/o/logs/lane-104.log"
# 5 no status line at all → UNKNOWN, counted and printed, never folded into the rate
printf 'some work happened but no deliverable line was printed\n' > "$T/o/logs/lane-105.log"
# 6 the new lane-end token for a lane that cannot supply the attestation
printf 'Issue #106 — status: BLOCKED_ATTESTATION (green, needs a fresh-context review record)\n' > "$T/o/logs/lane-106.log"
# 6b THE LANE IS GONE WHEN THE DETACHED CHAIN MERGES (E6). lane-merge.sh launches the chain detached
#    on purpose, so the lane's wall clock can end while the chain merges minutes later; the lane's log
#    then ends at PR_OPENED and only `state/merged-<PR>.done` attests the merge. Counting only the
#    lane's own token would UNDER-count exactly the case the change exists to produce.
printf '**Issue #107** — status: **PR_OPENED**\n- PR: https://github.com/o/r/pull/9\n' > "$T/o/logs/lane-107.log"
# 7 the merge loop's own CHAIN log — carries the rail's "MERGED via the rail" line and must NOT be
#   counted as a lane (pre-fix it added both a lane and a MERGED: a 1-lane population read 2/2 = 100%)
printf 'rail: MERGED via the rail (stub)\n' > "$T/o/logs/lane-merge-9.log"
# machine-written truth (post-change): ONE merged verdict, written twice (PR-keyed + issue-keyed)
printf 'MERGED abc123\n' > "$T/o/state/lanemerge-9.verdict"
printf 'MERGED abc123\n' > "$T/o/state/lanemerge-issue-77.verdict"
printf 'abc123\n' > "$T/o/state/merged-9.done"

echo "==> merge-rate.sh offline suite"
J="$(say --json)"
ck "lanes read = 7 (every lane log on disk is in the population)" \
   $([ "$(field "$J" lanes)" = 7 ] && echo 0 || echo 1)
ck "PR_OPENED = 1 (only lane 101 — ALREADY_FIXED and BLOCKED_* are NOT opened PRs)" \
   $([ "$(field "$J" pr_opened)" = 1 ] && echo 0 || echo 1)
ck "MERGED = 3 (102; 103 whose LAST status wins over its earlier PR_OPENED; 107 attested only by state/merged-9.done)" \
   $([ "$(field "$J" merged)" = 3 ] && echo 0 || echo 1)
ck "merged_from_marker = 1 (the detached-chain attribution is REPORTED as an inference, not hidden)" \
   $([ "$(field "$J" merged_from_marker)" = 1 ] && echo 0 || echo 1)
ck "other_end = 2 (ALREADY_FIXED + BLOCKED_ATTESTATION, reported rather than hidden)" \
   $([ "$(field "$J" other_end)" = 2 ] && echo 0 || echo 1)
ck "unknown = 1 (a lane with no status line is COUNTED, not dropped)" \
   $([ "$(field "$J" unknown)" = 1 ] && echo 0 || echo 1)
ck "merge rate = 75.0% (3 merged / 4 with a definite end state; UNKNOWN is in neither side)" \
   $([ "$(field "$J" merge_rate)" = "75.0%" ] && echo 0 || echo 1)
ck "the machine-written cross-checks are DEDUPED (one outcome written twice = 1 verdict, not 2)" \
   $([ "$(field "$J" verdicts)" = 1 ] && [ "$(field "$J" verdict_merged)" = 1 ] && [ "$(field "$J" merged_markers)" = 1 ] && echo 0 || echo 1)
ck "the merge loop's own chain log is NOT a lane (lane-merge-*.log excluded: lanes still 7, merged still 3)" \
   $([ "$(field "$J" lanes)" = 7 ] && [ "$(field "$J" merged)" = 3 ] && echo 0 || echo 1)

# ── the empty population is n/a, NOT 0% and NOT 100% ─────────────────────────────────────────────
mkdir -p "$T/empty/logs" "$T/empty/state"
JE="$(O="$T/empty" bash "$SCRIPT" --json)"
ck "an EMPTY population prints n/a (a rate over nothing is not a number, least of all '0%')" \
   $([ "$(field "$JE" merge_rate)" = "n/a" ] && [ "$(field "$JE" lanes)" = 0 ] && echo 0 || echo 1)

# ── the window filter, driven by real mtimes ────────────────────────────────────────────────────
if touch -t 202001010000 "$T/o/logs/lane-101.log" 2>/dev/null; then
  JW="$(say --hours 2 --json)"
  ck "--hours excludes an old lane log from the population (and from every count)" \
     $([ "$(field "$JW" lanes)" = 6 ] && [ "$(field "$JW" pr_opened)" = 0 ] && echo 0 || echo 1)
else
  bad "could not set an old mtime (touch -t) — the window case did not run"
fi

# ── a malformed window argument is refused, not silently ignored ────────────────────────────────
O="$T/o" bash "$SCRIPT" --hours banana >/dev/null 2>&1
ck "a non-numeric --hours is refused with exit 2 (never a silently-unfiltered report)" \
   $([ $? = 2 ] && echo 0 || echo 1)

# ── an out-of-range --hours is refused (it feeds arithmetic and would overflow the window) ────────
O="$T/o" bash "$SCRIPT" --hours 200000000000000000 >/dev/null 2>&1
ck "an out-of-range --hours is refused with exit 2 (no silently-overflowed all-time window)" \
   $([ $? = 2 ] && echo 0 || echo 1)

# ── the report is a REPORT: it must not fail the build on a real population ─────────────────────
say >/dev/null 2>&1
ck "the text report exits 0 (a measurement is not a gate)" $([ $? = 0 ] && echo 0 || echo 1)
ck "the text report states the defect line and the n/a-safe rate field" \
   $(say | grep -q "ended at PR_OPENED" && say | grep -q "MERGE RATE" && echo 0 || echo 1)

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mALL %d merge-rate checks passed\033[0m\n' "$pass"
else
  printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"
fi
[ "$fail" -eq 0 ]
