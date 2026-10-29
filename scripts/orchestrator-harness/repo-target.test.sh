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
#      directory; an unreadable origin is a refusal, never a pass; the branch-level assertion; ambient
#      GIT_DIR cannot forge it; a `url.*.insteadOf` rewrite cannot forge it EITHER (raw config read),
#      and a legitimate MIRROR rewrite does not refuse a correct pair; case-insensitive slugs pass; a
#      self-referential target dir refuses; a malformed target refuses; the three shape rules agree.
#   B  lane.sh (the start gate inside the worktree): matching target starts; tortoise worktree with an
#      agent-infra target REFUSES (72) with both slugs in the message and writes NO brief; no target
#      refuses; a flag/positional contradiction refuses; a worktree checked out on another branch
#      refuses; the per-dispatch `[repo-target]` line is present; a 4th positional refuses; and a
#      `--repo-dir`-ONLY call starts with a NON-EMPTY `$OR` in the brief.
#   C  fix-one.sh (the PR-lane builder): a checkout/target mismatch refuses BEFORE any work; a branch
#      that is not in the target repo refuses BY NAME, never as `could not materialise`; a matching
#      target materialises and passes both assertions.
#   D  dispatch-merge.sh (the issue-lane builder): a checkout that is not the target refuses the whole
#      batch (both slugs named); no target refuses.
#   F  the module is REQUIRED: absent or stale -> exit 78 in EVERY caller (lane, fix-one,
#      dispatch-merge, adopt-fix).
#   E  the non-vacuity proof (optional): the PRE-FIX lane starts the wrong-repo lane.
#
# HERMETIC: every repo is a throwaway `git init` under a temp dir, and `http.proxy` points at a closed
# local port so the one fetch under test fails instantly without network. Fixture repos keep their
# GitHub origin URL (never rewire it: `url.<path>.insteadOf` rewrites `get-url` and makes the fixture
# unreadable). A11/A12 add a rewrite deliberately, through `GIT_CONFIG_GLOBAL`, to prove the identity
# read is the RAW configured value; they are the only places a rewrite is used.
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
{ [ "$a1" -eq 0 ] && grep -q 'check=ok' <<<"$A1" && grep -q 'repo=daniel-ospina/tortoise' <<<"$A1" \
    && grep -qF "worktree=$TWT" <<<"$A1"; }; ck "A1 target tortoise, worktree tortoise -> OK (line: $A1)" $?

# ⛔ A1b/A1c — A PRE-FLIGHT LINE MUST NEVER CLAIM A RESULT (#2935).
# `repo_target_assert` runs BEFORE the lane does any work. Its success arm used to print
# `result=OK`, and that token is what the fleet greps for a lane's verdict: 12 lanes were
# dispatched to two cells, each printed `result=OK`, and none of them did anything — the
# dispatcher read success from a line that is emitted whether or not the lane ever runs. The
# pass arm must claim only what it MEASURED (that the identity CHECK passed); `result=` is
# reserved for a line emitted once an outcome is known, so a dispatch carrying no `result=`
# line reads as "no outcome yet" — which is the truth.
# MUTATION: put `result=OK` back on either pass arm and A1b/A1c redden.
{ ! grep -q 'result=' <<<"$A1"; }; ck "A1b a passing identity line claims NO result (it is a check, not an outcome)" $?
{ [ "$(grep -cE "printf '\\[repo-target\\] .*check=ok" "$RT")" -ge 2 ] \
    && ! grep -qE "printf '\\[repo-target\\][^']*result=OK" "$RT"; } \
  ; ck "A1c both PASS arms print check=ok, and no [repo-target] printf claims result=OK (REFUSED arms may)" $?

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

# ⛔ AMBIENT GIT ENV MUST NOT FORGE THE IDENTITY (#2762 review, P1). With GIT_DIR pointed at the
# TARGET repo, the pre-scrub reads answered "tortoise" for an agent-infra worktree and the gate said
# OK. The gate must read the worktree path it was GIVEN.
A7="$(GIT_DIR="$AI/.git" repo_target_assert "unit" "$TWT" "daniel-ospina/agent-infra" "" 2>/dev/null)"; a7=$?
{ [ "$a7" -eq 72 ] && grep -q 'repo=daniel-ospina/tortoise' <<<"$A7" \
    && grep -q 'reason=slug-mismatch' <<<"$A7"; }; ck "A7 ambient GIT_DIR pointing at the target does NOT forge the worktree's identity (72)" $?

# GitHub slugs are CASE-INSENSITIVE; the cell supervisor folds case (#1745), so refusing here would
# certify the cell healthy and then block every dispatch on it (#2762 review, P1).
A8="$(repo_target_assert "unit" "$TWT" "Daniel-Ospina/Tortoise" "")"; a8=$?
{ [ "$a8" -eq 0 ] && grep -q 'check=ok' <<<"$A8"; }; ck "A8 same slug in a different case -> OK (GitHub slugs are case-insensitive)" $?

A9="$(repo_target_assert "unit" "$TWT" "" "$TWT")"; a9=$?
{ [ "$a9" -eq 72 ] && grep -q 'reason=target-self' <<<"$A9"; }; ck "A9 target dir IS the worktree under test -> REFUSED (a tautology can never refuse)" $?

A10="$(repo_target_assert "unit" "$TWT" "tortoise" "")"; a10=$?
A10b="$(repo_target_assert "unit" "$TWT" "/tmp/not-a-slug" "")"; a10b=$?
{ [ "$a10" -eq 72 ] && grep -q 'reason=target-invalid' <<<"$A10" \
    && [ "$a10b" -eq 72 ] && grep -q 'reason=target-invalid' <<<"$A10b"; }; ck "A10 malformed target ('tortoise', a path) -> REFUSED reason=target-invalid, not a wrong-repo claim" $?

# ⛔ A `url.<base>.insteadOf` REWRITE MUST NOT FORGE THE SLUG (#2762 review, P1). `git remote get-url`
# APPLIES url rewrites, so an ambient `GIT_CONFIG_GLOBAL` mapping the tortoise URL onto agent-infra's
# made a tortoise worktree answer `agent-infra` — through the GIT_DIR scrub — and the gate printed
# `check=ok`: the measured #2724 defect, certified by the gate built to stop it. Identity is read
# from `config --get remote.origin.url` (raw), which no rewrite touches.
FORGE_CFG="$T/gc-forge"
printf '[url "https://github.com/daniel-ospina/agent-infra.git"]\n\tinsteadOf = https://github.com/daniel-ospina/tortoise.git\n' > "$FORGE_CFG"
FORGED="$(GIT_CONFIG_GLOBAL="$FORGE_CFG" "$REAL_GIT" -C "$TWT" remote get-url origin 2>/dev/null || true)"
A11="$(GIT_CONFIG_GLOBAL="$FORGE_CFG" repo_target_assert "unit" "$TWT" "daniel-ospina/agent-infra" "")"; a11=$?
{ [ "$a11" -eq 72 ] && grep -q 'repo=daniel-ospina/tortoise' <<<"$A11" \
    && grep -q 'reason=slug-mismatch' <<<"$A11" && grep -q 'agent-infra' <<<"$FORGED"; }; ck "A11 a url.insteadOf rewrite that DOES re-point get-url ('$FORGED') does not forge the identity (72)" $?
# ...and the other direction: a LEGITIMATE mirror rewrite must not make a correct pair unreadable.
# (`remote get-url` answers the local mirror path, so the old read refused every correct dispatch.)
MIRROR_CFG="$T/gc-mirror"
printf '[url "/srv/mirror/tortoise.git"]\n\tinsteadOf = https://github.com/daniel-ospina/tortoise.git\n' > "$MIRROR_CFG"
A12="$(GIT_CONFIG_GLOBAL="$MIRROR_CFG" repo_target_assert "unit" "$TWT" "daniel-ospina/tortoise" "")"; a12=$?
{ [ "$a12" -eq 0 ] && grep -q 'check=ok' <<<"$A12"; }; ck "A12 a benign MIRROR rewrite does not refuse a correct pair (raw config, not the rewritten URL)" $?

# ⛔ APPEND-SCOPE CONFIG INJECTION (#2762 review, P1): `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/...
# OUTRANK a repo's real local origin, so `config --get` answered the injected value and the gate said
# OK for the wrong repo (measured with plain git). `--local` reads the checkout's own file.
A14="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.url \
  GIT_CONFIG_VALUE_0=https://github.com/daniel-ospina/agent-infra.git \
  repo_target_assert "unit" "$TWT" "daniel-ospina/agent-infra" "")"; a14=$?
{ [ "$a14" -eq 72 ] && grep -q 'repo=daniel-ospina/tortoise' <<<"$A14" \
    && grep -q 'reason=slug-mismatch' <<<"$A14"; }; ck "A14 GIT_CONFIG_COUNT injection does not override a REAL local origin (72)" $?
# ...and the other injection shape: a global config must not SUPPLY an origin to a repo that has none.
NOREM_CFG="$T/gc-supply"
printf '[remote "origin"]\n\turl = https://github.com/daniel-ospina/agent-infra.git\n' > "$NOREM_CFG"
A15="$(GIT_CONFIG_GLOBAL="$NOREM_CFG" repo_target_assert "unit" "$NOREMWT" "daniel-ospina/agent-infra" "")"; a15=$?
{ [ "$a15" -eq 72 ] && grep -q 'reason=worktree-origin-unreadable' <<<"$A15"; }; ck "A15 a global config cannot SUPPLY an origin to an origin-less repo (still a refusal)" $?

# ONE OWNER FOR THE SHAPE RULE, MEASURED (#2762 review, P2): a hand-copy that agrees on the two shapes
# A10 pins and diverges elsewhere would pass A10. Drive all three through one table.
shape_bad=0
for s in 'a/b' 'A/B' 'acme/widget.js' 'tortoise' '/tmp/x' 'a/b/c' 'a:b/c' 'a b/c' 'a//'; do
  if repo_slug_valid "$s"; then vs=0; else vs=1; fi
  if repo_target_valid_slug "$s"; then vt=0; else vt=1; fi
  if derive_or "$TT" "$s" >/dev/null 2>&1; then vd=0; else vd=2; fi
  case "$s" in 'a/b'|'A/B'|'acme/widget.js') want=0 ;; *) want=1 ;; esac
  { [ "$vs" = "$want" ] && [ "$vt" = "$vs" ] && { { [ "$want" = 0 ] && [ "$vd" = 0 ]; } || { [ "$want" = 1 ] && [ "$vd" = 2 ]; }; }; } \
    || { echo "     shape '$s': repo_slug_valid=$vs repo_target_valid_slug=$vt derive_or=$vd want=$want"; shape_bad=$((shape_bad+1)); }
done
ck "A13 repo_slug_valid / repo_target_valid_slug / derive_or agree on 9 shapes (one owner, not a copy)" "$shape_bad"

# ═══ B. lane.sh — the start gate ══════════════════════════════════════════════════════════════
echo
echo "── B. lane.sh: the post-build assertion before any lane artifact ──────────────────────────"
lane_drive "$TWT" 3001 feat/3001-ok --repo-dir "$TT" --repo daniel-ospina/tortoise
{ [ "$LR" -eq 0 ] && grep -q 'check=ok repo=daniel-ospina/tortoise' "$LRLOG" 2>/dev/null \
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
{ [ "${nline:-0}" = "1" ] && grep -q 'worktree=' "$B6LOG" && grep -q 'check=ok' "$B6LOG"; }; ck "B6 lane log carries EXACTLY ONE [repo-target] line naming repo, worktree and result" $?

# A malformed dispatch must not be silently truncated to its first three words.
lane_drive "$TWT" 3006 feat/3006-extra --repo daniel-ospina/tortoise extra1 extra2
{ [ "$LR" -eq 78 ] && grep -q 'too many positional' <<<"$RLOUT"; }; ck "B7 a 4th positional -> REFUSED (78) instead of silently dropped" $?

# ⛔ A `--repo-dir`-ONLY CALL MUST NAME THE REPO (#2762 review, P1). The module supports naming only a
# directory; `$OR` must then be derived from the ASSERTED worktree, or the written brief carries an
# EMPTY `--repo` and `gh` falls back to ambient GH_REPO (the #2235 fail-open).
B8WT="$(mk_wt "$TT" wt-b8 feat/3007-dironly)" || { echo "❌ worktree fixture"; exit 2; }
lane_drive "$B8WT" 3007 feat/3007-dironly --repo-dir "$TT"
{ [ "$LR" -eq 0 ] && [ -f "$LR_DIR/logs/prompt-3007.txt" ] \
    && grep -q -- '--repo daniel-ospina/tortoise' "$LR_DIR/logs/prompt-3007.txt" \
    && ! grep -q -- '--repo  ' "$LR_DIR/logs/prompt-3007.txt" \
    && grep -q 'branch=feat/3007-dironly check=ok repo=daniel-ospina/tortoise' "$LRLOG" 2>/dev/null; }; ck "B8 --repo-dir only -> STARTS, brief names the repo, branch line is not UNREADABLE (rc=$LR)" $?

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

# ⛔ THE EXIT CODE IS NOT EVIDENCE HERE (#2762 review, P3). MAX_LOAD=0 stops the SPAWN POINT from
# starting an agent on purpose (a test must not run a model), so fix-one.sh reaches its `gh` stub, the
# CI-queue gate defers (rc 2 "unreadable" -> DEFER, fail closed) and fix-one exits 0 — an unrelated
# mechanism. The three `[repo-target]` assertions below are what prove the gate passed, and the built
# worktree proves the work happened after them.
# ⛔ A CONTROLLER-SPAWNED (--argv, CTRL=1) IDENTITY REFUSAL MUST REFUND THE PER-HEAD BUDGET TOO
# (#2762 review, 3rd cycle, P1). The refund's per-head marker is keyed on `HEAD`; it used to be read
# AFTER these refusal sites, so the marker was silently skipped and two such refusals parked the PR
# as "attempts exhausted" having never run a fixer.
printf '%s\n' "2" > "$FO/state/fixcount-4004"
printf '%s\n' "$TT" daniel-ospina/agent-infra 4004 work > "$T/argv-4004"
( gh() { case "$*" in *headRefOid*) echo "cafebabe"; return 0 ;; esac; return 1; }; export -f gh
  REAP_LANE_VENV_DISABLE=1 O="$FO" MAX_LOAD=999999 DISK_MIN_FREE_MB=1 \
    bash "$FIX" --argv "$T/argv-4004" ) >/dev/null 2>&1
c4=$?
{ [ "$c4" -eq 72 ] && [ -f "$FO/state/fixgate-4004-cafebabe" ] \
    && [ "$(cat "$FO/state/fixcount-4004" 2>/dev/null)" = "1" ]; }; ck "C4 --argv (CTRL=1) identity refusal -> REFUNDS fixcount AND writes fixgate-<PR>-<head> (rc=$c4)" $?

"$REAL_GIT" -C "$AI" branch work >/dev/null 2>&1 || true
REAP_LANE_VENV_DISABLE=1 O="$FO" MAX_LOAD=0 DISK_MIN_FREE_MB=1 \
  bash "$FIX" "$AI" daniel-ospina/agent-infra 4003 work >/dev/null 2>&1
c3=$?
{ grep -q 'fixer #4003 target check=ok repo=daniel-ospina/agent-infra' "$FO/logs/fix-4003.log" 2>/dev/null \
    && grep -q 'fixer #4003 check=ok repo=daniel-ospina/agent-infra' "$FO/logs/fix-4003.log" 2>/dev/null \
    && grep -q 'fixer #4003 branch=work check=ok' "$FO/logs/fix-4003.log" 2>/dev/null \
    && [ -d "$AI/.worktrees/fix-4003" ]; }; ck "C3 matching target -> ALL THREE assertions pass (log survives the start truncation) and the worktree is built (rc=$c3, asserted by the lines not by rc)" $?

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

# ⛔ A REFUSAL MUST ALSO DROP THE BLACKLIST ROW (#2762 review, P1). The controller appends the id to
# `dispatched.txt` BEFORE calling this script; a refusal that leaves the row makes this box skip a FREE
# issue until the reaper prunes it — the same shape the CI-queue deferral already remedies.
DMO3="$T/o-dm3"; mkdir -p "$DMO3/logs" "$DMO3/state"; printf '5007\n' > "$DMO3/dispatched.txt"
O="$DMO3" bash "$DM" "$TT" daniel-ospina/agent-infra 5007 > "$T/dm3.out" 2>&1
d3=$?
{ [ "$d3" -eq 72 ] && [ -f "$DMO3/dispatched.txt" ] && ! grep -qx '5007' "$DMO3/dispatched.txt"; }; ck "D3 repo refusal drops the batch's dispatched.txt row (no phantom 'dispatched' work)" $?
DMO4="$T/o-dm4"; mkdir -p "$DMO4/logs" "$DMO4/state"; printf '5008\n' > "$DMO4/dispatched.txt"
O="$DMO4" bash "$DM" "$TT" "" 5008 > "$T/dm4.out" 2>&1
d4=$?
{ [ "$d4" -eq 72 ] && [ -f "$DMO4/dispatched.txt" ] && ! grep -qx '5008' "$DMO4/dispatched.txt"; }; ck "D4 no-target refusal drops the row too" $?

# ⛔ A PER-ISSUE REFUSAL IS NOT A DISPATCH EITHER (#2762 review, 2nd cycle, P1). The batch-level
# assertion exits 72, but the branch half runs per ISSUE and can refuse a REUSED worktree (the lane
# was left on another named branch) — then the loop `continue`s and the script exits 0 with `K` still
# counting the claim. `dispatch-merge.sh` publishes what reached a spawn; the controller recounts.
DMO5="$T/o-dm5"; mkdir -p "$DMO5/logs" "$DMO5/state"; printf '6001\n' > "$DMO5/dispatched.txt"
# the CI-queue gate must ALLOW this batch, or the deferral (rc 3) exits before the per-issue arm.
printf '%s\n' 'ciq_read() { return 0; }' 'ciq_eval() { return 0; }' 'ciq_defer_note_here() { return 0; }' \
  'ciq_ci_allowed() { return 0; }' 'ciq_verdict() { return 0; }' 'ciq_is_count() { return 0; }' \
  'ciq_ceiling() { return 0; }' 'ciq_defer_line() { return 0; }' 'ciq_horizon_min() { return 0; }' \
  'ciq_job_p90_min() { return 0; }' > "$DMO5/ci-queue.sh"
$REAL_GIT -C "$TT" worktree add -q "$TT/.worktrees/tm-6001" -b d5-other 2>/dev/null || true
O="$DMO5" bash "$DM" "$TT" daniel-ospina/tortoise 6001 > "$T/dm5.out" 2>&1
d5=$?
{ [ "$d5" -eq 0 ] && grep -q 'REFUSED (branch assertion)' "$T/dm5.out" \
    && [ -f "$DMO5/.dispatched-ids" ] && [ ! -s "$DMO5/.dispatched-ids" ] \
    && ! grep -qx '6001' "$DMO5/dispatched.txt"; }; ck "D5 per-issue branch refusal -> exit 0 BUT .dispatched-ids is EMPTY and the row dropped (rc=$d5)" $?
# ...and the controller's recount, extracted from orch-loop.sh and driven through both shapes.
sed -n '/# \[dmrecount:begin\]/,/# \[dmrecount:end\]/p' "$HERE/orch-loop.sh" | sed '1d;$d' > "$T/dmrecount.sh"
sed -n '/^is_num() {/p' "$HERE/orch-loop.sh" > "$T/isnum.sh"
[ -s "$T/dmrecount.sh" ] && grep -q 'dispatched-ids' "$T/dmrecount.sh"
ck "D6 the controller's recount block is extractable from orch-loop.sh" $?
RC_O="$T/o-rc"; mkdir -p "$RC_O"; : > "$RC_O/.batch"; printf '6002\n' >> "$RC_O/.batch"; : > "$RC_O/.dispatched-ids"
( LOG="$T/rc0.log"; : > "$LOG"; O="$RC_O"; K=1; _dmrc=0; . "$T/isnum.sh"; . "$T/dmrecount.sh"; \
    printf 'K=%s batch=[%s] gate=[%s]\n' "$K" "$(tr '\n' ' ' < "$RC_O/.batch")" "${GATE_WHY:-}" ) > "$T/rc0.out" 2>&1
{ grep -q 'K=0 batch=\[\] gate=\[dispatch(no lane reached a spawn' "$T/rc0.out"; }; ck "D6 zero-spawn batch -> K=0, .batch cleared, GATE_WHY names the DISPATCH (no cause attributed)" $?
RC_O2="$T/o-rc2"; mkdir -p "$RC_O2"; printf '6003\n6004\n' > "$RC_O2/.batch"; printf '6003\n' > "$RC_O2/.dispatched-ids"
( LOG="$T/rc1.log"; : > "$LOG"; O="$RC_O2"; K=2; _dmrc=0; . "$T/isnum.sh"; . "$T/dmrecount.sh"; \
    printf 'K=%s batch=[%s]\n' "$K" "$(tr '\n' ' ' < "$RC_O2/.batch")" ) > "$T/rc1.out" 2>&1
{ grep -q 'K=1 batch=\[6003 \]' "$T/rc1.out"; }; ck "D6 partial batch -> K counts only the lanes that reached a spawn (2 -> 1) and .batch is pruned" $?
# ⛔ THE SHAPE WHERE THE CALL ITSELF CANNOT RUN (#2762 review, 6th cycle, P2): bash 127 because
# dispatch-merge.sh is absent from a HALF-DEPLOYED $O (the very shape this change is about), or 126 when
# it is not executable. `rm -f .dispatched-ids` ran, so no file exists and NO recound arm above matched:
# the chain fell through with K still counting CLAIMS and the funnel recorded `dispatched=N` for a batch
# that spawned nothing — the permanent false PASS, in the shape the PR is otherwise about. The else arm
# is extracted and driven directly so the assertion survives a refactor of the surrounding chain.
sed -n '/# \[dmnofile:begin\]/,/# \[dmnofile:end\]/p' "$HERE/orch-loop.sh" | sed '1d;$d' > "$T/dmnofile.sh"
[ -s "$T/dmnofile.sh" ] && grep -q 'K=0' "$T/dmnofile.sh"
ck "D7 the 'dispatch-merge.sh never ran' arm is extractable from orch-loop.sh" $?
RC_O3="$T/o-rc3"; mkdir -p "$RC_O3"; printf '6005\n6006\n' > "$RC_O3/.batch"
( LOG="$T/rc2.log"; : > "$LOG"; O="$RC_O3"; K=2; _dmrc=127; unset GATE_WHY; . "$T/dmnofile.sh"; \
    printf 'K=%s batch=[%s] gate=[%s]\n' "$K" "$(tr '\n' ' ' < "$RC_O3/.batch")" "${GATE_WHY:-}" ) > "$T/rc2.out" 2>&1
{ grep -q 'K=0 batch=\[\] gate=\[dispatch(dispatch-merge.sh did not run: rc=127)' "$T/rc2.out"; }; ck "D7 no .dispatched-ids and rc=127 -> K=0, .batch cleared, GATE_WHY names the rc (never 'dispatched=N')" $?
RC_O4="$T/o-rc4"; mkdir -p "$RC_O4"; printf '6007\n' > "$RC_O4/.batch"
( LOG="$T/rc3.log"; : > "$LOG"; O="$RC_O4"; K=1; _dmrc=126; GATE_WHY="ci-queue(already set)"; . "$T/dmnofile.sh"; \
    printf 'K=%s gate=[%s]\n' "$K" "${GATE_WHY:-}" ) > "$T/rc3.out" 2>&1
{ grep -q 'K=0 gate=\[ci-queue(already set)\]' "$T/rc3.out"; }; ck "D7 an existing GATE_WHY is not overwritten by the no-file arm (same rule as every other arm)" $?

# ═══ F. the module is REQUIRED in every caller (T9) ═════════════════════════════════════════════
echo
echo "── F. a deployed box without repo-target.sh must REFUSE (exit 78), never silently skip ──"
# Copy the whole harness, then remove/replace the module, so the ONLY difference is the gate itself.
RIG_MISS="$T/rig-missing"; mkdir -p "$RIG_MISS"
cp "$HERE"/*.sh "$RIG_MISS/"
rm -f "$RIG_MISS/repo-target.sh"
( cd "$TWT" && O="$RIG_MISS/o-lane" LANE_DRY_RUN=1 bash "$RIG_MISS/lane.sh" --repo daniel-ospina/tortoise 5001 feat/5001 ) > "$T/f-lane.out" 2>&1
f1=$?
{ [ "$f1" -eq 78 ] && grep -q 'repo-target.sh missing' "$T/f-lane.out"; }; ck "F1 lane.sh without the module -> FATAL 78 (rc=$f1)" $?
( cd "$TT" && O="$RIG_MISS/o-fix" bash "$RIG_MISS/fix-one.sh" "$TT" daniel-ospina/tortoise 5002 work ) > "$T/f-fix.out" 2>&1
f2=$?
{ [ "$f2" -eq 78 ] && grep -q 'repo-target.sh missing' "$T/f-fix.out"; }; ck "F2 fix-one.sh without the module -> FATAL 78 (rc=$f2)" $?
( cd "$TT" && O="$RIG_MISS/o-dm" bash "$RIG_MISS/dispatch-merge.sh" "$TT" daniel-ospina/tortoise 5003 ) > "$T/f-dm.out" 2>&1
f3=$?
{ [ "$f3" -eq 78 ] && grep -q 'repo-target.sh missing' "$T/f-dm.out"; }; ck "F3 dispatch-merge.sh without the module -> FATAL 78 (rc=$f3)" $?

RIG_STALE="$T/rig-stale"; mkdir -p "$RIG_STALE"
cp "$HERE"/*.sh "$RIG_STALE/"
printf '#!/usr/bin/env bash\nREPO_TARGET_REFUSED=72\n' > "$RIG_STALE/repo-target.sh"
( cd "$TWT" && O="$RIG_STALE/o-lane" LANE_DRY_RUN=1 bash "$RIG_STALE/lane.sh" --repo daniel-ospina/tortoise 5004 feat/5004 ) > "$T/f-lane2.out" 2>&1
f4=$?
{ [ "$f4" -eq 78 ] && grep -q 'is stale' "$T/f-lane2.out"; }; ck "F4 lane.sh with a STALE module (no functions) -> FATAL 78 (rc=$f4)" $?
( cd "$TT" && O="$RIG_STALE/o-fix" bash "$RIG_STALE/fix-one.sh" "$TT" daniel-ospina/tortoise 5005 work ) > "$T/f-fix2.out" 2>&1
f5=$?
{ [ "$f5" -eq 78 ] && grep -q 'is stale' "$T/f-fix2.out"; }; ck "F5 fix-one.sh with a STALE module -> FATAL 78 (rc=$f5)" $?
( cd "$TT" && O="$RIG_STALE/o-dm" bash "$RIG_STALE/dispatch-merge.sh" "$TT" daniel-ospina/tortoise 5006 ) > "$T/f-dm2.out" 2>&1
f6=$?
{ [ "$f6" -eq 78 ] && grep -q 'is stale' "$T/f-dm2.out"; }; ck "F6 dispatch-merge.sh with a STALE module -> FATAL 78 (rc=$f6)" $?
# adopt-fix.sh is the FOURTH caller (#2762 review, P2): T9 says EVERY caller, so it is measured, not
# inspected. It builds a worktree before the fixer runs, so a stale/missing module here is wrong-repo
# work one layer above the assertion.
( cd "$TT" && O="$RIG_MISS/o-adopt" bash "$RIG_MISS/adopt-fix.sh" "$TT" daniel-ospina/tortoise 5010 feat/5010 ) > "$T/f-adopt.out" 2>&1
f7=$?
{ [ "$f7" -eq 78 ] && grep -qi 'missing' "$T/f-adopt.out"; }; ck "F7 adopt-fix.sh without the module -> FATAL 78 (rc=$f7)" $?
( cd "$TT" && O="$RIG_STALE/o-adopt" bash "$RIG_STALE/adopt-fix.sh" "$TT" daniel-ospina/tortoise 5011 feat/5011 ) > "$T/f-adopt2.out" 2>&1
f8=$?
{ [ "$f8" -eq 78 ] && grep -q 'is stale' "$T/f-adopt2.out"; }; ck "F8 adopt-fix.sh with a STALE module -> FATAL 78 (rc=$f8)" $?
# ...and the wrong-CHECKOUT half: refuse 72 BEFORE a fetch or a worktree exists in the wrong repo.
ADOPT_O="$T/o-adopt3"; mkdir -p "$ADOPT_O/logs"
( cd "$TWT" && O="$ADOPT_O" bash "$HERE/adopt-fix.sh" "$TWT" daniel-ospina/agent-infra 5012 feat/5012 ) > "$T/f-adopt3.out" 2>&1
f9=$?
{ [ "$f9" -eq 72 ] && grep -q 'reason=slug-mismatch' "$ADOPT_O/logs/adopt-5012.log" 2>/dev/null \
    && [ ! -d "$TWT/.worktrees/adopt-5012" ]; }; ck "F9 adopt-fix.sh on the wrong checkout -> REFUSED 72, NO worktree built (rc=$f9)" $?
# THE HALF-DEPLOY PAIR (#2762 review, P2): a SHIPPED repo-target.sh beside an OLD repo-slug.sh (one
# with the parser but no `repo_slug_valid`) must be FATAL, not refuse every explicit target as
# `target-invalid`. Nothing else in this suite reaches the `repo_slug_valid` half of the FATAL guard.
RIG_HALF="$T/rig-half"; mkdir -p "$RIG_HALF"; cp "$HERE"/*.sh "$RIG_HALF/"
printf '#!/usr/bin/env bash\nrepo_slug_from_remote() { printf "%%s\\n" "$1"; }\n' > "$RIG_HALF/repo-slug.sh"
( cd "$TWT" && O="$RIG_HALF/o-lane" LANE_DRY_RUN=1 bash "$RIG_HALF/lane.sh" --repo daniel-ospina/tortoise 5013 feat/5013 ) > "$T/f-half.out" 2>&1
f10=$?
{ [ "$f10" -eq 78 ] && grep -q 'missing or stale' "$T/f-half.out"; }; ck "F10 shipped module + OLD repo-slug.sh (no repo_slug_valid) -> FATAL 78, not target-invalid (rc=$f10)" $?

# A PARTIALLY stale module is the one shape that can DEFEAT the gate instead of failing closed: with
# the assertions present but `repo_target_head_branch` missing, HEAD_BRANCH is empty and the branch
# assertion is SKIPPED SILENTLY (the `prfixup` shape). The guard must name every symbol lane.sh reaches.
RIG_PART="$T/rig-partial"; mkdir -p "$RIG_PART"; cp "$HERE"/*.sh "$RIG_PART/"
sed '/^repo_target_head_branch() {/,/^}/d' "$HERE/repo-target.sh" > "$RIG_PART/repo-target.sh"
grep -q 'repo_target_head_branch()' "$RIG_PART/repo-target.sh" && echo "     (fixture build failed: function still present)"
( cd "$TWT" && O="$RIG_PART/o-lane" LANE_DRY_RUN=1 bash "$RIG_PART/lane.sh" --repo daniel-ospina/tortoise 5015 feat/5015 ) > "$T/f-part.out" 2>&1
f12=$?
{ [ "$f12" -eq 78 ] && grep -q 'repo_target_head_branch' "$T/f-part.out"; }; ck "F12 module missing ONLY repo_target_head_branch -> FATAL 78 (the branch half cannot be silently skipped) (rc=$f12)" $?

# ...and the SAME half-deploy on the BATCH path must not strand what the controller already did
# (#2762 review, 3rd cycle, P2): release the claims, drop the rows, and publish an EMPTY
# `.dispatched-ids` so the cycle records zero instead of a phantom dispatch.
DMOM="$T/o-dm-missing"; mkdir -p "$DMOM/logs" "$DMOM/state"; printf '5014\n' > "$DMOM/dispatched.txt"
O="$DMOM" bash "$RIG_MISS/dispatch-merge.sh" "$TT" daniel-ospina/tortoise 5014 >/dev/null 2>&1
f11=$?
{ [ "$f11" -eq 78 ] && [ -f "$DMOM/.dispatched-ids" ] && [ ! -s "$DMOM/.dispatched-ids" ] \
    && ! grep -qx '5014' "$DMOM/dispatched.txt"; }; ck "F11 half-deployed batch -> FATAL 78 but the row is DROPPED and .dispatched-ids is empty (rc=$f11)" $?

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
