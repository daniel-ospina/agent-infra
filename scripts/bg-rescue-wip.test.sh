#!/usr/bin/env bash
# bg-rescue-wip.test.sh — the regression contract for agent-infra#2045.
#
# ⛔ WHY THIS EXISTS. `bg-rescue-wip.sh` runs at the WORST possible moment: a lane is being killed,
# the process may still be writing, and the only copy of the work is that working tree. A rescuer that
# "usually works" is worse than none, because it converts "I have a backup" into a false belief. So
# every case here is driven against a REAL bare remote, and the two properties that matter are pinned
# separately:
#
#   1. the work reaches `origin` as `refs/wip/<slug>` — and its CONTENT is the content that was dirty
#      (a ref that exists but does not carry the work is vacuous, so the case reads the blob back);
#   2. the branch does NOT move and the working tree is NOT touched — a rescue must not change the
#      state it is rescuing, because the lane it is rescuing may still be running.
#
# The failure case is pinned too: when the push cannot happen the script must exit 2 and say the work
# is still only on this disk, because that is the one outcome a caller must never read as success.
#
# Run:  bash scripts/bg-rescue-wip.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RR="$HERE/bg-rescue-wip.sh"
[ -x "$RR" ] || { echo "❌ missing $RR"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/bg-rescue.XXXXXX")"
trap 'rm -rf "$T"' EXIT
echo "==> bg-rescue-wip contract ($HERE)"
echo "    scratch: $T"

# mk_repo <name> — a bare "origin" plus a clone with one commit on branch fix/lane-one.
mk_repo() {
  local n="$1"
  local d="$T/$n"
  mkdir -p "$d"; git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/wt" 2>/dev/null
  git -C "$d/wt" config user.email t@t; git -C "$d/wt" config user.name t
  printf 'base\n' > "$d/wt/base.txt"
  git -C "$d/wt" add base.txt
  git -C "$d/wt" commit -qm "base"
  git -C "$d/wt" checkout -qb fix/lane-one
  git -C "$d/wt" push -q -u origin fix/lane-one 2>/dev/null
}

echo; echo "── a CLEAN worktree has nothing at risk, and the rescue says so ──"
mk_repo clean
OUT="$(bash "$RR" "$T/clean/wt" "test" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "clean: exit 0" || bad "clean: exit $RC (want 0)"
case "$OUT" in
  *"nothing at risk"*) ok "clean: reported as nothing at risk (not as a rescue)" ;;
  *) bad "clean: did not say nothing at risk — got: $OUT" ;;
esac
[ "$(git -C "$T/clean/origin.git" for-each-ref refs/wip --format=x | wc -l | tr -d ' ')" = "0" ] \
  && ok "clean: no ref pushed for a clean tree (does not manufacture empty refs)" \
  || bad "clean: pushed a ref for a clean tree"

echo; echo "── a DIRTY worktree is archived with its CONTENT, and the branch does not move ──"
mk_repo dirty
D="$T/dirty"
printf 'the fix that would have been lost\n' >> "$D/wt/base.txt"     # unstaged edit
printf 'brand new file\n' > "$D/wt/untracked.txt"                    # untracked
BEFORE="$(git -C "$D/wt" rev-parse fix/lane-one)"
WT_BEFORE="$(git -C "$D/wt" status --porcelain | sort | tr '\n' '|')"
OUT="$(bash "$RR" "$D/wt" "lane hit its 60s cap" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "dirty: exit 0 (rescued)" || bad "dirty: exit $RC (want 0) — $OUT"
case "$OUT" in
  *"refs/wip/fix-lane-one"*) ok "dirty: names the pushed ref (the recovery handle)" ;;
  *) bad "dirty: did not name the ref — $OUT" ;;
esac

# (1) the work reached ORIGIN — read it back from the bare remote, not from the local ref.
SHA="$(git -C "$D/origin.git" rev-parse refs/wip/fix-lane-one 2>/dev/null)"
[ -n "$SHA" ] && ok "dirty: refs/wip/fix-lane-one exists on ORIGIN" \
               || bad "dirty: no refs/wip/fix-lane-one on origin (the rescue did not travel)"
if [ -n "$SHA" ]; then
  git -C "$D/origin.git" show "$SHA:base.txt" 2>/dev/null | grep -q 'the fix that would have been lost' \
    && ok "dirty: the UNSTAGED edit is in the archived tree (content, not just a ref)" \
    || bad "dirty: the archived tree is missing the unstaged edit"
  git -C "$D/origin.git" show "$SHA:untracked.txt" 2>/dev/null | grep -q 'brand new file' \
    && ok "dirty: the UNTRACKED file is in the archived tree" \
    || bad "dirty: the archived tree is missing the untracked file"
fi

# (2) the branch did not move and the working tree is untouched.
[ "$(git -C "$D/wt" rev-parse fix/lane-one)" = "$BEFORE" ] \
  && ok "dirty: the BRANCH did not move (a rescue must not commit to the lane's branch)" \
  || bad "dirty: the branch moved — the rescue changed the state it was rescuing"
[ "$(git -C "$D/wt" status --porcelain | sort | tr '\n' '|')" = "$WT_BEFORE" ] \
  && ok "dirty: the WORKING TREE is unchanged (safe to run under a live lane)" \
  || bad "dirty: the working tree changed — the throwaway index leaked"

echo; echo "── a worktree that does not exist is refused, not silently 'rescued' ──"
OUT="$(bash "$RR" "$T/nope" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok "missing: exit 1" || bad "missing: exit $RC (want 1)"
case "$OUT" in
  *"not a worktree"*) ok "missing: says why" ;;
  *) bad "missing: no diagnosis — $OUT" ;;
esac

echo; echo "── a push that CANNOT happen exits 2 and refuses to read as success ──"
mk_repo nopush
N="$T/nopush"
printf 'work that cannot leave\n' > "$N/wt/stranded.txt"
git -C "$N/wt" remote set-url origin "$T/nopush/does-not-exist.git"   # unreachable
OUT="$(bash "$RR" "$N/wt" "test" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "nopush: exit 2 (the loud failure)" || bad "nopush: exit $RC (want 2) — $OUT"
case "$OUT" in
  *"STILL ONLY ON THIS DISK"*) ok "nopush: says the work is still only on this disk" ;;
  *) bad "nopush: did not warn that the work is still local — $OUT" ;;
esac
git -C "$N/wt" rev-parse refs/wip-local/fix-lane-one >/dev/null 2>&1 \
  && ok "nopush: still recorded LOCALLY, so the work is reachable in the repo" \
  || bad "nopush: no local ref either — the work is unreachable"

echo; echo "── the shipped dispatcher actually CALLS the rescue before it kills ──"
# The contract that matters in production: the watchdog must rescue, not just the rescuer work.
grep -q 'bg-rescue-wip.sh' "$HERE/bg-dispatch.sh" \
  && ok "dispatch: the watchdog invokes bg-rescue-wip.sh" \
  || bad "dispatch: the watchdog kills without rescuing (#2045 unfixed)"
grep -q '_rescue; kill -TERM' "$HERE/bg-dispatch.sh" \
  && ok "dispatch: the rescue runs BEFORE the TERM (the lane is still alive to be archived)" \
  || bad "dispatch: no rescue before TERM"
grep -q 'sleep 20; _rescue; kill -KILL' "$HERE/bg-dispatch.sh" \
  && ok "dispatch: a second rescue covers whatever was written during the grace period" \
  || bad "dispatch: no rescue after the grace period"

echo; echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ contract holds"
