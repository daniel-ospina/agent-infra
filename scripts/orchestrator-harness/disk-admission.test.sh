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
#   1. BELOW the requirement -> the NAMED refusal (`REFUSED-DISK(free=…, need=…, box=…)`), rc **4** at
#      the SEAM (the callers map it to 77; see the ⛔ note above `ck`), and
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
mkdir -p "$T/bin-ok" "$T/bin-dead" "$T/bin-select"
printf '#!/bin/sh\navail=$(( ${FAKE_DF_AVAIL_MB:-0} * 1024 ))\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "fake 9999999 0 $avail 1%% /"\n' > "$T/bin-ok/df"
printf '#!/bin/sh\nexit 1\n' > "$T/bin-dead/df"
# ⛔ A PATH-SELECTIVE STUB (review round 4, P3), because the two above are all-or-nothing and so
# cannot tell the FIXED ancestor walk from the round-1 mutant that walked PAST a failed `df`. Here
# `df` fails for <dir>/vol — which EXISTS — and answers a roomy 999,999 MB for everything else. A
# walk that treats a failed read as "not here, try the parent" therefore reaches `/` and ADMITS
# (measured on the mutant: free=976562, rc 0), while the shipped code refuses as unreadable.
mkdir -p "$T/vol"
printf '#!/bin/sh\ncase "$*" in\n  *"$FAKE_DF_FAIL_DIR"*) exit 1 ;;\nesac\navail=999999000\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "fake 9999999 0 $avail 1%% /"\n' > "$T/bin-select/df"
chmod +x "$T/bin-ok/df" "$T/bin-dead/df" "$T/bin-select/df"

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

# provision <bin-dir> <avail-mb> <name> [extra env assignments…] [<absolute-target>]
# Drives the SHIPPED `wt_provision` in a subshell with the stub on PATH, then reports what the
# lifecycle actually did: the rc, WT_RESULT, whether a directory exists, whether a ref exists.
# An ABSOLUTE path anywhere in the extra args overrides the worktree target (the ancestor-walk arm
# needs a target that is not `$REPO/.worktrees/<name>`); every other extra arg is an env assignment.
# ⛔ rc 4 IS THE SEAM'S OWN CODE for a disk refusal (nothing was ATTEMPTED); the CALLERS map it to the
# harness's 77/AGENT_DISK_REFUSED so the capacity ledger and the operator see the disk gate. Both are
# asserted below: 4 here, 77 in the verb arm — one verdict, two surfaces.
provision() {
    local bindir="$1" avail="$2" name="$3"; shift 3
    local target="$REPO/.worktrees/$name" envs="" a
    for a in "$@"; do case "$a" in /*) target="$a" ;; *) envs="$envs $a" ;; esac; done
    ( cd "$REPO" && env PATH="$bindir:$PATH" FAKE_DF_AVAIL_MB="$avail" DISK_MIN_FREE_MB=500 \
        DISK_BOX=cell-test $envs bash -c '
          . "$1" || exit 99
          wt_provision "$2" "$3" "feat/$4" origin/main
          printf "rc=%s\nWT_RESULT=%s\n" "$?" "$WT_RESULT"
        ' _ "$WTL" "$REPO" "$target" "$name" )
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

# ⛔ THE ANCESTOR WALK MUST NOT WALK PAST A FAILED READ (review round 4, P3 — the round-1 fix was
# unpinned, so a revert was invisible). The target does not exist; its nearest EXISTING ancestor does,
# and `df` fails for exactly that directory while answering a roomy figure for `/`. The seam must
# report UNREADABLE, not hop to `/` and admit on a number that says nothing about this volume.
OUT="$(provision "$T/bin-select" 0 e0-tm FAKE_DF_FAIL_DIR="$T/vol" "$T/vol/absent/deeper")"
case "$OUT" in *'rc=4'*) rc=0 ;; *) rc=1 ;; esac
ck "a failed \`df\` on the nearest EXISTING ancestor is REFUSED, not walked past to / ($(printf '%s' "$OUT" | head -1))" $rc
case "$OUT" in *'REFUSED-UNKNOWN'*) rc=0 ;; *) rc=1 ;; esac
ck "…and it is REFUSED-UNKNOWN — a parent's free space is not this volume's" $rc

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

# ⛔ …AND THE ARM ABOVE CANNOT SEE A RAISED `tree` (review round 5, P2 — MEASURED). With the shipped
# defaults `tree` (350) < `self` (6,144), so `max(tree, self)` IS `self` and a tree-BLIND seam agrees
# with the live arm by accident. State the tree the cell actually pays and the two seams parted:
# `disk_worktree_need` answered 2,064 while `disk_lane_need` answered 22,000 — so the worktree was
# materialised and `run_agent` refused one step later, i.e. #3395's defect under a configured bound.
# `DISK_LANE_TREE_MB` is precisely the remedy docs/ops/disk-reaper.md gives a repo whose python markers
# do not match, so the arm that pins "one bound" has to drive it.
SEAM_T="$( env DISK_MIN_FREE_MB=500 DISK_LANE_TREE_MB=20000 DISK_LANE_SELF_MB=64 bash -c '. "$1"; disk_worktree_need' _ "$GATE" )"
LIVE_T="$( env DISK_MIN_FREE_MB=500 DISK_LANE_TREE_MB=20000 DISK_LANE_SELF_MB=64 bash -c '. "$1"; set -- $(disk_lane_costs "$2"); disk_lane_need "$1" "$2" "$3"' _ "$GATE" "$T/pytarget" )"
{ [ "$SEAM_T" = "$LIVE_T" ] && [ "$SEAM_T" = 22000 ]; }; rc=$?
ck "the seam equals the live arm under a RAISED DISK_LANE_TREE_MB (seam=$SEAM_T, live=$LIVE_T, want 22000) — a tree-blind seam answers 2064, which admits the lane run_agent then refuses" $rc

# ⛔ …AND IT MUST NOT GO BELOW THE LIVE ARM WHEN THE OPERATOR LOWERS `self` INSTEAD (review round 6,
# P2 — MEASURED). The arms above and below both survive a seam whose `tree` defaults to 0, because
# `self` (6,144) dominates 0 AND dominates the classifier's 350. Lower `self` — which is exactly what
# `disk_admit`'s own refusal text recommends for a box whose lanes are measured cheaper — and a
# 0-defaulted seam falls BELOW the live arm: measured `DISK_LANE_SELF_MB=64`, tree unstated, python
# target -> seam 2,064 (`terms="0 64 2000"`) vs live 2,350 (`350 64 2000`). 2,064–2,349 MB free then
# ADMITS a worktree `run_agent` refuses, i.e. #3395 once more. So `tree` defaults to the classifier's
# PYTHON constant (350, the larger of 350/64), which cannot lower the seam and keeps 8,144 shipped.
SEAM_LOW="$( env DISK_MIN_FREE_MB=500 DISK_LANE_SELF_MB=64 bash -c '. "$1"; disk_worktree_need' _ "$GATE" )"
LIVE_LOW="$( env DISK_MIN_FREE_MB=500 DISK_LANE_SELF_MB=64 bash -c '. "$1"; set -- $(disk_lane_costs "$2"); disk_lane_need "$1" "$2" "$3"' _ "$GATE" "$T/pytarget" )"
{ [ "$SEAM_LOW" -ge "$LIVE_LOW" ] && [ "$LIVE_LOW" = 2350 ]; }; rc=$?
ck "the seam is never BELOW the live arm when DISK_LANE_SELF_MB is lowered (seam=$SEAM_LOW, live=$LIVE_LOW, want live 2350) — a seam defaulting tree to 0 answers 2064 here and admits what run_agent refuses" $rc

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
# ⛔ THE LINE'S ARITHMETIC MUST BE THE ARITHMETIC IT COMPUTED (review round 6, P2 — MEASURED). It used
# to read `worst case ${worst}MB = max(tree, self) + reserve` with `worst` = max(tree, self) alone, an
# equation false by the reserve on every refusal — on the line an operator is meant to re-derive the
# number from. Pinned VERBATIM at the shipped defaults (350/6,144/2,000 -> 8,144).
case "$GVOUT" in *'need 8144MB = max(tree 350MB, self 6144MB) + reserve 2000MB'*) rc=0 ;; *) rc=1 ;; esac
ck "…and the refusal states the arithmetic it actually computed (need = max(tree, self) + reserve) — $(printf '%s' "$GVOUT" | grep -o 'need [0-9]*MB = max(tree [0-9]*MB, self [0-9]*MB) + reserve [0-9]*MB' | head -1)" $rc

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
# ⛔ ONE EXTRACTION, USED BY THE CENSUS **AND** BY ITS NON-VACUITY PROOF (review round 4, P2 —
# MEASURED). The round-3 proof re-implemented the extraction with a SECOND copy of the awk, so
# reverting the census's own regex to the round-2 terminator left the suite at 40/40 including
# "✅ the census is non-vacuous": the proof measured a copy of the code rather than the code. Now a
# regression in HERE breaks the proof too, which is the only thing that makes it a proof.
arm_of() { # <script> -> the rc-4 arm's body (empty if there is no arm)
  if grep -qE '^[[:space:]]*4\)' "$1"; then
    # ⛔ TERMINATE ON THE ARM'S OWN TERMINATOR, WHICH IS `break ;;` IN dispatch-merge (review round 3,
    # P2 — MEASURED). Requiring a bare `;;` on its own line ran the capture to the END OF FILE (139
    # lines instead of 27), so `grep -qF break` was satisfiable by any later `break`: changing the arm's
    # `break ;;` to `continue ;;` still printed the pass. Any line ENDING in `;;` ends the arm.
    awk '/^[[:space:]]*4\)[[:space:]]*#?/{f=1} f{print} f&&/;;[[:space:]]*$/{exit}' "$1"
  else
    awk '/(^|[[:space:]])(if|elif)[[:space:]]+\[.*_wt_rc[" ]*=[[:space:]]*["]?4/{f=1} f{print}' "$1" | awk '{print} /^[[:space:]]*fi[[:space:]]*$/{exit}'
  fi
}
for pair in "fix-one.sh:AGENT_DISK_REFUSED" "adopt-fix.sh:exit 77" "dispatch-merge.sh:break"; do
  f="${pair%%:*}"; want="${pair##*:}"
  script="$HERE/$f"
  if [ ! -f "$script" ]; then bad "H) $f is missing — the census cannot be vacuous"; continue; fi
  # ⛔ SCOPED TO THE rc-4 ARM'S OWN BODY (review round 2, P2 — MEASURED). The first version grepped the
  # WHOLE file, and both tokens already appear pre-change elsewhere (`AGENT_DISK_REFUSED` at fix-one.sh's
  # live-arm readers, `break` in dispatch-merge's loop), so it could not fail for the reason it claims.
  arm="$(arm_of "$script")"
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

# ⛔ NON-VACUITY PROOF FOR THE CENSUS (review rounds 3 and 4). A source census that cannot fail for
# its own reason is a decoration. This mutates a COPY twice — `break ;;` → `continue ;;` (the batch no
# longer stops, exactly the regression the arm exists for) while ADDING an unrelated `break` later in
# the file — and requires the extraction to see the arm WITHOUT the token. It extracts through
# `arm_of`, the SAME function the census uses, so a regression in that extraction fails HERE rather
# than being masked by a second copy of it. The real tree is untouched.
_mut="$T/mut-dispatch-merge.sh"
sed -e 's/^\([[:space:]]*\)break ;;$/\1continue ;;/' "$HERE/dispatch-merge.sh" > "$_mut" 2>/dev/null
printf '\nbreak\n' >> "$_mut"
_marm="$(arm_of "$_mut")"
# ⛔ NO PIPELINE HERE (review round 5, P2 — MEASURED). `printf … | grep -q` under the suite's own
# `set -o pipefail` is a SIGPIPE flake: `grep -q` exits on the first match, `printf` dies of SIGPIPE
# (141), and pipefail turns a CORRECT tree into "the mutation harness could not extract a mutated
# arm" — measured 271 false negatives in 3,000 runs with pipefail on, 0 with a `case` match. A gate
# that reds at random is the same defect as one that never fires.
case "$_marm" in
  *SPAWNED_IDS*|*CHAIN_IDS*)
    if grep -qF 'break' <<<"$_marm"; then
      bad "H) the census is VACUOUS: a mutated dispatch-merge (break→continue, plus a stray break later) still passes"
    else
      ok "H) the census is non-vacuous: on the mutated copy it reads the arm and the token IS absent"
    fi ;;
  *)
    bad "H) the mutation harness could not extract a mutated arm — fix the harness, do not trust the pass above" ;;
esac

# ⛔ THE CENSUS POPULATION IS ASSERTED AS AN EQUALITY, NOT AS A HARDCODED LIST (review round 6, P1 —
# MEASURED). `for pair in "fix-one.sh:…" …` names THREE files, so a FOURTH `wt_provision` caller can
# drift in ungated and the census still reads green — the corpus-drift failure this repo already
# guards by asserting populations as equalities (`spawn-gate.test.sh`'s pi-invoker equality,
# `wt-lifecycle.test.sh` L9). The population is DERIVED from the source, so a new caller reds HERE.
# ⛔ NO `xargs` AT ALL (review round 6, P2 — and round 7 corrected its reasoning). The round-6 note
  # said `xargs -r` was dropped as a GNU extension because "on an empty one `xargs` runs nothing either
  # way — the `-r` bought nothing". MEASURED round 7: that is FALSE. On empty input, GNU `xargs`
  # WITHOUT `-r` still runs the command once with no arguments, so `basename` printed
  # `Try 'basename --help' for more information.` to stderr — exposed by the doc-comment probe below,
  # which is the one derivation input that legitimately matches NOTHING. `-r` bought exactly the
  # empty-input behaviour it was removed for, and its absence is a stderr leak on a real path. A
  # `while read` loop runs ZERO times on empty input on every platform, so the datum is kept and the
  # extension is not needed.
# ⛔ ONE DERIVATION, CALLED BY THE CENSUS AND BY ITS OWN NON-VACUITY PROOFS BELOW (the `arm_of`
# idiom). A second copy of the regex would let the census regress while its proof still passed — the
# round-3 defect that idiom was written for.
#
# ⛔ AND THE PATTERN MUST SEE EVERY SPELLING A NEW CALLER MAY USE (review round 7, P1 — MEASURED).
# The round-6 pattern was anchored at line start and admitted only an optional literal `if `, so BOTH
# plausible 4th-caller spellings were INVISIBLE while the census still read green:
#     if ! wt_provision …        (`!` follows `if `)
#     WT_RC=$(wt_provision …)    (the line starts with an assignment)
# So the equality below proved "no new BARE caller appeared", not "no new caller appeared" — and the
# three verified callers (adopt-fix.sh:38, dispatch-merge.sh:301, fix-one.sh:231) are all bare, which
# is exactly what kept the hole hidden. The token is now matched wherever it STARTS A COMMAND: at line
# start, or after any non-alphanumeric character (`$(`, `;`, `&&`, whitespace), with `[^#]*` unable to
# cross a `#` so a commented-out call (wt-lifecycle.sh:365's own doc line) is not counted as a caller,
# and `[^[:alnum:]_.-]` keeping longer words (`my_wt_provision`, `wt_provision_helper`) out.
census_pop() { # <dir> -> space-separated basenames of the files holding a wt_provision CALL
  grep -rlE '^([^#]*[^[:alnum:]_.-])?wt_provision[[:space:]]' --include='*.sh' "$1" \
    | grep -v '\.test\.sh$' | while IFS= read -r _cf; do basename "$_cf"; done | sort | tr '\n' ' '
}
# ⛔ ROOTED AT `scripts/`, NOT AT `$HERE` (review round 7, P2 — MEASURED). The arm's stated purpose is
# that "a 4th ungated caller reds the suite", but a census rooted at the harness directory cannot see
# one directory up — and `scripts/` is both the natural home for the README's own "move them onto
# wt_provision" follow-up and the directory that already holds sibling checkout code
# (`scratch-worktree.sh`, `admin-merge.sh`). Measured: a caller added as
# `scripts/zz-outside-caller.sh` left this suite at 65 passed / 0 failed while the arm printed
# "EXACTLY". The root is the repo's `scripts/` tree, so the same caller now reds here. The expected
# population is unchanged by the wider root, because the three callers are the only files under
# `scripts/` that invoke `wt_provision` at all.
_census_pop="$(census_pop "$(cd "$HERE/.." && pwd)")"
_census_want='adopt-fix.sh dispatch-merge.sh fix-one.sh '
if [ "$_census_pop" = "$_census_want" ]; then
  ok "H) the wt_provision caller population is EXACTLY the censused set (${_census_want% })"
else
  bad "H) the wt_provision caller population DRIFTED — a caller is ungated (found: '${_census_pop% }', censused: '${_census_want% }'). Add it to arm H's list and to the rc-4 mapping."
fi

# ⛔ THE PATTERN'S COVERAGE IS DRIVEN, NOT ASSERTED IN A COMMENT (review round 7, P1 — MEASURED). The
# equality above can only red for a spelling the pattern ALREADY SEES: measured on a scratch tree of
# this head, injecting a 4th caller as `if ! wt_provision …` left the suite at 55 passed / 0 failed,
# while the bare control red it. Each spelling therefore gets a probe file and the SAME `census_pop`,
# so a regression in the derivation breaks the proof too.
_pd="$T/census-probe"; mkdir -p "$_pd"
for _probe in \
  'bare:wt_provision "$R" "$W" "$B" "$BASE"' \
  'if-bang:if ! wt_provision "$R" "$W" "$B" "$BASE"; then' \
  'assignment:WT_RC=$(wt_provision "$R" "$W" "$B" "$BASE")'
do
  _name="${_probe%%:*}"; _body="${_probe#*:}"
  printf '%s\n' "$_body" > "$_pd/zz-$_name.sh"
  case "$(census_pop "$_pd")" in
    *"zz-$_name.sh"*)
      ok "H) the census SEES a caller written as '$_name' — a 4th caller in that spelling cannot drift in blind" ;;
    *)
      bad "H) the census is BLIND to a caller written as '$_name' — a 4th caller in that spelling would drift in ungated while the population still read green" ;;
  esac
  rm -f "$_pd/zz-$_name.sh"
done
# The other half, so the census does not red on PROSE: a doc line that merely names the seam is not a
# call site, and `wt-lifecycle.sh` carries one (`# wt_provision <repo> …`).
printf '%s\n' '# wt_provision <repo> <worktree-path> <branch> [base]' > "$_pd/zz-doc.sh"
case "$(census_pop "$_pd")" in
  *zz-doc.sh*)
    bad "H) the census counts a DOC COMMENT as a caller — prose about the seam is not a call site, and this arm would red on an unmodified tree" ;;
  *)
    ok "H) the census does NOT count a doc comment that merely names wt_provision" ;;
esac

# ⛔ READ THE `echo` LINES ONLY, NEVER THE COMMENTS (review round 6, self-caught — MEASURED). The
# first version of this pin extracted from the `elif` line onwards, so the COMMENT above the echo — which
# names REFUSED-DISK to explain the finding — satisfied the match by itself and the pin passed against
# the OLD, WRONG message. A comment-fabricated declaration is not a declaration; the registry's own
# forward scan refuses one for exactly this reason. Only lines whose first token is `echo` count.
_c77="$(awk '/elif \[ "\$rc" = "77" \]/{f=1} f&&/^[[:space:]]*echo /{print} f&&/^[[:space:]]*echo /&&/adopt-\$PR\.log/{exit}' "$HERE/adopt-fix.sh")"
case "$_c77" in
  *REFUSED-DISK*REFUSED-UNKNOWN*|*REFUSED-UNKNOWN*REFUSED-DISK*)
    ok "H) adopt-fix.sh's exit-77 remedy names the PRE-START refusal and its own token, not only the live arm" ;;
  *) bad "H) adopt-fix.sh's exit-77 remedy does not name the #3395 pre-start refusal (REFUSED-DISK / REFUSED-UNKNOWN) — the operator is sent to a '[disk-gate] REFUSED' line that does not exist on that path" ;;
esac

# ⛔ THE VERDICT→REMEDY SELECTOR IS DRIVEN, NOT CENSUSED (review round 7, P2 — MEASURED). The `_c77`
# arm above pins the exit-77 echo; the `case "$WT_RESULT" in …` selector that CHOOSES the remedy was
# pinned by NOTHING. It is the #2721 wrong-cause class: both pre-start arms reach rc 4 carrying
# REFUSED-UNKNOWN (an unreadable `df`, AND a half-deployed `$O` with no spawn-gate.sh), so a selector
# that collapsed to the disk remedy would tell an operator to reclaim space for a broken probe — a
# remedy that cannot arrive. Measured: deleting the selector from a scratch copy left the suite at
# 65 passed / 0 failed, while the same class in `fix-one.sh` IS driven (H3). The fix exists twice and
# was pinned once.
#
# The block is EXTRACTED FROM THE SHIPPED SCRIPT and EXECUTED with `$WT_RESULT` injected (the `arm_of`
# idiom), so the assertion is on BEHAVIOUR and a regression breaks this arm rather than a copy of it.
_af_sel="$(awk '/^[[:space:]]*case "\$WT_RESULT" in/{f=1} f{print} f&&/^[[:space:]]*esac[[:space:]]*$/{exit}' "$HERE/adopt-fix.sh")"
if [ -z "$_af_sel" ]; then
  bad "H) adopt-fix.sh's verdict-to-remedy selector is GONE or unextractable — two DIFFERENT causes would get one remedy"
else
  _af_remedy() { # <verdict> -> the lines the shipped selector produces for it
    ( mkdir -p "$T/af-o/logs"; O="$T/af-o" PR=999 WT_RESULT="$1"; eval "$_af_sel" ) 2>&1
  }
  _af_unk="$(_af_remedy REFUSED-UNKNOWN)"
  _af_dsk="$(_af_remedy REFUSED-DISK)"
  case "$_af_unk" in
    *REFUSED-UNKNOWN*probe*|*probe*REFUSED-UNKNOWN*)
      ok "H) an UNREADABLE probe gets its own remedy (it names the probe), selected from the verdict" ;;
    *) bad "H) adopt-fix.sh's REFUSED-UNKNOWN remedy does not name the PROBE — an unreadable df is reported as a full disk (the #2721 wrong-cause class)" ;;
  esac
  case "$_af_unk" in
    *"reclaim space"*)
      bad "H) the REFUSED-UNKNOWN remedy tells the operator to RECLAIM SPACE — that remedy cannot arrive for a broken probe or a half-deployed box" ;;
    *) ok "H) …and it does NOT tell an unreadable probe to reclaim space" ;;
  esac
  case "$_af_dsk" in
    *REFUSED-DISK*"reclaim space"*)
      ok "H) a genuine DISK refusal still gets the reclaim-space remedy (so the selector is not inert the other way)" ;;
    *) bad "H) adopt-fix.sh's REFUSED-DISK remedy is missing or no longer says to reclaim space — a real full disk would be sent down the wrong arm" ;;
  esac
fi

# ═══ H2. THE BATCH-STOP ARM, DRIVEN ═════════════════════════════════════════════════════════════
# ⛔ ARM H ABOVE IS A SOURCE CENSUS: it proves the token `break` sits inside the rc-4 arm. MEASURED
# (review round 6): it stayed 42 passed / 0 failed while BOTH regressions its own comments call P1/P2
# were re-introduced — `for _dm in "$N" "$@"` (round 5) and deleting the
# `case " $SPAWNED_IDS $CHAIN_IDS " in *" $_dm "*) continue ;; esac` guard (round 3, which releases a
# LIVE lane's or chain's claim and lets a peer duplicate in-flight work). A census cannot see a loop
# that releases the wrong set; this executes it.
#
# SCOPE, STATED PLAINLY: what is DRIVEN here is the RELEASE LOOP (and its dispatched.txt drop). The
# arm's `break` — "the batch stops" — is still only TOKEN-CENSUSED by arm H above; it is not driven,
# and this header must not imply otherwise.
#
# The release loop is EXTRACTED FROM THE SHIPPED SCRIPT and run with injected state, so the assertion
# is on BEHAVIOUR and survives a refactor of the surrounding case arm. Same idiom, and the same
# anti-pipeline rule, as the `dmrecount` arms in repo-target.test.sh.
echo
echo "── H2) the batch-stop arm releases EXACTLY the unspawned remainder (batch-stop itself: arm H) ──"
_relblock="$(awk '/^[[:space:]]*_dm_unspawned=""/{f=1} f{print} f&&/drop_dispatched_rows/{exit}' "$HERE/dispatch-merge.sh")"
case "$_relblock" in
  *release_issue_claim_unspawned*)
    # ⛔ A CONJUNCTION, NOT AN ALTERNATION (review cycle 2, P1). `*SPAWNED_IDS*|*CHAIN_IDS*` accepted
    # EITHER token, so dropping `CHAIN_IDS` from the guard — round 3's actual regression — still
    # satisfied it. Both halves must be present or the tokens below prove nothing.
    _has_sp=0; _has_ch=0
    case "$_relblock" in *SPAWNED_IDS*) _has_sp=1 ;; esac
    case "$_relblock" in *CHAIN_IDS*) _has_ch=1 ;; esac
    if [ "$_has_sp" -eq 1 ] && [ "$_has_ch" -eq 1 ]; then
      ok "H2) the release loop is extractable and carries BOTH halves of the live-work guard (SPAWNED_IDS + CHAIN_IDS)"
    else
      bad "H2) the extracted block is missing part of the live-work guard (SPAWNED_IDS=$_has_sp CHAIN_IDS=$_has_ch) — a live lane's or chain's claim is releasable"
      _relblock=""
    fi ;;
  *) bad "H2) the batch-stop release loop is no longer extractable — fix this harness, do not trust the arms below"; _relblock="" ;;
esac
drive_rel() { # <N> <spawned> <chain> <all-ids...> -> "REL=[…] DROP=[…]"
  local n="$1" sp="$2" ch="$3"; shift 3
  ( N="$n"; SPAWNED_IDS="$sp"; CHAIN_IDS="$ch"; _rel=""; _drop=""
    release_issue_claim_unspawned() { _rel="$_rel $1"; }
    drop_dispatched_rows() { _drop="$_drop $*"; }
    eval "$_relblock"
    printf 'REL=[%s] DROP=[%s]\n' "${_rel# }" "${_drop# }" ) 2>&1
}
# (1) mid-batch: 10 already HAS a live lane. Releasing it is the round-3 P3 defect.
H2OUT="$(drive_rel 11 "10" "" 10 11 12)"
case "$H2OUT" in
  *'REL=[11 12]'*) ok "H2) a mid-batch refusal releases ONLY the unspawned remainder (11 12) — never the live lane's 10" ;;
  *) bad "H2) the batch-stop arm released the WRONG set — a live lane's claim can be released and a peer can duplicate in-flight work (got: $H2OUT)" ;;
esac
case "$H2OUT" in
  *'DROP=[11 12]'*) ok "H2) …and drops exactly those dispatched.txt rows, so no phantom dispatched work" ;;
  *) bad "H2) the batch-stop arm dropped the wrong dispatched.txt rows (got: $H2OUT)" ;;
esac
# (2) THE GUARD, DRIVEN — and the protected id must sit INSIDE the at-or-after window.
# ⛔ MEASURED (review cycle 2, P1): the first version of (1)/(2) protected id `10`, which is BEFORE
# `$N`=11, so the `[ "$_dm_seen" -eq 1 ] || continue` window skipped it and the
# `case " $SPAWNED_IDS $CHAIN_IDS " in *" $_dm "*)` guard NEVER RAN. Both arms printed ✅ for
# protection they did not verify: a NEUTERED guard (`case " … " in *) : ;; esac`, tokens intact) and a
# half-deleted one (`CHAIN_IDS` dropped) both left the suite at 53/0. An in-window id is what makes the
# guard the only thing that can skip it.
H2OUT4="$(drive_rel 11 "11" "" 10 11 12)"
case "$H2OUT4" in
  *'REL=[12]'*) ok "H2) an IN-WINDOW id whose LANE is live is not released (SPAWNED_IDS half, driven)" ;;
  *) bad "H2) the SPAWNED_IDS half of the guard is INERT — an in-window lived id is released (got: $H2OUT4)" ;;
esac
H2OUT5="$(drive_rel 11 "" "11" 10 11 12)"
case "$H2OUT5" in
  *'REL=[12]'*) ok "H2) an IN-WINDOW id whose CHAIN started is not released (CHAIN_IDS half, driven)" ;;
  *) bad "H2) the CHAIN_IDS half of the guard is INERT — an in-window chained id is released (got: $H2OUT5)" ;;
esac
# (3) the CHAIN_IDS half, protecting a WHOLE REMAINDER — the id must sit INSIDE the at-or-after
# window for the guard to be the thing that skips it (cycle 3, P1 — MEASURED). The earlier form of this
# arm protected id `10`, which is BEFORE `$N`=11, so the `_dm_seen` window skipped it and the guard
# never ran: it printed ✅ while the CHAIN_IDS half was DEAD under a functionally-removed half whose
# token was still printed. Chaining 11 AND 12 makes the correct answer `REL=[]`, which ONLY the guard
# can produce — a weakened guard releases one or both.
H2OUT2="$(drive_rel 11 "" "11 12" 10 11 12)"
case "$H2OUT2" in
  *'REL=[]'*) ok "H2) a live CHAIN protects its WHOLE remainder — 11 and 12 are both chained, so nothing is released" ;;
  *) bad "H2) the CHAIN_IDS guard does not protect the chained remainder — a released claim lets a peer duplicate live work (got: $H2OUT2)" ;;
esac
# (4) everything BEFORE $N is never touched, even with nothing spawned (the `_dm_seen` window).
#     This is what the round-5 `for _dm in "$N" "$@"` regression breaks: `$N` first sets _dm_seen on
#     iteration 1, so the at-or-after guard opens for ids EARLIER than $N too.
H2OUT3="$(drive_rel 11 "" "" 10 11 12)"
case "$H2OUT3" in
  *'REL=[11 12]'*) ok "H2) ids BEFORE the refusing issue are never released (the at-or-after window holds)" ;;
  *) bad "H2) the at-or-after window is broken — an EARLIER issue's claim is released (got: $H2OUT3). This is the round-5 'for _dm in \"\$N\" \"\$@\"' defect." ;;
esac

# ═══ H3. fix-one.sh's rc-4 arm, DRIVEN: the attempt is REFUNDED and the exit is 77 ═══════════════
# Arm H's census only proves the TOKEN `AGENT_DISK_REFUSED` sits in the arm. It cannot see the two
# things the arm exists for: that the attempt is refunded (a refusal that spends an attempt is the
# misattribution #2721 fixed) and that the exit is the disk gate's own 77 (folded into a generic 1,
# the operator is sent to wait for a load remedy that cannot arrive). Both are behavioural, so drive.
echo
echo "── H3) fix-one.sh's rc-4 arm refunds the attempt and exits 77, not a generic 1 ──"
_fixarm="$(awk '/if \[ "\$_wt_rc" = 4 \]/{f=1} f{print} f&&/^[[:space:]]*fi[[:space:]]*$/{c++; exit}' "$HERE/fix-one.sh")"
case "$_fixarm" in
  *refund_gate_attempt*)
    case "$_fixarm" in
      *exit*) ok "H3) fix-one.sh's rc-4 arm is extractable and contains its refund + exit (so H3 cannot be vacuous)" ;;
      *) bad "H3) fix-one.sh's rc-4 arm no longer exits — the refusal would fall through to the generic arm"; _fixarm="" ;;
    esac ;;
  *) bad "H3) fix-one.sh's rc-4 arm is no longer extractable or no longer refunds the attempt"; _fixarm="" ;;
esac
H3D="$T/h3"; mkdir -p "$H3D"
# ⛔ THE ARM IS DRIVEN THROUGH A HELPER FUNCTION, NOT AN INLINE `$( … )` BLOCK (review round 5, P1 —
# MEASURED). The stub defines a FUNCTION, and a `$( … )` whose double-quoted string spanned three
# physical lines left `check-false-pass-shapes.sh`'s brace walk believing a block opened there never
# closed — the scan of THIS file then reported PARTIAL, and that suite FAILED on it ("1 of 310 file(s)
# were only PARTIALLY scanned", #2096). The helper is also the honest shape: it NAMES what the subshell
# is for. The subshell is still required — the arm's own `exit 77` must not end this suite.
# ⛔ THE STUB READS `_h3dir`, NOT `$1`: a function called with no arguments has its OWN (empty)
# positional parameters, so a `"$1"` body would be an unbound variable under this file's `set -u`.
_h3drive() { # <dir> <issue> <verdict> — run the extracted rc-4 arm under that refusal verdict
  _h3dir="$1"; _wt_rc=4; PR="$2"; L="$1"; WT_RESULT="$3"
  refund_gate_attempt() { : > "$_h3dir/refunded"; }
  eval "$_fixarm"
}
( _h3drive "$H3D" 4242 "REFUSED-DISK(free=100, need=200, box=rig)" ) >/dev/null 2>&1
H3RC=$?
if [ "$H3RC" -eq 77 ]; then ok "H3) the rc-4 arm exits 77, the disk gate's own code (never a generic 1)"; else bad "H3) the rc-4 arm exited $H3RC, not 77 — the operator is sent to a remedy that cannot clear it"; fi
if [ -f "$H3D/refunded" ]; then ok "H3) …and the attempt is REFUNDED (a free refusal must not spend one)"; else bad "H3) the refusal consumed the attempt — refund_gate_attempt did not run"; fi
# ⛔ DRIVEN WITH `REFUSED-UNKNOWN`, NOT `REFUSED-DISK` (review cycle 4, P1 — MEASURED). The first
# version drove with a `WT_RESULT` that ALREADY carried `REFUSED-DISK`, so the arm's own
# `REFUSED before creating a worktree: $WT_RESULT` line satisfied the match by itself: DELETING the
# dedicated remedy line, and renaming its token to `REFUSED-DISKX`, both left the suite at 55/0. The
# arm pinned nothing. With an UNKNOWN verdict the only way `REFUSED-DISK` can appear is the DISK
# remedy line, and `REFUSED-UNKNOWN` proves the interpolated verdict survives — so this drives BOTH
# branches of the cause selector.
H3U="$T/h3u"; mkdir -p "$H3U"
( _h3drive "$H3U" 4243 "REFUSED-UNKNOWN(free=?, need=8144, box=rig)" ) >/dev/null 2>&1
H3ULOG="$(cat "$H3U.log" 2>/dev/null)"
case "$H3ULOG" in
  *REFUSED-UNKNOWN*) ok "H3) …the operator log carries the verdict it was given (REFUSED-UNKNOWN survives the interpolation)" ;;
  *) bad "H3) the refusal swallowed the verdict — the operator cannot tell a skew from a full disk (got: $(printf '%s' "$H3ULOG" | head -1))" ;;
esac
# ⛔ THE MISATTRIBUTION ITSELF, ASSERTED DIRECTLY: an UNKNOWN verdict must NEVER be reported as a DISK
# refusal. The verdict-echo line carries `REFUSED-UNKNOWN(…)`, so any `REFUSED-DISK` in this log could
# ONLY come from a remedy that guessed "full disk" — which is the #2721 wrong-cause class.
case "$H3ULOG" in
  *REFUSED-DISK*) bad "H3) an UNREADABLE probe was reported as a DISK refusal — a version skew or a broken df cannot be cleared by reclaiming space (#2721 class)" ;;
  *) ok "H3) …and an UNREADABLE probe is NOT reported as a DISK refusal (the remedy names the probe/skew)" ;;
esac
# The DISK verdict must reach the operator with a DISK REMEDY, not merely echo its own token: the
# verdict-echo line ALWAYS contains `REFUSED-DISK(…)`, so a `*REFUSED-DISK*` match here would be
# satisfied by that line alone — the original vacuity (deleting the remedy line left 55/0). The
# assertion names text that ONLY the remedy line can supply.
case "$(cat "$H3D.log" 2>/dev/null)" in
  *'reclaim space'*'will NOT clear'*) ok "H3) …and a DISK verdict reaches the operator with a DISK remedy, not just its own echoed token" ;;
  *) bad "H3) a DISK refusal did not carry its remedy (reclaim-space guidance) — the token echo alone is not a remedy (got: $(head -1 "$H3D.log" 2>/dev/null))" ;;
esac

# ═══ H4. THE ONLY LINE THAT EVER POPULATES CHAIN_IDS MUST EXIST ═══════════════════════════════════
# ⛔ MEASURED (review cycle 4, P1): `drive_rel` INJECTS `CHAIN_IDS`, so every H2 arm stayed green
# (55/0) when the production assignment `CHAIN_IDS="$CHAIN_IDS $N"` was DELETED from the chain-start
# branch — i.e. the suite could not detect the round-3 P3 defect (a peer duplicating in-flight chain
# work) if it were re-introduced by deleting one line. Nothing else in the repo covers it:
# refresh-scout.test.sh slices only the chain-FAILURE branch. This pins the SUCCESS branch.
echo
echo "── H4) the chain-start branch is the only producer of CHAIN_IDS, and it still produces it ──"
_chainok="$(sed -n '/if wt_spawn "chain-/,/^  fi$/p' "$HERE/dispatch-merge.sh")"
case "$_chainok" in
  *'release_issue_claim_unspawned'*|*'chain-'*)
    case "$_chainok" in
      *'CHAIN_IDS="$CHAIN_IDS $N"'*) ok "H4) the chain-START branch records the id in CHAIN_IDS (so arm H2's guard has a producer)" ;;
      *) bad "H4) the chain-start branch no longer assigns CHAIN_IDS — a live chain's claim becomes releasable and a peer duplicates in-flight work (round 3, P3)" ;;
    esac ;;
  *) bad "H4) the chain-start branch is no longer extractable — fix this harness, do not trust H4" ;;
esac

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
