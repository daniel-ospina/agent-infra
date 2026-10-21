#!/usr/bin/env bash
# bg-rescue-wip.test.sh — the regression contract for agent-infra#2045.
#
# ⛔ WHY THIS EXISTS. `bg-rescue-wip.sh` runs at the WORST possible moment: a lane is being killed,
# the process may still be writing, and the only copy of the work is that working tree. A rescuer that
# "usually works" is worse than none, because it converts "I have a backup" into a false belief. So
# every case here is driven against a REAL bare remote, and the properties that matter are pinned
# separately:
#
#   1. the work reaches `origin` as `refs/wip/<slug>` — and its CONTENT is the content that was dirty
#      (a ref that exists but does not carry the work is vacuous, so the case reads the blob back);
#   2. the branch does NOT move and the working tree is NOT touched — a rescue must not change the
#      state it is rescuing, because the lane it is rescuing may still be running;
#   3. a rescue that is called TWICE — the real sequence, before the TERM and after the grace period —
#      ACCUMULATES: the second snapshot reaches origin and the first is still reachable;
#   4. a failure is never reported as "nothing at risk": an unreadable status, an unborn HEAD, a
#      nested repo with no commit, and a wrong path each have their own required outcome.
#
# The failure case is pinned too: when the push cannot happen the script must exit 2 and say the work
# is still only on this disk, because that is the one outcome a caller must never read as success.
#
# Run:  bash scripts/bg-rescue-wip.test.sh
#       BG_DISPATCH=<path> bash scripts/bg-rescue-wip.test.sh   # also run the 3 wiring arms
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RR="$HERE/bg-rescue-wip.sh"
[ -x "$RR" ] || { echo "❌ missing $RR"; exit 1; }

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
# A skip is LOUD and counted separately from PASS. It must never inflate the pass count: the arms it
# covers simply cannot run here, and a reader has to be able to see that from the summary alone.
skip() { SKIP=$((SKIP+1)); echo "  ⏭  SKIP: $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/bg-rescue.XXXXXX")"
trap 'rm -rf "$T"' EXIT
echo "==> bg-rescue-wip contract ($HERE)"
echo "    scratch: $T"

# ⛔ SIGPIPE SAFE: `git show <blob> | grep -q …` is the shape scripts/check-no-sigpipe-grep.sh exists
# to keep out of the tree. `grep -q` exits at its first match while the producer is still writing, so
# under `set -o pipefail` the PIPELINE returns 141 and a MATCHING blob reports as missing. Capture
# first, then match against a here-string.
has_blob() { # has_blob <bare-repo> <rev> <path> <needle>
  local got; got="$(git -C "$1" show "$2:$3" 2>/dev/null)"
  grep -q -- "$4" <<<"$got"
}

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
IDX_BEFORE="$(shasum "$D/wt/.git/index" 2>/dev/null | cut -d' ' -f1)"
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
  has_blob "$D/origin.git" "$SHA" base.txt 'the fix that would have been lost' \
    && ok "dirty: the UNSTAGED edit is in the archived tree (content, not just a ref)" \
    || bad "dirty: the archived tree is missing the unstaged edit"
  has_blob "$D/origin.git" "$SHA" untracked.txt 'brand new file' \
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
[ "$(shasum "$D/wt/.git/index" 2>/dev/null | cut -d' ' -f1)" = "$IDX_BEFORE" ] \
  && ok "dirty: the REAL index is byte-identical (the same lane's next 'git commit' is not disturbed)" \
  || bad "dirty: the real .git/index was rewritten — a live lane would see it"

# (3) ⛔ THE REAL SEQUENCE: the rescue is called AGAIN after the grace period, on a CHANGED tree.
# This is the arm whose absence let a shipped defect through — every other case rescues once.
FIRST="$SHA"
printf 'written while the lane was dying\n' > "$D/wt/during-grace.txt"
OUT2="$(bash "$RR" "$D/wt" "second rescue, after the 20s grace period" 2>&1)"; RC2=$?
[ "$RC2" -eq 0 ] && ok "twice: the SECOND rescue exits 0 (a sibling commit would be rejected non-fast-forward)" \
                 || bad "twice: second rescue exit $RC2 (want 0) — $OUT2"
SHA2="$(git -C "$D/origin.git" rev-parse refs/wip/fix-lane-one 2>/dev/null)"
[ -n "$SHA2" ] && [ "$SHA2" != "$FIRST" ] \
  && ok "twice: origin's ref ADVANCED to the second snapshot" \
  || bad "twice: origin's ref did not advance (still $FIRST)"
has_blob "$D/origin.git" "$SHA2" during-grace.txt 'written while the lane was dying' \
  && ok "twice: the WORK WRITTEN DURING THE GRACE PERIOD is on origin (the whole point of the 2nd call)" \
  || bad "twice: grace-period work never reached origin"
git -C "$D/origin.git" merge-base --is-ancestor "$FIRST" "$SHA2" 2>/dev/null \
  && ok "twice: the FIRST snapshot is still reachable (the archive accumulates, it does not replace)" \
  || bad "twice: the first snapshot was orphaned by the second rescue"
has_blob "$D/origin.git" "$SHA2" untracked.txt 'brand new file' \
  && ok "twice: the earlier work is still in the second snapshot's tree too" \
  || bad "twice: the second snapshot lost the earlier untracked file"

echo; echo "── a worktree that does not exist, or is not a worktree ROOT, is refused ──"
OUT="$(bash "$RR" "$T/nope" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok "missing: exit 1" || bad "missing: exit $RC (want 1)"
case "$OUT" in
  *"not a worktree"*) ok "missing: says why" ;;
  *) bad "missing: no diagnosis — $OUT" ;;
esac
mkdir -p "$T/dirty/wt/sub/deeper"
OUT="$(bash "$RR" "$T/dirty/wt/sub/deeper" "misrouted" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] \
  && ok "subdir: a path INSIDE a worktree is refused with exit 1 (would otherwise push the enclosing repo and report success)" \
  || bad "subdir: exit $RC (want 1) — a misrouted path archived the wrong repo"

echo; echo "── an UNREADABLE status is AT RISK, never 'nothing at risk' ──"
mk_repo corrupt
K="$T/corrupt"
printf 'precious uncommitted work\n' > "$K/wt/precious.txt"
printf 'garbage-not-an-index' > "$K/wt/.git/index"          # e.g. a lane SIGKILLed mid git operation
OUT="$(bash "$RR" "$K/wt" "corrupt index" 2>&1)"; RC=$?
case "$OUT" in
  *"nothing at risk"*) bad "corrupt: reported 'nothing at risk' on an unreadable status — the one false success" ;;
  *) ok "corrupt: did NOT claim there was nothing at risk" ;;
esac
KSHA="$(git -C "$K/origin.git" rev-parse refs/wip/fix-lane-one 2>/dev/null)"
[ "$RC" -eq 0 ] && [ -n "$KSHA" ] \
  && ok "corrupt: still ARCHIVED and pushed (a failed read is not a reason to skip the rescue)" \
  || bad "corrupt: exit $RC and ref '${KSHA:-none}' — the work was not rescued"
[ -n "$KSHA" ] && { has_blob "$K/origin.git" "$KSHA" precious.txt 'precious uncommitted work' \
  && ok "corrupt: the content is on origin despite the unreadable index" \
  || bad "corrupt: the archived tree lacks the work"; }

echo; echo "── a lane that has NEVER COMMITTED is still rescued (the #2045 modal case) ──"
mkdir -p "$T/unborn"; git init -q --bare "$T/unborn/origin.git"
git clone -q "$T/unborn/origin.git" "$T/unborn/wt" 2>/dev/null
git -C "$T/unborn/wt" config user.email t@t; git -C "$T/unborn/wt" config user.name t
printf 'work from a lane that committed NOTHING\n' > "$T/unborn/wt/only-work.txt"
git -C "$T/unborn/wt" checkout -q -b fix/lane-unborn 2>/dev/null
OUT="$(bash "$RR" "$T/unborn/wt" "lane hit its cap" 2>&1)"; RC=$?
USHA="$(git -C "$T/unborn/origin.git" rev-parse refs/wip/fix-lane-unborn 2>/dev/null)"
[ "$RC" -eq 0 ] && [ -n "$USHA" ] \
  && ok "unborn: an unborn HEAD is archived (no 'cannot read HEAD tree' dead end)" \
  || bad "unborn: exit $RC, ref '${USHA:-none}' — a lane with no commits cannot be rescued — $OUT"
[ -n "$USHA" ] && { has_blob "$T/unborn/origin.git" "$USHA" only-work.txt 'committed NOTHING' \
  && ok "unborn: its content reached origin" || bad "unborn: content missing from the archive"; }

echo; echo "── ONE nested repo that cannot be staged must not abort the WHOLE rescue ──"
mk_repo nested
N2="$T/nested"
printf 'top-level work that must survive\n' > "$N2/wt/top.txt"
mkdir -p "$N2/wt/extra"; git -C "$N2/wt/extra" init -q 2>/dev/null   # nested repo, unborn HEAD
printf 'inner\n' > "$N2/wt/extra/inner.txt"
OUT="$(bash "$RR" "$N2/wt" "nested repo" 2>&1)"; RC=$?
NSHA="$(git -C "$N2/origin.git" rev-parse refs/wip/fix-lane-one 2>/dev/null)"
[ -n "$NSHA" ] && has_blob "$N2/origin.git" "$NSHA" top.txt 'top-level work that must survive' \
  && ok "nested: the superproject work IS archived (a nested repo no longer aborts everything)" \
  || bad "nested: exit $RC — the whole rescue was abandoned over one nested repo — $OUT"
case "$OUT" in
  *"nested repo"*|*"could NOT be archived"*|*"per path"*) ok "nested: the difficulty is REPORTED, not swallowed" ;;
  *) bad "nested: nothing said about the staged paths that were skipped" ;;
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

echo; echo "── a dispatcher that CALLS the rescue before it kills ──"
# The contract that matters in production: the watchdog must rescue, not just the rescuer work.
#
# ⛔ THE TARGET IS NOT IN THIS REPO. `scripts/bg-dispatch.sh` is unversioned (it exists in no commit)
# and this PR deliberately does not add it — the shipped harness already has a dispatch path, and
# agent-infra#2169 is the open fix in THAT path. So the arms below are pointed at whatever dispatcher
# the caller names, defaulting to the repo-relative path that #2169 is expected to version:
#
#   BG_DISPATCH=/path/to/bg-dispatch.sh bash scripts/bg-rescue-wip.test.sh   # run the 3 arms
#   BG_DISPATCH=/Users/home/orchestrator/bg/bg-dispatch.sh ...              # the live overlay
#
# When no dispatcher is present the arms SKIP — loudly, with the reason named, and NOT counted as
# passes. They are not dropped: they are the proof that the wiring is real, and they light up the
# moment a dispatcher is available. The rescue primitive's own contract above is unaffected and
# always gates.
DISPATCH="${BG_DISPATCH:-$HERE/bg-dispatch.sh}"
if [ ! -f "$DISPATCH" ]; then
  skip "no dispatcher at $DISPATCH — 3 wiring arms not run (set BG_DISPATCH to run them; #2169 versions the dispatcher)"
  skip "dispatch: the rescue is CALLED, not merely defined (not run)"
  skip "dispatch: rescue before the TERM / after the grace period (not run)"
else
  echo "    dispatcher: $DISPATCH"
  # ⛔ NOT a bare `grep bg-rescue-wip.sh`: that string already appears in the `_rescue()` DEFINITION,
  # so it matches a watchdog that defines the helper and never calls it. The arm must see CALLS.
  NCALLS="$(grep -o '_rescue;' "$DISPATCH" | wc -l | tr -d ' ')"
  [ "$NCALLS" -ge 2 ] \
    && ok "dispatch: the watchdog CALLS the rescue ($NCALLS call sites: a definition that is never called is not a rescue)" \
    || bad "dispatch: the rescue is defined but called $NCALLS time(s) — it never runs (#2045 unfixed)"
  NCALLED="$(grep -E '^[[:space:]]*[^#]*_rescue;' "$DISPATCH" | wc -l | tr -d ' ')"
  grep -qE '^[[:space:]]*[^#]*_rescue;[[:space:]]*kill -TERM' "$DISPATCH" \
    && ok "dispatch: the rescue runs BEFORE the TERM, on a live line (a commented-out call is not a rescue)" \
    || bad "dispatch: no rescue before TERM (or it is only in a comment)"
  grep -qE 'sleep [0-9]+;[[:space:]]*_rescue;[[:space:]]*kill -KILL' "$DISPATCH" \
    && ok "dispatch: a second rescue covers whatever was written during the grace period" \
    || bad "dispatch: no rescue after the grace period"
fi

echo; echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
if [ "$SKIP" -gt 0 ]; then
  echo "  ✅ contract holds — but $SKIP arm(s) SKIPPED (not passed). Re-run with BG_DISPATCH=<path> for the full set."
else
  echo "  ✅ contract holds (all $PASS arms ran, nothing skipped)"
fi
