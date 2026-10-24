#!/usr/bin/env bash
# repo-target.test.sh — a lane must not start in a worktree of a DIFFERENT repo than its target
# (agent-infra#2724, #2694).
#
# THE MEASURED DEFECT. The cell launcher created EVERY worktree from `/tmp/cell-t3` (the tortoise
# checkout), so an `agent-infra` brief was handed a tortoise worktree and nothing refused: `prfixup`
# and `trigcell` both ran there, and a doctor given `PR_DOCTOR_REPO_DIR=/tmp/cell-ai` while
# `REPO`/`OR` said tortoise failed with `cannot materialise <branch>` — a branch message that hid a
# repo mismatch. A lane cannot do its work in the wrong repository, and every downstream gate
# (review, rail, attestation) would certify the wrong repo perfectly.
#
# WHAT IS PINNED — behaviour, not prose:
#   A  the shared identity assertion: target+worktree agree; mismatch refuses naming BOTH slugs; no
#      target refuses with a named reason; two checkouts of the SAME slug are distinguished by
#      directory; an unreadable origin is a refusal, never a pass; the branch-level assertion.
#   B  lane.sh (the start gate inside the worktree): matching target starts; tortoise worktree with an
#      agent-infra target REFUSES (72) with both slugs in the message and writes NO brief; no target
#      refuses; a flag/positional contradiction refuses; a worktree checked out on another branch
#      refuses; and the lane log carries the per-dispatch `[repo-target]` line.
#   C  fix-one.sh (the PR-lane builder): a checkout/target mismatch refuses BEFORE any work; a branch
#      that is not in the target repo refuses BY NAME, never as `could not materialise`; a matching
#      target materialises and passes both assertions.
#   D  dispatch-merge.sh (the issue-lane builder): a checkout that is not the target refuses the whole
#      batch (both slugs named); no target refuses.
#
# HERMETIC: every repo is a throwaway `git init` under a temp dir, with a LOCAL bare repo wired via
# `url.<path>.insteadOf` so the GitHub slug stays readable for the parser while no network is used.
# Run: bash repo-target.test.sh            (and `--nonvacuity <rev>` to re-measure the pre-fix tree)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RT="$HERE/repo-target.sh"
LANE="$HERE/lane.sh"
FIX="$HERE/fix-one.sh"
DM="$HERE/dispatch-merge.sh"
for f in "$RT" "$LANE" "$FIX" "$DM"; do [ -f "$f" ] || { echo "❌ missing $f"; exit 2; }; done

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/repo-target.XXXXXX")" || exit 2
T="$(cd "$T" && pwd -P)" || exit 2
trap 'rm -rf "$T"' EXIT INT TERM
REAL_GIT="$(command -v git)" || { echo "❌ git not found"; exit 2; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# mk_repo <name> <owner/name|""> -> prints the checkout path
mk_repo() {
  local d="$T/$1"
  mkdir -p "$d" || return 1
  "$REAL_GIT" init -q -b main "$d" || return 1
  if [ -n "${2:-}" ]; then
    "$REAL_GIT" -C "$d" remote add origin "https://github.com/$2.git" || return 1
    # ⛔ A PROXY THAT REFUSES INSTANTLY keeps any fetch local-and-fast without touching the ORIGIN
    # URL: `git remote get-url origin` must keep answering the GitHub slug the parser reads (an
    # `url.<local>.insteadOf` REWRITES get-url too, which made every fixture unreadable in this
    # suite's first cut). `http.proxy` affects transport only, so the refusal path under test is
    # reached in milliseconds and no network is used.
    "$REAL_GIT" -C "$d" config http.proxy "http://127.0.0.1:9" || return 1
  fi
  "$REAL_GIT" -C "$d" commit -q --allow-empty -m init || return 1
  "$REAL_GIT" -C "$d" update-ref refs/remotes/origin/main HEAD 2>/dev/null || true
  printf '%s' "$d"
}
# mk_wt <repo> <leaf> [branch] -> prints the worktree path (detached from origin/main without a branch)
mk_wt() {
  local repo="$1" leaf="$2" br="${3:-}" d="$T/$2"
  if [ -n "$br" ]; then
    "$REAL_GIT" -C "$repo" worktree add -q "$d" -b "$br" >/dev/null 2>&1 || return 1
  else
    "$REAL_GIT" -C "$repo" worktree add -q --detach "$d" origin/main >/dev/null 2>&1 || return 1
  fi
  printf '%s' "$d"
}
# lane_drive <worktree> <issue> <branch> <args...> -> runs lane.sh with LANE_DRY_RUN=1; sets LR/RLOUT
lane_drive() {
  local wt="$1" n="$2" br="$3"; shift 3
  LR_DIR="$T/o-$n"; mkdir -p "$LR_DIR/logs"
  ( cd "$wt" && O="$LR_DIR" REAP_LANE_VENV_DISABLE=1 LANE_DRY_RUN=1 \
      bash "$LANE" "$@" "$n" "$br" ) > "$T/lane-$n.out" 2>&1
  LR=$?
  LRLOG="$LR_DIR/logs/lane-$n.log"
  RLOUT="$(cat "$T/lane-$n.out" 2>/dev/null || true)"
}

# ═══ A. the shared assertion ═══════════════════════════════════════════════════════════════════
echo
echo "── A. repo_target_assert / repo_target_branch_assert (the ONE identity check) ────────────"
# shellcheck source=/dev/null
. "$RT" || { echo "❌ cannot source $RT"; exit 2; }

TT="$(mk_repo tortoise daniel-ospina/tortoise)" || { echo "❌ fixture"; exit 2; }
AI="$(mk_repo agentinfra daniel-ospina/agent-infra)" || { echo "❌ fixture"; exit 2; }
TWT="$(mk_wt "$TT" wt-tortoise)" || { echo "❌ worktree fixture"; exit 2; }
AIWT="$(mk_wt "$AI" wt-ai)" || { echo "❌ worktree fixture"; exit 2; }

A1="$(repo_target_assert "unit" "$TWT" "" "$TT")"; a1=$?
{ [ "$a1" -eq 0 ] && grep -q 'result=OK' <<<"$A1" && grep -q 'repo=daniel-ospina/tortoise' <<<"$A1" \
    && grep -qF "worktree=$TWT" <<<"$A1"; }; ck "A1 target tortoise, worktree tortoise -> OK (line: $A1)" $?

A2="$(repo_target_assert "unit" "$TWT" "daniel-ospina/agent-infra" "")"; a2=$?
{ [ "$a2" -eq 72 ] && grep -q 'result=REFUSED' <<<"$A2" \
    && grep -q 'repo=daniel-ospina/tortoise' <<<"$A2" && grep -q 'target=daniel-ospina/agent-infra' <<<"$A2" \
    && grep -q 'reason=slug-mismatch' <<<"$A2"; }; ck "A2 tortoise worktree, agent-infra target -> REFUSED (72), BOTH slugs named" $?

A3="$(repo_target_assert "unit" "$TWT" "" "")"; a3=$?
{ [ "$a3" -eq 72 ] && grep -q 'reason=no-target' <<<"$A3"; }; ck "A3 no target -> REFUSED (72) with reason=no-target (never a default/guess)" $?

# Two CHECKOUTS of the same slug: the dir half is what distinguishes them; equal slugs alone pass.
AI2="$(mk_repo agentinfra2 daniel-ospina/agent-infra)" || { echo "❌ fixture"; exit 2; }
AI2WT="$(mk_wt "$AI2" wt-ai2)" || { echo "❌ worktree fixture"; exit 2; }
A4="$(repo_target_assert "unit" "$AI2WT" "daniel-ospina/agent-infra" "$AI")"; a4=$?
{ [ "$a4" -eq 72 ] && grep -q 'reason=dir-mismatch' <<<"$A4"; }; ck "A4 same slug, DIFFERENT checkout -> REFUSED (post-build identity, not the target string)" $?

NOREM="$(mk_repo noremo "")" || { echo "❌ fixture"; exit 2; }
NOREMWT="$(mk_wt "$NOREM" wt-noremo)" || { echo "❌ worktree fixture"; exit 2; }
A5="$(repo_target_assert "unit" "$NOREMWT" "daniel-ospina/agent-infra" "")"; a5=$?
{ [ "$a5" -eq 72 ] && grep -q 'reason=worktree-origin-unreadable' <<<"$A5"; }; ck "A5 unreadable worktree origin -> REFUSED (an absence is never a pass)" $?

A6="$(repo_target_branch_assert "unit" "$TWT" "feat/not-there" "daniel-ospina/tortoise")"; a6=$?
{ [ "$a6" -eq 72 ] && grep -q 'feat/not-there' <<<"$A6" && grep -q 'daniel-ospina/tortoise' <<<"$A6" \
    && grep -q 'reason=branch-missing' <<<"$A6"; }; ck "A6 branch not in the target repo -> REFUSED naming the branch AND the repo" $?

# ═══ B. lane.sh — the start gate ══════════════════════════════════════════════════════════════
echo
echo "── B. lane.sh: the post-build assertion before any lane artifact ──────────────────────────"
lane_drive "$TWT" 3001 feat/3001-ok --repo-dir "$TT" --repo daniel-ospina/tortoise
{ [ "$LR" -eq 0 ] && grep -q 'result=OK repo=daniel-ospina/tortoise' "$LRLOG" 2>/dev/null \
    && [ -f "$LR_DIR/logs/prompt-3001.txt" ]; }; ck "B1 (a) target tortoise + tortoise worktree -> STARTS (rc=$LR, brief written)" $?

lane_drive "$TWT" 3002 feat/3002-bad --repo daniel-ospina/agent-infra
{ [ "$LR" -eq 72 ] \
    && grep -q 'daniel-ospina/agent-infra' <<<"$RLOUT" && grep -q 'daniel-ospina/tortoise' <<<"$RLOUT" \
    && grep -q 'result=REFUSED' "$LRLOG" 2>/dev/null \
    && [ ! -f "$LR_DIR/logs/prompt-3002.txt" ]; }; ck "B2 (b) agent-infra target + tortoise worktree -> REFUSED (72), both slugs, NO brief (rc=$LR)" $?

lane_drive "$TWT" 3003 feat/3003-none
{ [ "$LR" -eq 72 ] && grep -q 'reason=no-target' <<<"$RLOUT" \
    && [ ! -f "$LR_DIR/logs/prompt-3003.txt" ]; }; ck "B3 (c) no target -> REFUSED (72) with reason=no-target, NO brief" $?

lane_drive "$TWT" 3004 feat/3004-conflict --repo daniel-ospina/agent-infra daniel-ospina/tortoise
{ [ "$LR" -eq 72 ] && grep -q 'contradicts' <<<"$RLOUT"; }; ck "B4 --repo and the positional target disagree -> REFUSED (a contradiction is not resolved by picking one)" $?

OWT="$(mk_wt "$TT" wt-other other)" || { echo "❌ worktree fixture"; exit 2; }
lane_drive "$OWT" 3005 main --repo daniel-ospina/tortoise
{ [ "$LR" -eq 72 ] && grep -q 'branch-checkout-mismatch' "$LRLOG" 2>/dev/null; }; ck "B5 worktree checked out on another named branch -> REFUSED (the prfixup shape)" $?

# The per-dispatch record: exactly one repo-target line per lane, naming repo + worktree + result.
B6LOG="$T/o-3001/logs/lane-3001.log"
nline="$(grep -c '^\[repo-target\]' "$B6LOG" 2>/dev/null || true)"
{ [ "${nline:-0}" = "1" ] && grep -q 'worktree=' "$B6LOG" && grep -q 'result=OK' "$B6LOG"; }; ck "B6 lane log carries EXACTLY ONE [repo-target] line naming repo, worktree and result" $?

# A malformed dispatch must not be silently truncated to its first three words.
lane_drive "$TWT" 3006 feat/3006-extra --repo daniel-ospina/tortoise extra1 extra2
{ [ "$LR" -eq 78 ] && grep -q 'too many positional' <<<"$RLOUT"; }; ck "B7 a 4th positional -> REFUSED (78) instead of silently dropped" $?

# ═══ C. fix-one.sh — the PR-lane builder (#2694) ═══════════════════════════════════════════════
echo
echo "── C. fix-one.sh: the PR lane refuses a wrong checkout and names a missing branch ────────"
FO="$T/o-fix"; mkdir -p "$FO/logs" "$FO/state"
# The gh stub keeps the arms from reaching the network. Nothing in C needs a real PR read.
gh() { return 1; }
export -f gh 2>/dev/null || true

REAP_LANE_VENV_DISABLE=1 O="$FO" MAX_LOAD=999999 DISK_MIN_FREE_MB=1 \
  bash "$FIX" "$TT" daniel-ospina/agent-infra 4001 work >/dev/null 2>&1
c1=$?
{ [ "$c1" -eq 72 ] && grep -q 'daniel-ospina/tortoise' "$FO/logs/fix-4001.log" 2>/dev/null \
    && grep -q 'daniel-ospina/agent-infra' "$FO/logs/fix-4001.log" 2>/dev/null \
    && [ ! -e "$TT/.worktrees/fix-4001" ]; }; ck "C1 PR lane with a checkout/target mismatch -> REFUSED (72), no worktree built" $?

REAP_LANE_VENV_DISABLE=1 O="$FO" MAX_LOAD=999999 DISK_MIN_FREE_MB=1 \
  bash "$FIX" "$AI" daniel-ospina/agent-infra 4002 feat/not-there >/dev/null 2>&1
c2=$?
{ [ "$c2" -eq 72 ] \
    && grep -q 'feat/not-there' "$FO/logs/fix-4002.log" 2>/dev/null \
    && grep -q 'daniel-ospina/agent-infra' "$FO/logs/fix-4002.log" 2>/dev/null \
    && ! grep -q 'could not materialise' "$FO/logs/fix-4002.log" 2>/dev/null; }; ck "C2 branch absent from the target repo -> REFUSED naming branch+repo, NOT 'could not materialise'" $?

"$REAL_GIT" -C "$AI" branch work >/dev/null 2>&1 || true
REAP_LANE_VENV_DISABLE=1 O="$FO" MAX_LOAD=0 DISK_MIN_FREE_MB=1 \
  bash "$FIX" "$AI" daniel-ospina/agent-infra 4003 work >/dev/null 2>&1
c3=$?
{ [ "$c3" -eq 0 ] \
    && grep -q 'fixer #4003 target result=OK repo=daniel-ospina/agent-infra' "$FO/logs/fix-4003.log" 2>/dev/null \
    && grep -q 'fixer #4003 result=OK repo=daniel-ospina/agent-infra' "$FO/logs/fix-4003.log" 2>/dev/null \
    && grep -q 'fixer #4003 branch=work result=OK' "$FO/logs/fix-4003.log" 2>/dev/null \
    && [ -d "$AI/.worktrees/fix-4003" ]; }; ck "C3 matching target -> ALL THREE assertions pass (log survives the start truncation) and the worktree is built (rc=$c3)" $?

# ═══ D. dispatch-merge.sh — the issue-lane batch ═══════════════════════════════════════════════
echo
echo "── D. dispatch-merge.sh: the batch refuses a checkout that is not the target ─────────────"
DMO="$T/o-dm"; mkdir -p "$DMO/logs" "$DMO/state"
O="$DMO" bash "$DM" "$TT" daniel-ospina/agent-infra 5001 > "$T/dm.out" 2>&1
d1=$?
{ [ "$d1" -eq 72 ] && grep -q 'daniel-ospina/tortoise' "$T/dm.out" \
    && grep -q 'daniel-ospina/agent-infra' "$T/dm.out" \
    && grep -q 'result=REFUSED' "$T/dm.out"; }; ck "D1 checkout= tortoise, target= agent-infra -> batch REFUSED (72), both slugs" $?

O="$DMO" bash "$DM" "$TT" > "$T/dm2.out" 2>&1
d2=$?
{ [ "$d2" -eq 72 ] && grep -q 'no-target' "$T/dm2.out"; }; ck "D2 no target -> REFUSED (72) with a named reason, before any worktree" $?

# ═══ E. the pre-fix tree does NOT refuse (the non-vacuity proof) ══════════════════════════════
# Optional because the baseline must be a commit BEFORE this change: run it manually with
#   bash repo-target.test.sh --nonvacuity <pre-fix-sha>
# and it drives the OLD lane.sh in the tortoise worktree with an agent-infra target. The old launcher
# reaches its dry run (rc 0) — i.e. it starts a lane in the wrong repo, which is the defect. The same
# case against the shipped lane.sh is B2 (rc 72), so B2 is not always-green.
if [ "${1:-}" = "--nonvacuity" ]; then
  REV="${2:-}"
  if [ -z "$REV" ]; then echo "  ❌ --nonvacuity needs a revision (e.g. the commit before this change)"; FAIL=$((FAIL+1)); else
    mkdir -p "$T/old"
    if "$REAL_GIT" -C "$HERE" show "$REV:scripts/orchestrator-harness/lane.sh" > "$T/old/lane.sh" 2>/dev/null; then
      cp "$HERE/spawn-gate.sh" "$HERE/reviewer-preflight.sh" "$HERE/repo-slug.sh" "$T/old/" 2>/dev/null || true
      OLD_O="$T/o-old"; mkdir -p "$OLD_O/logs"
      ( cd "$TWT" && O="$OLD_O" REAP_LANE_VENV_DISABLE=1 LANE_DRY_RUN=1 \
          bash "$T/old/lane.sh" 9001 feat/9001-old daniel-ospina/agent-infra ) > "$T/old.out" 2>&1
      oldrc=$?
      { [ "$oldrc" -eq 0 ] && [ -f "$OLD_O/logs/prompt-9001.txt" ]; }
      ck "E  NON-VACUITY: pre-fix lane.sh ($REV) STARTS a lane in a tortoise worktree for an agent-infra target (rc=$oldrc) — the defect B2 catches" $?
    else
      echo "  ❌ E  cannot read $REV:scripts/orchestrator-harness/lane.sh"; FAIL=$((FAIL+1))
    fi
  fi
fi

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
