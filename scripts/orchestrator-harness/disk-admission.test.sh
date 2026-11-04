#!/usr/bin/env bash
# disk-admission.test.sh — the regression contract for the PRE-START disk admission seam
# (agent-infra#3395).
#
# THE DEFECT. On cell-3 at 98 % used / 3.5 GB free, a dispatch did not refuse:
#
#   git worktree add -> fatal: cannot create directory at 'tools/ts': No space left on device
#
# The harness's own disk gate existed and was CORRECT — it just ran inside `run_agent`, i.e. after
# `wt_provision` had already materialised the checkout, so on a full volume it was never reached. And
# the dispatcher that produced the failure (an ad-hoc pusher) printed `df=` in a log line and
# asserted nothing, because there was nothing for it to call. A `df` in a log is a REPORT; a report is
# not a gate.
#
# WHAT IS PINNED HERE, and why each one is a distinct failure mode:
#   1. BELOW the requirement -> the NAMED refusal (`REFUSED-DISK(free=…, need=…, box=…)`), rc 77, and
#      NO WORKTREE AND NO BRANCH (the refusal is free: nothing was attempted, so nothing to roll back);
#   2. ABOVE it -> a real worktree. Without this arm every refusal below would pass on a gate that
#      refuses unconditionally — the inert-gate mirror of the same defect;
#   3. the message CARRIES THE THREE NUMBERS. A gate that refuses without stating what it measured is
#      indistinguishable from a bug, and this fleet has read a CORRECT refusal as a false positive
#      more than once;
#   4. an UNREADABLE `df` is `REFUSED-UNKNOWN`, not "assume enough" — the PRE-START posture, where
#      refusing costs nothing (the live-dispatch arm's documented fail-open is a different seam and is
#      pinned by spawn-gate.test.sh, unchanged);
#   5. the VERB (`spawn-gate.sh --disk-admit`) answers the same, so a dispatcher that is not this
#      tree's shell code has ONE command to call instead of re-implementing `df`.
#
# ⛔ EVERY READING HERE IS STUBBED, and that is the point of the suite: an arm that used THIS host's
# free space would be green on a roomy box and red on a full one, i.e. a test of the host rather than
# of the gate (the defect `spawn-gate.test.sh` records for its own early `df` stub, review round 6).
# The stub is a POSIX `df -Pk`-shaped fixture whose 4th column is set by `FAKE_DF_AVAIL_MB`.
#
# Run:  bash scripts/orchestrator-harness/disk-admission.test.sh
set -uo pipefail

bash -n "$0" || { echo "FATAL: the suite itself does not parse (see above)" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WTL="$HERE/wt-lifecycle.sh"
GATE="$HERE/spawn-gate.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
ck()   { local msg="$1" rc="$2"; if [ "$rc" -eq 0 ]; then ok "$msg"; else bad "$msg"; fi; }

REAL_GIT="$(command -v git)" || { echo "FATAL: git is required" >&2; exit 2; }
T="$(mktemp -d "${TMPDIR:-/tmp}/disk-admission-test.XXXXXX")" || { echo "FATAL: no temp dir" >&2; exit 2; }
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

[ -f "$WTL" ]  || { echo "FATAL: no wt-lifecycle.sh beside this suite" >&2; exit 2; }
[ -f "$GATE" ] || { echo "FATAL: no spawn-gate.sh beside this suite" >&2; exit 2; }

# ⛔ HERMETIC AGAINST THE AMBIENT OVERRIDES TOO (review round 2, P2 — MEASURED). The arms below assert
# the SHIPPED requirement (need_mb=8144), so an operator's `DISK_LANE_SELF_MB=1024` in the environment —
# the very remedy the refusal text recommends for a cheaper box — turned this suite into 25 passed /
# 12 failed. Cleared here and passed explicitly only by the arms that mean to vary them.
export DISK_LANE_SELF_MB= DISK_LANE_RESERVE_MB= DISK_LANE_TREE_MB=

# ── the `df` stubs ───────────────────────────────────────────────────────────────────────────────
# TWO separate directories, never one PATH prefix: the fixture must be able to say "readable, N MB"
# and "UNREADABLE" without the arms sharing state.
mkdir -p "$T/bin-ok" "$T/bin-dead"
printf '#!/bin/sh\navail=$(( ${FAKE_DF_AVAIL_MB:-0} * 1024 ))\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "fake 9999999 0 $avail 1%% /"\n' > "$T/bin-ok/df"
printf '#!/bin/sh\nexit 1\n' > "$T/bin-dead/df"
chmod +x "$T/bin-ok/df" "$T/bin-dead/df"

# ── a repo whose worktree creation we can watch ──────────────────────────────────────────────────
mk_repo() {
    local d="$T/repo"
    "$REAL_GIT" init -q --bare "$T/origin.git"
    "$REAL_GIT" init -q -b main "$d"
    "$REAL_GIT" -C "$d" config user.email t@t
    "$REAL_GIT" -C "$d" config user.name t
    printf 'base\n' > "$d/base.txt"
    "$REAL_GIT" -C "$d" add -A
    "$REAL_GIT" -C "$d" commit -q -m base
    "$REAL_GIT" -C "$d" remote add origin "$T/origin.git"
    "$REAL_GIT" -C "$d" push -q origin main
    "$REAL_GIT" -C "$d" fetch -q origin
}
mk_repo
REPO="$T/repo"

# provision <bin-dir> <avail-mb> <name> [extra env assignments…]
# Drives the SHIPPED `wt_provision` in a subshell with the stub on PATH, then reports what the
# lifecycle actually did: the rc, WT_RESULT, whether a directory exists, whether a ref exists.
# ⛔ rc 4 IS THE SEAM'S OWN CODE for a disk refusal (nothing was ATTEMPTED); the CALLERS map it to the
# harness's 77/AGENT_DISK_REFUSED so the capacity ledger and the operator see the disk gate. Both are
# asserted below: 4 here, 77 in the verb arm — one verdict, two surfaces.
provision() {
    local bindir="$1" avail="$2" name="$3"; shift 3
    ( cd "$REPO" && env PATH="$bindir:$PATH" FAKE_DF_AVAIL_MB="$avail" DISK_MIN_FREE_MB=500 \
        DISK_BOX=cell-test "$@" bash -c '
          . "$1" || exit 99
          wt_provision "$2" ".worktrees/$3" "feat/$3" origin/main
          printf "rc=%s\nWT_RESULT=%s\n" "$?" "$WT_RESULT"
        ' _ "$WTL" "$REPO" "$name" )
}

ref_exists() { "$REAL_GIT" -C "$REPO" rev-parse --verify -q "refs/heads/$1" >/dev/null 2>&1; }

echo "── disk-admission.test.sh (agent-infra#3395) ──────────────────────────────────────────"

# ── A) BELOW the requirement: REFUSED-DISK, with the numbers, and NOTHING created ───────────────
# 3.5 GB free (3,584 MB) against the delivered default need of 8,144 MB — the exact reading the
# #3395 record quotes from cell-3.
echo
echo "── A) below the requirement: the named refusal, and NO worktree ──"
OUT="$(provision "$T/bin-ok" 3584 a-tm)"
case "$OUT" in *'rc=4'*) rc=0 ;; *) rc=1 ;; esac
ck "a lane that does not fit is REFUSED by the seam (rc 4) ($(printf '%s' "$OUT" | head -1))" $rc

case "$OUT" in *'REFUSED-DISK('*) rc=0 ;; *) rc=1 ;; esac
ck "the refusal is NAMED 'REFUSED-DISK(…)' — not a generic add failure, not the load gate" $rc

{ case "$OUT" in *'free=3.5GB'*) ;; *) false ;; esac \
  && case "$OUT" in *'need=8.0GB'*) ;; *) false ;; esac \
  && case "$OUT" in *'box=cell-test'*) ;; *) false ;; esac; }; rc=$?
ck "the message CARRIES all three terms — free=3.5GB, need=8.0GB, box=cell-test (the arithmetic is checkable from the line alone)" $rc

# ⛔ AND THE EXACT MEBIBYTES TOO (review round 1, P2 — MEASURED). One decimal of GiB cannot separate
# `free = need` from `free = need - 1` (8,143 and 8,144 both render `8.0GB`), so the token carries the
# raw figures: a boundary refusal that printed `free=8.0GB, need=8.0GB` would read as a FALSE POSITIVE
# on a gate that was right.
{ case "$OUT" in *'free_mb=3584'*) ;; *) false ;; esac \
  && case "$OUT" in *'need_mb=8144'*) ;; *) false ;; esac; }; rc=$?
ck "…and the raw mebibytes, so a refusal at the boundary cannot read 'free == need'" $rc

[ -d "$REPO/.worktrees/a-tm" ] && rc=1 || rc=0
ck "NO worktree directory was created — the refusal happens BEFORE \`git worktree add\`" $rc

ref_exists feat/a-tm && rc=1 || rc=0
ck "NO branch was created either (a refused add leaves no 0-ahead residue — the #2033 class)" $rc

# The refusal must also NOT be reachable from the LIVE arm's wording: a reader greps one token.
case "$OUT" in *'DISK-NOHEADROOM'*) rc=1 ;; *) rc=0 ;; esac
ck "…and it is distinguishable from the live arm's DISK-NOHEADROOM verdict" $rc

# ── B) ABOVE the requirement: a real worktree (the non-vacuity control) ──────────────────────────
echo
echo "── B) above the requirement: the same call ADMITS and creates ──"
OUT="$(provision "$T/bin-ok" 11264 b-tm)"
case "$OUT" in *'rc=0'*) rc=0 ;; *) rc=1 ;; esac
ck "a lane that fits is ADMITTED with rc 0 ($(printf '%s' "$OUT" | head -1))" $rc
[ -d "$REPO/.worktrees/b-tm" ] && rc=0 || rc=1
ck "…and the worktree EXISTS at the requested path" $rc
ref_exists feat/b-tm && rc=0 || rc=1
ck "…and its branch exists" $rc
case "$OUT" in *'REFUSED'*) rc=1 ;; *) rc=0 ;; esac
ck "…and it prints no refusal line (a gate that also shouts on admission is noise, not a gate)" $rc

# ── C) EXACTLY at the requirement is ADMITTED (the boundary is inclusive, as `disk_headroom_ok` is) ─
echo
echo "── C) the boundary: free == need is ADMITTED, free-1 is REFUSED ──"
# The delivered need with DISK_MIN_FREE_MB=500 is 6144 + 2000 = 8144 MB.
OUT="$(provision "$T/bin-ok" 8144 c-tm)"
case "$OUT" in *'rc=0'*) rc=0 ;; *) rc=1 ;; esac
ck "free == need (8,144 MB) is ADMITTED ($(printf '%s' "$OUT" | head -1))" $rc
OUT="$(provision "$T/bin-ok" 8143 c2-tm)"
case "$OUT" in *'rc=4'*) rc=0 ;; *) rc=1 ;; esac
ck "one MB below it is REFUSED — the comparison is not off by a whole lane" $rc
# The boundary refusal must NAME the difference rather than rounding it away (review round 1, P2).
case "$OUT" in *'free_mb=8143'*'need_mb=8144'*) rc=0 ;; *) rc=1 ;; esac
ck "…and it prints free_mb=8143 vs need_mb=8144, so the one-MB gap is visible instead of both rounding to 8.0GB" $rc
[ -d "$REPO/.worktrees/c2-tm" ] && rc=1 || rc=0
ck "…and that refusal created nothing" $rc

# ── D) UNREADABLE `df`: REFUSED-UNKNOWN, nothing created (the PRE-START fail-closed arm) ────────
echo
echo "── D) unreadable probe: REFUSED-UNKNOWN, never 'assume enough' ──"
OUT="$(provision "$T/bin-dead" 0 d-tm)"
case "$OUT" in *'rc=4'*) rc=0 ;; *) rc=1 ;; esac
ck "an unreadable \`df\` is REFUSED by the seam (rc 4; the verb and the callers map it to 77), not admitted ($(printf '%s' "$OUT" | head -1))" $rc
case "$OUT" in *'REFUSED-UNKNOWN'*) rc=0 ;; *) rc=1 ;; esac
ck "…and it is named REFUSED-UNKNOWN, so it is not read as 'the volume is full'" $rc
case "$OUT" in *'free=?'*) rc=0 ;; *) rc=1 ;; esac
ck "…and it says the measurement is MISSING (free=?) rather than inventing a number" $rc
[ -d "$REPO/.worktrees/d-tm" ] && rc=1 || rc=0
ck "…and nothing was created" $rc

# ── E) THE VERB: a dispatcher that is not this tree's shell code calls the same predicate ────────
echo
echo "── E) the verb: spawn-gate.sh --disk-admit <target> ──"
VOUT="$( env PATH="$T/bin-ok:$PATH" FAKE_DF_AVAIL_MB=3584 DISK_BOX=cell-3 DISK_MIN_FREE_MB=500 \
         bash "$GATE" --disk-admit "$REPO/.worktrees/verb-tm" )"; vrc=$?
[ "$vrc" = 77 ]; rc=$?
ck "the verb exits 77 below the requirement (the same code the shell seam returns)" $rc
case "$VOUT" in *'REFUSED-DISK(free=3.5GB, need=8.0GB, box=cell-3'*) rc=0 ;; *) rc=1 ;; esac
ck "…and prints the EXACT token #3395 specifies: REFUSED-DISK(free=3.5GB, need=8.0GB, box=cell-3…)" $rc
[ -d "$REPO/.worktrees/verb-tm" ] && rc=1 || rc=0
ck "…having created nothing (the verb answers, it does not dispatch)" $rc

VOUT="$( env PATH="$T/bin-ok:$PATH" FAKE_DF_AVAIL_MB=11264 DISK_BOX=cell-1 DISK_MIN_FREE_MB=500 \
         DISK_ADMIT_VERBOSE=1 bash "$GATE" --disk-admit "$REPO" )"; vrc=$?
[ "$vrc" = 0 ]; rc=$?
ck "…and exits 0 above it" $rc
case "$VOUT" in *'ADMITTED'*) rc=0 ;; *) rc=1 ;; esac
ck "…saying ADMITTED (so a dispatcher's log states what was measured, not just that it proceeded)" $rc

# ── F) THE SINGLE PREDICATE: the seam obeys the SAME overrides the live arm documents ───────────
echo
echo "── F) one predicate: the documented seams move BOTH arms ──"
# A box whose lanes are MEASURED cheaper lowers the requirement deliberately; the seam must honour it
# rather than carrying a private constant. 1,500 MB free is refused at the default and admitted once
# the operator states the smaller worst case.
OUT="$(provision "$T/bin-ok" 1500 f-tm)"
case "$OUT" in *'rc=4'*) rc=0 ;; *) rc=1 ;; esac
ck "1,500 MB free is refused at the default requirement" $rc
OUT="$(provision "$T/bin-ok" 1500 f2-tm DISK_LANE_SELF_MB=1024 DISK_LANE_RESERVE_MB=256)"
case "$OUT" in *'rc=0'*) rc=0 ;; *) rc=1 ;; esac
ck "…and ADMITTED once DISK_LANE_SELF_MB/DISK_LANE_RESERVE_MB state a smaller worst case (1,280 MB)" $rc

# The need the seam computes is the FILE's own function, not a second copy: assert the two agree.
NEED="$( env DISK_MIN_FREE_MB=500 bash -c '. "$1"; disk_worktree_need' _ "$GATE" )"
[ "$NEED" = 8144 ]; rc=$?
ck "disk_worktree_need derives 8,144 MB from the shipped defaults (6,144 MB worst case + 2,000 MB reserve) — got '$NEED'" $rc
NEED2="$( env DISK_MIN_FREE_MB=500 DISK_LANE_SELF_MB=2048 DISK_LANE_RESERVE_MB=512 bash -c '. "$1"; disk_worktree_need' _ "$GATE" )"
[ "$NEED2" = 2560 ]; rc=$?
ck "…and honours the overrides (2,048 + 512 = 2,560) — got '$NEED2'" $rc

# ⛔ THE SEAM'S REQUIREMENT IS PINNED TO THE LIVE ARM'S OWN FUNCTION, NOT TO ITSELF (review round 2,
# P2). `disk_lane_costs` on a PYTHON fixture is the reference: if someone raises the live arm's SELF
# and not the named constant, this arm reds instead of the drift admitting a lane one step late.
mkdir -p "$T/pytarget" && : > "$T/pytarget/uv.lock"
LIVE_NEED="$( env DISK_MIN_FREE_MB=500 bash -c '. "$1"; set -- $(disk_lane_costs "$2"); disk_lane_need "$1" "$2" "$3"' _ "$GATE" "$T/pytarget" )"
[ "$NEED" = "$LIVE_NEED" ]; rc=$?
ck "the seam's requirement equals the live arm's disk_lane_need on a python target (seam=$NEED, live=$LIVE_NEED)" $rc

# ⛔ AN ALL-DIGIT READING BEYOND THE COMPARISON'S RANGE MUST REFUSE (review round 2, P2). The first
# version compared `free -lt need`, so an ERRORED comparison (rc 2) read as "not below" and ADMITTED.
OVR="$( env DISK_MIN_FREE_MB=500 bash -c '
        . "$1"; disk_free_mb_target() { printf "%s\n" 99999999999999999999; }; disk_admit "$2"; printf "rc=%s\n" "$?"
      ' _ "$GATE" "$REPO" 2>/dev/null )"
case "$OVR" in *'rc=77'*) rc=0 ;; *) rc=1 ;; esac
ck "an over-range all-digit reading REFUSES (an errored comparison is not an admission) — $(printf '%s' "$OVR" | tail -1)" $rc

# ── F2) A GARBLED OVERRIDE STILL PRODUCES A NAMED REFUSAL (review round 1, P2) ───────────────
# The message used to re-derive the reserve from the RAW env value, so `DISK_LANE_SELF_MB=12x`-
# style spellings (an operator writing `6G` or `6144MB` is the realistic case) made the REFUSAL
# ITSELF die inside `$(( ))`: rc 1, an empty line, and a verb exiting 1 outside 0/77/64.
echo
echo "── F2) a garbled override is TOLERATED by the message, not fatal to it ──"
OUT="$(provision "$T/bin-ok" 3584 g-tm DISK_LANE_SELF_MB=12x)"
case "$OUT" in *'rc=4'*) rc=0 ;; *) rc=1 ;; esac
ck "DISK_LANE_SELF_MB=12x still REFUSES at the seam (rc 4), not a crashed comparison ($(printf '%s' "$OUT" | head -1))" $rc
case "$OUT" in *'REFUSED-DISK('*) rc=0 ;; *) rc=1 ;; esac
ck "…with a NAMED line (the fallback would say the measurement is MISSING, which is not what happened)" $rc
GVOUT="$( env PATH="$T/bin-ok:$PATH" FAKE_DF_AVAIL_MB=3584 DISK_BOX=cell-3 DISK_MIN_FREE_MB=500 \
          DISK_LANE_SELF_MB=6G bash "$GATE" --disk-admit "$REPO" )"; gvrc=$?
{ [ "$gvrc" = 77 ] && case "$GVOUT" in *'need_mb=8144'*) true ;; *) false ;; esac; }; rc=$?
ck "…and the verb still honours its own contract (77, need_mb=8144 for a garbled '6G'), not 1 (rc=$gvrc)" $rc

# ── G) A MISSING GATE IS A REFUSAL, NOT A SKIP (version skew, the #2033 rule applied to disk) ───
echo
echo "── G) a box whose \$O is missing spawn-gate.sh refuses rather than creating blind ──"
mkdir -p "$T/skew"
cp "$WTL" "$T/skew/wt-lifecycle.sh"
SOUT="$( cd "$REPO" && env PATH="$T/bin-ok:$PATH" FAKE_DF_AVAIL_MB=11264 bash -c '
        . "$1" || exit 99
        wt_disk_admit "$2" "$2/.worktrees/skew-tm"
        printf "rc=%s\nWT_RESULT=%s\n" "$?" "$WT_RESULT"
      ' _ "$T/skew/wt-lifecycle.sh" "$REPO" 2>&1 )"
case "$SOUT" in *'rc=1'*) rc=0 ;; *) rc=1 ;; esac
ck "wt_disk_admit REFUSES when the predicate is not loadable ($(printf '%s' "$SOUT" | head -1))" $rc
case "$SOUT" in *'REFUSED-UNKNOWN'*) rc=0 ;; *) rc=1 ;; esac
ck "…and names it REFUSED-UNKNOWN, so a skew is diagnosed instead of looking like a full disk" $rc

echo
# ── H) THE CALLERS KEEP THE MAPPING (review round 1, P3: rc 4 was pinned at the seam only) ─────
# These are SOURCE-CENSUS arms, not drives: driving dispatch-merge/fix-one/adopt-fix needs the $O + argv
# rigs their own suites build. What they catch is the regression that matters — someone restoring the
# old `if [ "$_wt_rc" != 0 ]` and folding a disk refusal back into a generic add failure, or forgetting
# the 77 mapping so the operator is told to wait for a load remedy that cannot arrive.
echo "── H) every wt_provision caller keeps the rc-4 arm and its documented mapping ──"
for pair in "fix-one.sh:AGENT_DISK_REFUSED" "adopt-fix.sh:exit 77" "dispatch-merge.sh:break"; do
  f="${pair%%:*}"; want="${pair##*:}"
  script="$HERE/$f"
  if [ ! -f "$script" ]; then bad "H) $f is missing — the census cannot be vacuous"; continue; fi
  # ⛔ SCOPED TO THE rc-4 ARM'S OWN BODY (review round 2, P2 — MEASURED). The first version grepped the
  # WHOLE file, and both tokens already appear pre-change elsewhere (`AGENT_DISK_REFUSED` at fix-one.sh's
  # live-arm readers, `break` in dispatch-merge's loop), so it could not fail for the reason it claims.
  arm=""
  if grep -qE '^[[:space:]]*4\)' "$script"; then
    # ⛔ TERMINATE ON THE ARM'S OWN TERMINATOR, WHICH IS `break ;;` IN dispatch-merge (review round 3,
    # P2 — MEASURED). Requiring a bare `;;` on its own line ran the capture to the END OF FILE (139
    # lines instead of 27), so `grep -qF break` was satisfiable by any later `break`: changing the arm's
    # `break ;;` to `continue ;;` still printed the pass. Any line ENDING in `;;` ends the arm.
    arm="$(awk '/^[[:space:]]*4\)[[:space:]]*#?/{f=1} f{print} f&&/;;[[:space:]]*$/{exit}' "$script")"
  else
    arm="$(awk '/(^|[[:space:]])(if|elif)[[:space:]]+\[.*_wt_rc[" ]*=[[:space:]]*["]?4/{f=1} f{print}' "$script" | awk '{print} /^[[:space:]]*fi[[:space:]]*$/{exit}')"
  fi
  if [ -z "$arm" ]; then
    bad "H) $f has no rc-4 arm — a disk refusal from wt_provision would be read as an add failure"
    continue
  fi
  if grep -qF -- "$want" <<<"$arm"; then ok "H) $f keeps the rc-4 arm and names $want inside it"; else bad "H) $f's rc-4 arm does not reach '$want' (arm: $(printf '%s' "$arm" | head -1))"; fi
done

# The seam returns 4, and 4 must not collide with a code the callers already use for something else.
case "$(grep -n '4 = REFUSED-DISK' "$WTL" | head -1)" in '')
  bad "H) wt-lifecycle.sh no longer documents rc 4 — the contract and the code have drifted" ;;
*)
  ok "H) wt-lifecycle.sh documents rc 4 = REFUSED-DISK in its own contract table" ;;
esac

# ⛔ NON-VACUITY PROOF FOR THE CENSUS (review round 3, P2 — the round-2 version was measured vacuous).
# A source census that cannot fail for its own reason is a decoration. This mutates a COPY twice —
# `break ;;` → `continue ;;` (the batch no longer stops, exactly the regression the arm exists for)
# while ADDING an unrelated `break` later in the file — and requires the extraction to see the arm
# WITHOUT the token. The real tree is untouched.
_mut="$T/mut-dispatch-merge.sh"
sed -e 's/^\([[:space:]]*\)break ;;$/\1continue ;;/' "$HERE/dispatch-merge.sh" > "$_mut" 2>/dev/null
printf '\nbreak\n' >> "$_mut"
_marm="$(awk '/^[[:space:]]*4\)[[:space:]]*#?/{f=1} f{print} f&&/;;[[:space:]]*$/{exit}' "$_mut")"
if printf '%s' "$_marm" | grep -q 'SPAWNED_IDS\|CHAIN_IDS'; then
  if grep -qF 'break' <<<"$_marm"; then
    bad "H) the census is VACUOUS: a mutated dispatch-merge (break→continue, plus a stray break later) still passes"
  else
    ok "H) the census is non-vacuous: on the mutated copy it reads the arm and the token IS absent"
  fi
else
  bad "H) the mutation harness could not extract a mutated arm — fix the harness, do not trust the pass above"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
