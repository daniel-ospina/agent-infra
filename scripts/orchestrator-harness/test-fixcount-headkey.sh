#!/usr/bin/env bash
# test-fixcount-headkey.sh — the fixer attempt budget re-arms for a NEW revision, but never for the
# revision the controller's own fixer produced.
#
# HOW THESE CHECKS ARE WRITTEN. The subject is the SHIPPED `orch-loop.sh`: `fixcount_sync()` and
# `refund_bailed_fixer()` are EXTRACTED from it (never copy-pasted) and DRIVEN; the three cap arms
# (CONFLICTING, ai-review-gate, CI-red) are extracted from the arm itself, IN FILE ORDER, so a
# re-implementation cannot pass this suite. The extraction guard is a HARD FAIL: on the pre-fix tree
# there is no `fixcount_sync` to extract, so this suite exits non-zero instead of reporting a
# vacuous pass.
#
# THE DEFECT THIS GUARDS — TWO HALVES, AND BOTH ARE ASSERTED.
#
# (1) A BARE COUNTER IS NOT A CAP (measured 2026-10-16). Every other per-PR marker re-arms on a
# push: `state/needsfix-<PR>-<head>` is head-keyed and `state/parked-<PR>` stores the head inside the
# file, so the sweep skips the park check for a new revision. `state/fixcount-<PR>` was the ONE
# marker that did not — a bare counter — so a PR that reached `MAX_FIX_TRIES` at revision A was
# PARKED the moment revision B appeared, before B had had a single fix attempt. Two PRs (#8370,
# #8443) were in exactly that state and were un-parked by hand by resetting `fixcount` to 0. The
# remedy is the `parked`-keyed re-arm: the count for a head we GAVE UP ON does not poison the next.
#
# (2) A RESET ON *ANY* HEAD CHANGE IS AN INERT CAP (round-2 review P1). Pushing is what a fixer DOES
# (`fix-one.sh`: "pushes, then re-runs the merge chain"). If every observed head change cleared the
# count, the actor being capped would supply the push that refills its own budget — the count would
# reset at every new revision, the cap would never fire, and `parked-<PR>` would be unreachable on
# the normal path. The remedy is that the re-arm is keyed on the PARK: a head that was NOT parked is
# a revision our own fixer advanced and it stays on the SAME budget. Both halves are driven below,
# and each is the other's non-vacuity control.
#
# THE HEAD IS NOT IN THE COUNT'S FILENAME. `state/fixcount-<PR>` stays a BARE INTEGER on purpose:
# `fix-one.sh` reads and writes it on its load-refusal refund path, which runs at process exit where
# its own `gh pr view` head may have failed — a head it cannot name is a head it cannot put in a
# path. Keeping the filename bare keeps every increment site and the refund UNCHANGED. Growth is
# bounded by construction: both files are per-PR, never per-head, so a PR pushed N times owns two
# files, not N counters.
#
# ⛔ NOT DOCUMENTED HERE: the `launchctl unload` trap (an unload removes the JOB but leaves the
# PROCESS running, so a reload starts a second controller that can never take the lock while the
# orphan keeps driving the queue). `orch-loop.sh` is not the right home for prose and neither is a
# test; it belongs in README §6 and ARCHITECTURE, which are held by another lane. The note placed
# beside the lock in `orch-loop.sh` is the in-repo pointer.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP="$HERE/orch-loop.sh"
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/O/state"
O="$TMP/O"; LOG="$TMP/O/loop.log"; : > "$LOG"

echo "==> fixcount head-key contract test ($HERE)"

# ── 0) extract the shipped functions (a missing extraction is a FAIL, not a skip) ──────────────
# `fixcount_sync` is the whole fix; on the pre-fix tree this file does not contain it and the
# sed below yields nothing — so the guard fails this suite LOUDLY and non-zero rather than letting
# every behavioural check below pass against an empty definition file.
{ grep -m1 '^is_num() {' "$LOOP"; sed -n '/^refund_bailed_fixer() {/,/^}/p' "$LOOP"; sed -n '/^fixcount_sync() {/,/^}/p' "$LOOP"; } > "$TMP/funcs.sh"
if [ -s "$TMP/funcs.sh" ] && grep -q '^fixcount_sync() {' "$TMP/funcs.sh"; then rc=0; else
  rc=1; echo "      extracted: $(grep -c '^[a-z_]*() {' "$TMP/funcs.sh" 2>/dev/null || echo 0) function(s) — fixcount_sync is missing from $LOOP"
fi
ck "fixcount_sync() is extracted from the shipped orch-loop.sh (the fix is present)" $rc
if [ "$rc" -ne 0 ]; then
  echo; echo "================ RESULT: $PASS passed, $FAIL failed ================"; exit 1
fi
# shellcheck source=/dev/null
. "$TMP/funcs.sh"

# ── 1) ALL THREE cap arms call the sync BEFORE they read the counter ─────────────────────────────
# The suite once pinned only the CI-red arm; deleting `fixcount_sync` from the CONFLICTING or
# ai-review arm was GREEN (round-2 review Issue: 2 of 3 call sites unprotected). Each arm is
# extracted from the arm itself, and the SYNC line's number must be below the READ line's.
extract_arm() { # extract_arm <start-awk-test> <end-awk-test> <out>
  awk -v s="$1" -v e="$2" 'index($0,s)>0{b=1} b{print} b&&index($0,e)>0{exit}' "$LOOP" > "$3"
}
# CONFLICTING arm: MSTAT check .. the arm's `continue`.
awk 'index($0,"if [ \"${MSTAT:-}\" = \"CONFLICTING\" ]; then")>0{b=1}
     b{print} b&&index($0,"continue")>0{exit}' "$LOOP" > "$TMP/arm-conflicting.sh"
# ai-review-gate arm: _gate_hit branch .. the `elif [ -n "$CI_RED" ]`.
extract_arm 'if [ "$_gate_hit" = "1" ]; then' 'elif [ -n "$CI_RED" ]' "$TMP/arm-ai.sh"
# CI-red arm: the arm banner up to (but not including) `if grep -q python-ci-gate`. The region's
# last line is the `fi` that closes the outer `elif [ -n "$CI_RED" ]` chain, so it is wrapped in
# `if true; then` to keep the EVAL'd text syntactically balanced (this arm is EVAL'd, not grepped).
awk 'BEGIN{print "if true; then"}
     index($0,"# CI-red arm (agent-infra")>0{b=1}
     b&&index($0,"if grep -q python-ci-gate")>0{exit}
     b{print}' "$LOOP" > "$TMP/arm-ci.sh"
arm_order() { # arm_order <label> <region> <read-regex>
  local label="$1" reg="$2" rre="$3" ns nr ls lr
  ns="$(grep -c 'fixcount_sync "\$PR"' "$reg" 2>/dev/null | tr -d ' ')"
  nr="$(grep -cE "$rre" "$reg" 2>/dev/null | tr -d ' ')"
  ls="$(grep -n 'fixcount_sync "\$PR"' "$reg" 2>/dev/null | head -1 | cut -d: -f1)"
  lr="$(grep -nE "$rre" "$reg" 2>/dev/null | head -1 | cut -d: -f1)"
  { [ "${ns:-0}" -ge 1 ] && [ "${nr:-0}" -ge 1 ] && [ -n "$ls" ] && [ -n "$lr" ] && [ "$ls" -lt "$lr" ]; }; local r=$?
  ck "$label: fixcount_sync BEFORE the count read (sync@${ls:-?} read@${lr:-?})" $r
}
arm_order "CONFLICTING arm" "$TMP/arm-conflicting.sh" 'NFC="\$\(cat'
arm_order "ai-review-gate arm" "$TMP/arm-ai.sh" 'NF="\$\(cat'
arm_order "CI-red arm" "$TMP/arm-ci.sh" 'NFC2="\$\(cat'
# POSITIVE CONTROL for the extraction itself: each arm region must be non-trivial. An empty or
# mis-anchored region would make the ordering check pass on nothing.
for _a in conflicting ai ci; do
  n="$(wc -l < "$TMP/arm-$_a.sh" | tr -d ' ')"
  [ "${n:-0}" -ge 5 ]; rc=$?
  ck "the $_a arm region extracts at least 5 statements (extraction proven live, got $n)" $rc
done

# ── 2) the TWO HALVES, DRIVEN through the shipped CI-red arm ─────────────────────────────────────
# fixture <count> <marker-head> <HEAD_N> [bail] [parked-head]
# `bail` creates fix-one.sh's head-keyed bail marker so the refund fires before the read.
# `parked-head` writes `parked-231`, i.e. we had GAVE UP on that head (the re-arm trigger).
drive_arm() { # drive_arm <count|-> <marker-head|-> <HEAD_N> [bail] [parked-head]
  rm -f "$O"/state/fixcount-* "$O"/state/fixbail-* "$O"/state/parked-*
  if [ -n "$1" ]; then printf '%s\n' "$1" > "$O/state/fixcount-231"; fi
  if [ -n "$2" ]; then printf '%s\n' "$2" > "$O/state/fixcount-head-231"; fi
  [ "${4:-}" = "bail" ] && : > "$O/state/fixbail-231-$3"
  if [ -n "${5:-}" ]; then printf '%s\n' "$5" > "$O/state/parked-231"; fi
  PR=231; HEAD_N="$3"; MAX_FIX_TRIES=3; NFC2=unset; V="ci-red-fixture"
  # shellcheck disable=SC1090
  # stderr is dropped: the arm calls worker helpers (claim_live/sess/tmux/can_spawn) that are not
  # defined in this rig, and their "command not found" noise is not a test result.
  eval "$(cat "$TMP/arm-ci.sh")" 2>/dev/null
  printf '%s' "${NFC2:-unset}"
}

# HALF (1), THE MEASURED CASE: 3 attempts booked at revision AAAA, AAAA was PARKED, the PR has been
# pushed to BBBB. The stale 3 must not park BBBB: NFC2 must read 0 so the arm SPAWNS.
got="$(drive_arm 3 AAAA BBBB no AAAA)"
{ [ "$got" = "0" ] && [ "$got" -lt 3 ]; }; rc=$?
ck "PARKED head + new push re-arms: 3 at AAAA -> NFC2=$got (want 0) at BBBB, so the arm SPAWNS" $rc

# ... and a bail AT THE CURRENT HEAD: refund_bailed_fixer decrements 3 -> 2 and drops the park,
# and the sync must be a no-op on an unchanged head (it must NOT clear 2). The two bookkeeping
# paths must not compound into a wrong count.
got="$(drive_arm 3 BBBB BBBB bail)"
[ "$got" = "2" ]; rc=$?
ck "a bailed fixer at the current head refunds 3 -> NFC2=$got (want 2), the sync does not zero it" $rc

# HALF (2), THE INERT-CAP CASE: the head moved but it was NOT parked — our own fixer advanced it.
# The budget must be KEPT, or the fixer refills the cap it is being held to.
got="$(drive_arm 1 AAAA BBBB)"
{ [ "$got" = "1" ] && [ "$got" -ge 1 ]; }; rc=$?
ck "the fixer's OWN push does NOT re-arm: 1 at AAAA -> NFC2=$got (want 1) at BBBB, budget kept" $rc

# NON-VACUITY for half (1): without this check "always 0" would pass the re-arm line above while
# deleting MAX_FIX_TRIES entirely.
got="$(drive_arm 3 BBBB BBBB)"
{ [ "$got" = "3" ] && [ "$got" -ge 3 ]; }; rc=$?
ck "the cap still binds at the SAME head: 3 attempts at BBBB -> NFC2=$got (want 3), so the arm PARKS" $rc

# ... and a count at an unchanged head is not zeroed by a re-read.
got="$(drive_arm 1 BBBB BBBB)"
[ "$got" = "1" ]; rc=$?
ck "the count survives an unchanged head: 1 attempt at BBBB -> NFC2=$got (want 1)" $rc

# ── 3) THE CAP FIRES ACROSS A RUN OF FIXER PUSHES (the P1 class, end to end) ─────────────────────
# The dominant path the old implementation could not terminate: every cycle the fixer SUCCEEDS at
# pushing and the head advances, but the PR never clears. Drive the shipped sync with the shipped
# arm's own bookkeeping (read, cap test, `echo $((n+1))`); the cap must fire by MAX_FIX_TRIES+1.
rm -f "$O"/state/fixcount-* "$O"/state/parked-*
park_at=""
for _i in 1 2 3 4 5 6; do
  _h="push$_i"
  fixcount_sync 231 "$_h"
  _n="$(cat "$O/state/fixcount-231" 2>/dev/null || echo 0)"; is_num "$_n" || _n=0
  if [ "$_n" -ge 3 ]; then park_at="$_i"; break; fi
  echo $((_n + 1)) > "$O/state/fixcount-231"
done
[ "$park_at" = "4" ]; rc=$?
ck "MAX_FIX_TRIES bounds a run of fixer pushes: cap at cycle ${park_at:-never} (want 4) — a reset on ANY push never fires" $rc

# ── 4) fixcount_sync() unit contract ───────────────────────────────────────────────────────────
rm -f "$O"/state/fixcount-* "$O"/state/parked-*
# (a) FIRST observation (no marker): the count cannot be attributed to this head -> cleared.
printf '3\n' > "$O/state/fixcount-77"
fixcount_sync 77 BBBB
{ [ "$(cat "$O/state/fixcount-77" 2>/dev/null || echo 0)" = "0" ] && [ "$(cat "$O/state/fixcount-head-77")" = "BBBB" ]; }; rc=$?
ck "first observation (no head marker) clears the count and records the head" $rc
# (b) previous head PARKED -> re-arm.
printf '3\n' > "$O/state/fixcount-77"; printf 'AAAA\n' > "$O/state/fixcount-head-77"; printf 'AAAA\n' > "$O/state/parked-77"
fixcount_sync 77 BBBB
{ [ "$(cat "$O/state/fixcount-77" 2>/dev/null || echo 0)" = "0" ] && [ "$(cat "$O/state/fixcount-head-77")" = "BBBB" ]; }; rc=$?
ck "a PARKED previous head re-arms the budget (the #8370/#8443 case)" $rc
# (c) previous head NOT parked -> the count is KEPT (the fixer's own push).
printf '2\n' > "$O/state/fixcount-77"; printf 'CCCC\n' > "$O/state/fixcount-head-77"; rm -f "$O/state/parked-77"
fixcount_sync 77 DDDD
{ [ "$(cat "$O/state/fixcount-77")" = "2" ] && [ "$(cat "$O/state/fixcount-head-77")" = "DDDD" ]; }; rc=$?
ck "a non-parked previous head KEEPS the count and moves the marker (budget not refilled)" $rc
# (d) match -> untouched.
fixcount_sync 77 DDDD
[ "$(cat "$O/state/fixcount-77")" = "2" ]; rc=$?
ck "fixcount_sync leaves an unchanged head's counter alone" $rc
# (e) UNKNOWN head -> never resets. `gh pr view` failing must not hand out a free attempt.
printf '2\n' > "$O/state/fixcount-77"
fixcount_sync 77 ""
{ [ "$(cat "$O/state/fixcount-77")" = "2" ] && [ "$(cat "$O/state/fixcount-head-77")" = "DDDD" ]; }; rc=$?
ck "fixcount_sync does NOT reset on an unreadable (empty) head — 2 attempts kept" $rc
# (f) a leading-zero counter is not arithmetic'd by the sync (it is removed, never evaluated).
# A re-arm must be in play for the clear to happen: first observation (no head marker).
rm -f "$O/state/fixcount-head-77" "$O/state/parked-77"
printf '08\n' > "$O/state/fixcount-77"
fixcount_sync 77 EEEE
[ ! -f "$O/state/fixcount-77" ]; rc=$?
ck "fixcount_sync clears a leading-zero counter without evaluating it (no octal abort)" $rc
# (g) THE MARKER WRITE MUST SUCCEED BEFORE THE COUNT IS CLEARED (round-2 review P2). A directory in
# the marker's place makes the redirect fail for any uid (EISDIR), so the write cannot be recorded;
# the counter must survive, or every later call clears again and the cap is silently disabled.
printf '2\n' > "$O/state/fixcount-77"; rm -f "$O/state/fixcount-head-77"; mkdir "$O/state/fixcount-head-77"
fixcount_sync 77 FFFF
[ "$(cat "$O/state/fixcount-77" 2>/dev/null || echo 0)" = "2" ]; rc=$?
[ "$rc" -eq 0 ] || echo "      counter after an unrecordable head: '$(cat "$O/state/fixcount-77" 2>/dev/null)'"
ck "an UNRECORDABLE head leaves the count intact (a failed marker write cannot disable the cap)" $rc
rmdir "$O/state/fixcount-head-77"

# ── 5) GROWTH IS BOUNDED: N pushes own 2 files, never N counters ────────────────────────────────
# The alternative fix — `fixcount-<PR>-<head>` — needs a prune pass or `state/` gains one file per
# sha. This fix stores the head BESIDE the bare counter, so the bound is structural: assert it,
# because "bounded growth" is a claim in the PR body and an unchecked claim is not one.
rm -f "$O"/state/fixcount-*
for _h in aaaa bbbb cccc dddd eeee; do
  printf '1\n' > "$O/state/fixcount-77"; fixcount_sync 77 "$_h"
done
nfiles="$(ls "$O/state" 2>/dev/null | grep -c '^fixcount' | tr -d ' ')"
{ [ "${nfiles:-0}" -le 2 ] && ! ls "$O/state" 2>/dev/null | grep -q '^fixcount-77-'; }; rc=$?
[ "$rc" -eq 0 ] || echo "      state after 5 pushes: $(ls "$O/state" | grep '^fixcount' | tr '\n' ' ')"
ck "5 head transitions leave at most 2 files (count+marker), never one per head — got $nfiles" $rc

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
