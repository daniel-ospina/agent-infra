#!/usr/bin/env bash
# test-fixcount-headkey.sh — the fixer cap is TWO bounds: per-REVISION and cumulative per-PR.
#
# ⛔ WHY TWO BOUNDS (agent-infra#1848). One counter cannot express both requirements, and each naive
# fix of one requirement installs the other defect:
#   1. A single PER-PR counter parks a revision that never had an attempt. Measured 2026-10-16: #8370
#      and #8443 carried `fixcount=3` from an old head and were PARKED at their new head with ZERO
#      attempts there (un-parked by hand).
#   2. A PER-REVISION (head-keyed) counter alone is re-armed by the very worker it bounds. The only
#      actor that changes a PR's head in this harness is the FIXER (`fix-one.sh` commits and pushes;
#      the controller books the attempt at SPAWN), so `[ "$NFC" -ge "$MAX_FIX_TRIES" ]` can only fire
#      after N attempts with NO intervening commit — a fixer that keeps pushing never parks, burning
#      a fresh-context review every cycle forever (the failure the terminal park exists to prevent).
# The shipped design: `state/fixcount-<PR>` counts attempts at the CURRENT revision,
# `state/fixcount-head-<PR>` records which revision that is, and `state/fixtotal-<PR>` accumulates
# attempts FOLDED IN from superseded revisions. `fixcap_hit` parks when EITHER bound fires and prints
# WHICH one, with its numbers, so a park is diagnosable. A head change FOLDS rather than discards,
# which is what keeps the cumulative bound terminal against a self-pushing fixer — and it also makes
# `fix-one.sh`'s refund correct without touching it: every arm refunds BEFORE it folds.
#
# HOW THESE CHECKS ARE WRITTEN. The subject is the SHIPPED `orch-loop.sh`: `fixcount_sync()`,
# `fixcap_hit()` and `refund_bailed_fixer()` are EXTRACTED (never copy-pasted) and DRIVEN, and each of
# the THREE cap call sites (CONFLICTING, ai-review-gate, CI-red) has its own bookkeeping prefix
# extracted IN FILE ORDER and evaluated exactly as the controller evaluates it. A check that
# re-implements the rule would pass on the pre-fix tree too, which is the vacuity this suite exists
# to avoid. A missing extraction FAILS its check and installs a STUB, so the rest of the suite still
# RUNS and reports which individual pins are RED instead of aborting at the first one.
#
# ⛔ NOT DOCUMENTED HERE: the `launchctl unload` trap (an unload removes the JOB but leaves the
# PROCESS running, so a reload starts a second controller that can never take the lock while the
# orphan keeps driving the queue). `orch-loop.sh` carries that note beside the lock; prose belongs in
# the README/ARCHITECTURE, which are held by another lane.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP="${FIXCOUNT_LOOP_UNDER_TEST:-$HERE/orch-loop.sh}"
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/O/state"
O="$TMP/O"; LOG="$TMP/O/loop.log"; : > "$LOG"

echo "==> fixer-cap contract test ($HERE) — subject: $LOOP"

# ── 0) extract the shipped functions (a missing extraction is a FAIL, not a skip) ───────────────
{ grep -m1 '^is_num() {' "$LOOP"; grep -m1 '^is_limit() {' "$LOOP"; \
  sed -n '/^refund_bailed_fixer() {/,/^}/p' "$LOOP"; \
  sed -n '/^fixcount_sync() {/,/^}/p' "$LOOP"; \
  sed -n '/^fixcap_hit() {/,/^}/p' "$LOOP"; } > "$TMP/funcs.sh"
grep -q '^fixcount_sync() {' "$TMP/funcs.sh"; ck "fixcount_sync() is extracted from the shipped orch-loop.sh (the fold is present)" $?
grep -q '^fixcap_hit() {' "$TMP/funcs.sh"; ck "fixcap_hit() is extracted from the shipped orch-loop.sh (the two-bound predicate is present)" $?
# shellcheck source=/dev/null
[ -s "$TMP/funcs.sh" ] && . "$TMP/funcs.sh"
# STUBS so a pre-fix tree still RUNS every check below (and fails the ones that assert new
# behaviour) instead of aborting here. A stub cannot make a check pass by accident: the behavioural
# checks assert a COUNTER VALUE and a NAMED BOUND, and `fixcap_hit` printing nothing asserts "no
# bound", which the same check contradicts with the same-head control unless the fold really ran.
command -v is_num >/dev/null 2>&1 || is_num() { case "${1:-}" in ''|*[!0-9]*|0*) return 1 ;; *) return 0 ;; esac; }
command -v is_limit >/dev/null 2>&1 || is_limit() { is_num "${1:-}" && [ "${#1}" -le 9 ]; }
command -v refund_bailed_fixer >/dev/null 2>&1 || refund_bailed_fixer() { return 0; }
command -v fixcount_sync >/dev/null 2>&1 || fixcount_sync() { return 0; }
command -v fixcap_hit >/dev/null 2>&1 || fixcap_hit() { return 0; }

# ── fixtures ───────────────────────────────────────────────────────────────────────────────────
# seed <count|-> <marker-head|-> <folded-total|->   ('-' = file absent)
seed() {
  rm -f "$O"/state/fixcount-* "$O"/state/fixtotal-* "$O"/state/fixbail-* "$O"/state/parked-*
  [ "$1" = "-" ] || printf '%s\n' "$1" > "$O/state/fixcount-231"
  [ "$2" = "-" ] || printf '%s\n' "$2" > "$O/state/fixcount-head-231"
  [ "${3:--}" = "-" ] || printf '%s\n' "$3" > "$O/state/fixtotal-231"
}
# run_arm <extracted-prefix> <head> [bail]  — evaluate the shipped arm prefix exactly as the
# controller does. `bail` creates fix-one.sh's head-keyed bail marker so the shipped refund fires
# before the fold (the shipped order), letting the two bookkeeping paths be driven together.
run_arm() {
  PR=231; HEAD_N="${2:-}"; MAX_FIX_TRIES=3
  NFC=unset; NF=unset; NFC2=unset; FBOUND=unset
  [ "${3:-}" = "bail" ] && : > "$O/state/fixbail-231-$2"
  # shellcheck disable=SC1090
  eval "$(cat "$1")"
  return 0
}
numof() { case "${1:-}" in ''|*[!0-9]*) printf 'unset' ;; *) printf '%s' "$1" ;; esac; }

# ── 1) THE THREE CAP CALL SITES, EACH PINNED ───────────────────────────────────────────────────
# Every arm is EXTRACTED from its own anchors (in file order) and then (a) its bookkeeping prefix is
# evaluated, (b) the guard that consumes FBOUND is pinned by text. Mutation-verified: with the sync
# (or FBOUND) removed, the corresponding checks are RED; pre-fix all three are RED.
extract_arm() { # <start-substr> <end-substr> <outfile>
  awk -v s="$1" -v e="$2" '!b { if (index($0,s)>0) b=1; next } index($0,e)>0 { exit } b { print }' \
    "$LOOP" > "$3"
}
extract_arm 'if [ "${MSTAT:-}" = "CONFLICTING" ]' 'elif claim_live "$PR"' "$TMP/arm-conf.sh"
extract_arm 'if [ "$_gate_hit" = "1" ]' 'elif [ -n "$CI_RED" ]' "$TMP/arm-gate.sh"
extract_arm '# CI-red arm (agent-infra' 'if grep -q python-ci-gate' "$TMP/arm-ci.sh"
grep -E '^ *(refund_bailed_fixer "\$PR"|fixcount_sync "\$PR"|CF=|NFC=|is_num "\$NFC"|FBOUND=)' \
  "$TMP/arm-conf.sh" > "$TMP/prefix-conf.sh"
grep -E '^ *(refund_bailed_fixer "\$PR"|fixcount_sync "\$PR"|FIXN=|is_num "\$NF"|FBOUND=)' \
  "$TMP/arm-gate.sh" > "$TMP/prefix-gate.sh"
grep -E '^ *(refund_bailed_fixer "\$PR"|fixcount_sync "\$PR"|NFC2=|is_num "\$NFC2"|FBOUND=)' \
  "$TMP/arm-ci.sh" > "$TMP/prefix-ci.sh"

# pin_arm <label> <prefix-file> <arm-file> <count-var> <read-pattern> <guard-pattern>
pin_arm() {
  local lbl="$1" pf="$2" af="$3" var="$4" rpat="$5" gpat="$6" l_sync l_read n_sync n_read rc v b
  n_sync="$(grep -c 'fixcount_sync' "$pf" 2>/dev/null || echo 0)"
  n_read="$(grep -cE "$rpat" "$pf" 2>/dev/null || echo 0)"
  l_sync="$(grep -n 'fixcount_sync' "$pf" 2>/dev/null | head -1 | cut -d: -f1)"
  l_read="$(grep -nE "$rpat" "$pf" 2>/dev/null | head -1 | cut -d: -f1)"
  { [ "$n_sync" -ge 1 ] && [ "$n_read" -ge 1 ] && [ -n "$l_sync" ] && [ -n "$l_read" ] \
    && [ "$l_sync" -lt "$l_read" ]; }; rc=$?
  ck "$lbl arm calls fixcount_sync BEFORE reading the count (sync@${l_sync:-none} read@${l_read:-none})" $rc
  grep -qF "$gpat" "$af"; rc=$?
  ck "$lbl arm's decision consults FBOUND ($gpat)" $rc
  # POSITIVE CONTROL for the extraction: a mis-anchored empty prefix would make the ordering check
  # pass on nothing.
  [ "$(wc -l < "$pf" | tr -d ' ')" -ge 3 ]; rc=$?
  ck "$lbl arm's bookkeeping prefix extracts at least 3 statements (extraction proven live)" $rc

  # (i) FAIR NEW REVISION — the measured false park. 3 attempts at AAAA, head is now BBBB: the count
  # is folded away and NO bound fires, so the arm spawns. The same-head control in the next check is
  # what makes "no bound" meaningful rather than "the predicate always says nothing".
  seed 3 AAAA -
  run_arm "$pf" BBBB
  v="$(eval "numof \"\${$var:-unset}\"")"
  fd="$(numof "$(cat "$O/state/fixtotal-231" 2>/dev/null)")"
  { [ "$v" = "0" ] && [ -z "${FBOUND:-}" ] && [ "$fd" = "3" ]; }; rc=$?
  ck "$lbl arm: 3 attempts at AAAA -> new head BBBB gets its own fair attempt (count=$v, bound='${FBOUND:-}', folded=$fd)" $rc
  # (ii) THE CAP STILL BINDS AT THE SAME HEAD — non-vacuity for (i): "always reset" is not a cap.
  seed 3 BBBB -
  run_arm "$pf" BBBB
  v="$(eval "numof \"\${$var:-unset}\"")"
  case "${FBOUND:-}" in *"per-revision bound"*) b=1 ;; *) b=0 ;; esac
  { [ "$v" = "3" ] && [ "$b" = "1" ]; }; rc=$?
  ck "$lbl arm: at the SAME head, 3/3 fires the per-revision bound (count=$v, bound='${FBOUND:-}')" $rc
  # (iii) THE CUMULATIVE BOUND PARKS EVEN WHEN THE PER-REVISION COUNT IS LOW — the self-pushing
  # fixer's case: 5 attempts already folded in from superseded heads + 1 here = 6/6.
  seed 1 FFFF 5
  run_arm "$pf" FFFF
  v="$(eval "numof \"\${$var:-unset}\"")"
  case "${FBOUND:-}" in *"cumulative bound"*) b=1 ;; *) b=0 ;; esac
  { [ "$v" = "1" ] && [ "$b" = "1" ]; }; rc=$?
  ck "$lbl arm: 1 attempt at this head + 5 folded = cumulative bound fires with the count below the per-revision cap (bound='${FBOUND:-}')" $rc
}
pin_arm CONFLICTING "$TMP/prefix-conf.sh" "$TMP/arm-conf.sh" NFC '^ *CF=' '[ -n "$FBOUND" ]'
pin_arm ai-review-gate "$TMP/prefix-gate.sh" "$TMP/arm-gate.sh" NF '^ *FIXN=' '[ -z "$FBOUND" ]'
pin_arm CI-red "$TMP/prefix-ci.sh" "$TMP/arm-ci.sh" NFC2 '^ *NFC2=' '[ -n "$FBOUND" ]'

# The CI-red arm's refund must still precede the fold+read (selftest §15(e) drives the same order).
# Driven with the bail marker: the refund decrements the stale count FIRST, the fold then carries the
# refunded value, so a cross-box refusal can never be charged to the cumulative budget.
seed 3 AAAA -
run_arm "$TMP/prefix-ci.sh" BBBB bail
{ [ "$(numof "${NFC2:-}")" = "0" ] && [ "$(cat "$O/state/fixtotal-231" 2>/dev/null)" = "2" ]; }; rc=$?
ck "CI-red arm: refund BEFORE fold — 3 stale attempts, one bailed -> folded total is 2, not 3" $rc

# ── 2) THE REVIEWER'S FINDING, DRIVEN: a self-pushing fixer is bounded by the CUMULATIVE bound ──
# The controller books an attempt at SPAWN; the fixer commits and pushes; the next cycle folds. Under
# a per-revision counter alone this never parks (the fixer re-arms its own cap), so assert BOTH halves:
# the per-revision bound never fires in this scenario, AND the cumulative bound stops it.
seed - - -
attempts=0; fired=""; perrev=0
for _i in 1 2 3 4 5 6 7; do
  _h="sha${_i}0000000000000000000000000000000000000"
  fixcount_sync 231 "$_h"
  _b="$(fixcap_hit 231 "$_h")"
  case "$_b" in *"per-revision bound"*) perrev=$((perrev+1)) ;; esac
  if [ -n "$_b" ]; then fired="$_b"; break; fi
  _c="$(cat "$O/state/fixcount-231" 2>/dev/null || echo 0)"; is_num "$_c" || _c=0
  echo $((_c + 1)) > "$O/state/fixcount-231"; attempts=$((attempts+1))
done
case "$fired" in *"cumulative bound"*) rc=0 ;; *) rc=1 ;; esac
ck "a self-pushing fixer cannot loop forever: cumulative bound fired after $attempts pushes (bound='$fired')" $rc
[ "$perrev" -eq 0 ] && [ "$attempts" -ge 1 ]; rc=$?
ck "the per-revision bound NEVER fires while the fixer keeps pushing (fires=$perrev over $attempts attempts) — the defect a head-keyed counter alone installs" $rc

# ── 3) fixcount_sync() unit contract: FOLD, do not discard ────────────────────────────────────
seed - - -
# (a) mismatch -> attempt folded into the per-PR total, current counter cleared, marker moved.
printf '3\n' > "$O/state/fixcount-77"; printf 'AAAA\n' > "$O/state/fixcount-head-77"
fixcount_sync 77 BBBB
{ [ ! -f "$O/state/fixcount-77" ] && [ "$(cat "$O/state/fixtotal-77" 2>/dev/null)" = "3" ] \
  && [ "$(cat "$O/state/fixcount-head-77")" = "BBBB" ]; }; rc=$?
ck "fixcount_sync folds a superseded revision's attempts (3 -> fixtotal=3, count cleared, head moved)" $rc
# (b) match -> untouched (no fold, no reset).
printf '2\n' > "$O/state/fixcount-77"
fixcount_sync 77 BBBB
{ [ "$(cat "$O/state/fixcount-77")" = "2" ] && [ "$(cat "$O/state/fixtotal-77")" = "3" ]; }; rc=$?
ck "fixcount_sync leaves an unchanged head's count AND total alone" $rc
# (c) UNKNOWN head -> never folds or resets. `gh pr view` failing must not hand out a free attempt.
fixcount_sync 77 ""
{ [ "$(cat "$O/state/fixcount-77")" = "2" ] && [ "$(cat "$O/state/fixtotal-77")" = "3" ] \
  && [ "$(cat "$O/state/fixcount-head-77")" = "BBBB" ]; }; rc=$?
ck "fixcount_sync does NOT fold or reset on an unreadable (empty) head" $rc
# (d) folds ACCUMULATE across revisions (the cumulative bound's whole input).
printf '2\n' > "$O/state/fixcount-77"
fixcount_sync 77 CCCC
[ "$(cat "$O/state/fixtotal-77")" = "5" ] && [ ! -f "$O/state/fixcount-77" ]; rc=$?
ck "folds ACCUMULATE: 3 at AAAA + 2 at BBBB -> fixtotal=5 at CCCC" $rc
# (e) a leading-zero count is rejected by is_num and never reaches arithmetic (no octal abort).
printf '08\n' > "$O/state/fixcount-77"; printf 'DDDD\n' > "$O/state/fixcount-head-77"
fixcount_sync 77 EEEE
{ [ ! -f "$O/state/fixcount-77" ] && [ "$(cat "$O/state/fixtotal-77")" = "5" ]; }; rc=$?
ck "fixcount_sync discards a leading-zero count without evaluating it (no octal abort, no fold)" $rc

# ── 4) fixcap_hit() NAMES the bound(s) that fired, with numbers ───────────────────────────────
seed 3 HEADAAA -
b="$(fixcap_hit 231 HEADAAA)"
case "$b" in "per-revision bound: 3/3 attempts at head=HEADAAA") rc=0 ;; *) rc=1 ;; esac
ck "fixcap_hit names the per-revision bound with its numbers ('$b')" $rc
seed 1 HEADBBB 5
b="$(fixcap_hit 231 HEADBBB)"
case "$b" in *"cumulative bound: 6/6 attempts across revisions"*) rc=0 ;; *) rc=1 ;; esac
ck "fixcap_hit names the cumulative bound with its numbers ('$b')" $rc
seed 3 HEADCCC 9
b="$(fixcap_hit 231 HEADCCC)"
case "$b" in *"per-revision bound"*"cumulative bound"*) rc=0 ;; *) rc=1 ;; esac
ck "both bounds exhausted is reported as BOTH (a park stays diagnosable) ('$b')" $rc
seed 2 HEADDDD 3
b="$(fixcap_hit 231 HEADDDD)"
{ [ -z "$b" ] && [ "$(cat "$O/state/fixcount-231")" = "2" ]; }; rc=$?
ck "fixcap_hit reports no bound below both limits, and does not mutate state" $rc

# ── 5) GROWTH IS BOUNDED: N pushes own 3 per-PR files, never one counter per head ────────────
seed - - -
for _h in aaaa bbbb cccc dddd eeee; do
  printf '1\n' > "$O/state/fixcount-77"; fixcount_sync 77 "$_h"
done
nfiles="$(ls "$O/state" 2>/dev/null | grep -c '^fixcount\|^fixtotal' || true)"
{ [ "$nfiles" -le 3 ] && ! ls "$O/state" 2>/dev/null | grep -q '^fixcount-77-' \
  && [ -f "$O/state/fixcount-head-77" ] && [ -f "$O/state/fixtotal-77" ]; }; rc=$?
[ "$rc" -eq 0 ] || echo "      state after 5 pushes: $(ls "$O/state" 2>/dev/null | grep 'fixcount\|fixtotal' | tr '\n' ' ')"
ck "5 head transitions leave 3 per-PR files (count+head+folded), never one per head — got $nfiles" $rc

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
