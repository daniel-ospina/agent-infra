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
# ⛔ THE BOX ID ON THIS ARM IS SANITISED TOO (review cycle 10, P2 — MEASURED). This is the ONE refusal
# that cannot call `disk_box_id` — `spawn-gate.sh` is precisely the file that is missing — so it used a
# bare `hostname -s` and emitted a nodename containing a space or a comma VERBATIM, splitting `box=`
# into two tokens in a line whose contract says that cannot happen, and leaking it into `WT_RESULT`,
# which all three callers quote into their own logs. Driven with a hostile `hostname` shim, because a
# source census would not notice a sanitisation that stopped running.
mkdir -p "$T/bin-badhost" "$T/skew2"
printf '#!/bin/sh\nprintf "cell 3,x"\n' > "$T/bin-badhost/hostname"
chmod +x "$T/bin-badhost/hostname"
cp "$WTL" "$T/skew2/wt-lifecycle.sh"
SOUT2="$( cd "$REPO" && env PATH="$T/bin-badhost:$PATH" bash -c '
        . "$1" || exit 99
        wt_disk_admit "$2" "$2/.worktrees/skew-tm2"
        printf "%s\n" "$WT_RESULT"
      ' _ "$T/skew2/wt-lifecycle.sh" "$REPO" 2>&1 )"
case "$SOUT2" in *'box=UNIDENTIFIED'*) rc=0 ;; *) rc=1 ;; esac
ck "…and a hostile hostname is REPLACED with UNIDENTIFIED, not printed raw ('box=cell 3,x' would split the two-token contract)" $rc
case "$SOUT2" in *'box=cell'*|*'box=cell '*) rc=1 ;; *) rc=0 ;; esac
ck "…and the raw nodename never reaches the line" $rc

# ⛔ THE THIRD PRODUCER OF `REFUSED-UNKNOWN` IS DRIVEN TOO (review cycle 11, P2 — MEASURED). THREE
# arms reach rc 4 carrying `REFUSED-UNKNOWN`, and ALL THREE callers select their operator remedy from
# that token (`fix-one.sh`, `adopt-fix.sh`, `dispatch-merge.sh`), so a producer nobody exercises is a
# verdict free to silently regress to `REFUSED-DISK` — the #2721 wrong-cause class, arriving through
# the fallback. Arm D pins `spawn-gate.sh`'s unreadable-`df` arm and arm G pins the
# missing-`spawn-gate.sh` arm; THIS one pins `wt_disk_admit`'s "refused without naming its numbers"
# fallback, which no arm executed at all (the suite mentioned it only in prose). MEASURED before this
# arm: reverting that one token to `REFUSED-DISK` on a copy left the suite at 88 passed / 0 failed.
# The stub is the ONLY way that branch runs — a `disk_admit` that REFUSES without setting
# `DISK_ADMIT_LINE` — and `disk_box_id` is stubbed so the arm never reads this host.
mkdir -p "$T/noname" "$T/bin-fakehost"
printf '#!/bin/sh\nprintf "cell 3,x"\n' > "$T/bin-fakehost/hostname"
chmod +x "$T/bin-fakehost/hostname"
cp "$WTL" "$T/noname/wt-lifecycle.sh"
_drive_noname() { # <wt-lifecycle-copy> -> "rc=<n>" + the WT_RESULT the seam produced
  # `hostname` is a shim returning a HOSTILE id (a space and a comma), so the box arm below is decided
  # here rather than by this host's nodename — and so a mutation that routes the id around the one
  # sanitiser produces a value that cannot collide with the stub's.
  ( cd "$REPO" && env PATH="$T/bin-fakehost:$PATH" bash -c '
      disk_admit() { DISK_ADMIT_LINE=""; return 77; }
      disk_box_id() { printf "cell-9"; }
      . "$1" || exit 99
      wt_disk_admit "$2" "$2/.worktrees/noname-tm"
      printf "rc=%s\n%s\n" "$?" "$WT_RESULT"
    ' _ "$1" "$REPO" 2>&1 )
}
NOUT="$(_drive_noname "$T/noname/wt-lifecycle.sh")"
case "$NOUT" in *'rc=1'*) rc=0 ;; *) rc=1 ;; esac
ck "wt_disk_admit REFUSES when disk_admit refuses without naming its numbers ($(printf '%s' "$NOUT" | head -1))" $rc
case "$NOUT" in *'REFUSED-UNKNOWN(free=?'*) rc=0 ;; *) rc=1 ;; esac
ck "…and names it REFUSED-UNKNOWN(free=?), never REFUSED-DISK, so an UNMEASURED refusal is not reported as a full disk" $rc
case "$NOUT" in *'box=cell-9'*) rc=0 ;; *) rc=1 ;; esac
ck "…and takes the box id from the ONE sanitiser (disk_box_id), not a private hostname read" $rc
# ⛔ NON-VACUITY, DRIVEN THROUGH THE SAME RUNNER — **ONE MUTATION PER ARM, AND THE COMMENT NAMES WHICH**
# (review cycle 11, P2 — MEASURED). The first version of this proof said it red "the two arms above"
# and drove ONE mutation, which moves only the token: the box arm stayed green under it, so a reader
# was told a guard was protected that was not — the "comment claims a guard that does not exist"
# class this file has already had to fix twice (cycles 9 and 10). The measured proof of that: with the
# token reverted on a copy, the suite read 90 passed / 2 failed and the box arm was NOT among the two.
# So there are two mutations below, each naming the ONE arm it must red, and each guarded by `cmp -s`
# so a sed that matches nothing fails instead of passing silently. The shipped file is untouched.
#   (i) THE TOKEN ARM. Reverting `REFUSED-UNKNOWN` to `REFUSED-DISK` moves the token and nothing else
#   (`rc` stays 1, `box=` stays `cell-9`), so it must red the token arm — and it is NOT claimed to
#   red the others.
sed 's/REFUSED-UNKNOWN(free=?, need=?/REFUSED-DISK(free=?, need=?/' \
  "$WTL" > "$T/noname/wt-lifecycle-token-mut.sh"
if cmp -s "$WTL" "$T/noname/wt-lifecycle-token-mut.sh"; then
  bad "G2) the TOKEN mutation did not change the copy — that non-vacuity proof proves nothing (the sed matched nothing)"
else
  MOUT="$(_drive_noname "$T/noname/wt-lifecycle-token-mut.sh")"
  case "$MOUT" in
    *'REFUSED-UNKNOWN(free=?'*) bad "G2) the TOKEN arm is VACUOUS: reverting the fallback's token to REFUSED-DISK on a copy still reads REFUSED-UNKNOWN" ;;
    *) ok "G2) …and the TOKEN arm is non-vacuous: reverting the fallback's token to REFUSED-DISK on a copy IS caught" ;;
  esac
fi
#   (ii) THE BOX ARM. Routing the id around the one sanitiser — a private `hostname -s` read, which is
#   exactly what emitted `box=cell 3,x` before cycle 10 — must red the box arm and leave the token arm
#   green (the token is untouched), so this arm is not resting on the first mutation either.
sed 's|box=$(disk_box_id 2>/dev/null|box=$(hostname -s 2>/dev/null|' \
  "$WTL" > "$T/noname/wt-lifecycle-box-mut.sh"
if cmp -s "$WTL" "$T/noname/wt-lifecycle-box-mut.sh"; then
  bad "G2) the BOX mutation did not change the copy — that non-vacuity proof proves nothing (the sed matched nothing)"
else
  BOUT="$(_drive_noname "$T/noname/wt-lifecycle-box-mut.sh")"
  case "$BOUT" in
    *'box=cell-9'*) bad "G2) the BOX arm is VACUOUS: a private hostname read on a copy still produced the sanitiser's id" ;;
    *'REFUSED-UNKNOWN(free=?'*) ok "G2) …and the BOX arm is non-vacuous: routing the id around \`disk_box_id\` to a bare \`hostname -s\` IS caught, while the token arm stays green" ;;
    *) bad "G2) the BOX mutation did not produce a named refusal at all ($(printf '%s' "$BOUT" | head -1)) — fix the harness, do not read the arm above as coverage" ;;
  esac
fi

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
# cross a `#` so a commented-out call (the `# wt_provision <repo> …` doc line in `wt-lifecycle.sh` —
# cited by SYMBOL: this diff's insertion into that file moved the line number this once named) is not
# counted as a caller,
# and `[^[:alnum:]_.-]` keeping longer words (`my_wt_provision`, `wt_provision_helper`) out.
census_pop() { # <dir> -> space-separated paths RELATIVE TO <dir> of the files holding a wt_provision CALL
  # ⛔ RELATIVE PATHS, NOT BASENAMES (review cycle 10, P1 — MEASURED). `basename` discarded the
  # subdirectory, so the only way a consumer could open the file was to re-guess the directory — and
  # the remedy census below guessed wrong (`$HERE` instead of the `scripts/` root it had just walked),
  # silently `continue`d past every caller that was not directly in `$_pd`, and printed "every caller
  # selects" over a population it had only partly looked at. Emitting the path this walk already had
  # removes the guess entirely: one derivation, and a consumer joins it to the SAME root it passed in.
  # For a probe root (`$_pd`) the relative path IS the basename, so those assertions are unchanged.
  grep -rlE '^([^#]*[^[:alnum:]_.-])?wt_provision[[:space:]]' --include='*.sh' "$1" \
    | grep -v '\.test\.sh$' | while IFS= read -r _cf; do printf '%s\n' "${_cf#"$1"/}"; done | sort | tr '\n' ' '
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
_census_want='orchestrator-harness/adopt-fix.sh orchestrator-harness/dispatch-merge.sh orchestrator-harness/fix-one.sh '
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
# ⛔ AND THE REMEDY ON THAT LINE MUST FOLLOW THE CAUSE (review cycle 10, P2 — MEASURED). The assertion
# above only proves BOTH tokens appear — it cannot tell a cause-SELECTED remedy from one sentence
# prescribing "Reclaim space … waiting will NOT clear it" for all three causes, which is what shipped.
# For the REFUSED-UNKNOWN cause that remedy cannot arrive (broken probe, or spawn-gate.sh missing), so
# the line the file's own comment calls "the log a manual operator reads (#1720)" sent the operator to
# prune a filesystem that was not full — the #2721 class the rc-4 arms were fixed for. This arm now
# pins the distinction, and its non-vacuity proof applies the SAME match to a mutated copy.
_c77r="$(grep -F 'remedy follows the cause' "$HERE/adopt-fix.sh" | grep -E '^[[:space:]]*echo ')"
if [ -z "$_c77r" ]; then
  bad "H) adopt-fix.sh's exit-77 summary has no cause-selected REMEDY line — one remedy is prescribed for three causes"
else
  _c77r_ok() { case "$1" in *REFUSED-UNKNOWN*'NOT a full disk'*) return 0 ;; esac; return 1; }
  if _c77r_ok "$_c77r"; then
    ok "H) adopt-fix.sh's exit-77 remedy follows the CAUSE — the UNKNOWN cause is named as explicitly NOT a full disk"
  else
    bad "H) adopt-fix.sh's exit-77 remedy does not distinguish the UNKNOWN cause — a broken probe or a missing spawn-gate.sh is answered with a space remedy that cannot arrive (#2721)"
  fi
  case "$_c77r" in
    *'Reclaim space (cloud-cell-supervisor.sh prune --caches, and --scratch for /tmp); waiting will NOT clear it'*)
      bad "H) adopt-fix.sh still prescribes the UNCONDITIONAL reclaim-space sentence for all three causes" ;;
    *) ok "H) …and the unconditional reclaim-space sentence is gone" ;;
  esac
  if _c77r_ok "$(printf '%s' "$_c77r" | sed 's/NOT a full disk/a full disk/')"; then
    bad "H) the cause-selected remedy arm is VACUOUS: it still passes with the distinction removed"
  else
    ok "H) …and that arm is non-vacuous: removing the distinction makes it fail"
  fi
fi

# ⛔ THE VERDICT→REMEDY SELECTOR IS DRIVEN, NOT CENSUSED (review round 7, P2 — MEASURED). The `_c77`
# arm above pins the exit-77 echo; the `case "$WT_RESULT" in …` selector that CHOOSES the remedy was
# pinned by NOTHING. It is the #2721 wrong-cause class: several pre-start arms reach rc 4 carrying
# REFUSED-UNKNOWN (an unreadable `df`, AND a half-deployed `$O` with no spawn-gate.sh, AND
# wt_disk_admit's "refused without naming its numbers" fallback), so a selector that collapsed to the
# disk remedy would tell an operator to reclaim space for a broken probe — a remedy that cannot arrive.
# Measured: deleting the selector from a scratch copy left the suite at 65 passed / 0 failed, while the
# same class in `fix-one.sh` IS driven (H3).
#
# ⛔ AND IT WAS PINNED FOR **ONE OF THREE** CALLERS (review round 8, P2 — MEASURED). This block named
# the count "twice" and pinned only `adopt-fix.sh`; `dispatch-merge.sh` — a real `wt_provision` caller,
# listed as one in this PR's own description — kept a SINGLE hardcoded "reclaim space" remedy for all
# three REFUSED-UNKNOWN causes, and this suite stayed fully green.
#
# ⛔ SO THE POPULATION IS NOW DERIVED, AND THE FIRST VERSION OF THIS COMMENT LIED ABOUT IT (review
# cycle 9, P2 — MEASURED). That version claimed "the loop below DERIVES the driven set from arm H's
# own caller census". There was no loop: `_af_sel` and `_dm_sel` below are TWO HAND-WRITTEN
# extractions, so a FOURTH caller with a hardcoded remedy would still arrive unpinned — behind a
# comment asserting it could not. A comment claiming a guard that does not exist is worse than no
# comment: it is what stops the next reviewer looking. What is actually derived is the TOKEN census
# immediately below (`arm_selects_remedy` over `census_pop`'s output), which is generic across caller
# shapes and reds on a new caller; the BEHAVIOUR is driven per caller, because the three shipped
# selectors do not share one extractable shape (`fix-one.sh`/`adopt-fix.sh` are multi-arm `case`
# blocks; `dispatch-merge.sh` is a one-line `case … esac` plus an `if`, chosen so arm H's `arm_of`
# still reaches its terminator). Stated, not implied.
#
# Each behaviour block is EXTRACTED FROM THE SHIPPED SCRIPT and EXECUTED with `$WT_RESULT` injected
# (the `arm_of` idiom), so the assertion is on BEHAVIOUR and a regression breaks this arm rather than
# a copy of it.

# ⛔ ONE MATCHER AND ONE POPULATION PREDICATE, USED BY THE CENSUS **AND** BY ITS NON-VACUITY PROOF.
# A second copy of either would let the check regress while its proof still passed — the `arm_of` idiom.
arm_selects_remedy() { # <script> -> rc 0 when its rc-4 arm really BRANCHES on the verdict
  # ⛔ A SUBSTRING TEST IS NOT A SELECTION (review cycle 10, P2 — MEASURED). This predicate used to be
  # `case "$(arm_of "$1")" in *REFUSED-UNKNOWN*)`, and the census therefore printed "selects its
  # rc-4 remedy from $WT_RESULT" for a caller whose arm was ONE hardcoded sentence —
  # `echo "zz4: REFUSED-UNKNOWN or full disk — reclaim space and retry"` — which is exactly the #2721
  # misattribution the census exists to catch. A selector has a PATTERN (the glob, asterisks included)
  # and a NON-UNKNOWN fallback arm (the other `case` arm or the `else`); prose only mentions the token.
  local _arm
  _arm="$(arm_of "$1")"
  case "$_arm" in
    *'*REFUSED-UNKNOWN*'*)
      case "$_arm" in
        *else*|*'*)'*) return 0 ;;
      esac ;;
  esac
  return 1
}
# ⛔ AN UNKNOWN REFUSAL MUST NOT USE THE WORD THAT SENDS AN OPERATOR TO FREE SPACE (review cycle 9,
# P1 — MEASURED). The first version of these asserts keyed on the literal `"reclaim space"`, but ALL
# THREE shipped UNKNOWN remedies said "Reclaiming space will NOT clear it" — a DIFFERENT spelling — so
# the assert could not fire on the very text it was written about, and appending "you may also try
# reclaiming space in the uv cache first" to `dispatch-merge.sh`'s UNKNOWN echo left the suite at
# 78 passed / 0 failed. The remedies are reworded to "Waiting will NOT clear it" and the matcher is
# widened to any use of the word, so either spelling of the wrong remedy is caught.
remedy_names_reclaim() { # <remedy text> -> rc 0 when it tells the operator to reclaim space
  case "$1" in *[Rr]eclaim*) return 0 ;; esac
  return 1
}

# ══ THE DERIVED CENSUS: EVERY `wt_provision` CALLER MUST SELECT ITS REMEDY FROM THE VERDICT ══════
# Over `census_pop`'s own output (the population arm H asserts as an EQUALITY), so a FOURTH caller reds
# HERE instead of drifting in with one hardcoded remedy — the round-8 defect.
_remedy_uncovered=""
_remedy_covered=0
_remedy_root="$(cd "$HERE/.." && pwd)"
# ⛔ RESOLVE AGAINST THE SAME ROOT `census_pop` WALKED (review cycle 10, P1 — MEASURED). `census_pop`
# is rooted at `scripts/` (the round-7 widening, so a caller one directory up is SEEN) but returns
# BASENAMES, and this loop resolved them against `$HERE` — `scripts/orchestrator-harness/`. A caller
# at `scripts/zz-outside-caller.sh` therefore failed `[ -f "$HERE/$_rf" ]` and was `continue`d away
# SILENTLY, while the arm printed "every wt_provision caller (3 of them) selects …". A silent skip that
# reads as coverage is the same fail-open shape this suite exists against, one level up: the round-8
# defect drifts straight back in behind a green line. The root is held once and used for BOTH the walk
# and the resolve, and the count is asserted against the population so a skip can never read as clean.
_remedy_popn=0
for _rf in $(census_pop "$_remedy_root"); do
  _remedy_popn=$((_remedy_popn + 1))
  if [ ! -f "$_remedy_root/$_rf" ]; then
    _remedy_uncovered="$_remedy_uncovered $_rf(unresolvable)"
    continue
  fi
  if arm_selects_remedy "$_remedy_root/$_rf"; then
    _remedy_covered=$((_remedy_covered + 1))
  else
    _remedy_uncovered="$_remedy_uncovered $_rf"
  fi
done
if [ -n "$_remedy_uncovered" ]; then
  bad "H) these wt_provision caller(s) do NOT select a remedy from \$WT_RESULT:${_remedy_uncovered} — a REFUSED-UNKNOWN (probe failure / version skew) is reported as a full disk, the #2721 wrong-cause class"
elif [ "$_remedy_covered" -ne "$_remedy_popn" ]; then
  bad "H) the remedy census resolved $_remedy_covered of $_remedy_popn caller(s) — a cohort was SKIPPED, and a skip must never read as coverage"
else
  ok "H) every wt_provision caller ($_remedy_covered of $_remedy_popn) selects its rc-4 remedy from \$WT_RESULT"
fi
# NON-VACUITY for that census: BOTH shapes it must catch are driven through the SAME predicate, on
# scratch files — the real tree untouched. (i) an arm that never mentions the token; (ii) the subtler
# one, an arm that MENTIONS it inside a single hardcoded sentence with no branch — the shape the
# substring predicate above could not see.
_rf_probe="$T/noremedy-caller.sh"
printf '%s\n' 'case "$_wt_rc" in' '  4) echo "reclaim space and retry"; break ;;' 'esac' > "$_rf_probe"
if arm_selects_remedy "$_rf_probe"; then
  bad "H) the derived census is VACUOUS: a caller whose rc-4 arm hardcodes one remedy was counted as covered"
else
  ok "H) the derived census is non-vacuous: a hardcoded single-remedy caller IS flagged"
fi
_rf_probe2="$T/noremedy-caller2.sh"
printf '%s\n' 'case "$_wt_rc" in' '  4) echo "zz4: REFUSED-UNKNOWN or a full disk — reclaim space and retry"; break ;;' 'esac' > "$_rf_probe2"
if arm_selects_remedy "$_rf_probe2"; then
  bad "H) the census counts MENTIONING as selecting: a single hardcoded sentence that names REFUSED-UNKNOWN but never branches on it passed"
else
  ok "H) …and merely MENTIONING the token in one hardcoded sentence is NOT counted as selection"
fi
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
  # Same matcher, widened: ANY use of the word, not one spelling (review cycle 9, P1).
  if remedy_names_reclaim "$_af_unk"; then
    bad "H) adopt-fix.sh's REFUSED-UNKNOWN remedy names RECLAIMING at all — an unreadable probe or a version skew is not a space problem"
  else
    ok "H) …and it does not name reclaiming in any spelling"
  fi
  case "$_af_dsk" in
    *REFUSED-DISK*"reclaim space"*)
      ok "H) a genuine DISK refusal still gets the reclaim-space remedy (so the selector is not inert the other way)" ;;
    *) bad "H) adopt-fix.sh's REFUSED-DISK remedy is missing or no longer says to reclaim space — a real full disk would be sent down the wrong arm" ;;
  esac
fi

# ⛔ THE SAME SELECTOR IN `dispatch-merge.sh`, DRIVEN (review round 8, P2 — MEASURED). This caller was
# the one left hardcoding a single remedy, and because its rc-4 arm STOPS THE WHOLE BATCH, a box whose
# probe cannot answer went dark every cycle with the operator sent to prune a filesystem that was not
# full. Nothing above could see it: arm H only censuses the token `break` inside that arm. Driven, not
# censused, for the same reason as adopt-fix's block above.
_dm_sel="$(awk '/^[[:space:]]*_dm_unknown=0[[:space:]]*$/{f=1} f{print} f&&/^[[:space:]]*fi[[:space:]]*$/{exit}' "$HERE/dispatch-merge.sh")"
if [ -z "$_dm_sel" ]; then
  bad "H) dispatch-merge.sh's verdict-to-remedy selector is GONE or unextractable — its rc-4 arm would report one cause for three different ones (#2721)"
else
  _dm_remedy() { # <verdict> -> the lines the shipped selector produces for it
    ( N=7 WT_RESULT="$1"; eval "$_dm_sel" ) 2>&1
  }
  _dm_unk="$(_dm_remedy REFUSED-UNKNOWN)"
  _dm_dsk="$(_dm_remedy REFUSED-DISK)"
  case "$_dm_unk" in
    *spawn-gate.sh*)
      ok "H) dispatch-merge.sh's REFUSED-UNKNOWN remedy names the PROBE and the version skew, selected from the verdict" ;;
    *) bad "H) dispatch-merge.sh's REFUSED-UNKNOWN remedy does not name the probe/skew — an unreadable df or a half-deployed box is reported as a full disk (the #2721 wrong-cause class)" ;;
  esac
  if remedy_names_reclaim "$_dm_unk"; then
    bad "H) dispatch-merge.sh's REFUSED-UNKNOWN remedy names RECLAIMING at all — and this arm stops the WHOLE batch, so the wrong remedy compounds every cycle"
  else
    ok "H) …and it does not name reclaiming in any spelling"
  fi
  # NON-VACUITY FOR THE MATCHER ITSELF: the widening above must actually catch the spelling the old
  # literal missed. Driven through the SAME predicate the asserts use.
  if remedy_names_reclaim "Freeing things is pointless; you may also try reclaiming space in the uv cache first."; then
    ok "H) the reclaim matcher is non-vacuous: the 'reclaiming space' spelling the old literal missed IS caught"
  else
    bad "H) the reclaim matcher cannot see 'reclaiming space' — the assert passes on the exact wrong remedy it exists to forbid"
  fi
  case "$_dm_dsk" in
    *"reclaim space"*)
      ok "H) a genuine DISK refusal in dispatch-merge.sh still gets reclaim-space (the selector is not inert the other way)" ;;
    *) bad "H) dispatch-merge.sh's DISK remedy is missing or no longer says to reclaim space — a real full disk would not name its own remedy" ;;
  esac
  # NON-VACUITY: the arms above must be able to FAIL. Neutralising the glob on a COPY (the real tree
  # untouched) reverts the selector to the single hardcoded remedy it replaced — exactly the shape
  # dispatch-merge.sh shipped with — and must be flagged here.
  _dm_mut="$T/mut-dispatch-merge-remedy.sh"
  sed 's/\*REFUSED-UNKNOWN\*/*NEVER-MATCHES*/' "$HERE/dispatch-merge.sh" > "$_dm_mut" 2>/dev/null
  _dm_sel_mut="$(awk '/^[[:space:]]*_dm_unknown=0[[:space:]]*$/{f=1} f{print} f&&/^[[:space:]]*fi[[:space:]]*$/{exit}' "$_dm_mut")"
  if [ -z "$_dm_sel_mut" ]; then
    bad "H) the mutation harness could not extract the mutated selector — fix the harness, do not trust the passes above"
  else
    _dm_mut_unk="$( ( N=7 WT_RESULT=REFUSED-UNKNOWN; eval "$_dm_sel_mut" ) 2>&1 )"
    case "$_dm_mut_unk" in
      *"reclaim space"*)
        ok "H) the arm is non-vacuous: with the selector neutralised the mutation IS caught (it falls back to 'reclaim space')" ;;
      *) bad "H) the mutation harness did not reproduce the regression — the arms above may be passing for the wrong reason" ;;
    esac
  fi
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
# ⛔ AND THE THIRD SHIPPED UNKNOWN REMEDY IS PINNED THE SAME WAY AS THE OTHER TWO (review cycle 10,
# P1 — MEASURED). The round-9 `remedy_names_reclaim` widening was wired to `adopt-fix.sh` and
# `dispatch-merge.sh` only; the assert above looks for the token `REFUSED-DISK`, which a reclaim
# remedy does not contain, so restoring the exact spelling round 9 was ABOUT ("Reclaiming space will
# NOT clear it") into `fix-one.sh` left the suite at 81 passed / 0 failed. Two of three remedies pinned
# and the third free to regress is how the round-8 miss happened; all three are pinned now.
if remedy_names_reclaim "$H3ULOG"; then
  bad "H3) fix-one.sh's REFUSED-UNKNOWN remedy names RECLAIMING at all — a broken probe or a missing spawn-gate.sh is not a space problem, and the operator cannot clear it that way (#2721 class)"
else
  ok "H3) …and it does not name reclaiming in any spelling (the third shipped UNKNOWN remedy, now pinned)"
fi
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

# ═══ I. A NEUTRALISATION THAT LEAVES A TERM ARMED STILL MEASURES THE HOST ═════════════════════════
# ⛔ MEASURED (review P2, #3409). FOUR terms decide admission — the floor (#1765) and the three lane
# terms (#2721) — and `disk_worktree_terms` DEFAULTS the TREE term to its python default (350 MB)
# whenever `DISK_LANE_TREE_MB` is unstated, while `spawn-gate.sh` coerces a `DISK_MIN_FREE_MB=0` floor
# back to 500 (`[ "$x" -ge 1 ] || x=500`, because a 0 floor is a gate that can never refuse). So a
# suite neutralising only SELF and RESERVE still refuses on a box below 350 MB, and one that writes
# the floor as `=0` still refuses below 500 MB — measuring the HOST while its comment claims the
# opposite. Measured: three suites copied two of the four terms; a 100 MB `df` stub turned
# `wt-lifecycle.test.sh` into 46 passed / 62 failed, every red on a provision that was merely refused.
# The gate was right; the SUITES lied about what they had turned off.
# ⛔ A CORRECTION, BECAUSE THE PREVIOUS SENTENCE HERE WAS FALSE (fresh review, P2 — MEASURED). It read
# "`spawn-gate.test.sh` had always named all four …, which is why it was immune". It had NOT: this very
# change is what makes THIRTEEN of that suite's lines carry all four terms — ELEVEN arms newly state the
# three lane terms (ten repaired in the review commit plus `:2041` repaired earlier in the PR) and TWO
# already carried them and gain the floor. A rationale that tells a maintainer the sibling suite needs no
# attention, while the diff repairs it, is the claim-vs-code drift this file exists against — so it is
# deleted rather than re-worded.
# ⛔ AND THIS COUNT IS RESTATED BECAUSE IT WAS WRONG IN AN EARLIER DRAFT OF THIS VERY COMMENT (fresh
# review, P3 — MEASURED). A count in this file is load-bearing, so a wrong one is corrected, not softened.
# ⛔ AND "THIS PINS THE CLASS" WAS THE SECOND FALSE CLAIM (fresh review, P1 — MEASURED). This census
# only inspects a command that ALREADY matches a lane term (`if (cmd !~ PAT) next`), so a command that
# states the FLOOR and omits all three lane terms is invisible to it — and invisible to arm J too,
# which is satisfied by any ONE effective line in the FILE. Ten such arms existed in
# `spawn-gate.test.sh` at `4a97c0f64`; arm K below is what actually pins that class.
echo
echo "── I) every suite that neutralises the disk admission zeroes all FOUR terms ──"
# The matcher is a FUNCTION, not an inline pipeline, so the positive controls below drive the SAME code
# the census uses. A census whose matcher nothing exercises is the false-PASS shape this file refuses.
NEUTRAL_LANE_TERMS='DISK_LANE_(SELF|RESERVE|TREE)_MB=0'
neutralisation_offenders() { # <file>... -> "file:NN: <command> [missing: …]" for each neutralising COMMAND missing a term
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    # ⛔ THE UNIT IS A LOGICAL COMMAND, NOT A PHYSICAL LINE (measured, #3409). A `\`-continued arm
    # states `DISK_MIN_FREE_MB=…` on the line ABOVE its lane terms; a line-based scan flagged five
    # such arms in `spawn-gate.test.sh` that were already complete, i.e. it would have been deleted as
    # a cry-wolf — the failure mode this whole file exists against, one level up. Continuations are
    # joined BEFORE the match, so the census sees what bash sees.
    awk -v FILE="$f" -v PAT="$NEUTRAL_LANE_TERMS" '
      function trimleft(s) { sub(/^[ \t]+/, "", s); return s }
      {
        cmd = $0; start = NR
        while (cmd ~ /\\$/) {
          if ((getline nxt) <= 0) break
          sub(/\\$/, " ", cmd); cmd = cmd " " nxt
        }
        if (cmd !~ PAT) next
        # PROSE IS NOT A NEUTRALISATION: a comment quoting the incomplete shape to condemn it must not
        # be flagged, or the census reds on the text that explains it and gets deleted with the check.
        if (substr(trimleft(cmd), 1, 1) == "#") next
        missing = ""
        if (cmd ~ /DISK_MIN_FREE_MB=0([^0-9]|$)/)
          missing = missing " DISK_MIN_FREE_MB=<nonzero: 0 is COERCED back to 500>"
        else if (cmd !~ /DISK_MIN_FREE_MB=[^ ]/)
          missing = missing " DISK_MIN_FREE_MB=<nonzero>"
        # The contract is NAME IT, not "set it to 0": an arm that deliberately holds a term at a
        # non-zero value (`spawn-gate.test.sh` varies TREE at 100/2000 to pin the live arm) is a
        # legitimate member — what it may not do is leave a term UNSET, because unset is what DEFAULTS
        # (TREE to 350, SELF to 6,144, the floor to 500) and that re-introduces the host dependency.
        # ⛔ THE VALUE MAY BE A VARIABLE (`DISK_MIN_FREE_MB="$floor"` in the floor arms, `"${4:-1}"`
        # in run_fork): the assertion is that the term is STATED, so the test is "a non-empty value
        # follows `=`", not "a digit follows it" — the digit form flagged two complete, variable-driven
        # arms (measured). An EMPTY assignment is still flagged: `DISK_LANE_TREE_MB=` fails `is_limit`
        # and defaults to 350, i.e. it neutralises nothing.
        if (cmd !~ /DISK_LANE_TREE_MB=[^ ]/)    missing = missing " DISK_LANE_TREE_MB=<explicit>"
        if (cmd !~ /DISK_LANE_SELF_MB=[^ ]/)    missing = missing " DISK_LANE_SELF_MB=<explicit>"
        if (cmd !~ /DISK_LANE_RESERVE_MB=[^ ]/) missing = missing " DISK_LANE_RESERVE_MB=<explicit>"
        if (missing != "") printf "%s:%d: %s [missing:%s]\n", FILE, start, substr(cmd, 1, 220), missing
      }' "$f"
  done
}
# the population is BOUNDED: this directory's own suites, no recursion
_off="$(neutralisation_offenders "$HERE"/*.test.sh)"
[ -z "$_off" ] \
  && ok "I) no suite leaves a disk-admission term armed: every neutralising line names the floor (=1) and all three lane terms" \
  || bad "I) a suite neutralises the disk admission but LEAVES A TERM ARMED, so it measures the host after all:
$_off"
_neut="$(grep -hcE "$NEUTRAL_LANE_TERMS" "$HERE"/*.test.sh 2>/dev/null | awk '{s+=$1} END {print s+0}')"
[ "$_neut" -ge 30 ] \
  && ok "I) …and the census saw $_neut neutralising line(s) across the suite population (floor 30 — an empty scan is not a clean scan)" \
  || bad "I) only $_neut neutralising line(s) seen, floor 30 — the population shrank or the pattern stopped matching, so the arm above is vacuous"
# POSITIVE CONTROLS. The fixtures are DERIVED from the complete line by dropping one term, never
# written out literally: a literal incomplete export in this file's own source would be a TRUE
# positive against the census above (correctly — and unhelpfully, since it is a fixture, not a
# neutralisation of anything). Order matters: TREE first and the FLOOR last, so `#* ` drops TREE and
# `% *` drops the floor.
mkdir -p "$T/neut"
_terms4="DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 DISK_MIN_FREE_MB=1"
printf 'export %s\n' "$_terms4" > "$T/neut/complete.test.sh"
printf 'export %s\n' "${_terms4#* }" > "$T/neut/no-tree.test.sh"
printf 'export %s\n' "${_terms4% *}" > "$T/neut/no-floor.test.sh"
printf 'export %s\n' "${_terms4%DISK_MIN_FREE_MB=1}DISK_MIN_FREE_MB=0" > "$T/neut/zero-floor.test.sh"
if [ -z "$(neutralisation_offenders "$T/neut/complete.test.sh")" ]; then
  ok "I) …a COMPLETE four-term neutralisation is NOT flagged (the census is not red on its own remedy, which is how a real check gets deleted)"
else
  bad "I) a correct four-term neutralisation WAS flagged — the matcher is too broad and would be removed, taking the real check with it"
fi
for _fx in no-tree no-floor zero-floor; do
  case "$(neutralisation_offenders "$T/neut/$_fx.test.sh")" in
    ?*) ok "I) POSITIVE CONTROL: a '$_fx' neutralisation IS flagged (the matcher is not blind to the defect it exists for)" ;;
    *) bad "I) POSITIVE CONTROL FAILED: a '$_fx' neutralisation was NOT flagged — the census above proves nothing" ;;
  esac
done

echo
echo "── K) every CALLER-DRIVING command states all four terms, not the floor alone ──"
# ⛔ WHY THIS ARM EXISTS (fresh review, P1 — MEASURED 2026-11-06). Arm I inspects only a command that
# already MATCHES a lane term (`if (cmd !~ PAT) next`), and arm J is satisfied by ANY ONE effective line
# in the FILE. A command that states the FLOOR and omits all three lane terms therefore satisfied
# neither: arm I skipped it, arm J never looked at it. That is not hypothetical — TEN arms in
# `spawn-gate.test.sh` drive the real `fix-one.sh` (→ `wt_provision` → `disk_admit`) with
# `DISK_MIN_FREE_MB=1` alone. With the lane terms unstated, `disk_worktree_need` is 6,148 MB, so on any
# box under ~6 GB free `disk_admit` refuses (MEASURED: a 1 GB `df` stub →
# `REFUSED-DISK(free=1.0GB, need=6.0GB … free_mb=1024, need_mb=6148)` rc 77), and the arm reports a DISK
# refusal where it asserts a claim/load outcome. Removing all three terms from all ten left THIS suite
# at 106 passed / 0 failed, i.e. nothing here could see the defect. This is the same class as
# `pr-doctor-fetch-refspec.test.sh` above: a census whose population cannot contain the defect.
#
# The unit is a LOGICAL COMMAND (continuations joined, comments skipped) and "DRIVES" is the same two
# predicates arm J uses (D1/D2), evaluated per COMMAND rather than per FILE. The deliberate
# disk-refusal arms are exempt BY VALUE, not by name: a command stating an absurd floor
# (`DISK_MIN_FREE_MB` >= 100000) is ASKING to be refused, so unstated lane terms cannot change its
# outcome. That is a stated rule, not a whitelist.
caller_driving() { # <files|offenders> <file>... -> one driving COMMAND (mode=files: its FILE) per line
  local mode="$1" f; shift
  for f in "$@"; do
    [ -f "$f" ] || continue
    awk -v FILE="$f" -v MODE="$mode" '
      function trimleft(s) { sub(/^[ \t]+/, "", s); return s }
      {
        cmd = $0; start = FNR
        while (cmd ~ /\\$/) {
          if ((getline nxt) <= 0) break
          sub(/\\$/, " ", cmd); cmd = cmd " " nxt
        }
        if (substr(trimleft(cmd), 1, 1) == "#") next
        # DRIVES: D1 references the seam, D2 executes a shipped caller
        drives = 0
        if (cmd ~ /wt-lifecycle[.]sh|wt_provision/) drives = 1
        if (cmd ~ /(^|[ \t;&|(])(bash|sh|source)[ \t]/ && cmd ~ /(wt-lifecycle|fix-one|adopt-fix|dispatch-merge)[.]sh/) drives = 1
        if (!drives) next
        # ⛔ ONE PREDICATE, TWO QUESTIONS: the non-vacuity floor below counts DRIVING COMMANDS through
        # THIS branch, not through a second grep. A floor measured with a looser predicate than the
        # census it guards counts something else and can never go red for the reason it states
        # (measured at 74567c286: a mention-grep counted 18 files while the real driver count was 5,
        # and deleting all 5 real drivers left the floor saying "saw 13" — green, vacuous).
        if (MODE == "files") { printf "%s\n", FILE; exit }
        # only a command that states SOME admission term is a neutralisation at all
        if (cmd !~ /DISK_(MIN_FREE|LANE_(SELF|RESERVE|TREE))_MB=/) next
        # EXEMPT BY VALUE: an absurd floor is a deliberate disk-refusal arm
        if (match(cmd, /DISK_MIN_FREE_MB=[0-9]+/)) {
          v = substr(cmd, RSTART + 17, RLENGTH - 17)
          if (v + 0 >= 100000) next
        }
        missing = ""
        if (cmd !~ /DISK_MIN_FREE_MB=[^ ]/)         missing = missing " DISK_MIN_FREE_MB=<nonzero>"
        else if (cmd ~ /DISK_MIN_FREE_MB=0([^0-9]|$)/) missing = missing " DISK_MIN_FREE_MB=<nonzero: 0 is COERCED back to 500>"
        if (cmd !~ /DISK_LANE_TREE_MB=[^ ]/)        missing = missing " DISK_LANE_TREE_MB=<explicit>"
        if (cmd !~ /DISK_LANE_SELF_MB=[^ ]/)        missing = missing " DISK_LANE_SELF_MB=<explicit>"
        if (cmd !~ /DISK_LANE_RESERVE_MB=[^ ]/)     missing = missing " DISK_LANE_RESERVE_MB=<explicit>"
        if (missing != "") printf "%s:%d: %s [missing:%s]\n", FILE, start, substr(cmd, 1, 200), missing
      }' "$f"
  done
}
# the population is BOUNDED and is the same population arm J censuses — no recursion.
# ⛔ IT MUST INCLUDE `test-*.sh`, NOT ONLY `*.test.sh` (fresh review, P1 — MEASURED).
# `scripts/orchestrator-harness/test-crossbox.sh` drives the REAL `fix-one.sh` at five call sites and
# carried `DISK_MIN_FREE_MB=1` alone (before this PR), so on a box under ~6 GB free every arm reports exit 77 —
# the very wrong-cause class this PR removes — while BOTH censuses were green because the FILENAME does
# not end in `.test.sh`. `spawn-gate.test.sh` already enumerates this file as a suite, so the repo knew
# it was one and the census did not read it. The blast radius is bounded (it is not in CI's shard list);
# the false claim is not.
_kdrv_pop=( "$HERE"/*.test.sh "$HERE"/test-*.sh "$HERE"/../*.test.sh "$HERE"/../../tests/*/run.sh "$HERE"/../../pi-bootstrap/tests/*.sh )
_koff="$(caller_driving offenders "${_kdrv_pop[@]}")"
[ -z "$_koff" ] \
  && ok "K) no CALLER-DRIVING command leaves an admission term unstated — every arm that provisions states all four, so none is decided by THIS host's free space" \
  || bad "K) a CALLER-DRIVING command states the floor but LEAVES a lane term unstated, so that arm is decided by THIS host's free space (unstated TREE/SELF default to 350/6144 MB):
$_koff
  remedy: add $_terms4 to that command (all four terms), or — if the arm WANTS a disk refusal — state an absurd floor (DISK_MIN_FREE_MB>=100000) so its intent is explicit"
# ⛔ THE REMEDY EMBEDS $_terms4 RATHER THAN SPELLING THE TERMS OUT (measured: arm I flagged this very
# message). Arm I's matcher selects any command naming a lane term, so a remedy line written literally
# is a TRUE positive against it — the same self-reference trap the fixtures above are derived to avoid.
# NON-VACUITY: the population must actually contain DRIVING COMMANDS, counted through the SAME
# predicate the census uses (mode=files), not a looser second grep.
_ndrv2=0
for _f in $(caller_driving files "${_kdrv_pop[@]}" 2>/dev/null | sort -u); do
  [ -n "$_f" ] && _ndrv2=$((_ndrv2 + 1))
done
[ "$_ndrv2" -ge 5 ] \
  && ok "K) …and the census saw $_ndrv2 file(s) containing a DRIVING command by its own predicate (floor 5 — an empty population is not a clean population)" \
  || bad "K) only $_ndrv2 file(s) with a driving command seen, floor 5 — the population or the predicate stopped matching, so the arm above is vacuous"
# POSITIVE AND NEGATIVE CONTROLS, driving the SAME function the census uses.
# ⛔ THE INCOMPLETE SHAPES ARE DERIVED FROM VARIABLES, NEVER WRITTEN LITERALLY — the same idiom arm I
# uses, for the same reason: a literal floor-only command in THIS file's source is a TRUE positive
# against the census above, and the census correctly flagged its own fixtures (measured: 2 failed) until
# they were built this way. The driver token stays literal, because that is what makes them drivers.
mkdir -p "$T/kdrv"
_k_floor1='DISK_MIN_FREE_MB=1'
_k_floor_absurd='DISK_MIN_FREE_MB=9999999'
_k_load='MAX_LOAD=1'
_k_call='bash "$HERE/../fix-one.sh" 7 work'
# ONE logical command that both DRIVES the seam and states the floor alone — the exact shipped shape.
printf '( cd "$X" && %s %s %s )\n' "$_k_load" "$_k_floor1" "$_k_call" > "$T/kdrv/caller-floor-only.test.sh"
printf '( cd "$X" && %s %s %s )\n' "$_k_load" "$_terms4"  "$_k_call" > "$T/kdrv/caller-complete.test.sh"
printf '( cd "$X" && %s %s %s )\n' "$_k_load" "$_k_floor_absurd" "$_k_call" > "$T/kdrv/caller-wants-refusal.test.sh"
printf '# %s %s\n' "$_k_floor1" "$_k_call" > "$T/kdrv/caller-prose.test.sh"
printf 'echo %s\n' "$_k_floor1" > "$T/kdrv/not-a-driver.test.sh"
case "$(caller_driving offenders "$T/kdrv/caller-floor-only.test.sh")" in
  ?*) ok "K) POSITIVE CONTROL: a caller-driving command with the FLOOR ALONE IS flagged (the arm above can see the defect it exists for)" ;;
  *)  bad "K) POSITIVE CONTROL FAILED: a caller-driving command with the floor alone was NOT flagged — this arm proves nothing" ;;
esac
case "$(caller_driving offenders "$T/kdrv/caller-complete.test.sh")" in
  '') ok "K) …a caller-driving command with ALL FOUR terms is NOT flagged (the census is not red on its own remedy)" ;;
  *)  bad "K) a correctly-stated caller-driving command WAS flagged — the matcher is too broad and would be deleted, taking the real check with it" ;;
esac
case "$(caller_driving offenders "$T/kdrv/caller-wants-refusal.test.sh")" in
  '') ok "K) …and the deliberate disk-refusal arm (absurd floor) is exempt BY VALUE, so the intent is stated rather than whitelisted" ;;
  *)  bad "K) the deliberate disk-refusal arm was flagged — the value exemption is not working, and the census would red on intent" ;;
esac
case "$(caller_driving offenders "$T/kdrv/caller-prose.test.sh")" in
  '') ok "K) NEGATIVE CONTROL: a COMMENT quoting the incomplete shape is not flagged (prose is not a neutralisation)" ;;
  *)  bad "K) NEGATIVE CONTROL FAILED: a comment quoting the incomplete shape was flagged — the census would red on the text that explains it" ;;
esac
case "$(caller_driving offenders "$T/kdrv/not-a-driver.test.sh")" in
  '') ok "K) NEGATIVE CONTROL: a floor-only command that DRIVES NOTHING is not flagged (the live-arm floor tests are legitimate)" ;;
  *)  bad "K) NEGATIVE CONTROL FAILED: a non-driving floor-only command was flagged — this would red ~80 legitimate live-arm arms and be deleted as cry-wolf" ;;
esac

echo
echo "── J) every suite that DRIVES the provision seam neutralises the admission (the CLASS, not one file) ──"
# ⛔ WHY THIS ARM EXISTS (measured 2026-11-06, fresh review P1 on #3409). Arm I above is SOUND BUT
# PARTIAL in the two directions that produced a false PASS:
#   • its matcher only inspects a logical command that MATCHES the lane-term pattern, so a suite that
#     neutralises NOTHING has no such command and is INVISIBLE to it; and
#   • its population is `"$HERE"/*.test.sh` — THIS directory — so a suite authored one level up is not
#     even read.
# `scripts/pr-doctor-fetch-refspec.test.sh` is that suite: it drives the REAL `wt_provision` through
# `run_shipped_provision` and carried no neutralisation at all. Measured with a 1 GB `df` stub:
# 23 passed / 3 failed on this head, 26 passed / 0 failed on the same stub at the base commit — while
# arm I printed "no suite leaves a term armed". A census whose population cannot contain the defect is
# the false-PASS shape this whole file exists against, one level up from the one it already names.
#
# ── WHAT COUNTS AS "DRIVES": TWO PREDICATES, EACH MEASURED AT ZERO FALSE POSITIVES ────────────────
# A suite reaches `wt_provision` two ways, and neither predicate can see both:
#   (D1) it references the seam itself — `wt-lifecycle.sh` / `wt_provision` on a non-comment command.
#        That is how the LIBRARY is sourced (`WTL="$HERE/wt-lifecycle.sh"` then `. "$WTL"`); the path
#        lives in a variable, so an invocation-shaped rule cannot see it.
#   (D2) it EXECUTES a shipped caller — an argument to `bash`/`sh`/`source` naming `fix-one.sh`,
#        `adopt-fix.sh` or `dispatch-merge.sh`, tolerating leading `VAR=value` prefixes (the repo's own
#        idiom: `( cd "$TT" && O=… bash "$RIG_MISS/fix-one.sh" … )`).
# Measured over this population: D1 selects 3 suites, D2 selects 3 more (`test-crossbox.sh` is D2-only
# and is in scope now that the population reads `test-*.sh`), 6 in total — the same 6 arm J prints — and
# NEITHER has a false positive. A looser rule — "the file mentions a caller anywhere" — selects 18 and
# flags 12 suites that
# only READ a script's text (`sed -n … "$HERE/fix-one.sh"`, `grep -qF … "$HARNESS/fix-one.sh"`); that
# census would be deleted as cry-wolf, and it would take the real check with it.
#
# ── TWO DOCUMENTED EXCEPTIONS, EACH MEASURED, AND THE RESIDUAL THAT IS NOT COVERED ────────────────
#   1. `disk-admission.test.sh` (this file) drives `wt_provision` but STUBS `df` per arm — a stronger
#      immunity than neutralising the terms, because it measures the gate and not the host. Excluded by
#      name so the exclusion is stated rather than silent.
#   2. `harness-refresh.test.sh` drives `dispatch-merge.sh` through a VARIABLE (`DM="$HERE/dispatch-
#      merge.sh"` … `bash "$DM" …`). Resolving that needs a two-pass dataflow over shell variables, and
#      measured on this population such a rule ALSO selects `fix-one-brief.test.sh` (verified: it stays
#      4/4 GREEN under the same 1 GB `df` stub). Shipping it would red a healthy suite, so this one is
#      PINNED below.
#      ⛔ THE REASON PREVIOUSLY GIVEN HERE WAS FALSE (fresh review, P2 — MEASURED). It read "`fix-one-
#      brief.test.sh`, which runs `fix-one.sh --section fixer` and therefore never provisions". It never
#      RUNS `fix-one.sh` as a program: it assigns `FIXER="$HERE/fix-one.sh"` (`:27`) and treats the file
#      as TEXT — an `awk` heredoc extraction (`:82`) and a `bash -n` syntax check (`:111`). `--section`
#      is not a `fix-one.sh` option either; it belongs to `brief-gate.sh` (`fix-one.sh:80` calls
#      `bash "$brief_gate_sh" --section fixer`).
#      ⛔ AND "IT EXECUTES NOTHING" WAS ALSO TOO STRONG (fresh review, P3 — MEASURED): the suite SOURCES
#      the region it extracted (`:92`, `. "$T/region.sh"`), so a change to `fix-one.sh`'s brief heredoc
#      CAN red this suite. What is true — and all that the exclusion needs — is that it never provisions,
#      so it is correctly not a driver; the 4/4-green measurement above stands.
#   ⛔ THE RESIDUAL, stated so this cannot be read as complete coverage: a FUTURE suite that reaches
#      provisioning only through a variable-held caller path is NOT in the derived population. The pin
#      covers the one such suite that exists today; it is not a general rule.
#
# ── EFFECTIVENESS, NOT PRESENCE (measured, review P1) ─────────────────────────────────────────────
# The first revision asked only "does a non-comment line carry the terms", so a line that assigned them
# to NOTHING satisfied it. Measured: replacing `pr-doctor`'s export with the no-op `true <four terms>`
# left this arm GREEN (99 passed / 0 failed) while the suite was still decided by the host (23/3 under
# the stub, 26/0 restored). `true A=0` is an ARGUMENT; a bare `A=0` statement is a SHELL variable that
# children do NOT inherit. Both neutralise nothing, so the SHAPE decides:
#   EFFECTIVE   `export <four terms>`                              (S1, the shipped idiom)
#   EFFECTIVE   `VAR=v <four terms> bash …` (leading env prefix)    (S2, spawn-gate.test.sh's idiom)
#   NOT         `true <terms>` / `: <terms>` / `echo <terms>` …     (the terms are ARGUMENTS)
#   NOT         `<terms>` alone on a line, no export, no command    (a shell variable, not the env)
provision_drives_seam() { # <file> -> 0 when a NON-COMMENT command references the seam (D1)
  [ -f "$1" ] || return 1
  awk '/^[ \t]*#/ { next } /wt-lifecycle\.sh|wt_provision/ { found = 1; exit } END { exit(found ? 0 : 1) }' "$1"
}
provision_invokes_caller() { # <file> -> 0 when a NON-COMMENT command runs a shipped caller (D2)
  [ -f "$1" ] || return 1
  awk -v CALLER='(wt-lifecycle|fix-one|adopt-fix|dispatch-merge)[.]sh' '
    /^[ \t]*#/ { next }
    {
      if ($0 !~ CALLER) next
      rest = $0
      while (match(rest, /(^|[ \t;&|(])(bash|sh|source)[ \t]/)) {
        start = RSTART + RLENGTH
        tail  = substr(rest, start)
        sub(/[|;&].*$/, "", tail)
        if (tail ~ CALLER) { found = 1; exit }
        rest = substr(rest, start)
        if (length(rest) == 0) break
      }
    }
    END { exit(found ? 0 : 1) }' "$1"
}
provision_neutralises_effectively() { # <file> -> 0 when an EFFECTIVE four-term neutralisation exists
  [ -f "$1" ] || return 1
  awk '
    /^[ \t]*#/ { next }
    {
      if ($0 !~ /DISK_MIN_FREE_MB=[^ ]/      ||
          $0 !~ /DISK_LANE_TREE_MB=[^ ]/     ||
          $0 !~ /DISK_LANE_SELF_MB=[^ ]/     ||
          $0 !~ /DISK_LANE_RESERVE_MB=[^ ]/) next
      n = split($0, t, /[ \t]+/)
      cmd = ""
      for (i = 1; i <= n; i++) {
        s = t[i]
        gsub(/^[(){}"$]+/, "", s)
        if (s == "") continue
        if (s ~ /^(&&|\|\||;|\||then|do|else|!)$/) continue
        if (s ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
        cmd = s
        break
      }
      if (cmd == "") { if ($0 ~ /(^|[ \t])(export|declare)[ \t]/) { found = 1; exit } ; next }
      if (cmd == "export" || cmd == "declare") { found = 1; exit }
      if (cmd == "true" || cmd == ":" || cmd == "echo" || cmd == "printf" ||
          cmd == "test" || cmd == "["   || cmd == "[[") next
      found = 1; exit
    }
    END { exit(found ? 0 : 1) }' "$1"
}
provision_is_immune() { # <file> -> 0 when the suite cannot be decided by THIS HOST
  case "$(basename "$1")" in
    # exception 1 (documented above): stubs `df` per arm, which is the stronger immunity
    disk-admission.test.sh) return 0 ;;
  esac
  provision_neutralises_effectively "$1"
}
provision_neutralisation_offenders() { # <file>... -> each DRIVER that is neither immune nor neutralised
  local f
  for f in "$@"; do
    { provision_drives_seam "$f" || provision_invokes_caller "$f"; } || continue
    provision_is_immune "$f" || printf '%s\n' "$f"
  done
}
# Arm I owns "all four terms IN A NEUTRALISING LINE"; this arm owns "a suite that DRIVES the seam has
# an EFFECTIVE neutralisation at all". A file neutralising INCOMPLETELY is arm I's red already.
_drv_pop=( "$HERE"/*.test.sh "$HERE"/test-*.sh "$HERE"/../*.test.sh "$HERE"/../../tests/*/run.sh "$HERE"/../../pi-bootstrap/tests/*.sh )
_ounneut="$(provision_neutralisation_offenders "${_drv_pop[@]}")"
[ -z "$_ounneut" ] \
  && ok "J) every suite that DRIVES the provision seam carries an EFFECTIVE disk neutralisation — a suite that drives wt_provision without one measures THIS HOST's free space" \
  || bad "J) a suite DRIVES the provision seam (wt-lifecycle.sh / wt_provision / a shipped caller) but has no EFFECTIVE neutralisation, so it is decided by the host's free space:
$_ounneut
  remedy: add 'export DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0' — all four terms, and EXPORTED (a bare assignment is a shell variable, not the environment; TREE defaults to 350 MB when unstated)"
# ⛔ THE PINNED RESIDUAL (exception 2 above). Not derived, and saying so is the point: this is the one
# suite that reaches provisioning through a variable-held caller path, which no line-based predicate
# here can resolve without also redding a healthy suite. Pinning it means REMOVING its export still
# reds — the reviewer's measured hole — instead of depending on a rule that does not exist.
_pin="$HERE/harness-refresh.test.sh"
if [ ! -f "$_pin" ]; then
  bad "J) the PINNED RESIDUAL $_pin is missing — the census cannot vouch for a suite that is not there"
elif provision_neutralises_effectively "$_pin"; then
  ok "J) …and the PINNED residual (harness-refresh.test.sh — variable-held caller path, not derivable) still carries its four-term export"
else
  bad "J) the PINNED residual harness-refresh.test.sh has LOST its four-term export — it drives the REAL dispatch-merge.sh through 'bash \"\$DM\"', so removal re-makes it host-dependent and nothing derived above can see it"
fi
# NON-VACUITY: the population must actually contain drivers. An empty or shrunken population makes the
# arm above pass by having nothing to inspect — the same trap arm I's floor exists for.
_ndrv=0
for _f in "${_drv_pop[@]}"; do
  { provision_drives_seam "$_f" || provision_invokes_caller "$_f"; } && _ndrv=$((_ndrv + 1))
done
[ "$_ndrv" -ge 5 ] \
  && ok "J) …and the census saw $_ndrv suite(s) driving the provision seam (floor 5 — an empty population is not a clean population)" \
  || bad "J) only $_ndrv suite(s) driving the provision seam seen, floor 5 — the population or a predicate stopped matching, so the arm above is vacuous"
# POSITIVE AND NEGATIVE CONTROLS, driving the SAME functions the census uses. The fixtures spell the
# terms from `$_terms4` rather than copying them literally, so a literal incomplete export never
# appears in this file's own source (that would be a TRUE positive against arm I — correctly, and
# unhelpfully).
mkdir -p "$T/drv"
printf 'WTL="$HERE/wt-lifecycle.sh"\n'                              > "$T/drv/drives.test.sh"
printf 'WTL="$HERE/wt-lifecycle.sh"\nexport %s\n' "$_terms4"         > "$T/drv/drives-neut.test.sh"
printf 'WTL="$HERE/wt-lifecycle.sh"\n# %s\nexport %s\n' "$_terms4" "$_terms4" > "$T/drv/drives-neut-prose.test.sh"
printf 'WTL="$HERE/wt-lifecycle.sh"\n# %s\n' "$_terms4"              > "$T/drv/drives-prose.test.sh"
printf 'WTL="$HERE/wt-lifecycle.sh"\ntrue %s\n' "$_terms4"           > "$T/drv/drives-noop.test.sh"
printf 'WTL="$HERE/wt-lifecycle.sh"\n%s\n' "$_terms4"                > "$T/drv/drives-bare.test.sh"
printf 'WTL="$HERE/wt-lifecycle.sh"\n%s bash -c "exit 0"\n' "$_terms4" > "$T/drv/drives-prefix.test.sh"
printf '%s\n' '( cd "$T/drv" && O="$T/drv/o" bash "$HERE/../fix-one.sh" "$T/drv" o/r 7 work )' > "$T/drv/caller.test.sh"
printf '%s\nexport %s\n' '( cd "$T/drv" && O="$T/drv/o" bash "$HERE/../fix-one.sh" "$T/drv" o/r 7 work )' "$_terms4" > "$T/drv/caller-neut.test.sh"
printf '# wt_provision "$REPO" "$WT" "$BR"\necho static-analysis-only\n' > "$T/drv/mentions.test.sh"
if [ -z "$(provision_neutralisation_offenders "$T/drv/drives-neut.test.sh")" ]; then
  ok "J) …a DRIVER with the four-term export is NOT flagged (the census is not red on its own remedy)"
else
  bad "J) a correctly-neutralised DRIVER was flagged — the matcher is too broad and would be deleted, taking the real check with it"
fi
if [ -z "$(provision_neutralisation_offenders "$T/drv/drives-neut-prose.test.sh")" ]; then
  ok "J) …nor is a DRIVER whose terms sit next to prose, when a real export is also present"
else
  bad "J) a DRIVER with a real export beside a prose mention was flagged — the matcher is reading prose as the defect"
fi
if [ -z "$(provision_neutralisation_offenders "$T/drv/drives-prefix.test.sh")" ]; then
  ok "J) …and an INLINE ENV PREFIX (<terms> bash -c …) counts as effective (spawn-gate.test.sh's idiom)"
else
  bad "J) an inline env-prefix neutralisation was flagged — the effectivity rule only knows 'export', which is not the only effective spelling"
fi
if [ -z "$(provision_neutralisation_offenders "$T/drv/caller-neut.test.sh")" ]; then
  ok "J) …and a CALLER-INVOKING suite (D2) with the export is not flagged"
else
  bad "J) a correctly-neutralised CALLER-INVOKING suite was flagged — D2 is too broad"
fi
for _fx in drives drives-prose drives-noop drives-bare caller; do
  case "$(provision_neutralisation_offenders "$T/drv/$_fx.test.sh")" in
    ?*) ok "J) POSITIVE CONTROL: '$_fx' IS flagged (${_fx} = a driver with no effective neutralisation)" ;;
    *) bad "J) POSITIVE CONTROL FAILED: '$_fx' was NOT flagged — the arm above cannot see the defect it exists for" ;;
  esac
done
case "$(provision_neutralisation_offenders "$T/drv/mentions.test.sh")" in
  '') ok "J) NEGATIVE CONTROL: a suite that only MENTIONS the seam in a comment is not a driver and is not flagged (the predicate is not a mention-matcher)" ;;
  *) bad "J) NEGATIVE CONTROL FAILED: a comment-only mention was flagged as a driver — the predicate is a mention-matcher and would red on static-analysis suites" ;;
esac


echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
