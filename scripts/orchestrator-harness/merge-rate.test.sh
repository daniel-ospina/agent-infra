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
# NB: this was named `say()` until #2910. It is NOT the print helper — it invokes the script under
# test — so it gets a name that says so instead of inheriting the rename for a role it never had.
merge_rate() { O="$T/o" bash "$SCRIPT" "$@"; }
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
# 6c THE PROSE-AFTER-DELIVERABLE CASE (landing review F2): the lane ends `status: PR_OPENED` and then
#    mentions MERGED in prose. The whole-transcript read counted this as MERGED — the flattering
#    direction the header promises it cannot take, and the new brief's vocabulary makes it likelier.
cat > "$T/o/logs/lane-108.log" <<'EOF'
**Issue #108** — status: **PR_OPENED**
- Branch: `feat/108` · PR: https://github.com/o/r/pull/92
The harness chain will report MERGED when CI settles; nothing here is merged yet.
EOF
# 6d the reverse: a real MERGED deliverable followed by prose that mentions PR_OPENED must stay MERGED
printf '**Issue #109** — status: **MERGED** (sha feedface)\nMERGED via the rail; the earlier PR_OPENED line is superseded.\n' > "$T/o/logs/lane-109.log"
# 6e ⛔ A BLOCKED LANE NAMING A PR WITH A MERGED MARKER PRESENT IS NOT UPGRADED (landing review P2). The
#    attribution arm matched `'OTHER BLOCKED'*` as well, so this lane was counted MERGED_VIA_MARKER:
#    numerator up, `handed_off` down, denominator unchanged — the headline rate ROSE when the change
#    failed, contrary to the header's own promise. Its own conclusion is the authority about itself.
printf '**Issue #110** — status: **BLOCKED_ATTESTATION** (green; no signed review record at the head)\n- PR: https://github.com/o/r/pull/77\n' > "$T/o/logs/lane-110.log"
# 6f ⛔ A MID-LOG MENTION OF ANOTHER LANE'S PR IS NOT THIS LANE'S PR (landing review F2). The attribution
#    grepped the WHOLE transcript, so this lane — which ended PR_OPENED with its OWN PR (#93, unmerged) —
#    was credited with #78's merge because a progress line mentioned it. The read is scoped to the lane's
#    own deliverable block now, so the foreign mention is not evidence about this lane.
cat > "$T/o/logs/lane-111.log" <<'EOF'
[lane 111] waiting on the rail; blocked on PR: https://github.com/o/r/pull/78 (inherited from another lane)
**Issue #111** — status: **PR_OPENED**
- Branch: `feat/111` · PR: https://github.com/o/r/pull/93
EOF
# 7 the merge loop's own CHAIN log — carries the rail's "MERGED via the rail" line and must NOT be
#   counted as a lane (pre-fix it added both a lane and a MERGED: a 1-lane population read 2/2 = 100%)
printf 'rail: MERGED via the rail (stub)\n' > "$T/o/logs/lane-merge-9.log"
# machine-written truth (post-change): ONE merged verdict, written twice (PR-keyed + issue-keyed)
printf 'MERGED abc123\n' > "$T/o/state/lanemerge-9.verdict"
printf 'MERGED abc123\n' > "$T/o/state/lanemerge-issue-77.verdict"
printf 'abc123\n' > "$T/o/state/merged-9.done"
# …and the two markers the new fixtures name: one for the BLOCKED lane (110 → #77) and one for the PR a
# PR_OPENED lane only MENTIONED mid-transcript (111 → #78). Neither may move the numerator.
printf 'cafe01\n' > "$T/o/state/merged-77.done"
printf 'cafe02\n' > "$T/o/state/merged-78.done"

echo "==> merge-rate.sh offline suite"
J="$(merge_rate --json)"
ck "lanes read = 11 (every lane log on disk is in the population)" \
   $([ "$(field "$J" lanes)" = 11 ] && echo 0 || echo 1)
ck "PR_OPENED = 3 (lanes 101 + 108 — prose after the deliverable does NOT promote it — and 111, whose mid-log mention of ANOTHER lane's PR does not make it merged)" \
   $([ "$(field "$J" pr_opened)" = 3 ] && echo 0 || echo 1)
ck "MERGED = 4 (102; 103 whose LAST status wins over its earlier PR_OPENED; 107 attested only by state/merged-9.done; 109 whose prose PR_OPENED does not demote a MERGED deliverable)" \
   $([ "$(field "$J" merged)" = 4 ] && echo 0 || echo 1)
ck "merged_from_marker = 1 (the detached-chain attribution is REPORTED as an inference, not hidden)" \
   $([ "$(field "$J" merged_from_marker)" = 1 ] && echo 0 || echo 1)
ck "handed_off = 2 (BLOCKED_ATTESTATION lanes 106 and 110 — a PR that did not merge is IN the denominator, and a BLOCKED lane naming a merged PR is NOT upgraded)" \
   $([ "$(field "$J" handed_off)" = 2 ] && echo 0 || echo 1)
ck "other_end = 1 (ALREADY_FIXED only — no PR to merge, reported rather than hidden, never in the rate)" \
   $([ "$(field "$J" other_end)" = 1 ] && echo 0 || echo 1)
ck "unknown = 1 (a lane with no status line is COUNTED, not dropped)" \
   $([ "$(field "$J" unknown)" = 1 ] && echo 0 || echo 1)
LM_RATE="$(field "$J" merge_rate)"
ck "merge rate = ${LM_RATE} (4 merged / (4 merged + 3 opened + 2 handed off); a BLOCKED_* hand-off CANNOT be excluded, else the post-change population reads 100%, and neither a BLOCKED lane's PR nor a mid-log mention can be credited)" \
   $([ "$LM_RATE" = "44.4%" ] && echo 0 || echo 1)
ck "the machine-written cross-checks are DEDUPED (one outcome written twice = 1 verdict, not 2) and every marker on disk is REPORTED (3: merged-9/77/78 — the two that must not be credited are still visible)" \
   $([ "$(field "$J" verdicts)" = 1 ] && [ "$(field "$J" verdict_merged)" = 1 ] && [ "$(field "$J" merged_markers)" = 3 ] && echo 0 || echo 1)
ck "the merge loop's own chain log is NOT a lane (lane-merge-*.log excluded: lanes still 11, merged still 4)" \
   $([ "$(field "$J" lanes)" = 11 ] && [ "$(field "$J" merged)" = 4 ] && echo 0 || echo 1)

# ── the TEXT path on an EMPTY population must exit 0 (landing-review P2, measured) ───────────────
# The last statement used to be `[ -n "$details" ] && { … }`, which FAILS when the population is empty —
# so a fresh cell, or any --hours window with no lanes in it, printed the correct "n/a" report and then
# exited 1, contradicting the header's "0 always (a report is not a gate)". The suite's exit-0 case ran
# against a 9-lane $O, so the one input that exposed it was never given to the text path.
mkdir -p "$T/empty2/logs" "$T/empty2/state"
OUT_E="$(O="$T/empty2" bash "$SCRIPT" 2>&1)"; RC_E=$?
ck "the TEXT report on an EMPTY population exits 0 (a measurement is not a gate) and says n/a" \
   $([ "$RC_E" = 0 ] && grep -q "MERGE RATE            n/a" <<<"$OUT_E" && echo 0 || echo 1)
mkdir -p "$T/stale/logs" "$T/stale/state"
printf '**Issue #9** — status: **MERGED**\n' > "$T/stale/logs/lane-9.log"
touch -t 202001010000 "$T/stale/logs/lane-9.log" 2>/dev/null
OUT_S="$(O="$T/stale" bash "$SCRIPT" --hours 2 2>&1)"; RC_S=$?
ck "…and so does a --hours window that filters every lane out (exit 0, n/a — not a failure)" \
   $([ "$RC_S" = 0 ] && grep -q "MERGE RATE            n/a" <<<"$OUT_S" && echo 0 || echo 1)
ck "…and the header renders the window ONCE (\"last 2h\", never the mangled \"last 2h2\")" \
   $(grep -q "merge rate last 2h (" <<<"$OUT_S" && ! grep -q "2h2" <<<"$OUT_S" && echo 0 || echo 1)

# ── the empty population is n/a, NOT 0% and NOT 100% ─────────────────────────────────────────────
mkdir -p "$T/empty/logs" "$T/empty/state"
JE="$(O="$T/empty" bash "$SCRIPT" --json)"
ck "an EMPTY population prints n/a (a rate over nothing is not a number, least of all '0%')" \
   $([ "$(field "$JE" merge_rate)" = "n/a" ] && [ "$(field "$JE" lanes)" = 0 ] && echo 0 || echo 1)

# ── the window filter, driven by real mtimes ────────────────────────────────────────────────────
if touch -t 202001010000 "$T/o/logs/lane-101.log" 2>/dev/null; then
  JW="$(merge_rate --hours 2 --json)"
  ck "--hours excludes an old lane log from the population (and from every count)" \
     $([ "$(field "$JW" lanes)" = 10 ] && [ "$(field "$JW" pr_opened)" = 2 ] && echo 0 || echo 1)
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
merge_rate >/dev/null 2>&1
ck "the text report exits 0 (a measurement is not a gate)" $([ $? = 0 ] && echo 0 || echo 1)
ck "the text report states the defect line and the n/a-safe rate field" \
   $(rep="$(merge_rate)"; grep -q "ended at PR_OPENED" <<<"$rep" && grep -q "MERGE RATE" <<<"$rep" && echo 0 || echo 1)

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mALL %d merge-rate checks passed\033[0m\n' "$pass"
else
  printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"
fi
[ "$fail" -eq 0 ]
