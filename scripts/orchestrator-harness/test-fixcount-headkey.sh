#!/usr/bin/env bash
# test-fixcount-headkey.sh — the fixer attempt counter counts attempts at a REVISION.
#
# HOW THESE CHECKS ARE WRITTEN. The subject is the SHIPPED `orch-loop.sh`: `fixcount_sync()` and
# `refund_bailed_fixer()` are EXTRACTED from it (never copy-pasted) and DRIVEN, and the CI-red arm's
# own statements are extracted IN FILE ORDER and evaluated exactly as the controller evaluates them.
# A check that re-implements the rule passes on the tree before the fix too, which is the vacuity
# this suite exists to avoid. The extraction guard is a HARD FAIL: on the pre-fix tree there is no
# `fixcount_sync` to extract, so this suite exits non-zero instead of reporting a vacuous pass.
#
# THE DEFECT (measured 2026-10-16 on a live box). Every other per-PR marker re-arms on a push:
# `state/needsfix-<PR>-<head>` is head-keyed, and `state/parked-<PR>` stores the head inside the
# file, so the sweep deliberately skips the park check for a new revision. `state/fixcount-<PR>` was
# the ONE marker that did not — a bare counter — so a PR that reached `MAX_FIX_TRIES` at revision A
# was PARKED the moment revision B appeared: `[ "$NF" -ge "$MAX_FIX_TRIES" ]` was true before B had
# had a single fix attempt. Two PRs (#8370, #8443) were in exactly that state and were un-parked by
# hand by resetting `fixcount` to 0.
#
# THE FIX, AND WHY THE HEAD IS NOT IN THE FILENAME. The head is stored in
# `state/fixcount-head-<PR>` and compared at the three READ sites, which all hold `HEAD_N`.
# `state/fixcount-<PR>` stays a BARE INTEGER on purpose: `fix-one.sh` reads and writes it on its
# load-refusal refund path, which runs at process exit where its own `gh pr view` head may have
# failed — a head it cannot name is a head it cannot put in a path. Keeping the filename bare keeps
# every increment site and the refund UNCHANGED. Growth is bounded by construction: both files are
# per-PR, never per-head, so a PR pushed N times owns two files, not N counters.
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
# sed below yields nothing — so `need` fails this suite LOUDLY and non-zero rather than letting
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

# ── 1) the shipped CI-red arm calls the sync BEFORE it reads the counter ────────────────────────
# Extracted from the arm itself, in FILE ORDER — the same region `selftest.sh` §15(e) extracts, so
# the two suites cannot drift. `NFC2`'s read must come after the reset or the reset is too late.
awk 'index($0,"# CI-red arm (agent-infra")>0{b=1}
     b&&index($0,"if grep -q python-ci-gate")>0{b=0}
     b' "$LOOP" \
  | grep -E '^ *(fixcount_sync "\$PR"|refund_bailed_fixer "\$PR"|NFC2=|is_num "\$NFC2")' > "$TMP/ci-arm.sh"
n_sync="$(grep -c 'fixcount_sync' "$TMP/ci-arm.sh" 2>/dev/null || echo 0)"
n_read="$(grep -c '^ *NFC2=' "$TMP/ci-arm.sh" 2>/dev/null || echo 0)"
line_sync="$(grep -n 'fixcount_sync' "$TMP/ci-arm.sh" 2>/dev/null | head -1 | cut -d: -f1)"
line_read="$(grep -n '^ *NFC2=' "$TMP/ci-arm.sh" 2>/dev/null | head -1 | cut -d: -f1)"
{ [ "$n_sync" -ge 1 ] && [ "$n_read" -ge 1 ] && [ -n "$line_sync" ] && [ -n "$line_read" ] && [ "$line_sync" -lt "$line_read" ]; }; rc=$?
ck "the shipped CI-red arm calls fixcount_sync BEFORE reading NFC2 (sync@$line_sync read@$line_read)" $rc
# POSITIVE CONTROL for the extraction itself: the arm region must be non-trivial. An empty or
# mis-anchored region would make the ordering check pass on nothing.
[ "$(wc -l < "$TMP/ci-arm.sh" | tr -d ' ')" -ge 3 ]; rc=$?
ck "the CI-red arm region extracts at least 3 statements (extraction proven live)" $rc

# ── 2) the DEFECT, DRIVEN through the shipped arm ──────────────────────────────────────────────
# fixture <count> <marker-head> [bail] ; then eval the arm with HEAD_N as given.
# `bail` creates fix-one.sh's head-keyed bail marker, which makes the refund fire before the read —
# the shipped order — so the two bookkeeping paths are driven together, not in isolation.
drive_arm() { # drive_arm <count|-> <marker-head|-> <HEAD_N> [bail]
  rm -f "$O"/state/fixcount-* "$O"/state/fixbail-*
  if [ -n "$1" ]; then printf '%s\n' "$1" > "$O/state/fixcount-231"; fi
  if [ -n "$2" ]; then printf '%s\n' "$2" > "$O/state/fixcount-head-231"; fi
  [ "${4:-}" = "bail" ] && : > "$O/state/fixbail-231-$3"
  PR=231; HEAD_N="$3"; MAX_FIX_TRIES=3; NFC2=unset
  # shellcheck disable=SC1090
  eval "$(cat "$TMP/ci-arm.sh")"
  printf '%s' "${NFC2:-unset}"
}

# THE MEASURED CASE: 3 attempts booked at revision A, the PR has been pushed to revision B.
# Pre-fix NFC2 reads the stale 3 and the arm PARKS B before it is ever tried.
got="$(drive_arm 3 AAAA BBBB)"
{ [ "$got" = "0" ] && [ "$got" -lt 3 ]; }; rc=$?
ck "new head re-arms the budget: 3 attempts at AAAA -> NFC2=$got (want 0) at BBBB, so the arm SPAWNS not PARKS" $rc

# ... and the same case WITH a bailed fixer: the refund decrements the stale counter first and the
# sync then discards it, so the two paths cannot compound into a wrong count.
got="$(drive_arm 3 AAAA BBBB bail)"
[ "$got" = "0" ]; rc=$?
ck "new head + a bailed fixer still reads 0 (refund and reset do not compound) — got $got" $rc

# NON-VACUITY: the cap must still bind at the SAME head. Without this check "always 0" would pass
# the line above while deleting MAX_FIX_TRIES entirely.
got="$(drive_arm 3 BBBB BBBB)"
{ [ "$got" = "3" ] && [ "$got" -ge 3 ]; }; rc=$?
ck "the cap still binds at the SAME head: 3 attempts at BBBB -> NFC2=$got (want 3), so the arm PARKS" $rc

# ... and a genuinely fresh revision that has already had one attempt is not zeroed by a re-read.
got="$(drive_arm 1 BBBB BBBB)"
[ "$got" = "1" ]; rc=$?
ck "the count survives an unchanged head: 1 attempt at BBBB -> NFC2=$got (want 1)" $rc

# ── 3) fixcount_sync() unit contract ───────────────────────────────────────────────────────────
rm -f "$O"/state/fixcount-*
# (a) mismatch -> counter cleared, marker moved. The counter is REMOVED, not rewritten, so no
# arithmetic touches its digits (the leading-zero class every other site has to guard).
printf '3\n' > "$O/state/fixcount-77"; printf 'AAAA\n' > "$O/state/fixcount-head-77"
fixcount_sync 77 BBBB
{ [ "$(cat "$O/state/fixcount-77" 2>/dev/null || echo 0)" = "0" ] && [ "$(cat "$O/state/fixcount-head-77")" = "BBBB" ]; }; rc=$?
ck "fixcount_sync clears the counter and records the new head on a mismatch" $rc
# (b) match -> untouched.
printf '2\n' > "$O/state/fixcount-77"
fixcount_sync 77 BBBB
[ "$(cat "$O/state/fixcount-77")" = "2" ]; rc=$?
ck "fixcount_sync leaves an unchanged head's counter alone" $rc
# (c) UNKNOWN head -> never resets. `gh pr view` failing must not hand out a free attempt.
printf '2\n' > "$O/state/fixcount-77"
fixcount_sync 77 ""
{ [ "$(cat "$O/state/fixcount-77")" = "2" ] && [ "$(cat "$O/state/fixcount-head-77")" = "BBBB" ]; }; rc=$?
ck "fixcount_sync does NOT reset on an unreadable (empty) head — 2 attempts kept" $rc
# (d) a leading-zero counter is not arithmetic'd by the sync (it is removed, never evaluated).
printf '08\n' > "$O/state/fixcount-77"
fixcount_sync 77 CCCC
[ ! -f "$O/state/fixcount-77" ]; rc=$?
ck "fixcount_sync clears a leading-zero counter without evaluating it (no octal abort)" $rc

# ── 4) GROWTH IS BOUNDED: N pushes own 2 files, never N counters ────────────────────────────────
# The alternative fix — `fixcount-<PR>-<head>` — needs a prune pass or `state/` gains one file per
# sha. This fix stores the head BESIDE the bare counter, so the bound is structural: assert it,
# because "bounded growth" is a claim in the PR body and an unchecked claim is not one.
rm -f "$O"/state/fixcount-*
for _h in aaaa bbbb cccc dddd eeee; do
  printf '1\n' > "$O/state/fixcount-77"; fixcount_sync 77 "$_h"
done
nfiles="$(ls "$O/state" 2>/dev/null | grep -c '^fixcount' || true)"
{ [ "$nfiles" -le 2 ] && ! ls "$O/state" 2>/dev/null | grep -q '^fixcount-77-'; }; rc=$?
[ "$rc" -eq 0 ] || echo "      state after 5 pushes: $(ls "$O/state" | grep '^fixcount' | tr '\n' ' ')"
ck "5 head transitions leave at most 2 files (count+marker), never one per head — got $nfiles" $rc

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
