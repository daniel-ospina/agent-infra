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

# assert_bounded_arm <fixture> <label> — both pushes of a retried rescue went through `bounded 45`.
# ⛔ ONE HELPER FOR ALL THREE PUSH FUNCTIONS (review round 6, P1). The assertion used to live inside
# `assert_unshadow_arm`, so it measured only the UNShadow path: deleting `bounded 45` from
# `push_with_helper` — the macOS default and every `BG_RESCUE_PUSH_HELPER` host — was fully green, i.e.
# an unbounded retry in the second before a cap kill. `bounded` resolves `timeout` through PATH and the
# fixture records every invocation, so the count is available on every arm.
assert_bounded_arm() { # assert_bounded_arm <fixture> <label> [<want>]
  local f="$T/$1" l="$2" want="${3:-2}" got
  got="$(grep -c '^45$' "$f/shim/timeout.log" 2>/dev/null)"
  [ "${got:-0}" = "$want" ] \
    && ok "$l: BOTH pushes ran under the 45 s bound (an unbounded retry can hang the pre-kill rescue)" \
    || bad "$l: ${got:-0} bounded push(es) recorded (want $want) — this retry path is UNBOUNDED"
  # ⛔ AND THE LOW-SPEED ABORT IS THE OTHER HALF OF "THE SAME BOUNDS" (review round 9, P2). `bounded 45`
  # is a WALL CLOCK; `-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20` is what ends an attempt on a
  # remote that accepts the connection and then stalls. Nothing asserted it, so deleting the pair from
  # either retry path was fully green — and a stalled retry then holds the pre-kill rescue for the full
  # 45 s instead of aborting after 20 s of no progress.
  local ls_bad=0 n=2 i=1 lo hi arg
  while [ "$i" -le "$n" ]; do
    lo=0; hi=0
    while IFS= read -r arg; do
      [ "$arg" = "http.lowSpeedLimit=1000" ] && lo=1
      [ "$arg" = "http.lowSpeedTime=20" ] && hi=1
    done < "$f/shim/argv.$i" 2>/dev/null
    [ "$lo" -eq 1 ] && [ "$hi" -eq 1 ] || ls_bad=1
    i=$((i+1))
  done
  [ "$ls_bad" -eq 0 ] \
    && ok "$l: every attempt carries the low-speed abort (a stalled remote ends the attempt, not the kill window)" \
    || bad "$l: an attempt is missing http.lowSpeedLimit/lowSpeedTime — a stalled remote holds the rescue for the full wall clock"
}

# assert_plain_untouched <fixture> <label> — the FIRST push consults the configured credential chain.
# ⛔ ATTEMPT 1 WAS NEVER CHECKED FOR HELPER TAMPERING (review round 10, P1). The unshadow arm asserted it
# for attempt 2 only, so re-introducing the shipped defect's shape (`-c credential.helper=` clearing the
# chain) on the PRIMARY path was fully green — and on a cell with no keychain and no ambient token that
# leaves `push_plain` with NO credential at all, i.e. every rescue degrading to local-only.
assert_plain_untouched() { # assert_plain_untouched <fixture> <label>
  local f="$T/$1" l="$2"
  if grep -q 'credential\.helper' "$f/shim/argv.1" 2>/dev/null; then
    bad "$l: the FIRST push touched the credential-helper list — it must consult what git is configured with: $(tr '\n' ' ' < "$f/shim/argv.1")"
  else
    ok "$l: the first push consults git's CONFIGURED credential chain (no helper override on the primary path)"
  fi
}

# assert_ambient_preserved <fixture> <label> — the HELPER retry runs in the SAME environment as the first
# push (review round 12, P3). `push_with_helper` is "the same push, one named helper" — it must NOT also
# strip the ambient token the way `push_unshadowed` deliberately does. Nothing asserted that, so adding
# `env -u GH_TOKEN -u GITHUB_TOKEN` to it was FULLY GREEN (measured `PASS=182 FAIL=0`, same as a correct
# tree) while silently breaking the seam's own documented contract ("trusted exactly as the caller is"):
# on a host whose workflow-scoped credential IS `GH_TOKEN` — the #3483/#3453 shapes this PR exists for —
# an operator who sets the documented escape hatch would get a retry that cannot see its credential, and
# the run would degrade to local-only with no arm to say so. The shim already records each attempt's
# `GH_TOKEN`/`GITHUB_TOKEN`, so the property is one comparison: attempt 2's token line is attempt 1's.
assert_ambient_preserved() { # assert_ambient_preserved <fixture> <label>
  local f="$T/$1" l="$2" e1 e2
  e1="$(grep '^GH_TOKEN=' "$f/shim/attempts.env.1" 2>/dev/null)"
  e2="$(grep '^GH_TOKEN=' "$f/shim/attempts.env.2" 2>/dev/null)"
  if [ -z "$e1" ] || [ -z "$e2" ]; then
    bad "$l: one attempt's environment was not recorded, so 'the helper retry keeps the ambient token' is unproven"
  elif [ "$e1" = "$e2" ]; then
    ok "$l: the helper retry runs with the ambient token INTACT (only the named helper differs)"
  else
    bad "$l: the helper retry changed the ambient environment ('$e1' -> '$e2') — the operator's seam must be trusted exactly as the caller is"
  fi
}

# mk_repo <name> — a bare "origin" plus a clone with one commit on branch fix/lane-one.
# Returns NON-ZERO if any step failed: with `set -uo pipefail` and no `-e`, a silent fixture failure
# would otherwise degrade an arm into a green assertion about nothing.
mk_repo() {
  local n="$1" br="${2:-fix/lane-one}" d="$T/$1"
  mkdir -p "$d" || return 1
  git init -q --bare "$d/origin.git" || return 1
  git clone -q "$d/origin.git" "$d/wt" 2>/dev/null || return 1
  git -C "$d/wt" config user.email t@t || return 1
  git -C "$d/wt" config user.name t || return 1
  printf 'base\n' > "$d/wt/base.txt" || return 1
  git -C "$d/wt" add base.txt || return 1
  git -C "$d/wt" commit -qm "base" || return 1
  git -C "$d/wt" checkout -q -b "$br" || return 1
  git -C "$d/wt" push -q -u origin "$br" 2>/dev/null || return 1
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
  *"(2 changed/untracked path(s))"*)
    ok "dirty: the reported path count is EXACTLY 2 (an off-by-one that said 1 for 2 paths is not green)" ;;
  *"path(s)"*) bad "dirty: the path count is wrong (2 dirty paths; the off-by-one and the '0' both fail here) — $OUT" ;;
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

# (4b) and now the SECOND rescue from each clone — the dispatcher's real sequence, interleaved.
printf 'A grace-period work\n' > "$X/wt/a2-grace.txt"
OUT_A2="$(bash "$RR" "$X/wt" "clone A post-grace" 2>&1)"; RC_A2=$?
# A's grace-period content is reachable from the ref AS IT STANDS NOW. Once B rescues, the tip carries
# B's tree and A's work is reachable through the CHAIN — so assert it here, before B runs, and assert
# ancestry afterwards. Checking the final tip's tree for A's file would be asserting the wrong thing.
TIP_A="$(ref_of "$X/origin.git" refs/wip/fix-lane-one)"
[ "$RC_A2" -eq 0 ] && [ -n "$TIP_A" ] && has_blob "$X/origin.git" "$TIP_A" a2-grace.txt 'A grace-period work' \
  && ok "xclone-twice: A's grace-period work reached origin" \
  || bad "xclone-twice: A's grace-period work never left the disk"
printf 'B grace-period work\n' > "$X/wt2/b2-grace.txt"
OUT_B2="$(bash "$RR" "$X/wt2" "clone B post-grace" 2>&1)"; RC_B2=$?
[ "$RC_A2" -eq 0 ] \
  && ok "xclone-twice: clone A's POST-GRACE rescue exits 0 (with the chain gated on 'no local ref', this was a permanent non-fast-forward)" \
  || bad "xclone-twice: clone A's post-grace rescue exit $RC_A2 — the chain is gated, so it wedged — $OUT_A2"
[ "$RC_B2" -eq 0 ] \
  && ok "xclone-twice: clone B's POST-GRACE rescue also exits 0" \
  || bad "xclone-twice: clone B's post-grace rescue exit $RC_B2 — $OUT_B2"
TIP2="$(ref_of "$X/origin.git" refs/wip/fix-lane-one)"
[ -n "$TIP2" ] && has_blob "$X/origin.git" "$TIP2" b2-grace.txt 'B grace-period work' \
  && ok "xclone-twice: B's grace-period work reached origin" \
  || bad "xclone-twice: B's grace-period work never left the disk"
[ -n "$A_SHA" ] && [ -n "$TIP2" ] && git -C "$X/origin.git" merge-base --is-ancestor "$A_SHA" "$TIP2" 2>/dev/null \
  && ok "xclone-twice: every earlier snapshot is still reachable from the final tip" \
  || bad "xclone-twice: an earlier snapshot was orphaned"

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
# ⛔ The shim must INTERCEPT and then exec the REAL git with the environment INTACT. An earlier version
# used `env -i`, which dropped GIT_INDEX_FILE — so the arm silently wrote the lane's REAL index,
# violating the invariant asserted three sections above, and could not detect a regression to
# staging into the real index.
REALGIT="$(command -v git)"
cat > "$T/silent/shim/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = status ] && exit 137; done
exec "$REALGIT" "\$@"
SHIM
chmod +x "$T/silent/shim/git"
if command -v shasum >/dev/null 2>&1; then SL_IDX_BEFORE="$(shasum "$SL/wt/.git/index" | cut -d' ' -f1)"; else SL_IDX_BEFORE=""; fi
OUT="$(PATH="$T/silent/shim:$PATH" bash "$RR" "$SL/wt" "silent status failure" 2>&1)"; RC=$?
case "$OUT" in
  *"nothing at risk"*)
    bad "silent: a status that fails with NO output was reported as 'nothing at risk' — the exit code is not being checked" ;;
  *) ok "silent: did NOT claim there was nothing at risk on a silent status failure" ;;
esac
if [ -n "${SL_IDX_BEFORE:-}" ]; then
  [ "$(shasum "$SL/wt/.git/index" | cut -d' ' -f1)" = "$SL_IDX_BEFORE" ] \
    && ok "silent: the REAL index is untouched on this path too (the shim no longer hides GIT_INDEX_FILE)" \
    || bad "silent: the real .git/index was rewritten on the silent-failure path"
else
  skip "silent: real-index witness needs shasum (absent here)"
fi
SSHA="$(ref_of "$SL/origin.git" refs/wip/fix-lane-one)"
[ -n "$SSHA" ] && has_blob "$SL/origin.git" "$SSHA" precious2.txt 'the only copy' \
  && ok "silent: the work was still ARCHIVED (a silent failure is treated as AT RISK)" \
  || bad "silent: rc=$RC and nothing archived — the fail-open gate is still live"

echo; echo "── an UNREADABLE path is AT RISK and makes the archive PARTIAL, never 'clean' ──"
mk_repo unreadable || { echo "❌ fixture failed (unreadable)"; exit 1; }
U="$T/unreadable"
mkdir -p "$U/wt/secret"
printf 'the only copy of this file\n' > "$U/wt/secret/only-copy.txt"
chmod 000 "$U/wt/secret" 2>/dev/null
printf 'visible work\n' > "$U/wt/visible.txt"
OUT="$(bash "$RR" "$U/wt" "unreadable dir" 2>&1)"; RC=$?
chmod 755 "$U/wt/secret" 2>/dev/null
case "$OUT" in
  *"nothing at risk"*)
    bad "unreadable: a directory git could not read was reported as 'nothing at risk' — the listing was incomplete" ;;
  *) ok "unreadable: did NOT claim the worktree was clean with an unreadable directory present" ;;
esac
[ "$RC" -eq 2 ] \
  && ok "unreadable: exits 2 (a path was NOT archived, so the contract says work remains at risk)" \
  || bad "unreadable: rc=$RC (want 2) — the unreadable path was silently dropped"
# The ISOLATED case: nothing else is dirty, so the ONLY reason to act is the unreadable directory.
# Without this arm, a script that ignores the warning still passes the block above (another dirty file
# keeps it at risk), which is exactly how the warning-blind version stayed green.
mk_repo unreadonly || { echo "❌ fixture failed (unreadonly)"; exit 1; }
UO="$T/unreadonly"
mkdir -p "$UO/wt/secret"
printf 'the only copy, in an unreadable dir\n' > "$UO/wt/secret/only.txt"
chmod 000 "$UO/wt/secret" 2>/dev/null
OUTO="$(bash "$RR" "$UO/wt" "only an unreadable dir" 2>&1)"; RCO=$?
chmod 755 "$UO/wt/secret" 2>/dev/null
case "$OUTO" in
  *"nothing at risk"*)
    bad "unreadable-only: a CLEAN listing plus an unreadable dir read as 'nothing at risk' — the warning was ignored" ;;
  *) ok "unreadable-only: an incomplete listing is NOT reported as a clean worktree" ;;
esac
[ "$RCO" -eq 2 ] \
  && ok "unreadable-only: exits 2 (the unreadable path was not archived)" \
  || bad "unreadable-only: rc=$RCO (want 2) — the unreadable path was treated as nothing to save"
USHA2="$(ref_of "$U/origin.git" refs/wip/fix-lane-one)"
[ -n "$USHA2" ] && has_blob "$U/origin.git" "$USHA2" visible.txt 'visible work' \
  && ok "unreadable: the READABLE work is still archived and pushed (a partial rescue beats none)" \
  || bad "unreadable: rc=$RC — the readable work was not archived either — $OUT"

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
# ⛔ `*"extra/"*` was satisfied by GIT'S OWN echoed "error: 'extra/' does not have a commit checked
# out", so a script that named nothing still passed. Match the line the SCRIPT composes for a path.
case "$OUT" in
  *"bg-rescue-wip:    extra/"*) ok "nested: the SKIPPED path is NAMED on the script's own loud line (not git's echoed error)" ;;
  *) bad "nested: the skipped path is not named by the script — $OUT" ;;
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

echo; echo "── a WORKFLOW-SCOPE refusal is retried ONCE with the credential that can push (#2292) ──"
# ⛔ THE DEFECT (agent-infra#2292): a fine-grained PAT without `Workflows: write` is refused by
# github.com for any snapshot touching `.github/workflows/`, so the rescue exited 2 "STILL ONLY ON THIS
# DISK" for EXACTLY the lanes whose work touches CI — while the osxkeychain credential on the same host
# could push the same ref. Measured: one snapshot stranded this way, and 52 branches blocked fleet-wide.
#
# The arms below run a stub `git` that models each refusal the REAL remote can give, because the whole
# question is a PREDICATE: which refusal justifies selecting a different credential, and which must go
# straight to the loud failure. Asserting "it retries" alone would pass a blanket retry, and a blanket
# retry turns an auth outage, a hook rejection or a network stall into a push attempted twice with the
# wrong credential — and, when the second attempt happens to succeed, into a GREEN run that hid the
# first cause. So each arm pins attempts, exit code, whether the ref landed, and the message.
REALGIT="$(command -v git)"
# mk_pushshim <dir> <mode> — a `git` that intercepts ONLY `push`; everything else execs real git with
# the environment intact (an `env -i` shim once hid GIT_INDEX_FILE and silently wrote the real index).
# It records every attempt's argv and which credential it selected, so "was it retried, and with what"
# is read from EVIDENCE, not from the message the script prints.
# Generated from a QUOTED heredoc with __TOKEN__ placeholders: an unquoted one turned `$(cat …)` into a
# generation-time substitution and `"$@"` into shell-quoting soup, i.e. the stub itself was broken.
mk_pushshim() { # mk_pushshim <dir> <mode>
  local d="$1" mode="$2" slug="$3"
  mkdir -p "$d" || return 1
  cat > "$d/git" <<'SHIM'
#!/usr/bin/env bash
REAL="__REALGIT__"
MODE="__MODE__"
SHDIR="__SHDIR__"
SLUG="__SLUG__"
ispush=0; iskey=0; helper=""
for a in "$@"; do
  [ "$a" = push ] && ispush=1
  # ⛔ ANY NAMED HELPER COUNTS, AND ITS NAME IS RECORDED (review round 4, P1). Hard-coding
  # `credential.helper=osxkeychain` in `push_with_helper` was FULLY GREEN, because every fixture pinned
  # that exact name — so `BG_RESCUE_PUSH_HELPER=<operator's store>` could be ignored while the message
  # still named it. The clearing argument (`credential.helper=`, empty) is not a helper selection.
  case "$a" in
    credential.helper=)  : ;;
    credential.helper=*) iskey=1; helper="${a#credential.helper=}" ;;
  esac
done
# The real github.com refusal, verbatim (backticks included) — so the matcher is tested on the text
# that actually arrives, not on a simplified version written to fit the regex.
wf_reject() {
  printf '%s\n' \
    "remote: error: GH013: refusing to allow a Personal Access Token to create or update workflow \`.github/workflows/ci.yml\` without \`workflow\` scope" \
    " ! [remote rejected] aaaaaaa -> refs/wip/$SLUG (pre-receive hook declined)" >&2
}
# A generic hook rejection that ECHOES the ref name. The trap for a `grep workflow` matcher: a branch
# merely NAMED "workflow" must not look like a scope refusal.
other_reject() {
  printf '%s\n' " ! [remote rejected] aaaaaaa -> refs/wip/$SLUG (pre-receive hook declined)" >&2
}
auth_reject() {
  printf '%s\n' "fatal: Authentication failed for 'https://github.com/example/repo.git/'" >&2
}
if [ "$ispush" -eq 1 ]; then
  n=0; [ -f "$SHDIR/attempts" ] && n=$(cat "$SHDIR/attempts")
  n=$((n+1))
  echo "$n" > "$SHDIR/attempts"
  printf '%s\n' "$@" > "$SHDIR/argv.$n"
  echo "GIT_TERMINAL_PROMPT=${GIT_TERMINAL_PROMPT:-unset}" >> "$SHDIR/attempts.env.$n"
  # ⛔ WHICH AMBIENT TOKEN THIS ATTEMPT SAW (#2292). The portable retry is "the same push with the
  # ambient GH_TOKEN/GITHUB_TOKEN removed", so an arm has to be able to prove the shadow was PRESENT on
  # attempt 1 and ABSENT on attempt 2. "It retried" alone passes an implementation that retries with the
  # IDENTICAL credential, which cannot succeed.
  echo "GH_TOKEN=${GH_TOKEN:-unset} GITHUB_TOKEN=${GITHUB_TOKEN:-unset}" >> "$SHDIR/attempts.env.$n"
  if [ "$iskey" -eq 1 ]; then echo keychain >> "$SHDIR/attempts.who"; echo "$helper" > "$SHDIR/attempts.helper.$n"; else echo plain >> "$SHDIR/attempts.who"; fi
  case "$MODE" in
    wf_then_ok)   [ "$iskey" -eq 1 ] || { wf_reject; exit 1; } ;;
    wf_always)    wf_reject; exit 1 ;;
    wf_then_auth) if [ "$iskey" -eq 1 ]; then auth_reject; exit 1; else wf_reject; exit 1; fi ;;
    # ⛔ THE CELL SHAPE (#3453/#3483): a stored credential that CAN push `workflow` files, shadowed by
    # an ambient token that cannot. The remote refuses while the shadow variable is set and accepts the
    # moment it is gone — so this mode measures whether the retry removed the shadow, not whether it
    # said the words.
    wf_shadowed)  if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then wf_reject; exit 1; fi ;;
    # ⛔ AND THE HELPER'S NAME IS PART OF THE CONTRACT (review round 4, P1): a remote whose credential
    # lives in `store` refuses anything else, so "the operator's named helper was actually used" is
    # measured rather than assumed from the message.
    wf_then_store) [ "$helper" = "store" ] || { wf_reject; exit 1; } ;;
    plain_ok)     : ;;
    other)        [ "$iskey" -eq 1 ] || { other_reject; exit 1; } ;;
    authfail)     auth_reject; exit 1 ;;
  esac
fi
exec "$REAL" "$@"
SHIM
  [ -f "$d/git" ] || return 1
  # Placeholders are substituted with awk (a value containing '/' or '&' must not corrupt the stub).
  awk -v real="$REALGIT" -v mode="$mode" -v d="$d" -v slug="$slug" '
    { gsub(/__REALGIT__/, real); gsub(/__MODE__/, mode); gsub(/__SHDIR__/, d); gsub(/__SLUG__/, slug); print }
  ' "$d/git" > "$d/git.new" && mv "$d/git.new" "$d/git" || return 1
  chmod +x "$d/git" || return 1
  # The stub must be syntactically valid BEFORE an arm depends on it: a broken stub fails as "not a
  # worktree", which reads like a rescue bug and hides the real one (measured in this file's own
  # development — a mangled heredoc produced five confident reds about the wrong thing).
  bash -n "$d/git" 2>/dev/null || { echo "❌ generated stub is not valid bash: $d/git"; return 1; }
  # ⛔ A `timeout` STUB, SO "THE RETRY IS TIME-BOUNDED" IS MEASURABLE (review round 5, P2).
  # `bg-rescue-wip.sh`'s own docblock claims all three push functions carry "the same bounds", and
  # deleting `bounded 45 ` from `push_unshadowed` was FULLY GREEN: only GIT_TERMINAL_PROMPT was pinned,
  # so half of "it cannot block the kill" was unasserted — and an unbounded retry is a hang in the
  # second before a cap kill. `bounded` resolves `timeout` through PATH, so recording here is enough.
  # On a host with no real `timeout` (macOS) the stub records and runs the command unbounded, which is
  # exactly what `bounded` does there anyway — so the arm is platform-neutral.
  local _realt; _realt="$(command -v timeout 2>/dev/null)"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s/timeout.log"\nif [ -n "%s" ]; then exec "%s" "$@"; fi\nshift\nexec "$@"\n' \
    "$d" "$_realt" "$_realt" > "$d/timeout" || return 1
  chmod +x "$d/timeout" || return 1
  # ⛔ A `uname` STUB, SO THE macOS DEFAULT IS EXECUTED ON THE HOST CI ACTUALLY RUNS (review round 11, P2).
  # `retry_credential`'s `uname = Darwin` candidate (`bg-rescue-wip.sh:393`) is the PRE-PR macOS behaviour
  # this change promises to PRESERVE, and every arm that asserted it was gated on the same `uname` — so on
  # Linux, which is every runner this repo has (`grep -rn 'runs-on' .github/workflows` has no macOS entry),
  # **deleting :393 left the suite at its baseline** (`PASS=177 FAIL=0`, measured) and so did hoisting the
  # `unshadow` fall-through above it. A green PR could therefore regress every Mac rescue to local-only —
  # the exact #2292 degradation — and nothing would say so. The script resolves `uname` through PATH and
  # the fixture already prepends this directory, so a stub that answers the value of `BG_TEST_UNAME_S`
  # executes the branch on ANY host: the arm stops being a property of the machine. With the variable
  # unset this delegates to the real `uname`, so no other arm changes behaviour.
  local _realu; _realu="$(command -v uname 2>/dev/null)"
  printf '#!/usr/bin/env bash\nif [ -n "${BG_TEST_UNAME_S:-}" ]; then printf "%%s\\n" "$BG_TEST_UNAME_S"; exit 0; fi\nif [ -n "%s" ]; then exec "%s" "$@"; fi\nexec uname "$@"\n' \
    "$_realu" "$_realu" > "$d/uname" || return 1
  chmod +x "$d/uname" || return 1
  bash -n "$d/timeout" 2>/dev/null || { echo "❌ generated timeout stub is not valid bash: $d/timeout"; return 1; }
  return 0
}
# try_rescue <fixture> <mode> [<branch>] [<retry-env>] — build a worktree that touches
# .github/workflows, run the rescue under the stub, and export RC/OUT/ATTEMPTS/WHO for the assertions.
# ⛔ THE RETRY CREDENTIAL IS PINNED FOR EVERY FIXTURE, ON PURPOSE. `retry_credential` picks per HOST
# (osxkeychain on macOS, else "unshadow" an ambient token, else nothing), so an arm that asserts a
# specific credential SHAPE would pass on one platform and fail on the other for reasons that have
# nothing to do with the code — and the arms that assert `attempts=2` would be host-dependent too. The
# fixture therefore pins the operator seam (`BG_RESCUE_PUSH_HELPER=osxkeychain`), which is also how the
# macOS default is spelled. Arms that must exercise the DEFAULT selection pass `<retry-env>` explicitly
# (an empty value means "no override"), and they assert the outcome they require rather than a shape.
try_rescue() { # try_rescue <name> <mode> <branch> <retry-env>
  local n="$1" mode="$2" br="${3:-fix/lane-one}" renv="${4-BG_RESCUE_PUSH_HELPER=osxkeychain}" d="$T/$1"
  mk_repo "$n" || { echo "❌ fixture failed ($n)"; return 1; }
  if [ "$br" != "fix/lane-one" ]; then git -C "$d/wt" checkout -q -b "$br"; fi
  mkdir -p "$d/wt/.github/workflows"
  printf 'name: ci\non: push\n' > "$d/wt/.github/workflows/ci.yml"
  printf 'the work the rescue exists for\n' > "$d/wt/lane-work.txt"
  # The stub embeds the ref slug it refuses, so its rejection text echoes the REAL ref name — that is
  # what makes the "workflow-NAMED branch" arm a genuine test of the matcher.
  local slug; slug="$(printf '%s' "$br" | tr '/' '-')"
  mk_pushshim "$d/shim" "$mode" "$slug" || { echo "❌ shim failed ($n)"; return 1; }
  CFG_BEFORE="$(git -C "$d/wt" config --list --show-origin 2>/dev/null | sort)"
  # `$renv` is a deliberately word-split list of `env` arguments (an override assignment, or `-u VAR`)
  # owned by this file's own arms — never caller data.
  # ⛔ GIT_TERMINAL_PROMPT IS PINNED HOSTILE, NOT INHERITED (review round 9, P1). The assertion that the
  # retry runs with `GIT_TERMINAL_PROMPT=0` read the value git INHERITED — and pi's own bash tool exports
  # `GIT_TERMINAL_PROMPT=0` for every tool call, so the arm was satisfied by the ambient env and deleting
  # the export from BOTH retry branches was fully green (measured: green with the ambient value, red only
  # under `env -u`). Setting it to `1` here makes the arm prove the script OVERRIDES a hostile parent,
  # which is the actual property, on every host and every runner.
  # ⛔ EVERY `-u` COMES BEFORE EVERY ASSIGNMENT — INCLUDING THIS ONE. `$renv` may START with `-u`, so
  # the hostile pin has to be split: the unset goes FIRST, the assignment LAST. Writing
  # `env -u X X=1 $renv …` made `env` exec `-u` (rc 127) on every arm — measured, 57 reds — the same
  # POSIX option-order trap this file records elsewhere.
  OUT="$(env -u GIT_TERMINAL_PROMPT $renv GIT_TERMINAL_PROMPT=1 PATH="$d/shim:$PATH" bash "$RR" "$d/wt" "workflow-bearing lane killed" 2>&1)"; RC=$?
  ATTEMPTS=0; [ -f "$d/shim/attempts" ] && ATTEMPTS="$(cat "$d/shim/attempts")"
  WHO=""; [ -f "$d/shim/attempts.who" ] && WHO="$(tr '\n' ' ' < "$d/shim/attempts.who")"
  return 0
}

# (1) THE DEFECT ITSELF: a workflow-scope refusal, a keychain credential that works.
try_rescue wfretry wf_then_ok
assert_bounded_arm wfretry wfretry
assert_plain_untouched wfretry wfretry
assert_ambient_preserved wfretry wfretry
WSHA="$(ref_of "$T/wfretry/origin.git" refs/wip/fix-lane-one)"
[ "$RC" -eq 0 ] \
  && ok "wfretry: exit 0 — a workflow-bearing snapshot is RESCUED, not degraded to local-only" \
  || bad "wfretry: exit $RC (want 0) — the credential that can push was never tried — $OUT"
[ "${ATTEMPTS:-0}" = "2" ] \
  && ok "wfretry: exactly TWO push attempts (one plain, one with the keychain credential)" \
  || bad "wfretry: ${ATTEMPTS:-0} push attempt(s) (want exactly 2) — no retry, or a retry storm"
[ "${WHO:-}" = "plain keychain " ] \
  && ok "wfretry: the retry used the KEYCHAIN credential (sameness of the two attempts is not enough)" \
  || bad "wfretry: the retry did not select the keychain credential — attempts were: ${WHO:-none}"
[ -n "$WSHA" ] && has_blob "$T/wfretry/origin.git" "$WSHA" .github/workflows/ci.yml 'name: ci' \
  && ok "wfretry: the WORKFLOW FILE ITSELF reached origin (the content that used to strand the snapshot)" \
  || bad "wfretry: origin has no snapshot carrying the workflow file (ref: ${WSHA:-none})"
[ -n "$WSHA" ] && has_blob "$T/wfretry/origin.git" "$WSHA" lane-work.txt 'the work the rescue exists for' \
  && ok "wfretry: the lane's other work is in the same snapshot" \
  || bad "wfretry: the lane's work is missing from the published snapshot"
# ⛔ A rescue may never FORCE, and may never write credential config. Both are asserted on the
# recorded argv and on the repo's own config, not on the message that claims it.
# ⛔ THE ORDERED PAIR, NOT THE PRESENCE OF EACH FLAG. `-c credential.helper=` CLEARS the configured
# helper list and `-c credential.helper=osxkeychain` then names the one to use; the order is the whole
# mechanism. This arm had two `ok` branches, so deleting the clear (the retry then re-uses the SAME
# scope-less PAT and #2292 is unchanged) and reversing the pair (the retry ends with an EMPTY helper
# list) both stayed GREEN — found by two independent fresh reviewers, each by mutation. Every shape
# except clear-then-name is now a failure.
# ⛔ NO FORCE, ON EITHER ATTEMPT, CHECKED PER ARGUMENT. The old pattern `*"+refs/"*` is DEAD for this
# script's refspec: its source side is a raw sha, so the force form is `+<sha>:refs/wip/<slug>`, which
# contains no `+refs/`. A fresh reviewer's mutation (`"+$C:refs/wip/$SLUG"`) was GREEN — and a forced
# push is the one thing that can destroy a peer clone's snapshot, so this is the arm that must not be
# vacuous. Every recorded argument is checked, on both attempts, and the two attempts must carry the
# IDENTICAL refspec: a retry that publishes a different refspec than the first push is not a retry.
wf_force=0
for _n in 1 2; do
  _p="$T/wfretry/shim/argv.$_n"
  # ⛔ THE PATTERN MUST MATCH EVERY FORCE SPELLING, INCLUDING THE TWO `--force-*` FORMS (review round 3,
  # P2). `--force$` let `--force-with-lease` and `--force-if-includes` through GREEN — measured — and
  # `--force-with-lease` is precisely what a fixer adds when a peer clone moved `refs/wip/<slug>`, i.e.
  # the one force this arm exists to refuse. `--force` as a PREFIX covers all three spellings.
  if [ -f "$_p" ] && grep -qE '^(\+|-f$|-[fF]$|--force)' "$_p" 2>/dev/null; then
    wf_force=1; bad "wfretry: attempt $_n used a FORCE form (a forced rescue can overwrite a peer clone's snapshot): $(tr '\n' ' ' < "$_p")"
  fi
done
[ "$wf_force" -eq 0 ] && ok "wfretry: NEITHER attempt carries a force form (per-argument, so a '+<sha>:refs/…' force is caught)"
RS1="$(tail -1 "$T/wfretry/shim/argv.1" 2>/dev/null)"
RS2="$(tail -1 "$T/wfretry/shim/argv.2" 2>/dev/null)"
[ -n "$RS1" ] && [ "$RS1" = "$RS2" ] \
  && ok "wfretry: both attempts push the SAME refspec (the retry cannot publish something the first would not)" \
  || bad "wfretry: the retry's refspec differs from the first push's ('${RS1:-none}' vs '${RS2:-none}')"
case "$RS2" in
  [0-9a-f][0-9a-f]*) ok "wfretry: the refspec's source is a commit sha (not a ref or a force ref)" ;;
  *) bad "wfretry: the retry's refspec does not start with a commit sha — $RS2" ;;
esac
if [ -f "$T/wfretry/shim/argv.2" ]; then
  ARGV2="$(tr '\n' ' ' < "$T/wfretry/shim/argv.2")"
  case "$ARGV2" in
    *"-c credential.helper= -c credential.helper=osxkeychain"*)
      ok "wfretry: the retry CLEARS the configured helpers and then names the keychain one, in that order (no config write)" ;;
    *) bad "wfretry: the retry does not clear-then-name the helper (no clear re-uses the scope-less token; a reversed pair leaves an EMPTY helper list) — $ARGV2" ;;
  esac
else
  bad "wfretry: no recorded argv for the second attempt — the retry cannot be inspected"
fi
# ⛔ THE RETRY MAY NOT PROMPT: it runs in the second before a cap kill, so an absent keychain entry must
# FAIL rather than wait on a terminal nobody is watching. The script's own comment promises this; without
# this arm, deleting the `export GIT_TERMINAL_PROMPT=0` was green (a fresh reviewer's mutation).
grep -qx 'GIT_TERMINAL_PROMPT=0' "$T/wfretry/shim/attempts.env.2" 2>/dev/null \
  && ok "wfretry: the retry ran with GIT_TERMINAL_PROMPT=0 (it cannot block the kill on a prompt)" \
  || bad "wfretry: the retry did not disable the terminal prompt — a missing keychain entry could hang the rescue"
# ⛔ ALL SCOPES, not `--local`: a write to `$HOME/.gitconfig` would be invisible to `--local` and would
# also PERSIST on the machine that ran the suite. `--show-origin` names the file it came from.
[ "$(git -C "$T/wfretry/wt" config --list --show-origin 2>/dev/null | sort)" = "$CFG_BEFORE" ] \
  && ok "wfretry: git config is byte-identical at EVERY scope after the retry (read-only rescue, global included)" \
  || bad "wfretry: the rescue WROTE git config (any scope) — a rescue must not change the state it is rescuing"
# ⛔ THE SUCCESS LINE ITSELF, NOT A SUBSTRING ANYWHERE IN THE OUTPUT (review round 10, P2). The mid-run
# ANNOUNCE line ("retrying ONCE with the osxkeychain credential …") also contains the name, so a success
# line that named the wrong credential — or dropped the claim — stayed green.
case "$OUT" in
  *"pushed with the osxkeychain credential after the configured one was refused"*)
    ok "wfretry: the SUCCESS line names the credential that published it (a clean run must not imply the PAT worked)" ;;
  *) bad "wfretry: the success line does not name the credential it used — $OUT" ;;
esac
# ⛔ THE SHA IN THE MESSAGE IS THE SHA THAT WAS PUSHED. A message printing a re-chained or shortened sha
# hands the operator a handle that does not resolve — and the failure hint recommends exactly that retry.
# awk reads the input to EOF and takes the FIRST match itself: a `sed … | head -1` pipeline relies on a
# short write, and under `set -o pipefail` an early-exiting consumer turns a MATCHING line into rc=141 —
# the same SIGPIPE false negative `scripts/check-no-sigpipe-grep.sh` exists to keep out of the tree.
CLAIMED="$(printf '%s\n' "$OUT" | awk '
  found == "" && match($0, /refs\/wip\/[^ ]* \([0-9a-f]+\)/) {
    t = substr($0, RSTART, RLENGTH); if (match(t, /\([0-9a-f]+\)/)) found = substr(t, RSTART+1, RLENGTH-2) }
  END { print found }')"
[ -n "$CLAIMED" ] && [ "$CLAIMED" = "$WSHA" ] \
  && ok "wfretry: the sha the message claims is the sha origin's ref actually holds (a usable recovery handle)" \
  || bad "wfretry: the claimed sha '${CLAIMED:-none}' is not origin's '${WSHA:-none}' — the message names a handle that does not resolve"

# (1b) ⛔ THE OPPOSITE DIRECTION OF THE SUCCESS MESSAGE. A plain first-attempt push must NOT be reported
# as a retried push: an implementation that prints the credential claim on BOTH success branches passed
# the arm above, and would tell an operator the scope-less token works on a run where it was never used.
# ⛔ AN EXACT MATCH, NOT A DENY-LIST (review round 10, P2). This arm used to reject only `OSXKEYCHAIN`,
# so a plain success that claimed ANY OTHER credential — `— pushed with the STORED credential`, the
# mutant below — was fully green (measured: PASS=162 FAIL=0, the same counts as a correct tree). The
# property is not "names no keychain", it is "names no credential at all", and the only form that
# proves it is the success line in its one legal shape: this path has exactly one attempt, so there is
# nothing for it to attribute the push to. Matching the WHOLE line is what makes an added clause of any
# wording red, instead of a deny-list the next credential name walks straight past.
try_rescue plainok plain_ok
[ "$RC" -eq 0 ] && [ "${ATTEMPTS:-0}" = "1" ] \
  && ok "plainok: a first-attempt success is one attempt, exit 0" \
  || bad "plainok: rc=$RC attempts=${ATTEMPTS:-0} (want 0 and 1)"
PLAIN_SHA="$(ref_of "$T/plainok/origin.git" refs/wip/fix-lane-one)"
PLAIN_LINE="bg-rescue-wip: rescued fix/lane-one → origin refs/wip/fix-lane-one ($PLAIN_SHA)"
if [ -z "$PLAIN_SHA" ]; then
  bad "plainok: origin holds no refs/wip/fix-lane-one — the plain-success message cannot be checked"
elif grep -qxF "$PLAIN_LINE" <<<"$OUT"; then
  ok "plainok: the non-retried success line names NO credential — it is exactly the plain form"
else
  bad "plainok: a push that was NEVER retried does not print the plain success line — want '$PLAIN_LINE', got: $OUT"
fi

# (2) ⛔ A NON-WORKFLOW rejection is NOT retried. The stub would SUCCEED on the keychain attempt, so a
# blanket retry reports a false GREEN here — and the branch is named "workflow-scope" so the rejection
# text echoes the word, which is what a `grep workflow` matcher would trip over.
try_rescue noscopeblind other fix/workflow-scope
NSHA="$(ref_of "$T/noscopeblind/origin.git" refs/wip/fix-workflow-scope)"
[ "$RC" -eq 2 ] \
  && ok "noscopeblind: a hook rejection of a workflow-NAMED branch exits 2 (not retried into a green run)" \
  || bad "noscopeblind: exit $RC (want 2) — a non-workflow rejection was retried — $OUT"
[ "${ATTEMPTS:-0}" = "1" ] \
  && ok "noscopeblind: exactly ONE attempt (only a workflow-SCOPE refusal may select a credential)" \
  || bad "noscopeblind: ${ATTEMPTS:-0} attempts — the retry is gated on \"the push failed\", not on the refusal"
[ -z "$NSHA" ] \
  && ok "noscopeblind: nothing was published, so the exit 2 is true (a retry here WOULD have pushed a ref)" \
  || bad "noscopeblind: a ref landed on origin while the run reported failure — a false success"
case "$OUT" in
  *"STILL ONLY ON THIS DISK"*) ok "noscopeblind: still names the work as at risk" ;;
  *) bad "noscopeblind: the at-risk warning is missing — $OUT" ;;
esac
case "$OUT" in
  *"cause: REMOTE REJECTED THE UPDATE"*) ok "noscopeblind: names the CAUSE as a remote rejection (not a bare 'push failed')" ;;
  *) bad "noscopeblind: the failure does not name its cause — $OUT" ;;
esac

# (3) the retry is tried ONCE, and a second refusal is reported as a failure with BOTH causes — never as
# a success, and never as an endless loop.
try_rescue wfalways wf_always
WASHA="$(ref_of "$T/wfalways/origin.git" refs/wip/fix-lane-one)"
[ "$RC" -eq 2 ] \
  && ok "wfalways: exit 2 when even the keychain credential is refused (no false success)" \
  || bad "wfalways: exit $RC (want 2) — a refused retry was reported as a rescue — $OUT"
[ "${ATTEMPTS:-0}" = "2" ] \
  && ok "wfalways: exactly ONE retry (a refused retry must not loop)" \
  || bad "wfalways: ${ATTEMPTS:-0} attempt(s) (want exactly 2)"
[ -z "$WASHA" ] \
  && ok "wfalways: no ref reached origin, consistent with the exit code" \
  || bad "wfalways: a ref landed on origin while the run reported failure"
case "$OUT" in
  *"cause: WORKFLOW SCOPE"*) ok "wfalways: names WORKFLOW SCOPE as the first cause" ;;
  *) bad "wfalways: does not name the workflow-scope cause — $OUT" ;;
esac
case "$OUT" in
  *"ALSO failed"*) ok "wfalways: reports the retry's own outcome instead of hiding it" ;;
  *) bad "wfalways: says nothing about the retry's own failure — $OUT" ;;
esac
# ⛔ AND IT MUST NOT ALSO SAY THE OPPOSITE (review round 8, P2). The at-risk block's two diagnoses are
# mutually exclusive — "retried ONCE with <cred> — it ALSO failed" and "no second credential was tried" —
# and only the PRESENCE of each was asserted, on the arm where it belongs. Hoisting `NO_SECOND=1` (the
# mirror of round 6's hoisted `RETRIED=1`) printed both, the second factually false on that host, with
# the suite green. Every retried-failure arm asserts the other arm's line is ABSENT.
case "$OUT" in
  *"no second credential was tried"*)
    bad "wfalways: claims NO second credential after a retry DID run — two mutually exclusive diagnoses — $OUT" ;;
  *) ok "wfalways: does not also claim there was no second credential (the two diagnoses are exclusive)" ;;
esac
case "$OUT" in
  *"rescued"*) bad "wfalways: claimed a rescue that did not happen — $OUT" ;;
  *) ok "wfalways: does not claim a rescue it did not perform" ;;
esac

# (3b) ⛔ THE FIRST CAUSE SURVIVES THE RETRY. The stub refuses the first attempt for WORKFLOW SCOPE and
# the retry for AUTHENTICATION — a different reason. Reporting only the LAST cause sends the operator
# after a keychain entry that is fine while the real blocker (the token's scope) goes unnamed; that
# implementation passed the `wfalways` arm, where both attempts fail for the SAME reason.
try_rescue wfthenauth wf_then_auth
[ "$RC" -eq 2 ] && [ "${ATTEMPTS:-0}" = "2" ] \
  && ok "wfthenauth: exit 2 after exactly one retry" \
  || bad "wfthenauth: rc=$RC attempts=${ATTEMPTS:-0} (want 2 and 2)"
case "$OUT" in
  *"cause: WORKFLOW SCOPE"*) ok "wfthenauth: the FIRST cause (workflow scope) is still named" ;;
  *) bad "wfthenauth: the first cause was overwritten by the retry's — $OUT" ;;
esac
case "$OUT" in
  *"ALSO failed"*AUTHENTICATION*|*AUTHENTICATION*"ALSO failed"*)
    ok "wfthenauth: the retry's DIFFERENT cause is reported separately (both reasons reachable to the operator)" ;;
  *) bad "wfthenauth: the retry's own cause is not reported alongside the first — $OUT" ;;
esac
# ⛔ ORDER, NOT PRESENCE (review round 4, P2). The assertion above accepts EITHER ordering, so swapping
# WHY[0] and WHY[1] — printing the retry's cause first, which is the wrong operator action — was fully
# green. The first attempt's cause must come FIRST in the output.
WF_FIRST_LINE="$(printf '%s\n' "$OUT" | awk '/cause: WORKFLOW SCOPE/ {print NR; exit}')"
WF_RETRY_LINE="$(printf '%s\n' "$OUT" | awk '/ALSO failed/ {print NR; exit}')"
[ -n "$WF_FIRST_LINE" ] && [ -n "$WF_RETRY_LINE" ] && [ "$WF_FIRST_LINE" -lt "$WF_RETRY_LINE" ] \
  && ok "wfthenauth: the FIRST cause is printed BEFORE the retry's (line $WF_FIRST_LINE vs $WF_RETRY_LINE)" \
  || bad "wfthenauth: the retry's cause prints before the first (lines '${WF_FIRST_LINE:-none}' vs '${WF_RETRY_LINE:-none}') — the operator is sent after the wrong cause"
# ⛔ AND THE MIRROR (review round 8, P2): a retried-failure run must not ALSO claim there was no second
# credential. Only the PRESENCE of each diagnosis was asserted, on the arm where it belongs, so hoisting
# `NO_SECOND=1` (the mirror of round 6's hoisted `RETRIED=1`) printed both — the second factually false
# on that host — with the suite green.
case "$OUT" in
  *"no second credential was tried"*)
    bad "wfthenauth: claims NO second credential after a retry DID run — two mutually exclusive diagnoses — $OUT" ;;
  *) ok "wfthenauth: does not also claim there was no second credential (the two diagnoses are exclusive)" ;;
esac
[ -z "$(ref_of "$T/wfthenauth/origin.git" refs/wip/fix-lane-one)" ] \
  && ok "wfthenauth: nothing published, consistent with the failure" \
  || bad "wfthenauth: a ref landed while the run reported failure"

# (4) the cause is NAMED for the ordinary failures too (#2292, item 2) — 'the push failed' is what sent a
# diagnosis cycle after the wrong cause.
try_rescue authbad authfail
[ "$RC" -eq 2 ] && ok "authbad: exit 2" || bad "authbad: exit $RC (want 2)"
[ "${ATTEMPTS:-0}" = "1" ] \
  && ok "authbad: an AUTH failure is not retried (a different credential would not be the fix)" \
  || bad "authbad: ${ATTEMPTS:-0} attempts — an auth failure took the workflow-scope retry path"
case "$OUT" in
  *"cause: AUTHENTICATION"*) ok "authbad: names AUTHENTICATION as the cause" ;;
  *) bad "authbad: does not name the auth cause — $OUT" ;;
esac

echo; echo "── the retry's CREDENTIAL is chosen per host and never re-sends the refused one (#2292) ──"
# ⛔ THE SHIPPED RETRY NAMED `osxkeychain` UNCONDITIONALLY. That helper exists only on macOS, so on a
# Linux cell — every cell in this fleet, and the host class a lane is most likely to be reaped on — the
# retry could never succeed, AND `-c credential.helper=` had already cleared the helper the box does
# have, closing the only path to an off-box credential it had. The measured cell shape is not "no
# credential exists" but "a stored credential that can push is SHADOWED by an ambient token that
# cannot" (#3483 voided a review exactly this way; #3453 resolved a read-only PAT exactly this way), and
# no push output says which of the two git used.
#
# These arms therefore measure AVAILABILITY (does the workflow-bearing snapshot reach origin on a host
# with no osxkeychain), not the wording of a message.
#
# ⛔ AND EACH ARM RUNS ONLY WHERE ITS CANDIDATE EXISTS. The first draft of this block asserted the
# unshadow MECHANISM unconditionally, so on macOS — where the DEFAULT candidate is osxkeychain — it went
# red on a CORRECT tree (4 false reds, and the Darwin branch was green nowhere: red on the Mac, dead
# code on Linux). A fresh reviewer reproduced it by flipping the platform comparisons. There are now
# three arms, and every one of them is green on the platform whose branch it covers:
#   wfshadow   — the DEFAULT unshadow candidate (non-Darwin)
#   wfunshadow — the candidate ASKED FOR (`BG_RESCUE_PUSH_UNSHADOW=1`), on every platform — which is
#                also the only way to reach it on macOS, and is what makes that seam tested
#   wfhelper   — the macOS DEFAULT (`osxkeychain`), on Darwin
assert_unshadow_arm() { # assert_unshadow_arm <fixture> <label> <attempt-1 token line>
  local f="$T/$1" l="$2" tok1="$3" sha r1 r2 force=0 p
  sha="$(ref_of "$f/origin.git" refs/wip/fix-lane-one)"
  [ "$RC" -eq 0 ] \
    && ok "$l: exit 0 — the snapshot is RESCUED with no osxkeychain anywhere" \
    || bad "$l: exit $RC (want 0) — the retry did not reach the stored credential — $OUT"
  [ "${ATTEMPTS:-0}" = "2" ] \
    && ok "$l: exactly TWO attempts (one shadowed, one with the shadow removed)" \
    || bad "$l: ${ATTEMPTS:-0} attempt(s) (want exactly 2) — no retry, or a retry storm"
  grep -qx "$tok1" "$f/shim/attempts.env.1" 2>/dev/null \
    && ok "$l: attempt 1 really ran SHADOWED by the ambient token (so the arm is not vacuous)" \
    || bad "$l: attempt 1 did not see the shadow token '$tok1' — the fixture proves nothing: $(cat "$f/shim/attempts.env.1" 2>/dev/null)"
  grep -qx 'GH_TOKEN=unset GITHUB_TOKEN=unset' "$f/shim/attempts.env.2" 2>/dev/null \
    && ok "$l: attempt 2 ran with the ambient token REMOVED (that removal is the mechanism)" \
    || bad "$l: attempt 2 still carried the ambient token — the retry re-sent the credential that was just refused: $(cat "$f/shim/attempts.env.2" 2>/dev/null)"
  [ -n "$sha" ] && has_blob "$f/origin.git" "$sha" .github/workflows/ci.yml 'name: ci' \
    && ok "$l: the WORKFLOW FILE reached origin — the work left the disk without any keychain" \
    || bad "$l: origin has no snapshot carrying the workflow file (ref: ${sha:-none})"
  r1="$(tail -1 "$f/shim/argv.1" 2>/dev/null)"; r2="$(tail -1 "$f/shim/argv.2" 2>/dev/null)"
  [ -n "$r1" ] && [ "$r1" = "$r2" ] \
    && ok "$l: both attempts push the SAME refspec (changing the credential cannot change WHAT is published)" \
    || bad "$l: the retry's refspec differs from the first push's ('${r1:-none}' vs '${r2:-none}')"
  # ⛔ THE STORED-CREDENTIAL RETRY MUST NOT TOUCH THE HELPER LIST (review round 2, P1). This arm's whole
  # claim is "same push, ambient token out of the way, the configured helper answers" — and the SHIPPED
  # bug was exactly `-c credential.helper=` clearing the configured chain, which leaves a cell with NO
  # credential at all. Without this assertion a mutant that re-adds that clear to `push_unshadowed` was
  # fully GREEN (measured: `PASS=108 FAIL=0`), i.e. the suite would certify the defect this PR fixes.
  if grep -q 'credential\.helper' "$f/shim/argv.2" 2>/dev/null; then
    bad "$l: the stored-credential retry touched the credential-helper list — it must leave the CONFIGURED helpers alone and remove only the ambient token: $(tr '\n' ' ' < "$f/shim/argv.2")"
  else
    ok "$l: the retry leaves git's CONFIGURED helpers alone (only the ambient token is removed — the shipped bug cleared them)"
  fi
  # ⛔ AND IT MAY NOT PROMPT (review round 2, P2). This branch is the one every cell takes, and it runs in
  # the second before a cap kill: an absent store entry must FAIL, not wait on a terminal nobody watches.
  grep -qx 'GIT_TERMINAL_PROMPT=0' "$f/shim/attempts.env.2" 2>/dev/null \
    && ok "$l: the retry ran with GIT_TERMINAL_PROMPT=0 (it cannot block the kill on a prompt)" \
    || bad "$l: the stored-credential retry did not disable the terminal prompt — a missing store entry could hang the rescue"
  assert_plain_untouched "$1" "$l"
  # ⛔ AND IT IS TIME-BOUNDED (review round 5, P2; SHARED with the helper path in round 6). The docblock
  # claims all three push functions carry "the same bounds"; deleting `bounded 45 ` from ANY of them was
  # green while only this arm measured it. The fixture records every `timeout` invocation, so two 45 s
  # bounds (first push + retry) must be present on EVERY path that retries.
  assert_bounded_arm "$1" "$l"
  for p in "$f/shim/argv.1" "$f/shim/argv.2"; do
    [ -f "$p" ] && grep -qE '^(\+|-f$|-[fF]$|--force)' "$p" 2>/dev/null && force=1
  done
  [ "$force" -eq 0 ] \
    && ok "$l: NEITHER attempt carries a force form (a forced rescue can overwrite a peer clone's snapshot)" \
    || bad "$l: an attempt used a FORCE form"
  # ⛔ AND THE STORED-CREDENTIAL PATH MAY NOT WRITE GIT CONFIG EITHER (review round 3, P2). This was
  # asserted only on the helper arm, so a `git config credential.helper store` planted in
  # `push_unshadowed` — a fixer "making the store answer" instead of removing the ambient token — was
  # fully GREEN, and the write persists on the machine that ran the suite. ALL SCOPES, via
  # `--show-origin`: a `--local` comparison cannot see a `$HOME/.gitconfig` write.
  [ "$(git -C "$f/wt" config --list --show-origin 2>/dev/null | sort)" = "$CFG_BEFORE" ] \
    && ok "$l: git config is byte-identical at EVERY scope after the retry (read-only rescue, global included)" \
    || bad "$l: the stored-credential rescue WROTE git config (any scope) — a rescue must not change the state it is rescuing"
  case "$OUT" in
    *osxkeychain*|*OSXKEYCHAIN*) bad "$l: claims the keychain credential on a host that has none — $OUT" ;;
    *"pushed with the STORED credential (the ambient GH_TOKEN/GITHUB_TOKEN was removed for that attempt) after the configured one was refused"*)
      ok "$l: the SUCCESS line names the credential that published it (the stored one, shadow removed)" ;;
    *) bad "$l: the success line does not name the credential used (the mid-run announce line does not count) — $OUT" ;;
  esac
}

if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
  skip "wfshadow: on macOS the DEFAULT candidate is osxkeychain — the unshadow mechanism is covered by wfunshadow there, and the Darwin default by wfhelper"
else
  try_rescue wfshadow wf_shadowed fix/lane-one \
    "-u BG_RESCUE_PUSH_HELPER -u BG_RESCUE_PUSH_UNSHADOW -u GITHUB_TOKEN GH_TOKEN=shadow-readonly-pat"
  assert_unshadow_arm wfshadow wfshadow 'GH_TOKEN=shadow-readonly-pat GITHUB_TOKEN=unset'
fi

# ⛔ THE CANDIDATE ASKED FOR BY NAME (`BG_RESCUE_PUSH_UNSHADOW=1`) — platform-independent, because it is
# the only route to the stored credential on macOS (where the default is unconditional) and a seam that
# only exists in a comment is not a seam.
# ⛔ EVERY `-u` COMES BEFORE EVERY ASSIGNMENT. POSIX `env` stops option parsing at the first non-option
# word, so `env -u A B=1 -u C cmd` tries to EXEC `-u` (rc 127) and the arm silently never runs — measured
# on this suite's own first draft of this line, which reported 7 reds whose first line was
# `env: '-u': No such file or directory`.
try_rescue wfunshadow wf_shadowed fix/lane-one \
  "-u BG_RESCUE_PUSH_HELPER -u BG_RESCUE_PUSH_UNSHADOW -u GITHUB_TOKEN BG_RESCUE_PUSH_UNSHADOW=1 GH_TOKEN=shadow-readonly-pat"
assert_unshadow_arm wfunshadow wfunshadow 'GH_TOKEN=shadow-readonly-pat GITHUB_TOKEN=unset'

# ⛔ THE macOS DEFAULT — EXECUTED ON EVERY HOST, NOT ONLY ON A MAC (review round 11, P2). This arm used to
# be gated on the real `uname`, so it SKIPPED everywhere CI runs and the branch it protects was unasserted
# where the gate lives: deleting `bg-rescue-wip.sh:393` left the suite at its baseline. The fixture now
# ships a `uname` stub, so `BG_TEST_UNAME_S=Darwin` runs the macOS branch here, on Linux, in CI.
# ⛔ AND IT RUNS WITH AN AMBIENT TOKEN SET (review round 7, P2). Without one, `osxkeychain` at the
# platform arm and the `unshadow` fall-through below it are INDISTINGUISHABLE — both return the same
# plan — so swapping those two lines (a plausible "check the token before the platform" tidy-up)
# reversed the proven macOS default and falsified the declared residual, with the suite fully GREEN on a
# clean machine (and red only if the developer happened to have GH_TOKEN exported). With the token set,
# `wf_then_ok` accepts a helper-named attempt and only that, so an inverted order cannot pass.
try_rescue wfhelper wf_then_ok fix/lane-one \
  "-u BG_RESCUE_PUSH_HELPER -u BG_RESCUE_PUSH_UNSHADOW -u GITHUB_TOKEN BG_TEST_UNAME_S=Darwin GH_TOKEN=shadow-readonly-pat"
assert_ambient_preserved wfhelper wfhelper
[ "$RC" -eq 0 ] && [ "${ATTEMPTS:-0}" = "2" ] \
  && ok "wfhelper: the Darwin default retries ONCE with a helper credential and rescues (exit 0, 2 attempts)" \
  || bad "wfhelper: rc=$RC attempts=${ATTEMPTS:-0} (want 0 and 2) — $OUT"
[ "${WHO:-}" = "plain keychain " ] \
  && ok "wfhelper: the retry selected the KEYCHAIN helper (the macOS default is not silently dropped)" \
  || bad "wfhelper: the Darwin default selected no helper credential — attempts were: ${WHO:-none}"
[ -n "$(ref_of "$T/wfhelper/origin.git" refs/wip/fix-lane-one)" ] \
  && ok "wfhelper: the snapshot reached origin" \
  || bad "wfhelper: nothing was published"

# ⛔ THE macOS DEFAULT IS UNCONDITIONAL — ASSERTED WITH NO AMBIENT TOKEN AT ALL (review round 8,
# P2). `wfhelper` sets a token, because that is what makes the candidate ORDER observable; the cost was
# that no Darwin-runnable arm exercised the branch in a CLEAN environment, so gating it on "a shadow
# exists" — a plausible tidy-up, given the header's own "one rule: unshadow only when there is something
# to unshadow" — silently removed the macOS retry for the ordinary Mac (no GH_TOKEN exported) and NO
# host could see it: green on Linux, green in the flipped run. This arm unsets every seam and both
# tokens and requires the retry anyway.
# It too is now forced through the `uname` stub rather than skipped on a non-Mac (review round 11, P2).
try_rescue wfhelper2 wf_then_ok fix/lane-one \
  "-u BG_RESCUE_PUSH_HELPER -u BG_RESCUE_PUSH_UNSHADOW -u GH_TOKEN -u GITHUB_TOKEN BG_TEST_UNAME_S=Darwin"
[ "$RC" -eq 0 ] && [ "${ATTEMPTS:-0}" = "2" ] \
  && ok "wfhelper2: on a Mac with NO ambient token and no seams, the default retry still runs (exit 0, 2 attempts)" \
  || bad "wfhelper2: rc=$RC attempts=${ATTEMPTS:-0} (want 0 and 2) — the macOS default became CONDITIONAL on an ambient token — $OUT"
[ "${WHO:-}" = "plain keychain " ] \
  && ok "wfhelper2: and it selected the keychain helper (the pre-PR behaviour, unchanged)" \
  || bad "wfhelper2: the macOS default is no longer unconditional — attempts were: ${WHO:-none}"

# ⛔ THE DOCUMENTED PRECEDENCE, PINNED (review round 2, P2). The header says the explicit helper "wins
# everywhere"; nothing observed it, so swapping the two `if` lines in `retry_credential` was GREEN. An
# operator who sets `BG_RESCUE_PUSH_HELPER=<store>` and inherits `BG_RESCUE_PUSH_UNSHADOW=1` from a
# wrapper must get the store they named. The stub accepts ONLY a helper-named attempt, so an inverted
# precedence lands on `exit 2` instead of a rescue.
try_rescue wfprecedence wf_then_ok fix/lane-one \
  "-u GITHUB_TOKEN BG_RESCUE_PUSH_HELPER=osxkeychain BG_RESCUE_PUSH_UNSHADOW=1 GH_TOKEN=shadow-readonly-pat"
assert_ambient_preserved wfprecedence wfprecedence
[ "$RC" -eq 0 ] && [ "${ATTEMPTS:-0}" = "2" ] \
  && ok "wfprecedence: the explicit HELPER wins over BG_RESCUE_PUSH_UNSHADOW=1 (exit 0, 2 attempts)" \
  || bad "wfprecedence: rc=$RC attempts=${ATTEMPTS:-0} (want 0 and 2) — the documented precedence is inverted — $OUT"
[ "${WHO:-}" = "plain keychain " ] \
  && ok "wfprecedence: the second attempt selected the named helper, not the unshadow candidate" \
  || bad "wfprecedence: the seam precedence is wrong — attempts were: ${WHO:-none}"

# ⛔ AND THE SEAM CANNOT BUY A DIFFERENT CREDENTIAL OUT OF NOTHING (review round 2, P2). With no ambient
# token to remove, `BG_RESCUE_PUSH_UNSHADOW=1` used to select an attempt BYTE-IDENTICAL to the one that
# just failed — with a message claiming a removal that never happened. It must now decline the retry.
# ⛔ NON-DARWIN ONLY, for the same reason `wfnocred` is: on macOS the DEFAULT candidate (osxkeychain)
# exists regardless of the seam, so "no retry is spent" is false there — the platform simulation caught
# this arm red on the macOS path, which is the exact class of false red round 1 was about.
if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
  skip "wfseammsgs: on macOS the default candidate is osxkeychain, so a retry IS available with no shadow to remove"
else
try_rescue wfseammsgs wf_always fix/lane-one \
  "-u BG_RESCUE_PUSH_HELPER -u GH_TOKEN -u GITHUB_TOKEN BG_RESCUE_PUSH_UNSHADOW=1"
[ "${ATTEMPTS:-0}" = "1" ] \
  && ok "wfseammsgs: with no ambient token, BG_RESCUE_PUSH_UNSHADOW=1 spends NO retry (it cannot differ)" \
  || bad "wfseammsgs: ${ATTEMPTS:-0} attempt(s) — a retry was spent removing a shadow that does not exist"
case "$OUT" in
  # ⛔ BOTH TENSES, AND THE RETRY'S OWN LINE (review round 6, P2). Only `retrying ONCE` (the attempt's
  # PRESENT-participle line) was matched, while the at-risk block renders a made retry as
  # `retried ONCE with … it ALSO failed:` — so hoisting `RETRIED=1` above the plan printed a
  # self-contradicting block ("retried ONCE … it ALSO failed" immediately above "no second credential was
  # tried") and BOTH properties reported as holds. Match the claim, not one tense.
  *"retrying ONCE"*|*"retried ONCE"*|*"ALSO failed"*)
    bad "wfseammsgs: claims a retry that was withheld — $OUT" ;;
  *) ok "wfseammsgs: claims no retry it did not make (neither tense, and no retry-outcome line)" ;;
esac
case "$OUT" in
  *UNSHADOW=1*) bad "wfseammsgs: recommends BG_RESCUE_PUSH_UNSHADOW=1 on the one host shape where it cannot help — $OUT" ;;
  *) ok "wfseammsgs: does not recommend the unshadow seam where it is guaranteed useless" ;;
esac
fi


# ⛔ THE OPERATOR'S HELPER NAME IS PART OF THE CONTRACT (review round 4, P1). Every other fixture pins
# `BG_RESCUE_PUSH_HELPER=osxkeychain`, which is ALSO the Darwin default — so hard-coding that name in
# `push_with_helper` was fully green while the message still named whatever the operator asked for. This
# arm names a different store and the stub accepts only that one.
try_rescue wfhelpername wf_then_store fix/lane-one \
  "-u BG_RESCUE_PUSH_UNSHADOW -u GH_TOKEN -u GITHUB_TOKEN BG_RESCUE_PUSH_HELPER=store"
assert_bounded_arm wfhelpername wfhelpername
assert_plain_untouched wfhelpername wfhelpername
assert_ambient_preserved wfhelpername wfhelpername
[ "$RC" -eq 0 ] && [ "${ATTEMPTS:-0}" = "2" ] \
  && ok "wfhelpername: a NON-DEFAULT helper named by the operator is used and the snapshot is rescued" \
  || bad "wfhelpername: rc=$RC attempts=${ATTEMPTS:-0} (want 0 and 2) — the named helper was not used — $OUT"
[ "$(cat "$T/wfhelpername/shim/attempts.helper.2" 2>/dev/null)" = "store" ] \
  && ok "wfhelpername: the retry ran with the helper the operator NAMED (not a hard-coded default)" \
  || bad "wfhelpername: the retry's helper was '$(cat "$T/wfhelpername/shim/attempts.helper.2" 2>/dev/null)' — a hard-coded default is not the operator's choice"
# ⛔ ON THE SUCCESS LINE, AND WITH THE WRONG-NAME EXCLUSION (review round 10, P2): the announce line also
# carries the name, and a run that used `store` could print "pushed with the osxkeychain credential" and
# stay green.
case "$OUT" in
  *"pushed with the store credential after the configured one was refused"*)
    ok "wfhelpername: the SUCCESS line names the credential that actually ran" ;;
  *) bad "wfhelpername: the success line does not name the operator's helper — $OUT" ;;
esac
case "$OUT" in
  *osxkeychain*|*OSXKEYCHAIN*) bad "wfhelpername: names the keychain credential although the operator named store — $OUT" ;;
  *) ok "wfhelpername: never claims a different credential than the one it ran" ;;
esac

# ⛔ THE OTHER HALF OF THE SHADOW PREDICATE (review round 4, P1): `GITHUB_TOKEN` alone. gh reads EITHER
# variable, and cell/CI setups often export only this one; dropping `-u GITHUB_TOKEN`, or narrowing the
# predicate to `GH_TOKEN` alone, was green with only `GH_TOKEN` exercised.
# ⛔ AND IT ASKS FOR THE CANDIDATE BY NAME, so it is platform-NEUTRAL: on macOS the DEFAULT is
# `osxkeychain`, and an arm that relied on the default would be a false red there — the exact defect
# rounds 1 and 3a each fixed. `BG_RESCUE_PUSH_UNSHADOW=1` (conditional on an ambient token, which this
# arm sets) is what makes the unshadow path run on every host.
try_rescue wfshadow2 wf_shadowed fix/lane-one \
  "-u BG_RESCUE_PUSH_HELPER -u GH_TOKEN BG_RESCUE_PUSH_UNSHADOW=1 GITHUB_TOKEN=shadow-readonly-pat"
assert_unshadow_arm wfshadow2 wfshadow2 'GH_TOKEN=unset GITHUB_TOKEN=shadow-readonly-pat'

# ⛔ AND THE **DEFAULT**-PATH UNShadow BRANCH NEEDS ITS OWN `GITHUB_TOKEN` ARM (review round 5, P1).
# `wfshadow2` reaches the candidate through the SEAM (`:392`); the `GITHUB_TOKEN` term of the platform
# default (`:394`) — the branch every Linux cell actually takes — had no coverage at all, so narrowing
# it to `GH_TOKEN` alone was fully green while the run then told the operator there was "no ambient
# GH_TOKEN/GITHUB_TOKEN to unshadow" on a host that exports one. This arm is the same shape with NO
# seam, and (like its sibling) it is non-Darwin only: on macOS the default is `osxkeychain`.
if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
  skip "wfshadow3: on macOS the DEFAULT candidate is osxkeychain — the default-path GITHUB_TOKEN term only exists on non-Darwin hosts"
else
  try_rescue wfshadow3 wf_shadowed fix/lane-one \
    "-u BG_RESCUE_PUSH_HELPER -u BG_RESCUE_PUSH_UNSHADOW -u GH_TOKEN GITHUB_TOKEN=shadow-readonly-pat"
  assert_unshadow_arm wfshadow3 wfshadow3 'GH_TOKEN=unset GITHUB_TOKEN=shadow-readonly-pat'
fi

# ⛔ THE STORED-CREDENTIAL RETRY'S **FAILURE** BRANCH HAD NO ARM AT ALL (review round 10, P0). Every
# unshadow fixture used `wf_shadowed`, which accepts once the ambient token is gone, and
# `assert_unshadow_arm` hard-requires `RC=0` — so `push_unshadowed`'s `else` was unreachable, and a
# mutant that reported PUSHED=1 over a REFUSED stored-credential retry ("rescued … pushed with the STORED
# credential", exit 0, nothing on origin) was fully green: the one outcome this tool exists to prevent.
# This is also the shape of the PR's own declared residual (i) — a `store`/`cache` host whose helper never
# read the ambient token — where the retry MUST fail. `wf_always` refuses every attempt.
try_rescue wfunshadowfail wf_always fix/lane-one \
  "-u BG_RESCUE_PUSH_HELPER -u BG_RESCUE_PUSH_UNSHADOW -u GITHUB_TOKEN BG_RESCUE_PUSH_UNSHADOW=1 GH_TOKEN=shadow-readonly-pat"
[ "$RC" -eq 2 ] \
  && ok "wfunshadowfail: a REFUSED stored-credential retry exits 2 (never a cheerful 0)" \
  || bad "wfunshadowfail: rc=$RC (want 2) — a refused stored-credential retry was reported as a rescue — $OUT"
[ "${ATTEMPTS:-0}" = "2" ] \
  && ok "wfunshadowfail: both attempts ran (the retry is the thing being refused)" \
  || bad "wfunshadowfail: ${ATTEMPTS:-0} attempt(s) (want 2)"
[ -z "$(ref_of "$T/wfunshadowfail/origin.git" refs/wip/fix-lane-one)" ] \
  && ok "wfunshadowfail: nothing reached origin, so the exit 2 is true" \
  || bad "wfunshadowfail: a ref landed on origin while the run reported failure"
case "$OUT" in
  *"rescued"*) bad "wfunshadowfail: claimed a rescue that did not happen — $OUT" ;;
  *) ok "wfunshadowfail: does not claim a rescue it did not perform" ;;
esac
case "$OUT" in
  *"ALSO failed"*) ok "wfunshadowfail: reports the retry's own outcome" ;;
  *) bad "wfunshadowfail: says nothing about the retry's own failure — $OUT" ;;
esac
case "$OUT" in
  *"no second credential was tried"*)
    bad "wfunshadowfail: also claims there was no second credential, although it retried — two mutually exclusive diagnoses — $OUT" ;;
  *) ok "wfunshadowfail: does not also claim there was no second credential" ;;
esac
case "$OUT" in
  *"STILL ONLY ON THIS DISK"*) ok "wfunshadowfail: still says the work is on this disk only" ;;
  *) bad "wfunshadowfail: the at-risk warning is missing — $OUT" ;;
esac

# ⛔ A RETRIED RESCUE THAT IS STILL PARTIAL MUST EXIT 2 (review round 4, P2). The partial-archive guard
# was pinned only on a NON-retried rescue, so `if [ "${#SKIPPED[@]}" -gt 0 ] && [ "$RETRIED" -eq 0 ]` — a
# snapshot that touches `.github/workflows` AND carries an unarchivable path reporting exit 0 while a
# path is still only on disk — was fully green. That combination is newly reachable: this PR is what
# makes a retried push succeed.
mk_repo wfpartial || { echo "❌ fixture failed (wfpartial)"; exit 1; }
P2="$T/wfpartial"
mkdir -p "$P2/wt/.github/workflows"
printf 'name: ci\non: push\n' > "$P2/wt/.github/workflows/ci.yml"
printf 'the work that must survive\n' > "$P2/wt/lane-work.txt"
mkdir -p "$P2/wt/extra"; git -C "$P2/wt/extra" init -q 2>/dev/null   # nested repo, unborn HEAD
printf 'inner\n' > "$P2/wt/extra/inner.txt"
mk_pushshim "$P2/shim" wf_then_ok fix-lane-one || echo "❌ shim failed (wfpartial)"
OUT="$(env -u GIT_TERMINAL_PROMPT -u BG_RESCUE_PUSH_UNSHADOW -u GH_TOKEN -u GITHUB_TOKEN \
  GIT_TERMINAL_PROMPT=1 BG_RESCUE_PUSH_HELPER=osxkeychain \
  PATH="$P2/shim:$PATH" bash "$RR" "$P2/wt" "workflow-bearing and partial" 2>&1)"; RC=$?
PATT=0; [ -f "$P2/shim/attempts" ] && PATT="$(cat "$P2/shim/attempts")"
[ "$PATT" = "2" ] \
  && ok "wfpartial: the retry DID run (2 attempts), so this arm is about the partial guard and not the gate" \
  || bad "wfpartial: ${PATT} attempt(s) (want 2) — the refusal gate did not fire, so the arm proves nothing"
[ "$RC" -eq 2 ] \
  && ok "wfpartial: a RETRIED rescue that still skipped a path exits 2 (not a cheerful 0)" \
  || bad "wfpartial: rc=$RC (want 2) — a retried PARTIAL archive was reported as a complete rescue"
case "$OUT" in
  *"the rescue above is PARTIAL"*) ok "wfpartial: the PARTIAL line is still printed after a retried push" ;;
  *) bad "wfpartial: the partial warning is missing — $OUT" ;;
esac

# ⛔ AND NO CANDIDATE CAN BE A DIFFERENT CREDENTIAL, THERE IS NO RETRY. A second attempt carrying the
# credential the remote just refused cannot succeed, and in the second before a cap kill it costs a
# 45 s bound to re-learn what the first attempt said. What must NOT happen is that the run reads like "a
# credential was rejected": the operator's action differs — supply one, via the documented seam.
if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
  skip "wfnocred: the default candidate on macOS IS osxkeychain, so the no-second-credential arm cannot run here"
else
  try_rescue wfnocred wf_always fix/lane-one \
    "-u BG_RESCUE_PUSH_HELPER -u BG_RESCUE_PUSH_UNSHADOW -u GH_TOKEN -u GITHUB_TOKEN"
  [ "$RC" -eq 2 ] \
    && ok "wfnocred: exit 2 — still an honest local-only failure when there is nothing else to try" \
    || bad "wfnocred: exit $RC (want 2) — $OUT"
  [ "${ATTEMPTS:-0}" = "1" ] \
    && ok "wfnocred: exactly ONE attempt — no retry is spent re-sending the refused credential" \
    || bad "wfnocred: ${ATTEMPTS:-0} attempt(s) — a retry was spent on a credential that cannot differ"
  [ -z "$(ref_of "$T/wfnocred/origin.git" refs/wip/fix-lane-one)" ] \
    && ok "wfnocred: nothing was published, so the exit 2 is true" \
    || bad "wfnocred: a ref landed on origin while the run reported failure"
  case "$OUT" in
    *"cause: WORKFLOW SCOPE"*) ok "wfnocred: still names WHY (workflow scope), not a bare 'push failed'" ;;
    *) bad "wfnocred: the failure does not name its cause — $OUT" ;;
  esac
  case "$OUT" in
    *"no second credential was tried"*) ok "wfnocred: says there was NO second credential (a different operator action from 'the retry failed')" ;;
    *) bad "wfnocred: does not tell the operator that nothing else was tried — $OUT" ;;
  esac
  case "$OUT" in
    *"BG_RESCUE_PUSH_HELPER"*) ok "wfnocred: names the seam that supplies one, instead of leaving the operator to guess" ;;
    *) bad "wfnocred: names no way to supply a credential — $OUT" ;;
  esac
  case "$OUT" in
    # ⛔ BOTH TENSES AND THE RETRY'S OWN LINE (review round 6, P2) — see the sibling arm above: matching
    # only `retrying ONCE` let `retried ONCE with … it ALSO failed:` print beside "no second credential
    # was tried" while this property stayed green.
    *"retrying ONCE"*|*"retried ONCE"*|*"ALSO failed"*)
      bad "wfnocred: claims a retry that was deliberately not made — $OUT" ;;
    *) ok "wfnocred: does not claim a retry it did not make (neither tense, and no retry-outcome line)" ;;
  esac
  # ⛔ AND IT MUST NOT CLAIM A REMOVAL EITHER (review round 10, P3; hardened in round 12, P3), in ANY
  # INFLECTION OR CASE. "Does not claim a retry it did not make" covers the attempt; it says nothing about
  # the MECHANISM, so this message could grow "the ambient GH_TOKEN/GITHUB_TOKEN was removed for that
  # attempt" — on the one path where NOTHING was unset, no `env -u` ran, and no second credential exists
  # — and the suite stayed green (measured: PASS=162 FAIL=0, identical to a correct tree). That is the
  # false mechanism claim this script's own push_unshadowed docblock calls the worst kind, landing in the
  # block an operator reads while the work is still single-copy on disk.
  # ⛔ THE FIRST FIX MATCHED ONE SPELLING (`*[Rr]emoved*`) AND THAT WAS STILL TOO NARROW (round 12): this
  # script writes its emphatic claims in CAPS, so `…was REMOVED for that attempt` and
  # `Its removal of the ambient token was skipped` both stayed FULLY GREEN (measured PASS=182 FAIL=0 for
  # each). `grep -qi 'remov'` covers removed/REMOVED/removal/Removal/removes; the stem has no other
  # meaning in this output, and the honest line on this path says "no ambient GH_TOKEN/GITHUB_TOKEN **to
  # unshadow**" — a statement of absence, not a claim of action — so matching the stem cannot false-red
  # a correct tree (verified against the unmutated run below).
  if grep -qi 'remov' <<<"$OUT"; then
    bad "wfnocred: claims a credential was REMOVED on the path where nothing was tried — $(printf '%s\n' "$OUT" | grep -i 'remov' | head -1)"
  else
    ok "wfnocred: claims no removal, in any spelling — nothing was unset on the path where no retry was made"
  fi
  case "$OUT" in
    *"STILL ONLY ON THIS DISK"*) ok "wfnocred: still says the work is on this disk only (never a cheerful exit)" ;;
    *) bad "wfnocred: the at-risk warning is missing — $OUT" ;;
  esac
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
      if (line ~ /(^|[^_[:alnum:]_])(echo|printf|log_line|log)[[:space:]]/) next   # a usage/message line
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
      if (line ~ /(^|[^_[:alnum:]_])(echo|printf|log_line|log)[[:space:]]/) next
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

echo; echo "── the REF CARRIES ITS ISSUE, or says it does not (#3484) ──"
# ⛔ Measured 2026-11-05: 222 rescued refs/wip archives existed on origin and nothing told the next
# actor to look, because a ref named from the branch (`fix-3484-x`) is not reliably mappable to an
# issue. A rescue that cannot be found is a rescue that happens twice.
mk_repo wipissue fix/4242-first-attempt || { echo "❌ fixture failed (wipissue)"; exit 1; }
printf 'half-finished work\n' >> "$T/wipissue/wt/base.txt"
OUT="$(bash "$RR" "$T/wipissue/wt" "test" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "issue-link: exit 0 (rescued)" || bad "issue-link: exit $RC (want 0) — $OUT"
case "$OUT" in
  *"refs/wip/issue-4242-first-attempt"*) ok "issue-link: the pushed ref NAME carries the issue (refs/wip/issue-4242-first-attempt)" ;;
  *) bad "issue-link: the ref does not carry the issue — got: $OUT" ;;
esac
[ -n "$(ref_of "$T/wipissue/origin.git" refs/wip/issue-4242-first-attempt)" ] \
  && ok "issue-link: …and it really exists on ORIGIN under that name (verified, not echoed)" \
  || bad "issue-link: no refs/wip/issue-4242-first-attempt on origin"
case "$OUT" in
  *"NO ISSUE LINK"*) bad "issue-link: a branch that NAMES an issue was reported as UNLINKED (the rule matched nothing)" ;;
  *) ok "issue-link: a branch that names an issue is NOT reported as unlinked (no false alarm)" ;;
esac
# …and the other direction: a branch with no issue in it is rescued anyway — and SAYS it carries no
# issue link, because a silent unlinked ref is the failure the issue was filed for.
mk_repo wipnolink fix/lane-two || { echo "❌ fixture failed (wipnolink)"; exit 1; }
printf 'more work\n' >> "$T/wipnolink/wt/base.txt"
OUT="$(bash "$RR" "$T/wipnolink/wt" "test" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "unlinked: a branch with no issue is STILL rescued (losing the work is worse)" || bad "unlinked: exit $RC (want 0) — $OUT"
case "$OUT" in
  *"refs/wip/fix-lane-two CARRIES NO ISSUE LINK"*) ok "unlinked: …and the run REPORTS that the ref carries no issue link (not silently ignored)" ;;
  *) bad "unlinked: an unlinked ref was pushed silently — got: $OUT" ;;
esac
[ -n "$(ref_of "$T/wipnolink/origin.git" refs/wip/fix-lane-two)" ] \
  && ok "unlinked: …the old (branch-named) ref still travels, so nothing is lost by the new naming" \
  || bad "unlinked: the rescue did not travel under the branch-named ref"

# ── --verdict: the READ-ONLY mode `scripts/wip-sweep.sh` classifies with (agent-infra#3485) ─────────
# ⛔ THIS SUITE OWNS THE CONTRACT, so the mode is pinned HERE and not only in its consumer's suite: an
# edit to THIS file that broke `--verdict` would otherwise be seen only by a suite about a different
# script, and the sweep would silently archive nothing while reporting a clean fleet (its `clean`
# verdict is the one answer that costs work). The properties: one machine-readable line, 0/1/2 for
# clean/dirty/cannot-verify, NO `paths=` on cannot-verify (an unknown count is not zero), and the
# ordinary mode's exit codes untouched.
echo; echo "── --verdict: the read-only classifier ──"
mk_repo vd || { echo "❌ fixture failed (vd)"; exit 1; }
V="$T/vd"
OVO="$(bash "$RR" --verdict "$V/wt" 2>&1)"; RCVO=$?
case "$RCVO:$OVO" in
  0:*verdict=clean*) ok "V1 a clean tree is verdict=clean, exit 0" ;;
  *) bad "V1 clean verdict wrong (rc=$RCVO): $OVO" ;;
esac
printf 'wip\n' >> "$V/wt/base.txt"; printf 'new\n' > "$V/wt/new.txt"
OVO="$(bash "$RR" --verdict "$V/wt" 2>&1)"; RCVO=$?
case "$RCVO:$OVO" in
  1:*verdict=dirty*paths=2*) ok "V2 a dirty tree is verdict=dirty paths=2, exit 1" ;;
  *) bad "V2 dirty verdict wrong (rc=$RCVO): $OVO" ;;
esac
case "$OVO" in
  *" slug=fix-lane-one"*) ok "V3 the verdict carries the file's OWN slug, so a caller never re-derives the ref name" ;;
  *) bad "V3 the verdict did not carry slug=: $OVO" ;;
esac
# ⛔ THE ISSUE TRAVELS WITH THE SLUG, FROM THE SAME DERIVATION (review finding P2). `wip_ref_parts`
# already answers "which issue does this branch name" to build the ref, so `--verdict` reports that
# answer instead of letting every caller re-derive it — a second rule disagreed with the ref in both
# directions (`fix/lane-3485` claimed 3485 over a ref carrying none; `fix/1-x` claimed nothing over a
# ref carrying `issue-1-x`). V3b pins that the two fields AGREE; V3c pins the non-typed branch says `-`.
case "$OVO" in
  *" issue=-"*) ok "V3b an untyped branch reports issue=- (the field exists, and claims no link)" ;;
  *) bad "V3b the verdict carries no issue= field: $OVO" ;;
esac
mk_repo viss fix/4242-vissue || { echo "❌ fixture failed (viss)"; exit 1; }
printf 'wip\n' >> "$T/viss/wt/base.txt"
OVO="$(bash "$RR" --verdict "$T/viss/wt" 2>&1)"; RCVO=$?
case "$OVO" in
  *" slug=issue-4242-vissue issue=4242"*)
    ok "V3c a typed branch reports slug=issue-4242-vissue AND issue=4242 — one derivation supplies both" ;;
  *) bad "V3c slug= and issue= disagree with each other: $OVO" ;;
esac
# The mode must not archive: no ref may exist after a verdict run on a dirty tree.
[ -z "$(ref_of "$V/origin.git" refs/wip/fix-lane-one)" ] \
  && ok "V4 --verdict archived NOTHING (it returns before §3: no tree, no commit, no push)" \
  || bad "V4 --verdict pushed a ref — the read-only mode is not read-only"
# ⛔ THE ARM THAT MATTERS: an INCOMPLETE enumeration is cannot-verify, and it carries NO path count.
if [ "$(id -u)" = "0" ]; then
  skip "V5/V6 an unreadable directory cannot be simulated as root — the cannot-verify arm is UNPROVEN here"
else
  mkdir -p "$V/wt/locked" && printf 'x\n' > "$V/wt/locked/f.txt" && chmod 000 "$V/wt/locked"
  OVO="$(bash "$RR" --verdict "$V/wt" 2>&1)"; RCVO=$?
  chmod 755 "$V/wt/locked"
  [ "$RCVO" -eq 2 ] && case "$OVO" in *verdict=cannot-verify*) true ;; *) false ;; esac \
    && ok "V5 an INCOMPLETE enumeration is verdict=cannot-verify, exit 2 — never clean" \
    || bad "V5 an unreadable directory was not cannot-verify (rc=$RCVO): $OVO"
  case "$OVO" in
    *paths=*) bad "V6 cannot-verify carried a paths= field: $OVO" ;;
    *) ok "V6 cannot-verify carries NO paths= (an unenumerated tree has no count — 0 would read as clean)" ;;
  esac
fi
# The shipped ordinary contract must not move: same path, plain mode, still exit 1.
bash "$RR" "$V/origin.git" >/dev/null 2>&1; RCVO=$?
[ "$RCVO" -eq 1 ] \
  && ok "V7 plain mode still exits 1 for a non-worktree — the mode is ADDITIVE, no shipped code moved" \
  || bad "V7 plain-mode exit code moved for a non-worktree (rc=$RCVO, want 1)"

# ── V8/V9: NO REFUSAL MAY ANSWER WITH A VERDICT CODE (review finding P2) ────────────────────────
# `0` means clean and `1` means dirty in this mode, so an invocation that answered NOTHING must not
# exit 0 or 1 — an exit-code reader would read a verdict out of a refusal. Both were measured on the
# rebased tree: `--verdict --slug fix/x` fell through to the --slug branch and exited 0 ("clean"), and
# `--verdict` with no path died on `${1:?}` with 1 ("dirty").
OVO="$(bash "$RR" --verdict --slug fix/3485-x 2>&1)"; RCVO=$?
[ "$RCVO" -eq 2 ] \
  && ok "V8a --verdict --slug is REFUSED with 2 (the modes are exclusive, not silently re-ordered)" \
  || bad "V8a --verdict --slug exited $RCVO (want 2 — 0 would read as 'clean'): $OVO"
case "$OVO" in
  *verdict=*) bad "V8b the refusal still printed a verdict= line: $OVO" ;;
  *) ok "V8b …and it prints no verdict= line, so nothing can read it as an answer" ;;
esac
bash "$RR" --verdict >/dev/null 2>&1; RCVO=$?
[ "$RCVO" -eq 2 ] \
  && ok "V9 a MISSING ARGUMENT under --verdict exits 2 (cannot-verify), never 1 (= dirty)" \
  || bad "V9 --verdict with no path exited $RCVO (want 2, never 1)"
bash "$RR" >/dev/null 2>&1; RCVO=$?
[ "$RCVO" -eq 1 ] \
  && ok "V9b …while the ORDINARY mode keeps its shipped exit 1 for a missing argument" \
  || bad "V9b plain-mode missing-argument exit moved (rc=$RCVO, want 1)"

# ⛔ V10 — A SUBDIRECTORY OF A WORKTREE IS NOT A WORKTREE ROOT (#3588 review, cycle 8). The
# `vunmeasured "not a worktree root: …"` branch had NO arm: the mutation pass reverted it to `exit 1` and
# both suites stayed at 206/0, so in verdict mode a misrouted path would have reported `dirty` — the
# caller then "archives" nothing, and `dirty` is the answer this file exists to stop being wrong.
# `rev-parse --git-dir` succeeds ANYWHERE inside a repo, which is exactly why this branch must exist and
# must be graded: nothing else in the suite constructs that input.
mk_repo subroot || { echo "❌ fixture failed (subroot)"; exit 1; }
mkdir -p "$T/subroot/wt/sub/deeper" || { echo "❌ could not make the subdirectory"; exit 1; }
echo work > "$T/subroot/wt/sub/deeper/file.txt"
OVO="$(bash "$RR" --verdict "$T/subroot/wt/sub" 2>&1)"; RCVO=$?
[ "$RCVO" -eq 2 ] && case "$OVO" in *verdict=cannot-verify*) true ;; *) false ;; esac \
  && ok "V10 a SUBDIRECTORY answers verdict=cannot-verify, exit 2 — never dirty, never clean" \
  || bad "V10 a subdirectory of a worktree answered rc=$RCVO (want 2 = cannot-verify): $OVO"
case "$OVO" in
  *"not a worktree root"*) ok "V10b …and it SAYS it is not a root, so the caller knows to pass the root" ;;
  *) bad "V10b the refusal does not name 'not a worktree root': $OVO" ;;
esac
# the ordinary mode keeps its shipped exit 1 for the same path (no shipped code moved)
bash "$RR" "$T/subroot/wt/sub" >/dev/null 2>&1; RCVO=$?
[ "$RCVO" -eq 1 ] \
  && ok "V10c plain mode still exits 1 for a subdirectory — the mode is ADDITIVE" \
  || bad "V10c plain-mode exit moved for a subdirectory (rc=$RCVO, want 1)"

echo; echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
if [ "$SKIP" -gt 0 ]; then
  echo "  ✅ contract holds — but $SKIP arm(s) SKIPPED (not passed). Re-run with BG_DISPATCH=<path> for the full set."
else
  echo "  ✅ contract holds (all $PASS arms ran, nothing skipped)"
fi
