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
#      ACCUMULATES: the second snapshot reaches origin and the first stays REACHABLE. The only arm
#      that can prove that is `merge-base --is-ancestor`; the others assert weaker facts and are named
#      for what they actually check, so a reader is not shown four greens for one property;
#   4. a failure is never reported as "nothing at risk": an unreadable status (including one that
#      prints NOTHING), an unborn HEAD, a nested repo with no commit, and a wrong path each have
#      their own required outcome.
#
# ⛔ TWO TRAPS THIS FILE ITSELF FELL INTO, both fixed and both worth keeping in mind:
#   - `git rev-parse <ref>` on a MISSING ref ECHOES THE ARGUMENT to stdout (rc=128), so it looks like a
#     successful lookup. Every lookup here is `rev-parse -q --verify`, and a bare-repo arm checks the
#     remote EXISTS before concluding "no refs were pushed".
#   - a witness computed through a missing tool (`shasum`) compares "" to "" and passes. Witnesses are
#     skipped loudly when their tool is absent.
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
# ref_of <repo> <ref> — the sha, or "" — never the echoed argument.
ref_of() { git -C "$1" rev-parse -q --verify "$2" 2>/dev/null; }
# n_refs <bare-repo> — the count, but only after proving the remote is there (an absent repo also
# yields 0, which would make "did not push" vacuous).
n_refs() {
  [ -d "$1" ] || { echo "NO_REPO"; return 1; }
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || { echo "NO_REPO"; return 1; }
  # ⛔ `grep -c` PRINTS 0 and EXITS 1 on empty input — `|| echo 0` appended a second 0 ("0\n0") and
  # broke every comparison. `|| true` keeps the single printed count.
  git -C "$1" for-each-ref refs/wip --format=x 2>/dev/null | grep -c '' 2>/dev/null || true
}

# mk_repo <name> — a bare "origin" plus a clone with one commit on branch fix/lane-one.
# Returns NON-ZERO if any step failed: with `set -uo pipefail` and no `-e`, a silent fixture failure
# would otherwise degrade an arm into a green assertion about nothing.
mk_repo() {
  local n="$1" d="$T/$1"
  mkdir -p "$d" || return 1
  git init -q --bare "$d/origin.git" || return 1
  git clone -q "$d/origin.git" "$d/wt" 2>/dev/null || return 1
  git -C "$d/wt" config user.email t@t || return 1
  git -C "$d/wt" config user.name t || return 1
  printf 'base\n' > "$d/wt/base.txt" || return 1
  git -C "$d/wt" add base.txt || return 1
  git -C "$d/wt" commit -qm "base" || return 1
  git -C "$d/wt" checkout -q -b fix/lane-one || return 1
  git -C "$d/wt" push -q -u origin fix/lane-one 2>/dev/null || return 1
}

echo; echo "── a CLEAN worktree has nothing at risk, and the rescue says so ──"
mk_repo clean || { echo "❌ fixture failed (clean)"; exit 1; }
OUT="$(bash "$RR" "$T/clean/wt" "test" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "clean: exit 0" || bad "clean: exit $RC (want 0)"
case "$OUT" in
  *"nothing at risk"*) ok "clean: reported as nothing at risk (not as a rescue)" ;;
  *) bad "clean: did not say nothing at risk — got: $OUT" ;;
esac
[ "$(n_refs "$T/clean/origin.git")" = "0" ] \
  && ok "clean: no ref pushed for a clean tree (and the remote was proven present, so 0 means 0)" \
  || bad "clean: pushed a ref for a clean tree, or the remote is missing"

echo; echo "── a CLEAN tree whose commit was never pushed says so, instead of implying it is safe ──"
printf 'committed but never pushed\n' > "$T/clean/wt/local-only.txt"
git -C "$T/clean/wt" add local-only.txt && git -C "$T/clean/wt" commit -qm "local only"
OUT="$(bash "$RR" "$T/clean/wt" "test" 2>&1)"
case "$OUT" in
  *"NOT archived"*|*"only locally"*)
    ok "unpushed: a clean tree with an UNPUSHED commit is named as NOT archived (not a bare 'nothing at risk')" ;;
  *) bad "unpushed: an unpushed commit was reported as nothing to worry about — $OUT" ;;
esac
[ "$(n_refs "$T/clean/origin.git")" = "0" ] \
  && ok "unpushed: no ref manufactured for committed-but-unpushed work (out of scope, and said so)" \
  || bad "unpushed: pushed a ref for work this tool does not claim to cover"

echo; echo "── a DIRTY worktree is archived with its CONTENT, and the branch does not move ──"
mk_repo dirty || { echo "❌ fixture failed (dirty)"; exit 1; }
D="$T/dirty"
printf 'the fix that would have been lost\n' >> "$D/wt/base.txt"     # unstaged edit
printf 'brand new file\n' > "$D/wt/untracked.txt"                    # untracked
BEFORE="$(ref_of "$D/wt" fix/lane-one)"; [ -n "$BEFORE" ] || { echo "❌ fixture: branch does not resolve"; exit 1; }
WT_BEFORE="$(git -C "$D/wt" status --porcelain | sort | tr '\n' '|')"
if command -v shasum >/dev/null 2>&1; then IDX_BEFORE="$(shasum "$D/wt/.git/index" | cut -d' ' -f1)"; else IDX_BEFORE=""; fi
OUT="$(bash "$RR" "$D/wt" "lane hit its 60s cap" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "dirty: exit 0 (rescued)" || bad "dirty: exit $RC (want 0) — $OUT"
case "$OUT" in
  *"refs/wip/fix-lane-one"*) ok "dirty: names the pushed ref (the recovery handle)" ;;
  *) bad "dirty: did not name the ref — $OUT" ;;
esac
case "$OUT" in
  *"(1 changed/untracked path(s))"*|*"(2 changed/untracked path(s))"*)
    ok "dirty: the reported path count is not 0 (the off-by-one that printed '0' on a real rescue)" ;;
  *"path(s)"*) bad "dirty: the path count is wrong (a single path read as '0 changed/untracked path(s)') — $OUT" ;;
  *) bad "dirty: no path count reported — $OUT" ;;
esac

# (1) the work reached ORIGIN — read it back from the bare remote, not from the local ref.
SHA="$(ref_of "$D/origin.git" refs/wip/fix-lane-one)"
[ -n "$SHA" ] && ok "dirty: refs/wip/fix-lane-one exists on ORIGIN (verified, not echoed)" \
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
[ "$(ref_of "$D/wt" fix/lane-one)" = "$BEFORE" ] \
  && ok "dirty: the BRANCH did not move (a rescue must not commit to the lane's branch)" \
  || bad "dirty: the branch moved — the rescue changed the state it was rescuing"
[ "$(git -C "$D/wt" status --porcelain | sort | tr '\n' '|')" = "$WT_BEFORE" ] \
  && ok "dirty: the WORKING TREE is unchanged (safe to run under a live lane)" \
  || bad "dirty: the working tree changed — the throwaway index leaked"
if [ -n "$IDX_BEFORE" ]; then
  [ "$(shasum "$D/wt/.git/index" | cut -d' ' -f1)" = "$IDX_BEFORE" ] \
    && ok "dirty: the REAL index is byte-identical (the same lane's next 'git commit' is not disturbed)" \
    || bad "dirty: the real .git/index was rewritten — a live lane would see it"
else
  skip "dirty: real-index witness needs shasum (absent here) — not asserting index bytes"
fi

# (3) ⛔ THE REAL SEQUENCE: the rescue is called AGAIN after the grace period, on a CHANGED tree.
# This is the arm whose absence let a shipped defect through — every other case rescued once.
printf 'written while the lane was dying\n' > "$D/wt/during-grace.txt"
OUT2="$(bash "$RR" "$D/wt" "second rescue, after the 20s grace period" 2>&1)"; RC2=$?
[ "$RC2" -eq 0 ] && ok "twice: the SECOND rescue exits 0 (with no chain it would be a rejected non-fast-forward)" \
                 || bad "twice: second rescue exit $RC2 (want 0) — $OUT2"
SHA2="$(ref_of "$D/origin.git" refs/wip/fix-lane-one)"
[ -n "$SHA2" ] && [ -n "$SHA" ] && [ "$SHA2" != "$SHA" ] \
  && ok "twice: origin's ref ADVANCED to the second snapshot" \
  || bad "twice: origin's ref did not advance"
has_blob "$D/origin.git" "$SHA2" during-grace.txt 'written while the lane was dying' \
  && ok "twice: the WORK WRITTEN DURING THE GRACE PERIOD is on origin (the whole point of the 2nd call)" \
  || bad "twice: grace-period work never reached origin"
has_blob "$D/origin.git" "$SHA2" untracked.txt 'brand new file' \
  && ok "twice: the second snapshot is COMPLETE (it still carries the earlier untracked file)" \
  || bad "twice: the second snapshot lost the earlier untracked file"
# ⛔ THE ONLY ARM THAT PROVES ACCUMULATION. Everything above is satisfied by a force-replacement too.
git -C "$D/origin.git" merge-base --is-ancestor "$SHA" "$SHA2" 2>/dev/null \
  && ok "twice: the FIRST snapshot is still REACHABLE from origin's ref (accumulate, never replace)" \
  || bad "twice: the first snapshot was ORPHANED by the second rescue"

# (3b) a THIRD rescue, and one after the branch gets a new commit (HEAD moves) — the chain must hold.
printf 'third\n' > "$D/wt/third.txt"
bash "$RR" "$D/wt" "third rescue" >/dev/null 2>&1; RC3=$?
printf 'a real commit between rescues\n' > "$D/wt/moved.txt"
git -C "$D/wt" add moved.txt >/dev/null 2>&1 && git -C "$D/wt" commit -qm "moved head" >/dev/null 2>&1
printf 'fourth\n' > "$D/wt/fourth.txt"
bash "$RR" "$D/wt" "rescue after the branch moved" >/dev/null 2>&1; RC4=$?
SHA_N="$(ref_of "$D/origin.git" refs/wip/fix-lane-one)"
[ "$RC3" -eq 0 ] && [ "$RC4" -eq 0 ] && [ -n "$SHA_N" ] \
  && git -C "$D/origin.git" merge-base --is-ancestor "$SHA" "$SHA_N" 2>/dev/null \
  && ok "chain: rescues 3 and 4 also succeed and the FIRST snapshot is still reachable after HEAD moved" \
  || bad "chain: a later rescue (rc3=$RC3 rc4=$RC4) broke the chain or orphaned the first snapshot"

# (3c) ⛔ THE CROSS-CLONE CASE — the one a FORCE push destroys. A second clone of the same origin has no
# local refs/wip-local/<slug>, so a forced push would replace the first clone's snapshot; a bare remote
# keeps no reflog, so the overwritten commit is gone at the next gc. Both must survive.
mk_repo xclone || { echo "❌ fixture failed (xclone)"; exit 1; }
X="$T/xclone"
printf 'from clone A\n' > "$X/wt/a-work.txt"
bash "$RR" "$X/wt" "clone A" >/dev/null 2>&1
A_SHA="$(ref_of "$X/origin.git" refs/wip/fix-lane-one)"
git clone -q "$X/origin.git" "$X/wt2" 2>/dev/null
git -C "$X/wt2" config user.email t@t; git -C "$X/wt2" config user.name t
git -C "$X/wt2" checkout -q -b fix/lane-one 2>/dev/null
printf 'from clone B\n' > "$X/wt2/b-work.txt"
OUTXB="$(bash "$RR" "$X/wt2" "clone B" 2>&1)"; RCXB=$?
B_SHA="$(ref_of "$X/origin.git" refs/wip/fix-lane-one)"
[ "$RCXB" -eq 0 ] && [ -n "$B_SHA" ] \
  && ok "xclone: a rescue from a SECOND clone succeeds (chained onto origin's snapshot)" \
  || bad "xclone: the second clone's rescue failed (rc=$RCXB) — $OUTXB"
[ -n "$A_SHA" ] && [ -n "$B_SHA" ] && git -C "$X/origin.git" merge-base --is-ancestor "$A_SHA" "$B_SHA" 2>/dev/null \
  && ok "xclone: clone A's snapshot is still reachable (a FORCE push here would have destroyed it)" \
  || bad "xclone: clone A's snapshot was DESTROYED by clone B's rescue"

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
mk_repo corrupt || { echo "❌ fixture failed (corrupt)"; exit 1; }
K="$T/corrupt"
printf 'precious uncommitted work\n' > "$K/wt/precious.txt"
printf 'garbage-not-an-index' > "$K/wt/.git/index"          # e.g. a lane SIGKILLed mid git operation
OUT="$(bash "$RR" "$K/wt" "corrupt index" 2>&1)"; RC=$?
case "$OUT" in
  *"nothing at risk"*) bad "corrupt: reported 'nothing at risk' on an unreadable status — the one false success" ;;
  *) ok "corrupt: did NOT claim there was nothing at risk" ;;
esac
KSHA="$(ref_of "$K/origin.git" refs/wip/fix-lane-one)"
[ "$RC" -eq 0 ] && [ -n "$KSHA" ] \
  && ok "corrupt: still ARCHIVED and pushed (a failed read is not a reason to skip the rescue)" \
  || bad "corrupt: exit $RC and ref '${KSHA:-none}' — the work was not rescued"
[ -n "$KSHA" ] && { has_blob "$K/origin.git" "$KSHA" precious.txt 'precious uncommitted work' \
  && ok "corrupt: the content is on origin despite the unreadable index" \
  || bad "corrupt: the archived tree lacks the work"; }

# ⛔ A status that fails and prints NOTHING. This is the arm that distinguishes "the exit code is
# checked" from "some error text happened to land on stdout" — without it the fail-open gate passed.
mk_repo silent || { echo "❌ fixture failed (silent)"; exit 1; }
SL="$T/silent"
printf 'the only copy\n' > "$SL/wt/precious2.txt"
mkdir -p "$T/silent/shim"
cat > "$T/silent/shim/git" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = status ] && exit 137; done
exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git "$@"
SHIM
chmod +x "$T/silent/shim/git"
OUT="$(PATH="$T/silent/shim:$PATH" bash "$RR" "$SL/wt" "silent status failure" 2>&1)"; RC=$?
case "$OUT" in
  *"nothing at risk"*)
    bad "silent: a status that fails with NO output was reported as 'nothing at risk' — the exit code is not being checked" ;;
  *) ok "silent: did NOT claim there was nothing at risk on a silent status failure" ;;
esac
SSHA="$(ref_of "$SL/origin.git" refs/wip/fix-lane-one)"
[ -n "$SSHA" ] && has_blob "$SL/origin.git" "$SSHA" precious2.txt 'the only copy' \
  && ok "silent: the work was still ARCHIVED (a silent failure is treated as AT RISK)" \
  || bad "silent: rc=$RC and nothing archived — the fail-open gate is still live"

echo; echo "── a lane that has NEVER COMMITTED is still rescued (the #2045 modal case) ──"
mkdir -p "$T/unborn"; git init -q --bare "$T/unborn/origin.git"
git clone -q "$T/unborn/origin.git" "$T/unborn/wt" 2>/dev/null
git -C "$T/unborn/wt" config user.email t@t; git -C "$T/unborn/wt" config user.name t
printf 'work from a lane that committed NOTHING\n' > "$T/unborn/wt/only-work.txt"
git -C "$T/unborn/wt" checkout -q -b fix/lane-unborn 2>/dev/null
OUT="$(/bin/bash "$RR" "$T/unborn/wt" "lane hit its cap" 2>&1)"; RC=$?
USHA="$(ref_of "$T/unborn/origin.git" refs/wip/fix-lane-unborn)"
[ "$RC" -eq 0 ] && [ -n "$USHA" ] \
  && ok "unborn: an unborn HEAD is archived under bash 3.2 (no 'cannot read HEAD tree' dead end)" \
  || bad "unborn: exit $RC, ref '${USHA:-none}' — a lane with no commits cannot be rescued — $OUT"
[ -n "$USHA" ] && { has_blob "$T/unborn/origin.git" "$USHA" only-work.txt 'committed NOTHING' \
  && ok "unborn: its content reached origin" || bad "unborn: content missing from the archive"; }

echo; echo "── ONE nested repo that cannot be staged must not abort the WHOLE rescue ──"
mk_repo nested || { echo "❌ fixture failed (nested)"; exit 1; }
N2="$T/nested"
printf 'top-level work that must survive\n' > "$N2/wt/top.txt"
mkdir -p "$N2/wt/extra"; git -C "$N2/wt/extra" init -q 2>/dev/null   # nested repo, unborn HEAD
printf 'inner\n' > "$N2/wt/extra/inner.txt"
OUT="$(bash "$RR" "$N2/wt" "nested repo" 2>&1)"; RC=$?
NSHA="$(ref_of "$N2/origin.git" refs/wip/fix-lane-one)"
[ -n "$NSHA" ] && has_blob "$N2/origin.git" "$NSHA" top.txt 'top-level work that must survive' \
  && ok "nested: the superproject work IS archived (a nested repo no longer aborts everything)" \
  || bad "nested: rc=$RC — the whole rescue was abandoned over one nested repo — $OUT"
# ⛔ THE EXIT CODE, not just the message: a partial archive leaves a path only on this disk, which the
# script's own contract calls exit 2. This arm previously never looked at $RC, so a partial rescue
# that returned 0 was green.
[ "$RC" -eq 2 ] \
  && ok "nested: the PARTIAL rescue exits 2 (the contract's 'work remains at risk'), not 0" \
  || bad "nested: rc=$RC (want 2) — a partial archive was reported as a complete rescue"
case "$OUT" in
  *"could NOT be archived"*) ok "nested: the loud 'could NOT be archived' line is present" ;;
  *) bad "nested: no 'could NOT be archived' line — $OUT" ;;
esac
case "$OUT" in
  *"extra/"*) ok "nested: the SKIPPED path is NAMED (not just 'something went wrong')" ;;
  *) bad "nested: the skipped path is not named — $OUT" ;;
esac

echo; echo "── a push that CANNOT happen exits 2 and refuses to read as success ──"
mk_repo nopush || { echo "❌ fixture failed (nopush)"; exit 1; }
N="$T/nopush"
printf 'work that cannot leave\n' > "$N/wt/stranded.txt"
git -C "$N/wt" remote set-url origin "$T/nopush/does-not-exist.git"   # unreachable
OUT="$(bash "$RR" "$N/wt" "test" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "nopush: exit 2 (the loud failure)" || bad "nopush: exit $RC (want 2) — $OUT"
case "$OUT" in
  *"STILL ONLY ON THIS DISK"*) ok "nopush: says the work is still only on this disk" ;;
  *) bad "nopush: did not warn that the work is still local — $OUT" ;;
esac
NP_SHA="$(ref_of "$N/wt" refs/wip-local/fix-lane-one)"
[ -n "$NP_SHA" ] && ok "nopush: still recorded LOCALLY, so the work is reachable in the repo" \
  || bad "nopush: no local ref either — the work is unreachable"
# the printed recovery handle must actually work once the remote is repaired
git -C "$N/wt" remote set-url origin "$T/nopush/origin.git"
if [ -n "$NP_SHA" ] && git -C "$N/wt" push -q origin "$NP_SHA:refs/wip/fix-lane-one" 2>/dev/null; then
  ok "nopush: the recorded local ref pushes cleanly once the remote is back (the retry path works)"
else
  bad "nopush: the local ref could not be pushed even after the remote was repaired"
fi

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
# passes. They are not dropped: they light up the moment a dispatcher is available.
#
# ⛔ THESE ARE TEXTUAL WIRING CHECKS AND NO STRONGER — read the ✅ as "a live-looking call is present",
# never as "the rescue runs". They accept a call with ARGUMENTS (`_rescue "$wt"`, which an earlier
# regex rejected) and ignore comments, `echo`/`printf` usage lines, and an `if false` dead branch
# (each of which satisfied an earlier, narrower regex while proving nothing). Two known FALSE PASSES
# remain and are NOT claimed away: a dispatcher whose `_rescue()` body is empty, and a call inside a
# dead branch that is not spelled `if false`. Proving the watchdog actually rescues needs a behavioural
# fixture with a stubbed `pi` and kill path, which is agent-infra#2169's surface (the shipped
# dispatcher), not this file's. What IS proven behaviourally here is the primitive itself — the
# `twice`, `chain` and `xclone` arms drive real rescues through a real bare remote.
# live_rescue_calls <file> — count `_rescue` occurrences that are actual calls.
live_rescue_calls() {
  awk '
    { line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/) next                                   # comment
      if (line ~ /^_rescue[[:space:]]*\(\)/) next             # the definition itself
      if (line ~ /(^|[^_[:alnum:]_])(echo|printf|say|log)[[:space:]]/) next   # a usage/message line
      if (line ~ /if[[:space:]]+(false|0)[[:space:]]*;/) next   # a dead branch (mid-line too)
      n = gsub(/(^|[^_[:alnum:]])_rescue([^_[:alnum:]]|$)/, "&", line)
      total += n }
    END { print total + 0 }' "$1" 2>/dev/null
}
# live_rescue_before <file> <signal> — a live line calling _rescue before `kill -SIG`.
live_rescue_before() {
  awk -v sig="$2" '
    { line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/) next
      if (line ~ /(^|[^_[:alnum:]_])(echo|printf|say|log)[[:space:]]/) next
      if (line ~ /if[[:space:]]+(false|0)[[:space:]]*;/) next
      r = index(line, "_rescue"); k = index(line, "kill -" sig)
      if (r > 0 && k > r) found = 1 }
    END { exit(found ? 0 : 1) }' "$1" 2>/dev/null
}
DISPATCH="${BG_DISPATCH:-$HERE/bg-dispatch.sh}"
if [ ! -f "$DISPATCH" ]; then
  skip "no dispatcher at $DISPATCH — 3 wiring arms not run (set BG_DISPATCH to run them; #2169 versions the dispatcher)"
  skip "dispatch: the rescue is CALLED, not merely defined (not run)"
  skip "dispatch: rescue before the TERM / after the grace period (not run)"
else
  echo "    dispatcher: $DISPATCH"
  NCALLS="$(live_rescue_calls "$DISPATCH")"
  [ "${NCALLS:-0}" -ge 2 ] \
    && ok "dispatch: the watchdog CALLS the rescue ($NCALLS call sites: a definition that is never called is not a rescue)" \
    || bad "dispatch: the rescue is defined but called ${NCALLS:-0} time(s) — it never runs (#2045 unfixed)"
  live_rescue_before "$DISPATCH" TERM \
    && ok "dispatch: a LIVE call runs before the TERM (comments, usage strings and dead branches are not rescues)" \
    || bad "dispatch: no live rescue before TERM"
  live_rescue_before "$DISPATCH" KILL \
    && ok "dispatch: a second live call covers whatever was written during the grace period" \
    || bad "dispatch: no live rescue after the grace period"
fi

echo; echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
if [ "$SKIP" -gt 0 ]; then
  echo "  ✅ contract holds — but $SKIP arm(s) SKIPPED (not passed). Re-run with BG_DISPATCH=<path> for the full set."
else
  echo "  ✅ contract holds (all $PASS arms ran, nothing skipped)"
fi
